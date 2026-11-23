"""Password SSH transport; credentials stay in memory and never enter argv."""
import base64
import codecs
import hashlib
import socket
import json
import select
import time
from pathlib import Path

import paramiko


def fingerprint(key):
    digest = hashlib.sha256(key.asbytes()).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


class RequireKnownKey(paramiko.MissingHostKeyPolicy):
    def missing_host_key(self, client, hostname, key):
        raise RuntimeError(f"Chưa có khóa của {hostname} trong known_hosts của tài khoản chạy Manager. "
                           f"Khóa VPS gửi là {key.get_name()} {fingerprint(key)}. "
                           "Đối chiếu với fingerprint từ console VPS rồi kết nối bằng lệnh ssh trên máy quản trị để lưu khóa.")


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
        ssh.set_missing_host_key_policy(RequireKnownKey())
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
