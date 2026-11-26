"""Single-file Linux user, permission, and disk/partition worker sent over SSH."""
import grp
import json
import os
import pwd
import re
import shutil
import subprocess
from pathlib import Path

USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
GROUP_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
DEVICE_RE = re.compile(r"^/dev/[a-zA-Z0-9/_-]+$")
MODE_RE = re.compile(r"^[0-7]{3,4}$")
PROTECTED_PATHS = {
    "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64",
    "/proc", "/root", "/run", "/sbin", "/sys", "/usr", "/var",
}
PROTECTED_MOUNTS = {"/", "/boot", "/boot/efi", "/var", "/usr", "/etc", "/home", "[SWAP]"}


def run(*args, input_text=None, timeout=60):
    return subprocess.run(
        args, input=input_text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=timeout,
    )


def require(*args, message, input_text=None, timeout=60):
    res = run(*args, input_text=input_text, timeout=timeout)
    if res.returncode != 0:
        err = (res.stderr or res.stdout or "").strip()
        raise ValueError(f"{message}: {err}" if err else message)
    return res.stdout


def valid_username(name: str):
    if not USERNAME_RE.fullmatch(name or ""):
        raise ValueError("Tên user không hợp lệ (chỉ dùng chữ thường, số, _, -; bắt đầu bằng chữ hoặc _).")


def valid_path(raw: str) -> Path:
    text = (raw or "").strip()
    if not text.startswith("/") or "\x00" in text:
        raise ValueError("Đường dẫn phải là đường dẫn tuyệt đối bắt đầu bằng '/'.")
    resolved = str(Path(text))
    if resolved in PROTECTED_PATHS:
        raise ValueError(f"Không cho phép thao tác trực tiếp lên thư mục hệ thống '{resolved}'.")
    return Path(resolved)


def _sudo_status(username: str):
    if username == "root":
        return {"sudo": True, "nopasswd": True}
    try:
        groups = [g.gr_name for g in grp.getgrall() if username in g.gr_mem]
    except Exception:
        groups = []
    has_sudo = any(g in groups for g in ("sudo", "wheel", "admin"))
    nopasswd = False
    sudoers_dir = Path("/etc/sudoers.d")
    if sudoers_dir.is_dir():
        for entry in sudoers_dir.iterdir():
            if not entry.is_file():
                continue
            try:
                content = entry.read_text(errors="ignore")
            except OSError:
                continue
            for line in content.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if re.match(rf"^{re.escape(username)}\s+", line) and "NOPASSWD" in line:
                    nopasswd = True
                if line.startswith("%") and "NOPASSWD" in line:
                    gname = line[1:].split()[0]
                    if gname in groups:
                        nopasswd = True
    return {"sudo": has_sudo or nopasswd, "nopasswd": nopasswd}


def _locked_users():
    locked = set()
    shadow = Path("/etc/shadow")
    if not shadow.exists():
        return locked
    try:
        for line in shadow.read_text(errors="ignore").splitlines():
            parts = line.split(":")
            if len(parts) >= 2 and (parts[1].startswith("!") or parts[1].startswith("*")):
                locked.add(parts[0])
    except OSError:
        pass
    return locked


def _ssh_keys(home_dir: str):
    auth = Path(home_dir) / ".ssh" / "authorized_keys"
    if not auth.is_file():
        return []
    try:
        return [ln.strip() for ln in auth.read_text(errors="ignore").splitlines() if ln.strip() and not ln.strip().startswith("#")]
    except OSError:
        return []


