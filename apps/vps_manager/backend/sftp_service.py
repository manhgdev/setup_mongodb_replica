"""SFTP file management, streaming upload/download, and cross-server transfer service."""
from __future__ import annotations

import asyncio
from contextlib import contextmanager
from dataclasses import dataclass, field
import os
from pathlib import Path
import posixpath
import shutil
import stat
import tarfile
import tempfile
import threading
import time
from typing import Iterator
from uuid import uuid4

import paramiko

from shared.manager_core.ssh_transport import identity_file

MAX_EDITOR_BYTES = 1_048_576  # 1 MiB
CHUNK_SIZE = 65_536


def _redact_error(exc: Exception, machine: dict) -> str:
    detail = str(exc) or type(exc).__name__
    pw = (machine or {}).get("ssh_password") or ""
    if pw:
        detail = detail.replace(pw, "•••")
    return detail


def _open_ssh_client(machine: dict, store=None) -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    known_hosts = Path.home() / ".ssh" / "known_hosts"
    if known_hosts.is_file():
        try:
            client.load_host_keys(str(known_hosts))
        except OSError:
            pass
    system_hosts = Path("/etc/ssh/ssh_known_hosts")
    if system_hosts.is_file():
        try:
            client.load_host_keys(str(system_hosts))
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

    with identity_file(machine, store=store) as key_path:
        if key_path:
            connect_kwargs["key_filename"] = key_path
        client.connect(**connect_kwargs)
    return client


class _LocalSFTP:
    """Minimal Paramiko-SFTP-compatible adapter for machines with mode == 'local'."""

    def normalize(self, path: str) -> str:
        raw = path or "."
        if raw == ".":
            return str(Path.home())
        return os.path.normpath(os.path.expanduser(raw))

    def listdir_attr(self, path: str):
        target = self.normalize(path)
        items = []
        with os.scandir(target) as it:
            for entry in it:
                st = entry.stat(follow_symlinks=False)
                attr = paramiko.SFTPAttributes.from_stat(st, filename=entry.name)
                items.append(attr)
        return items

    def stat(self, path: str):
        return paramiko.SFTPAttributes.from_stat(os.stat(self.normalize(path)))

    def lstat(self, path: str):
        return paramiko.SFTPAttributes.from_stat(os.lstat(self.normalize(path)))

    def mkdir(self, path: str, mode: int = 0o755):
        os.mkdir(self.normalize(path), mode)

    def rename(self, old_path: str, new_path: str):
        os.rename(self.normalize(old_path), self.normalize(new_path))

    def remove(self, path: str):
        os.unlink(self.normalize(path))

    def rmdir(self, path: str):
        os.rmdir(self.normalize(path))

    def chmod(self, path: str, mode: int):
        os.chmod(self.normalize(path), mode)

    def open(self, path: str, mode: str = "r", bufsize: int = -1):
        return open(self.normalize(path), mode)

    def close(self):
        pass


@contextmanager
def open_sftp_session(machine: dict, store=None):
    """Open an SFTP session (Paramiko SFTPClient or _LocalSFTP for mode=='local')."""
    if (machine or {}).get("mode") == "local":
        yield _LocalSFTP()
        return

    client = None
    sftp = None
    try:
        client = _open_ssh_client(machine, store=store)
        sftp = client.open_sftp()
        yield sftp
    except (OSError, EOFError, paramiko.SSHException) as exc:
        raise RuntimeError(f"Lỗi SFTP: {_redact_error(exc, machine)}") from exc
    finally:
        if sftp is not None:
            try:
                sftp.close()
            except Exception:
                pass
        if client is not None:
            try:
                client.close()
            except Exception:
                pass


def _clean_posix(path: str, fallback: str = "~") -> str:
    raw = (path or "").strip()
    if not raw or raw == "~":
        return fallback
    if raw.startswith("~/"):
        return raw
    return posixpath.normpath(raw)


def _resolve_path(sftp, path: str) -> tuple[str, str]:
    home = sftp.normalize(".")
    raw = (path or "").strip()
    if not raw or raw == "~":
        return home, home
    if raw.startswith("~/"):
        raw = posixpath.join(home, raw[2:])
    return posixpath.normpath(raw), home


