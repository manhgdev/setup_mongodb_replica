"""Single-file worker sent over SSH. Credentials arrive only via stdin."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import time
from uuid import uuid4


def run(*args, **kwargs):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, timeout=25, **kwargs)


def require(*args, message):
    result = run(*args)
    if result.returncode:
        raise ValueError(message)
    return result.stdout


def effective(user, connection):
    addr, _, local, port = connection.split()
    terms = f"user={user},host={addr},addr={addr},laddr={local},lport={port}"
    output = require("/usr/sbin/sshd", "-T", "-C", terms, message="Không đọc được chính sách sshd.")
    return dict(line.split(" ", 1) for line in output.splitlines() if " " in line)


def execute(action, p):
    actual = pwd.getpwuid(os.getuid()).pw_name
    if action == "identity":
        connection = os.environ.get("SSH_CONNECTION", "")
        sudo = os.getuid() == 0 or bool(shutil.which("sudo") and run("sudo", "-n", "true").returncode == 0)
        return dict(user=actual, connection=connection, sudo=sudo, hostname=os.uname().nodename[:63])
    user = p["user"]
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_-]{0,63}", user):
        raise ValueError("User không hợp lệ.")
    if action == "policy":
        policy = effective(user, p["connection"])
        return {"password":policy.get("passwordauthentication"), "pubkey":policy.get("pubkeyauthentication")}
    if os.getuid() != 0 or pwd.getpwnam(user).pw_uid == 0:
        raise ValueError("Cần sudo và tài khoản SSH thường.")
    state = Path("/run/zm-manager-ssh")
    state.mkdir(mode=0o700,exist_ok=True)
    with (state/"lock").open("a") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        pending = state/"pending"
        if action == "commit":
            if not pending.exists() or pending.read_text()!=p["ticket"]:
                raise ValueError("Đã hết thời gian xác minh. Kiểm tra lại cấu hình SSH.")
            unit = "zm-ssh-"+p["ticket"]
            require("systemctl","stop",unit+".timer",message="Không dừng được timer rollback.")
            pending.unlink()
            return {"verified":True}
        if action!="change" or pending.exists():
            raise ValueError("VPS đang chờ xác minh SSH.")
        secret = p["password"]
        if not secret or any(ch in secret for ch in "\r\n\x00"):
            raise ValueError("Mật khẩu không hợp lệ.")
        set_root = bool(p.get("set_root"))
        policy = effective(user,p["connection"]) if p["enable"] else {}
        root_policy = effective("root",p["connection"]) if (p["enable"] and set_root) else {}
        targets = [(user, secret)] + ([("root", secret)] if set_root else [])
        result = run("chpasswd",input="".join(f"{u}:{pw}\n" for u, pw in targets))
        if result.returncode:
            raise ValueError("PAM từ chối đặt mật khẩu Linux.")
        print(json.dumps({"event":"Đã đặt mật khẩu Linux cho "+(f"{user} và root" if set_root else user)}),flush=True)
        need_user_ssh = p["enable"] and policy.get("passwordauthentication")!="yes"
        need_root_ssh = p["enable"] and set_root and (root_policy.get("passwordauthentication")!="yes" or root_policy.get("permitrootlogin")!="yes")
        if not need_user_ssh and not need_root_ssh:
            return {"changed":True}
        service = next((s for s in ("ssh.service","sshd.service") if run("systemctl","is-active","--quiet",s).returncode==0),None)
        if not service:
            raise ValueError("Đã đặt mật khẩu Linux. Không tìm thấy dịch vụ SSH đang chạy.")
        config = Path("/etc/ssh/sshd_config")
        if config.is_symlink():
            raise ValueError("Cần kiểm tra thủ công đích symlink sshd_config.")
        ticket = uuid4().hex
        backup = state/("sshd_config-"+ticket)
        shutil.copy2(config,backup)
        unit = "zm-ssh-"+ticket
        rescue = ('exec 9>"$1/lock"; flock 9; [ "$(cat "$1/pending" 2>/dev/null)" = "$2" ] || exit 0; '
                  'cp --preserve=all "$1/sshd_config-$2" /etc/ssh/sshd_config && '
                  '/usr/sbin/sshd -t && systemctl reload "$3" && rm "$1/pending"')
        # Arm recovery before editing the configuration or reloading the service.
        require("systemd-run","--unit",unit,"--on-active=150s","/bin/sh","-ec",rescue,
                "rollback",str(state),ticket,service,message="Không tạo được timer rollback trên VPS.")
        pending.write_text(ticket)
        try:
            with config.open("a") as output:
                if need_user_ssh:
                    output.write(f"\n# ZM VPS Manager\nMatch User {user}\n    PasswordAuthentication yes\n")
                if need_root_ssh:
                    output.write("\n# ZM VPS Manager (root)\nMatch User root\n    PermitRootLogin yes\n    PasswordAuthentication yes\n")
            require("/usr/sbin/sshd","-t",message="sshd -t thất bại.")
            checked = effective(user,p["connection"])
            if checked.get("passwordauthentication")!="yes" or checked.get("pubkeyauthentication")!="yes":
                raise ValueError("Chính sách SSH hiệu lực xung đột.")
            require("systemctl","reload",service,message="Reload SSH thất bại.")
        except Exception:
            shutil.copy2(backup,config)
            require("systemctl","reload",service,message="Timer sẽ thử phục hồi SSH.")
            pending.unlink()
            raise
        return {"changed":True,"ticket":ticket}


def serve(request):
    try:
        result = execute(request["action"],request["params"])
        if request["action"]=="change" and result.get("ticket"):
            ticket=result.pop("ticket")
            print(json.dumps({"event":"verify-ticket:"+ticket}),flush=True)
            # Keep the authenticated control session alive while the manager opens
            # independent key and password sessions and commits the transaction.
            deadline=time.monotonic()+155
            pending=Path("/run/zm-manager-ssh/pending")
            while pending.exists() and time.monotonic()<deadline:
                time.sleep(.25)
        print(json.dumps({"result":result}),flush=True)
    except Exception as exc:
        message = str(exc) if isinstance(exc,ValueError) else "Worker tài khoản thất bại. Kiểm tra sudo và công cụ hệ thống."
        print(json.dumps({"error":message}),flush=True)
        sys.exit(1)


if __name__=="__main__":
    serve(json.load(sys.stdin))