def list_users(current_user: str):
    locked = _locked_users()
    all_groups = grp.getgrall()
    users = []
    for pw in sorted(pwd.getpwall(), key=lambda p: (0 if p.pw_uid == 0 else 1, p.pw_uid, p.pw_name)):
        if pw.pw_uid != 0 and (pw.pw_uid < 1000 or pw.pw_name == "nobody"):
            continue
        primary_group = grp.getgrgid(pw.pw_gid).gr_name if pw.pw_gid is not None else ""
        extra_groups = [g.gr_name for g in all_groups if pw.pw_name in g.gr_mem]
        groups = []
        for g in ([primary_group] + extra_groups):
            if g and g not in groups:
                groups.append(g)
        s = _sudo_status(pw.pw_name)
        keys = _ssh_keys(pw.pw_dir)
        users.append({
            "username": pw.pw_name,
            "uid": pw.pw_uid,
            "gid": pw.pw_gid,
            "home": pw.pw_dir,
            "shell": pw.pw_shell,
            "groups": groups,
            "sudo": s["sudo"],
            "nopasswd": s["nopasswd"],
            "locked": pw.pw_name in locked,
            "ssh_keys": keys,
            "ssh_key_count": len(keys),
            "is_current": pw.pw_name == current_user,
        })
    available_groups = sorted({g.gr_name for g in all_groups if g.gr_name in {"sudo", "wheel", "docker", "www-data", "adm", "systemd-journal"} or g.gr_gid >= 1000})
    return users, available_groups


def list_storage():
    disks = []
    res = run("lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,LABEL,MODEL")
    if res.returncode == 0 and res.stdout.strip():
        try:
            data = json.loads(res.stdout)
            for dev in data.get("blockdevices", []):
                if dev.get("type") not in ("disk", "loop", "lvm"):
                    continue
                if str(dev.get("name", "")).startswith("loop"):
                    continue
                children = []
                for ch in dev.get("children", []) or []:
                    children.append({
                        "name": ch.get("name"),
                        "path": ch.get("path"),
                        "size": int(ch.get("size") or 0),
                        "type": ch.get("type"),
                        "fstype": ch.get("fstype") or "",
                        "mountpoint": ch.get("mountpoint") or "",
                        "uuid": ch.get("uuid") or "",
                        "label": ch.get("label") or "",
                        "protected": (ch.get("mountpoint") or "") in PROTECTED_MOUNTS,
                    })
                disks.append({
                    "name": dev.get("name"),
                    "path": dev.get("path"),
                    "size": int(dev.get("size") or 0),
                    "type": dev.get("type"),
                    "fstype": dev.get("fstype") or "",
                    "mountpoint": dev.get("mountpoint") or "",
                    "uuid": dev.get("uuid") or "",
                    "model": (dev.get("model") or "").strip(),
                    "children": children,
                    "protected": (dev.get("mountpoint") or "") in PROTECTED_MOUNTS,
                })
        except json.JSONDecodeError:
            pass

    mounts = []
    df_res = run("df", "-B1", "-T", "-P")
    if df_res.returncode == 0:
        for line in df_res.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 7:
                continue
            fs, fstype, total, used, avail, pct, mnt = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], " ".join(parts[6:])
            if fstype in {"tmpfs", "devtmpfs", "squashfs", "overlay"}:
                continue
            mounts.append({
                "device": fs,
                "fstype": fstype,
                "size": int(total),
                "used": int(used),
                "avail": int(avail),
                "percent": pct,
                "mountpoint": mnt,
                "protected": mnt in PROTECTED_MOUNTS,
            })

    fstab = []
    fstab_path = Path("/etc/fstab")
    if fstab_path.is_file():
        for line in fstab_path.read_text(errors="ignore").splitlines():
            s = line.strip()
            if s and not s.startswith("#"):
                fstab.append(s)

    return {"disks": disks, "mounts": mounts, "fstab": fstab}


def _apply_sudoers(username: str, nopasswd: bool):
    if username == "root":
        return
    sudoers_file = Path(f"/etc/sudoers.d/90-zm-{username}")
    if not nopasswd:
        if sudoers_file.exists():
            sudoers_file.unlink()
        return
    tmp = Path(f"/etc/sudoers.d/.90-zm-{username}.tmp")
    tmp.write_text(f"{username} ALL=(ALL) NOPASSWD:ALL\n", encoding="utf-8")
    os.chmod(tmp, 0o440)
    chk = run("visudo", "-cf", str(tmp))
    if chk.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise ValueError("Cấu hình sudoers không hợp lệ.")
    tmp.replace(sudoers_file)