def _format_entry(name: str, full_path: str, attr) -> dict:
    mode = int(attr.st_mode or 0)
    if stat.S_ISDIR(mode):
        etype = "dir"
    elif stat.S_ISLNK(mode):
        etype = "symlink"
    else:
        etype = "file"
    perm_bits = stat.S_IMODE(mode)
    return {
        "name": name,
        "path": full_path,
        "type": etype,
        "size": int(attr.st_size or 0),
        "mode": perm_bits,
        "octal": f"{perm_bits:04o}",
        "perms": stat.filemode(mode),
        "mtime": int(attr.st_mtime or 0),
        "uid": int(attr.st_uid or 0),
        "gid": int(attr.st_gid or 0),
    }


def list_dir(machine: dict, path: str = "", show_hidden: bool = False, store=None) -> dict:
    with open_sftp_session(machine, store=store) as sftp:
        cwd, home = _resolve_path(sftp, path)
        attrs = sftp.listdir_attr(cwd)
        entries = []
        for attr in attrs:
            name = getattr(attr, "filename", "")
            if not name or name in {".", ".."}:
                continue
            if not show_hidden and name.startswith("."):
                continue
            full_path = posixpath.join(cwd, name) if cwd != "/" else f"/{name}"
            entries.append(_format_entry(name, full_path, attr))
        entries.sort(key=lambda e: (0 if e["type"] == "dir" else 1, e["name"].lower()))
        return {"cwd": cwd, "home": home, "entries": entries}


def mkdir(machine: dict, path: str, store=None) -> dict:
    with open_sftp_session(machine, store=store) as sftp:
        target, _ = _resolve_path(sftp, path)
        if not target or target == "/":
            raise ValueError("Đường dẫn thư mục không hợp lệ.")
        sftp.mkdir(target)
        return {"path": target}


def touch(machine: dict, path: str, store=None) -> dict:
    with open_sftp_session(machine, store=store) as sftp:
        target, _ = _resolve_path(sftp, path)
        if not target or target == "/":
            raise ValueError("Đường dẫn file không hợp lệ.")
        try:
            sftp.lstat(target)
            raise ValueError("File hoặc thư mục đã tồn tại.")
        except FileNotFoundError:
            pass
        except OSError:
            pass
        with sftp.open(target, "wb") as handle:
            handle.write(b"")
        return {"path": target}


def rename(machine: dict, old_path: str, new_path: str, store=None) -> dict:
    with open_sftp_session(machine, store=store) as sftp:
        src, _ = _resolve_path(sftp, old_path)
        dst, _ = _resolve_path(sftp, new_path)
        if not src or src == "/" or not dst or dst == "/":
            raise ValueError("Đường dẫn đổi tên không hợp lệ.")
        sftp.rename(src, dst)
        return {"old_path": src, "new_path": dst}


def _parse_mode(mode_val: str | int) -> int:
    if isinstance(mode_val, int):
        if 0 <= mode_val <= 0o7777:
            return mode_val
        raise ValueError("Mã phân quyền không hợp lệ.")
    raw = str(mode_val or "").strip()
    if not raw or not raw.isdigit() or any(ch not in "01234567" for ch in raw) or len(raw) > 4:
        raise ValueError("Mã phân quyền phải là số octal (ví dụ 0755 hoặc 644).")
    return int(raw, 8)


def _chmod_recursive(sftp, target: str, mode_int: int) -> None:
    sftp.chmod(target, mode_int)
    attr = sftp.lstat(target)
    if stat.S_ISDIR(int(attr.st_mode or 0)):
        for child in sftp.listdir_attr(target):
            name = getattr(child, "filename", "")
            if not name or name in {".", ".."}:
                continue
            child_path = posixpath.join(target, name)
            _chmod_recursive(sftp, child_path, mode_int)


def chmod(machine: dict, path: str, mode_val: str | int, recursive: bool = False, store=None) -> dict:
    mode_int = _parse_mode(mode_val)
    with open_sftp_session(machine, store=store) as sftp:
        target, _ = _resolve_path(sftp, path)
        if not target:
            raise ValueError("Đường dẫn không hợp lệ.")
        if recursive:
            _chmod_recursive(sftp, target, mode_int)
        else:
            sftp.chmod(target, mode_int)
        return {"path": target, "octal": f"{mode_int:04o}"}


