"""Password SSH transport; credentials stay in memory and never enter argv."""
import codecs
import json
import select
import time
from pathlib import Path

import paramiko


def run_password(machine, command, payload, emit):
    ssh = paramiko.SSHClient()
    channel = None
    try:
        ssh.load_system_host_keys()
        system_hosts = Path("/etc/ssh/ssh_known_hosts")
        if system_hosts.is_file():
            ssh.load_system_host_keys(str(system_hosts))
        ssh.set_missing_host_key_policy(paramiko.RejectPolicy())
        ssh.connect(hostname=machine["host"], port=machine["port"], username=machine["user"],
                    password=machine["ssh_password"], allow_agent=False, look_for_keys=False,
                    timeout=10, auth_timeout=20, banner_timeout=20, channel_timeout=20)
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
    except paramiko.BadHostKeyException:
        raise RuntimeError("Host key SSH đã thay đổi. Xác minh máy đích và cập nhật known_hosts trước khi kết nối.") from None
    except paramiko.SSHException:
        raise RuntimeError("Không thiết lập được SSH. Kiểm tra known_hosts và cấu hình SSH của VPS; dùng IP/hostname trực tiếp khi đăng nhập bằng mật khẩu.") from None
    except OSError:
        raise RuntimeError("Không kết nối được máy SSH. Kiểm tra địa chỉ, port và kết nối mạng.") from None
    finally:
        if channel is not None:
            channel.close()
        ssh.close()