def _sync_ssh_keys(username: str, keys: list):
    pw = pwd.getpwnam(username)
    ssh_dir = Path(pw.pw_dir) / ".ssh"
    ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    os.chown(ssh_dir, pw.pw_uid, pw.pw_gid)
    clean = [k.strip() for k in (keys or []) if k and k.strip() and "\n" not in k.strip() and "\r" not in k.strip()]
    auth = ssh_dir / "authorized_keys"
    auth.write_text(("\n".join(clean) + "\n") if clean else "", encoding="utf-8")
    os.chmod(auth, 0o600)
    os.chown(auth, pw.pw_uid, pw.pw_gid)


def user_create(p: dict):
    username = (p.get("username") or "").strip()
    valid_username(username)
    try:
        pwd.getpwnam(username)
        raise ValueError(f"User '{username}' đã tồn tại.")
    except KeyError:
        pass
    shell = (p.get("shell") or "/bin/bash").strip()
    if shell not in {"/bin/bash", "/bin/sh", "/bin/zsh", "/usr/sbin/nologin", "/bin/false"}:
        raise ValueError("Shell không hợp lệ.")
    home = (p.get("home") or "").strip()
    cmd = ["useradd", "-m", "-s", shell]
    if home:
        cmd += ["-d", str(valid_path(home))]
    groups = [g.strip() for g in (p.get("groups") or []) if g and g.strip()]
    for g in groups:
        if not GROUP_RE.fullmatch(g):
            raise ValueError(f"Tên nhóm '{g}' không hợp lệ.")
    if p.get("sudo") and "sudo" not in groups:
        try:
            grp.getgrnam("sudo")
            groups.append("sudo")
        except KeyError:
            pass
    if groups:
        cmd += ["-G", ",".join(groups)]
    cmd.append(username)
    require(*cmd, message=f"Không tạo được user '{username}'")
    password = p.get("password") or ""
    if password:
        if any(ch in password for ch in "\r\n\x00"):
            raise ValueError("Mật khẩu chứa ký tự không hợp lệ.")
        require("chpasswd", input_text=f"{username}:{password}\n", message="Không đặt được mật khẩu")
    _apply_sudoers(username, bool(p.get("nopasswd")))
    if p.get("ssh_keys") is not None:
        _sync_ssh_keys(username, p.get("ssh_keys") or [])
    return {"ok": True, "username": username}


def user_update(p: dict, current_user: str):
    username = (p.get("username") or "").strip()
    valid_username(username)
    try:
        pwd.getpwnam(username)
    except KeyError:
        raise ValueError(f"Không tìm thấy user '{username}'.")
    if p.get("password"):
        pw_val = p["password"]
        if any(ch in pw_val for ch in "\r\n\x00"):
            raise ValueError("Mật khẩu chứa ký tự không hợp lệ.")
        require("chpasswd", input_text=f"{username}:{pw_val}\n", message="Không đổi được mật khẩu")
    if username != "root":
        if p.get("shell"):
            shell = p["shell"].strip()
            if shell not in {"/bin/bash", "/bin/sh", "/bin/zsh", "/usr/sbin/nologin", "/bin/false"}:
                raise ValueError("Shell không hợp lệ.")
            require("usermod", "-s", shell, username, message="Không đổi được shell")
        if p.get("groups") is not None:
            groups = [g.strip() for g in p["groups"] if g and g.strip()]
            for g in groups:
                if not GROUP_RE.fullmatch(g):
                    raise ValueError(f"Tên nhóm '{g}' không hợp lệ.")
            if p.get("sudo") and "sudo" not in groups:
                try:
                    grp.getgrnam("sudo")
                    groups.append("sudo")
                except KeyError:
                    pass
            if not p.get("sudo"):
                groups = [g for g in groups if g != "sudo"]
            require("usermod", "-G", ",".join(groups), username, message="Không cập nhật được nhóm")
        if p.get("nopasswd") is not None:
            _apply_sudoers(username, bool(p["nopasswd"]))
        if p.get("locked") is not None:
            if username == current_user and p["locked"]:
                raise ValueError("Không thể tự khóa tài khoản đang kết nối SSH.")
            require("usermod", "-L" if p["locked"] else "-U", username, message="Không cập nhật được trạng thái khóa")
    if p.get("ssh_keys") is not None:
        _sync_ssh_keys(username, p["ssh_keys"])
    return {"ok": True, "username": username}