def _remove_recursive(sftp, target: str) -> None:
    attr = sftp.lstat(target)
    if stat.S_ISDIR(int(attr.st_mode or 0)):
        for child in sftp.listdir_attr(target):
            name = getattr(child, "filename", "")
            if not name or name in {".", ".."}:
                continue
            _remove_recursive(sftp, posixpath.join(target, name))
        sftp.rmdir(target)
    else:
        sftp.remove(target)


def delete_paths(machine: dict, paths: list[str], store=None) -> dict:
    if not paths:
        raise ValueError("Chưa chọn file hoặc thư mục cần xóa.")
    deleted = []
    with open_sftp_session(machine, store=store) as sftp:
        for raw in paths:
            target, _ = _resolve_path(sftp, raw)
            if not target or target == "/":
                raise ValueError("Không được phép xóa thư mục gốc '/'.")
            _remove_recursive(sftp, target)
            deleted.append(target)
    return {"deleted": deleted}


def read_text_file(machine: dict, path: str, max_bytes: int = MAX_EDITOR_BYTES, store=None) -> dict:
    with open_sftp_session(machine, store=store) as sftp:
        target, _ = _resolve_path(sftp, path)
        st = sftp.stat(target)
        mode = int(st.st_mode or 0)
        if stat.S_ISDIR(mode):
            raise ValueError("Không thể mở thư mục trong trình sửa file.")
        size = int(st.st_size or 0)
        if size > max_bytes:
            raise ValueError(f"File quá lớn để sửa trực tiếp ({size:,} bytes > {max_bytes:,} bytes). Hãy tải xuống.")
        with sftp.open(target, "rb") as handle:
            raw = handle.read(max_bytes + 1)
        if len(raw) > max_bytes:
            raise ValueError("File vượt quá giới hạn kích thước trình sửa trực tiếp.")
        if b"\x00" in raw:
            raise ValueError("File nhị phân không thể mở trong trình sửa văn bản.")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("File không phải mã hóa UTF-8 hợp lệ.") from exc
        perm_bits = stat.S_IMODE(mode)
        return {"path": target, "content": text, "size": len(raw), "octal": f"{perm_bits:04o}"}


def write_text_file(machine: dict, path: str, content: str, store=None) -> dict:
    data = (content or "").encode("utf-8")
    with open_sftp_session(machine, store=store) as sftp:
        target, _ = _resolve_path(sftp, path)
        with sftp.open(target, "wb") as handle:
            handle.write(data)
        return {"path": target, "size": len(data)}


def _safe_filename(filename: str) -> str:
    base = posixpath.basename((filename or "").replace("\\", "/")).strip()
    if not base or base in {".", ".."}:
        raise ValueError("Tên file tải lên không hợp lệ.")
    return base


async def upload_from_request_stream(machine: dict, dest_dir: str, filename: str, request, store=None) -> dict:
    safe_name = _safe_filename(filename)

    def _open_writer():
        if (machine or {}).get("mode") == "local":
            sftp = _LocalSFTP()
            client = None
        else:
            client = _open_ssh_client(machine, store=store)
            sftp = client.open_sftp()
        target_dir, _ = _resolve_path(sftp, dest_dir)
        remote_path = posixpath.join(target_dir, safe_name)
        handle = sftp.open(remote_path, "wb")
        return client, sftp, handle, remote_path

    client, sftp, handle, remote_path = await asyncio.to_thread(_open_writer)
    total = 0
    try:
        async for chunk in request.stream():
            if chunk:
                total += len(chunk)
                await asyncio.to_thread(handle.write, chunk)
        await asyncio.to_thread(handle.close)
        handle = None
        return {"path": remote_path, "name": safe_name, "size": total}
    finally:
        if handle is not None:
            try:
                await asyncio.to_thread(handle.close)
            except Exception:
                pass
        if sftp is not None:
            try:
                await asyncio.to_thread(sftp.close)
            except Exception:
                pass
        if client is not None:
            try:
                await asyncio.to_thread(client.close)
            except Exception:
                pass


