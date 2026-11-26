"""Interactive SSH and local PTY terminal sessions over WebSocket."""
import asyncio
import codecs
import fcntl
import os
import pty
import select
import signal
import struct
import termios
import threading
from pathlib import Path

import paramiko
from fastapi import WebSocketDisconnect


def _set_winsize(fd: int, rows: int, cols: int):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(rows, 1), max(cols, 1), 0, 0))


async def _run_local_pty(websocket, cols: int, rows: int):
    master_fd, slave_fd = pty.openpty()
    _set_winsize(master_fd, rows, cols)
    shell = os.environ.get("SHELL") or "/bin/bash"
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        os.close(master_fd)
        env = dict(os.environ, TERM="xterm-256color")
        os.execvpe(shell, [shell, "-l"], env)
    os.close(slave_fd)

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    stop = threading.Event()

    def reader():
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        try:
            while not stop.is_set():
                r, _, _ = select.select([master_fd], [], [], 0.2)
                if not r:
                    continue
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                text = decoder.decode(data, final=False)
                if text:
                    loop.call_soon_threadsafe(queue.put_nowait, ("data", text))
        finally:
            tail = decoder.decode(b"", final=True)
            if tail:
                loop.call_soon_threadsafe(queue.put_nowait, ("data", tail))
            loop.call_soon_threadsafe(queue.put_nowait, ("exit", 0))

    threading.Thread(target=reader, daemon=True).start()
    await websocket.send_json({"type": "status", "state": "connected"})

    async def writer():
        while True:
            kind, val = await queue.get()
            if kind == "data":
                await websocket.send_json({"type": "data", "data": val})
            elif kind == "exit":
                await websocket.send_json({"type": "exit", "code": val})
                break

    write_task = asyncio.create_task(writer())
    try:
        while True:
            msg = await websocket.receive_json()
            mtype = msg.get("type")
            if mtype == "data":
                os.write(master_fd, str(msg.get("data", "")).encode("utf-8"))
            elif mtype == "resize":
                _set_winsize(master_fd, int(msg.get("rows", 24)), int(msg.get("cols", 80)))
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        stop.set()
        write_task.cancel()
        try:
            os.close(master_fd)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, os.WNOHANG)
        except OSError:
            pass


async def run_terminal_session(websocket, machine: dict, cols: int = 100, rows: int = 30, store=None):
    if machine.get("mode") == "local":
        return await _run_local_pty(websocket, cols, rows)

    from shared.manager_core.ssh_transport import identity_file

    client = paramiko.SSHClient()
    known_hosts = Path.home() / ".ssh" / "known_hosts"
    if known_hosts.exists():
        try:
            client.load_host_keys(str(known_hosts))
        except OSError:
            pass
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    connect_kwargs = {
        "hostname": machine["host"],
        "port": int(machine.get("port") or 22),
        "username": machine["user"],
        "timeout": 12,
        "banner_timeout": 12,
    }
    if machine.get("ssh_auth") == "password":
        connect_kwargs["password"] = machine.get("ssh_password") or ""
        connect_kwargs["look_for_keys"] = False
        connect_kwargs["allow_agent"] = False
    else:
        connect_kwargs["look_for_keys"] = True
        connect_kwargs["allow_agent"] = True

    try:
        with identity_file(machine, store=store) as key_path:
            if key_path:
                connect_kwargs["key_filename"] = key_path
            await asyncio.to_thread(client.connect, **connect_kwargs)
        channel = await asyncio.to_thread(client.invoke_shell, term="xterm-256color", width=max(cols, 20), height=max(rows, 5))
        channel.settimeout(0.2)
    except Exception as exc:
        detail = str(exc)
        pw = machine.get("ssh_password") or ""
        if pw:
            detail = detail.replace(pw, "•••")
        await websocket.send_json({"type": "error", "message": f"Không thể mở SSH Terminal: {detail}"})
        client.close()
        return

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    stop = threading.Event()

    def reader():
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        try:
            while not stop.is_set():
                if channel.recv_ready():
                    data = channel.recv(4096)
                    if not data:
                        break
                    text = decoder.decode(data, final=False)
                    if text:
                        loop.call_soon_threadsafe(queue.put_nowait, ("data", text))
                elif channel.recv_stderr_ready():
                    data = channel.recv_stderr(4096)
                    if data:
                        text = decoder.decode(data, final=False)
                        if text:
                            loop.call_soon_threadsafe(queue.put_nowait, ("data", text))
                elif channel.exit_status_ready():
                    break
                else:
                    stop.wait(0.03)
        except Exception:
            pass
        finally:
            tail = decoder.decode(b"", final=True)
            if tail:
                loop.call_soon_threadsafe(queue.put_nowait, ("data", tail))
            code = channel.recv_exit_status() if channel.exit_status_ready() else 0
            loop.call_soon_threadsafe(queue.put_nowait, ("exit", code))

    threading.Thread(target=reader, daemon=True).start()
    await websocket.send_json({"type": "status", "state": "connected"})

    async def writer():
        while True:
            kind, val = await queue.get()
            if kind == "data":
                await websocket.send_json({"type": "data", "data": val})
            elif kind == "exit":
                await websocket.send_json({"type": "exit", "code": val})
                break

    write_task = asyncio.create_task(writer())
    try:
        while True:
            msg = await websocket.receive_json()
            mtype = msg.get("type")
            if mtype == "data":
                payload = str(msg.get("data", ""))
                if payload:
                    await asyncio.to_thread(channel.sendall, payload.encode("utf-8"))
            elif mtype == "resize":
                c = max(int(msg.get("cols", 80)), 20)
                r = max(int(msg.get("rows", 24)), 5)
                await asyncio.to_thread(channel.resize_pty, width=c, height=r)
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        stop.set()
        write_task.cancel()
        try:
            channel.close()
        except Exception:
            pass
        client.close()