def user_delete(p: dict, current_user: str):
    username = (p.get("username") or "").strip()
    valid_username(username)
    if username == "root":
        raise ValueError("Không thể xóa tài khoản root.")
    if username == current_user:
        raise ValueError("Không thể xóa tài khoản đang dùng để kết nối SSH.")
    _apply_sudoers(username, False)
    cmd = ["userdel"]
    if p.get("remove_home"):
        cmd.append("-r")
    cmd.append(username)
    require(*cmd, message=f"Không xóa được user '{username}'")
    return {"ok": True, "username": username}


def _find_block_device(device: str):
    storage = list_storage()
    for disk in storage["disks"]:
        if disk["path"] == device:
            return disk, True
        for ch in disk.get("children", []):
            if ch["path"] == device:
                return ch, False
    raise ValueError(f"Không tìm thấy thiết bị '{device}'.")


def storage_mount(p: dict):
    op = p.get("op")
    device = (p.get("device") or "").strip()
    if not DEVICE_RE.fullmatch(device):
        raise ValueError("Tên thiết bị không hợp lệ (ví dụ: /dev/sdb1).")
    info, is_disk = _find_block_device(device)
    if info.get("protected"):
        raise ValueError("Thiết bị thuộc phân vùng hệ thống, không được phép thao tác.")

    if op == "partition":
        if not is_disk:
            raise ValueError("Chỉ tạo phân vùng trên ổ đĩa gốc (ví dụ /dev/sdb).")
        if info.get("children"):
            raise ValueError("Ổ đĩa đã có phân vùng; hãy thao tác trực tiếp trên phân vùng hoặc ổ trống.")
        fstype = (p.get("fstype") or "ext4").strip()
        if fstype not in {"ext4", "xfs"}:
            raise ValueError("Chỉ hỗ trợ định dạng ext4 hoặc xfs.")
        require("parted", "-s", device, "mklabel", "gpt", "mkpart", "primary", fstype, "0%", "100%", message="Không tạo được phân vùng mới")
        run("partprobe", device)
        part = f"{device}1" if not device[-1].isdigit() else f"{device}p1"
        require("mkfs." + fstype, "-F" if fstype == "ext4" else "-f", part, message=f"Không format được {part}")
        return {"ok": True, "device": part}

    if op == "format":
        if is_disk and info.get("children"):
            raise ValueError("Không thể format ổ đĩa đang chứa phân vùng con.")
        if info.get("mountpoint"):
            raise ValueError(f"Thiết bị đang mount tại {info['mountpoint']}. Hãy unmount trước.")
        if (p.get("confirm_device") or "").strip() != device:
            raise ValueError(f"Nhập đúng tên thiết bị '{device}' để xác nhận format.")
        fstype = (p.get("fstype") or "ext4").strip()
        if fstype not in {"ext4", "xfs"}:
            raise ValueError("Chỉ hỗ trợ định dạng ext4 hoặc xfs.")
        require("mkfs." + fstype, "-F" if fstype == "ext4" else "-f", device, message=f"Format {device} thất bại")
        return {"ok": True, "device": device}

    if op == "mount":
        if info.get("mountpoint"):
            raise ValueError(f"Thiết bị đã được mount tại {info['mountpoint']}.")
        if not info.get("fstype"):
            raise ValueError("Phân vùng chưa có filesystem; hãy format trước khi mount.")
        target = valid_path(p.get("mountpoint") or "")
        target.mkdir(parents=True, exist_ok=True)
        require("mount", device, str(target), message=f"Mount {device} -> {target} thất bại")
        if p.get("persist_fstab"):
            uuid = (info.get("uuid") or "").strip()
            if not uuid:
                uuid = run("blkid", "-s", "UUID", "-o", "value", device).stdout.strip()
            spec = f"UUID={uuid}" if uuid else device
            fstab = Path("/etc/fstab")
            backup = fstab.read_text(encoding="utf-8") if fstab.exists() else ""
            if str(target) not in backup and spec not in backup:
                line = f"{spec} {target} {info['fstype']} defaults,nofail 0 2\n"
                fstab.write_text(backup.rstrip("\n") + "\n" + line, encoding="utf-8")
                chk = run("findmnt", "--verify")
                if chk.returncode != 0:
                    fstab.write_text(backup, encoding="utf-8")
                    raise ValueError("Kiểm tra /etc/fstab thất bại, đã khôi phục bản cũ.")
        if p.get("owner"):
            path_permissions({"path": str(target), "owner": p["owner"], "group": p.get("group") or p["owner"], "mode": p.get("mode") or "755", "recursive": False})
        return {"ok": True, "mountpoint": str(target)}

    if op == "unmount":
        mnt = info.get("mountpoint")
        if not mnt:
            raise ValueError("Thiết bị hiện chưa được mount.")
        if mnt in PROTECTED_MOUNTS:
            raise ValueError(f"Không được phép unmount phân vùng hệ thống '{mnt}'.")
        require("umount", mnt, message=f"Unmount {mnt} thất bại (có tiến trình đang sử dụng?)")
        if p.get("remove_fstab"):
            fstab = Path("/etc/fstab")
            if fstab.exists():
                lines = [ln for ln in fstab.read_text(encoding="utf-8").splitlines() if f" {mnt} " not in ln]
                fstab.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {"ok": True}

    raise ValueError("Thao tác ổ đĩa không hợp lệ.")


