"""Safe bundle inspection and SSH/local file transfer for Portable VPS Stacks."""
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

from shared.manager_core.ssh_transport import RememberNewKey


BUNDLE_ID_RE = re.compile(r"^[a-zA-Z0-9._-]{1,96}$")


def safe_bundle_path(bundles_dir: Path, bundle_id: str) -> Path:
    if not BUNDLE_ID_RE.fullmatch(bundle_id) or not bundle_id.endswith(".tar.gz"):
        raise ValueError("Mã gói bundle không hợp lệ.")
    bundles_dir.mkdir(parents=True, exist_ok=True)
    target = (bundles_dir / bundle_id).resolve()
    if target.parent != bundles_dir.resolve():
        raise ValueError("Đường dẫn bundle không hợp lệ.")
    return target


def validate_tar_members(tar: tarfile.TarFile) -> None:
    """Reject path traversal, absolute paths, and unsafe links inside a stack archive."""
    for member in tar.getmembers():
        name = member.name
        if not name or name.startswith("/") or "\\" in name:
            raise ValueError(f"Đường dẫn không an toàn trong gói: {name}")
        parts = Path(name).parts
        if any(part == ".." for part in parts):
            raise ValueError(f"Phát hiện path traversal trong gói: {name}")
        if member.issym() or member.islnk():
            link = member.linkname or ""
            if link.startswith("/") or ".." in Path(link).parts:
                raise ValueError(f"Liên kết không an toàn trong gói: {name} -> {link}")
        elif not (member.isdir() or member.isfile()):
            raise ValueError(f"Loại tệp không được hỗ trợ trong gói: {name}")


def inspect_bundle(bundle_path: Path) -> dict:
    """Validate a .tar.gz stack bundle and return its manifest summary."""
    if not bundle_path.is_file():
        raise ValueError("Không tìm thấy file bundle.")
    try:
        with tarfile.open(bundle_path, "r:gz") as tar:
            validate_tar_members(tar)
            try:
                member = tar.getmember("zm-stack-manifest.json")
            except KeyError:
                raise ValueError("Gói không hợp lệ: thiếu zm-stack-manifest.json.") from None
            if member.size > 2 * 1024 * 1024:
                raise ValueError("Manifest quá lớn.")
            raw = tar.extractfile(member)
            if raw is None:
                raise ValueError("Không đọc được zm-stack-manifest.json.")
            manifest = json.loads(raw.read().decode("utf-8"))
    except (tarfile.TarError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"File bundle .tar.gz không hợp lệ: {exc}") from None
    return {
        "id": bundle_path.name,
        "size": bundle_path.stat().st_size,
        "manifest": manifest,
    }


def transfer_bundle(machine: dict, direction: str, local_path: Path, remote_path: str) -> None:
    """Transfer a bundle between Manager host and target machine (local, key SSH, or password SSH)."""
    if direction not in {"put", "get"}:
        raise ValueError("Hướng truyền file không hợp lệ.")
    if machine["mode"] == "local":
        if direction == "put":
            shutil.copy2(local_path, remote_path)
        else:
            shutil.copy2(remote_path, local_path)
        return

    if machine.get("ssh_auth") == "password":
        import paramiko

        ssh = paramiko.SSHClient()
        try:
            ssh.load_system_host_keys()
            system_hosts = Path("/etc/ssh/ssh_known_hosts")
            if system_hosts.is_file():
                ssh.load_system_host_keys(str(system_hosts))
            ssh.set_missing_host_key_policy(
                paramiko.RejectPolicy() if machine.get("strict_key") else RememberNewKey()
            )
            ssh.connect(
                hostname=machine["host"],
                port=machine["port"],
                username=machine["user"],
                password=machine["ssh_password"],
                allow_agent=False,
                look_for_keys=False,
                timeout=15,
                auth_timeout=20,
                banner_timeout=20,
            )
            with ssh.open_sftp() as sftp:
                if direction == "put":
                    sftp.put(str(local_path), remote_path)
                else:
                    sftp.get(remote_path, str(local_path))
        finally:
            ssh.close()
        return

    cmd = [
        "scp",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=15",
        "-P", str(machine["port"]),
    ]
    if machine.get("identity"):
        cmd += ["-i", str(Path(machine["identity"]).expanduser())]
    remote_spec = f'{machine["user"]}@{machine["host"]}:{remote_path}'
    if direction == "put":
        cmd += [str(local_path), remote_spec]
    else:
        cmd += [remote_spec, str(local_path)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip().splitlines()
        hint = err[-1][:300] if err else f"exit {proc.returncode}"
        raise RuntimeError(f"Truyền bundle qua SCP thất bại: {hint}")
