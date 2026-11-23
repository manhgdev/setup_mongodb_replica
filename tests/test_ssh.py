import json
import socket
import threading
from unittest.mock import patch

import paramiko
import pytest

from web.operations import host_run
from web.ssh_transport import run_password


@pytest.fixture
def ssh_server(tmp_path):
    """Local disposable SSH server: exercises real protocol/password auth."""
    key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(5)
    port = listener.getsockname()[1]
    seen = {}
    done = threading.Event()
    command_ready = threading.Event()
    hosts = tmp_path / 'known_hosts'
    hosts.write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')

    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self, username):
            return 'password'

        def check_auth_password(self, username, password):
            seen['username'] = username
            seen['password'] = password
            return paramiko.AUTH_SUCCESSFUL if password == 'test-ssh-password' else paramiko.AUTH_FAILED

        def check_channel_request(self, kind, chanid):
            return paramiko.OPEN_SUCCEEDED

        def check_channel_exec_request(self, channel, command):
            seen['command'] = command.decode()
            command_ready.set()
            return True

    def serve():
        transport = None
        try:
            conn, _ = listener.accept()
            transport = paramiko.Transport(conn)
            transport.add_server_key(key)
            transport.start_server(server=Server())
            channel = transport.accept(5)
            if channel is None:
                return
            channel.settimeout(5)
            assert command_ready.wait(5)
            payload = b''
            while chunk := channel.recv(4096):
                payload += chunk
            seen['payload'] = json.loads(payload)
            output = (json.dumps({'event': 'Đã kết nối'}, ensure_ascii=False) + '\n' + json.dumps({'result': {'ok': True}})).encode()
            # Also exercise fragmented UTF-8 and final JSON without newline.
            channel.sendall(output[:15])
            channel.sendall(output[15:])
            channel.send_exit_status(0)
            channel.close()
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            if transport:
                transport.close()
            done.set()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    loader = paramiko.SSHClient.load_system_host_keys

    def load_test_hosts(client, filename=None):
        loader(client, str(hosts))

    with patch.object(paramiko.SSHClient, 'load_system_host_keys', load_test_hosts):
        yield {'mode': 'ssh', 'host': '127.0.0.1', 'port': port, 'user': 'tester', 'ssh_auth': 'password',
               'ssh_password': 'test-ssh-password', 'service': 'mongod'}, seen
    listener.close()
    thread.join(6)
    assert done.is_set()


def test_password_ssh_real_protocol(ssh_server):
    machine, seen = ssh_server
    events = []
    result = host_run(machine, 'preflight', {}, events.append)
    assert result == {'ok': True}
    assert events == ['Đã kết nối']
    assert seen['password'] == machine['ssh_password']
    assert machine['ssh_password'] not in seen['command']
    assert 'sudo' not in seen['command']
    assert len(seen['command']) < 1024
    assert 'def main(request)' in seen['payload'].pop('_worker')
    assert seen['payload'] == {'action': 'preflight', 'params': {'service': 'mongod'}}


def test_password_ssh_rejects_wrong_password(ssh_server):
    machine, _ = ssh_server
    with pytest.raises(RuntimeError, match='Đăng nhập SSH thất bại'):
        run_password(dict(machine, ssh_password='wrong-secret'), 'true', {}, lambda _: None)


def test_password_ssh_rejects_unknown_host(ssh_server):
    machine, seen = ssh_server
    with patch.object(paramiko.SSHClient, 'load_system_host_keys', lambda *args: None):
        with pytest.raises(RuntimeError, match=r'known_hosts.*SHA256:'):
            run_password(machine, 'true', {}, lambda _: None)
    assert 'password' not in seen