def _add_sftp_to_tar(sftp, remote_path: str, arcname: str, tar: tarfile.TarFile, tmp_dir: Path) -> None:
    attr = sftp.lstat(remote_path)
    mode = int(attr.st_mode or 0)
    if stat.S_ISDIR(mode):
        info = tarfile.TarInfo(name=arcname)
        info.type = tarfile.DIRTYPE
        info.mode = stat.S_IMODE(mode) or 0o755
        info.mtime = int(attr.st_mtime or time.time())
        tar.addfile(info)
        for child in sftp.listdir_attr(remote_path):
            cname = getattr(child, "filename", "")
            if not cname or cname in {".", ".."}:
                continue
            _add_sftp_to_tar(
                sftp,
                posixpath.join(remote_path, cname),
                posixpath.join(arcname, cname),
                tar,
                tmp_dir,
            )
    elif stat.S_ISREG(mode):
        local_tmp = tmp_dir / f"item_{uuid4().hex}"
        with sftp.open(remote_path, "rb") as src, local_tmp.open("wb") as dst:
            while True:
                buf = src.read(CHUNK_SIZE)
                if not buf:
                    break
                dst.write(buf)
        tar.add(local_tmp, arcname=arcname, recursive=False)
        local_tmp.unlink(missing_ok=True)


def prepare_download(machine: dict, paths: list[str], store=None) -> tuple[str, str, Iterator[bytes]]:
    if not paths:
        raise ValueError("Chưa chọn file hoặc thư mục để tải xuống.")

    if (machine or {}).get("mode") == "local":
        client = None
        sftp = _LocalSFTP()
    else:
        client = _open_ssh_client(machine, store=store)
        sftp = client.open_sftp()

    def _cleanup():
        try:
            sftp.close()
        except Exception:
            pass
        if client is not None:
            try:
                client.close()
            except Exception:
                pass

    try:
        resolved = [_resolve_path(sftp, p)[0] for p in paths]
        if len(resolved) == 1:
            st = sftp.stat(resolved[0])
            if not stat.S_ISDIR(int(st.st_mode or 0)):
                handle = sftp.open(resolved[0], "rb")
                filename = posixpath.basename(resolved[0]) or "download"

                def _file_iter():
                    try:
                        while True:
                            buf = handle.read(CHUNK_SIZE)
                            if not buf:
                                break
                            yield buf
                    finally:
                        try:
                            handle.close()
                        except Exception:
                            pass
                        _cleanup()

                return filename, "application/octet-stream", _file_iter()

        tmp_dir = Path(tempfile.mkdtemp(prefix="zm_sftp_dl_"))
        archive_path = tmp_dir / "archive.tar.gz"
        archive_name = (
            f"{posixpath.basename(resolved[0]) or 'archive'}.tar.gz"
            if len(resolved) == 1
            else "sftp-selection.tar.gz"
        )
        with tarfile.open(archive_path, "w:gz") as tar:
            for rpath in resolved:
                arcname = posixpath.basename(rpath) or "root"
                _add_sftp_to_tar(sftp, rpath, arcname, tar, tmp_dir)
        _cleanup()

        def _archive_iter():
            try:
                with archive_path.open("rb") as f:
                    while True:
                        buf = f.read(CHUNK_SIZE)
                        if not buf:
                            break
                        yield buf
            finally:
                shutil.rmtree(tmp_dir, ignore_errors=True)

        return archive_name, "application/gzip", _archive_iter()
    except Exception:
        _cleanup()
        raise


@dataclass
class TransferJob:
    id: str
    workspace_id: str
    source_machine: str
    target_machine: str
    op: str
    status: str = "running"
    bytes_transferred: int = 0
    total_bytes: int = 0
    files_done: int = 0
    files_total: int = 0
    current_file: str = ""
    error: str = ""
    cancel_event: threading.Event = field(default_factory=threading.Event)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "source_machine": self.source_machine,
            "target_machine": self.target_machine,
            "op": self.op,
            "status": self.status,
            "bytes_transferred": self.bytes_transferred,
            "total_bytes": self.total_bytes,
            "files_done": self.files_done,
            "files_total": self.files_total,
            "current_file": self.current_file,
            "error": self.error,
        }