def path_permissions(p: dict):
    target = valid_path(p.get("path") or "")
    if p.get("create") and not target.exists():
        target.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        raise ValueError(f"Đường dẫn '{target}' không tồn tại.")

    owner = (p.get("owner") or "").strip()
    group = (p.get("group") or "").strip()
    mode = (p.get("mode") or "").strip()
    recursive = bool(p.get("recursive"))

    if owner:
        valid_username(owner)
        try:
            pwd.getpwnam(owner)
        except KeyError:
            raise ValueError(f"User '{owner}' không tồn tại.")
    if group:
        if not GROUP_RE.fullmatch(group):
            raise ValueError(f"Group '{group}' không hợp lệ.")
        try:
            grp.getgrnam(group)
        except KeyError:
            raise ValueError(f"Group '{group}' không tồn tại.")
    if owner or group:
        spec = f"{owner}:{group}" if (owner and group) else (owner or f":{group}")
        cmd = ["chown"] + (["-R"] if recursive else []) + [spec, str(target)]
        require(*cmd, message="Phân quyền owner/group (chown) thất bại")

    if mode:
        if not MODE_RE.fullmatch(mode):
            raise ValueError("Mode phải là 3 hoặc 4 chữ số octal (ví dụ 755, 750, 700).")
        cmd = ["chmod"] + (["-R"] if recursive else []) + [mode, str(target)]
        require(*cmd, message="Phân quyền mode (chmod) thất bại")

    st = target.stat()
    return {
        "ok": True,
        "path": str(target),
        "owner": pwd.getpwuid(st.st_uid).pw_name,
        "group": grp.getgrgid(st.st_gid).gr_name,
        "mode": oct(st.st_mode & 0o777)[2:],
    }


def serve(request):
    try:
        action = request["action"]
        p = request.get("params") or {}
        current_user = p.get("current_user") or pwd.getpwuid(os.getuid()).pw_name
        if action == "overview":
            users, groups = list_users(current_user)
            result = {"users": users, "groups": groups, **list_storage()}
        elif action == "user_create":
            result = user_create(p)
        elif action == "user_update":
            result = user_update(p, current_user)
        elif action == "user_delete":
            result = user_delete(p, current_user)
        elif action == "storage_mount":
            result = storage_mount(p)
        elif action == "path_permissions":
            result = path_permissions(p)
        else:
            raise ValueError(f"Tác vụ không hỗ trợ: {action}")
        print(json.dumps({"result": result}), flush=True)
    except Exception as exc:
        msg = str(exc) if isinstance(exc, ValueError) else f"Sysadmin worker lỗi: {exc}"
        print(json.dumps({"error": msg}), flush=True)
