"""Password SSH transport; credentials stay in memory and never enter argv."""
import base64
import codecs
import hashlib
import fcntl
import os
import socket
import json
import select
import time
from pathlib import Path

import paramiko


def fingerprint(key):
    digest = hashlib.sha256(key.asbytes()).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def probe_host_key(machine):
    """Negotiate SSH without authenticating or sending the saved password."""
    try:
        with socket.create_connection((machine["host"], machine["port"]), timeout=10) as sock:
            with paramiko.Transport(sock) as transport:
                transport.start_client(timeout=15)
                return transport.get_remote_server_key()
    except (OSError, EOFError, paramiko.SSHException) as exc:
        raise ValueError("Không đọc được khóa SSH. Kiểm tra địa chỉ, cổng SSH và kết nối VPS.") from exc


def enroll_host_key(machine, expected):
    key = probe_host_key(machine)
    if fingerprint(key) != expected:
        raise ValueError("Fingerprint đã đổi. Đọc lại khóa và đối chiếu với console VPS.")
    host = machine["host"] if machine["port"] == 22 else f'[{machine["host"]}]:{machine["port"]}'
    remember_host_key(host, key)


def remember_host_key(host, key):
    folder = Path.home() / ".ssh"
    folder.mkdir(mode=0o700, exist_ok=True)
    path = folder / "known_hosts"
    with os.fdopen(os.open(path, os.O_CREAT | os.O_RDWR | os.O_APPEND, 0o600), "a+b") as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        system = Path("/etc/ssh/ssh_known_hosts")
        already_known = False
        for source in (path, system):
            if source.is_file():
                entries = paramiko.HostKeys(str(source)).lookup(host)
                if entries:
                    if entries.get(key.get_name()) != key:
                        raise ValueError("Máy đã có khóa SSH khác. Đối chiếu với console VPS trước khi thay khóa.")
                    already_known = True
        if already_known:
            return
        output.seek(0, os.SEEK_END)
        if output.tell():
            output.seek(-1, os.SEEK_END)
            if output.read(1) != b"\n":
                output.write(b"\n")
        output.write(f"{host} {key.get_name()} {key.get_base64()}\n".encode())
        output.flush()


class RememberNewKey(paramiko.MissingHostKeyPolicy):
    def missing_host_key(self, client, hostname, key):
        # Persist the key from this handshake before sending the SSH password.
        try:
            remember_host_key(hostname, key)
        except OSError as exc:
            raise RuntimeError(f"Không lưu được khóa SSH của {hostname} vào ~/.ssh/known_hosts. "
                               "Kiểm tra quyền ghi của tài khoản chạy Manager.") from exc


def run_password(machine, command, payload, emit):
    ssh = paramiko.SSHClient()
    channel = None
    endpoint = f'{machine["host"]}:{machine["port"]}'
    stage = "đọc known_hosts"
    try:
        ssh.load_system_host_keys()
        system_hosts = Path("/etc/ssh/ssh_known_hosts")
        if system_hosts.is_file():
            ssh.load_system_host_keys(str(system_hosts))
        ssh.set_missing_host_key_policy(RememberNewKey())
        stage = "bắt tay SSH"
        ssh.connect(hostname=machine["host"], port=machine["port"], username=machine["user"],
                    password=machine["ssh_password"], allow_agent=False, look_for_keys=False,
                    timeout=10, auth_timeout=20, banner_timeout=20, channel_timeout=20)
        stage = "mở phiên chạy tác vụ"
        transport = ssh.get_transport()
        transport.set_keepalive(15)
        channel = transport.open_session(timeout=20)
        channel.settimeout(30)
        channel.exec_command(command)
        channel.sendall(json.dumps(payload).encode())
        channel.shutdown_write()
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        buffer = ""
        result = None
        error = None

        def consume(line):
            nonlocal result, error
            try:
                message = json.loads(line)
            except (ValueError, TypeError):
                return
            if not isinstance(message, dict):
                return
            if "event" in message:
                emit(message["event"])
            if "error" in message:
                error = message["error"]
            if "result" in message:
                result = message["result"]

        started = time.monotonic()
        while True:
            if time.monotonic() - started > 7500:
                raise TimeoutError("Tác vụ quá thời gian; kiểm tra máy đích trước khi thử lại.")
            if channel.recv_ready():
                buffer += decoder.decode(channel.recv(65536))
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    consume(line)
            if channel.recv_stderr_ready():
                stderr = channel.recv_stderr(65536)
                if b"sudo" in stderr or b"password is required" in stderr:
                    error = "Đã kết nối SSH. Tác vụ hệ thống cần root hoặc quyền sudo -n không hỏi mật khẩu."
            if channel.exit_status_ready() and not channel.recv_ready() and not channel.recv_stderr_ready():
                buffer += decoder.decode(b"", final=True)
                if buffer.strip():
                    consume(buffer)
                if channel.recv_exit_status() != 0 or result is None:
                    raise RuntimeError(error or "Worker SSH thất bại. Kiểm tra Python 3 và công cụ trên máy đích.")
                return result
            if not transport.is_active():
                raise RuntimeError("Mất kết nối SSH. Kiểm tra trạng thái máy đích trước khi chạy lại.")
            select.select([channel], [], [], 0.2)
    except paramiko.AuthenticationException:
        raise RuntimeError("Đăng nhập SSH thất bại. Kiểm tra user, mật khẩu và quyền đăng nhập bằng mật khẩu trên VPS.") from None
    except paramiko.BadHostKeyException as exc:
        raise RuntimeError(f"Host key SSH của {endpoint} đã thay đổi. Khóa đang nhận: {fingerprint(exc.key)}. Đối chiếu qua console VPS trước khi cập nhật known_hosts.") from None
    except paramiko.SSHException as exc:
        detail = str(exc).replace(machine["ssh_password"], "•••") if machine.get("ssh_password") else str(exc)
        raise RuntimeError(f"SSH {endpoint} lỗi khi {stage}: {detail[:250] or type(exc).__name__}") from None
    except socket.gaierror:
        raise RuntimeError(f"Không phân giải được địa chỉ SSH {endpoint}. Kiểm tra hostname hoặc IP.") from None
    except (OSError, EOFError) as exc:
        raise RuntimeError(f"SSH {endpoint} lỗi khi {stage}: {exc.strerror if isinstance(exc, OSError) and exc.strerror else type(exc).__name__}.") from None
    finally:
        if channel is not None:
            channel.close()
        ssh.close()
