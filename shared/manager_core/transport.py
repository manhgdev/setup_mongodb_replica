import json
import os
import sys
import shlex
import selectors
import subprocess
import time
from pathlib import Path


def run_worker(machine, worker, payload, elevated, emit):
    if machine["mode"] == "local":
        cmd = [sys.executable, "-u", str(worker)]
        if elevated and os.geteuid() != 0:
            cmd = ["sudo", "-n", *cmd]
    else:
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-p", str(machine["port"])]
        if machine.get("fresh_key"):
            cmd += ["-o", "ControlPath=none", "-o", "PreferredAuthentications=publickey"]
        if machine.get("identity"):
            cmd += ["-i", str(Path(machine["identity"]).expanduser())]
        # Send source through stdin. SSH multiplexers impose a small command-size limit.
        payload["_worker"] = worker.read_text()
        loader = ("import json,sys; request=json.load(sys.stdin); scope={'__name__':'host_worker'}; "
                  "exec(compile(request.pop('_worker'),'host_worker.py','exec'),scope); scope['serve'](request)")
        remote = ["python3", "-u", "-c", loader]
        if elevated and machine["user"] != "root":
            remote = ["sudo", "-n", *remote]
        if machine.get("ssh_auth") == "password":
            from shared.manager_core.ssh_transport import run_password
            return run_password(machine, shlex.join(remote), payload, emit)
        cmd += [machine["user"] + "@" + machine["host"], shlex.join(remote)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    # Payload includes secrets, sent only through stdin (SSH encrypts transport).
    try:
        with proc.stdin:
            proc.stdin.write(json.dumps(payload))
    except BrokenPipeError:
        # A failed SSH connection can close stdin before the source upload finishes.
        # Drain stderr below to report the host-key, authentication or sudo error.
        pass
    result = None
    error = None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    selector.register(proc.stderr, selectors.EVENT_READ)
    start = time.monotonic()
    try:
        while selector.get_map():
            if time.monotonic() - start > 7500:
                raise TimeoutError("Tác vụ quá thời gian; kiểm tra máy đích trước khi thử lại.")
            for key, _ in selector.select(timeout=1):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                if key.fileobj is proc.stderr:
                    # No remote raw stderr (might contain secrets); give useful SSH hints.
                    if any(s in line for s in ("Host key verification failed", "Permission denied", "password is required", "Connection refused", "Could not resolve")):
                        error = "SSH/sudo chưa sẵn sàng. Kiểm tra known_hosts, SSH key và quyền sudo không hỏi mật khẩu."
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "event" in message:
                    emit(message["event"])
                if "error" in message:
                    error = message["error"]
                if "result" in message:
                    result = message["result"]
        if proc.wait(timeout=10) != 0 or result is None:
            raise RuntimeError(error or "Worker thất bại. Kiểm tra SSH, sudo, Python 3 và công cụ trên máy đích.")
        return result
    finally:
        selector.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()