class TransferManager:
    """In-memory tracker for asynchronous SFTP copy/move jobs between two machines."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, TransferJob] = {}

    def start(
        self,
        workspace_id: str,
        src_machine: dict,
        dst_machine: dict,
        paths: list[str],
        target_dir: str,
        op: str = "copy",
        store=None,
    ) -> dict:
        if op not in {"copy", "move"}:
            raise ValueError("Thao tác truyền chỉ hỗ trợ copy hoặc move.")
        if not paths:
            raise ValueError("Chưa chọn file hoặc thư mục để truyền.")
        tid = uuid4().hex[:12]
        job = TransferJob(
            id=tid,
            workspace_id=workspace_id,
            source_machine=src_machine["id"],
            target_machine=dst_machine["id"],
            op=op,
        )
        with self._lock:
            if len(self._jobs) > 200:
                oldest = [k for k, v in self._jobs.items() if v.status != "running"][:50]
                for k in oldest:
                    self._jobs.pop(k, None)
            self._jobs[tid] = job

        t = threading.Thread(
            target=self._run,
            args=(job, src_machine, dst_machine, list(paths), target_dir, store),
            daemon=True,
        )
        t.start()
        return job.to_dict()

    def get(self, transfer_id: str, workspace_id: str) -> dict:
        with self._lock:
            job = self._jobs.get(transfer_id)
            if not job or job.workspace_id != workspace_id:
                raise KeyError("Không tìm thấy tác vụ truyền file.")
            return job.to_dict()

    def cancel(self, transfer_id: str, workspace_id: str) -> dict:
        with self._lock:
            job = self._jobs.get(transfer_id)
            if not job or job.workspace_id != workspace_id:
                raise KeyError("Không tìm thấy tác vụ truyền file.")
            job.cancel_event.set()
            if job.status == "running":
                job.status = "cancelled"
            return job.to_dict()

    def _collect_plan(self, sftp_src, src_root: str, dst_root: str, dirs_out: list, files_out: list, job: TransferJob):
        attr = sftp_src.lstat(src_root)
        mode = int(attr.st_mode or 0)
        if stat.S_ISDIR(mode):
            dirs_out.append((src_root, dst_root, stat.S_IMODE(mode) or 0o755))
            for child in sftp_src.listdir_attr(src_root):
                cname = getattr(child, "filename", "")
                if not cname or cname in {".", ".."}:
                    continue
                self._collect_plan(
                    sftp_src,
                    posixpath.join(src_root, cname),
                    posixpath.join(dst_root, cname),
                    dirs_out,
                    files_out,
                    job,
                )
        else:
            size = int(attr.st_size or 0)
            files_out.append((src_root, dst_root, size, stat.S_IMODE(mode) or 0o644))
            job.total_bytes += size
            job.files_total += 1

    def _run(self, job: TransferJob, src_machine: dict, dst_machine: dict, paths: list[str], target_dir: str, store):
        try:
            with open_sftp_session(src_machine, store=store) as sftp_src, open_sftp_session(dst_machine, store=store) as sftp_dst:
                dst_base, _ = _resolve_path(sftp_dst, target_dir)
                dirs_out: list[tuple[str, str, int]] = []
                files_out: list[tuple[str, str, int, int]] = []
                resolved_srcs = []
                for raw in paths:
                    rsrc, _ = _resolve_path(sftp_src, raw)
                    if not rsrc or rsrc == "/":
                        raise ValueError("Đường dẫn nguồn không hợp lệ.")
                    resolved_srcs.append(rsrc)
                    name = posixpath.basename(rsrc)
                    self._collect_plan(sftp_src, rsrc, posixpath.join(dst_base, name), dirs_out, files_out, job)

                for _, dpath, dmode in dirs_out:
                    if job.cancel_event.is_set():
                        job.status = "cancelled"
                        return
                    try:
                        sftp_dst.mkdir(dpath, dmode)
                    except OSError:
                        pass

                for spath, dpath, _, fmode in files_out:
                    if job.cancel_event.is_set():
                        job.status = "cancelled"
                        return
                    job.current_file = posixpath.basename(spath)
                    with sftp_src.open(spath, "rb") as src_f, sftp_dst.open(dpath, "wb") as dst_f:
                        while True:
                            if job.cancel_event.is_set():
                                job.status = "cancelled"
                                return
                            buf = src_f.read(CHUNK_SIZE)
                            if not buf:
                                break
                            dst_f.write(buf)
                            job.bytes_transferred += len(buf)
                    try:
                        sftp_dst.chmod(dpath, fmode)
                    except OSError:
                        pass
                    job.files_done += 1

                if job.op == "move" and not job.cancel_event.is_set():
                    for rsrc in resolved_srcs:
                        _remove_recursive(sftp_src, rsrc)

                job.status = "succeeded"
        except Exception as exc:
            if job.cancel_event.is_set():
                job.status = "cancelled"
            else:
                job.status = "failed"
                job.error = _redact_error(exc, src_machine)
