"""Self-contained worker for scanning, exporting, and deploying Portable VPS Stacks."""
import json
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

EXCLUDE_DIRS = {"node_modules", ".git", ".venv", "venv", "__pycache__", ".next", "dist"}


def emit(message):
    print(json.dumps({"event": message}), flush=True)


def run_cmd(args, timeout=120, check=True, cwd=None, user=None):
    cmd = args
    if user and os.geteuid() == 0 and user != "root":
        shell_str = " ".join(shlex.quote(str(a)) for a in args)
        if cwd:
            shell_str = f"cd {shlex.quote(str(cwd))} && {shell_str}"
        cmd = ["su", "-", user, "-c", shell_str]
        cwd = None
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        errors="replace",
        timeout=timeout,
        cwd=str(cwd) if cwd else None,
    )
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise RuntimeError(detail[-1][:400] if detail else f"Command failed: {' '.join(args)}")
    return proc


def user_env_cmd(user, script, timeout=60, check=True):
    """Run a shell snippet as login_user with NVM/npm/pm2 PATH loaded."""
    preamble = (
        'export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node 2>/dev/null | tail -n 1)/bin:$PATH"; '
        '[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true; '
    )
    full = preamble + script
    if user and os.geteuid() == 0 and user != "root":
        cmd = ["su", "-", user, "-c", full]
    else:
        cmd = ["bash", "-lc", full]
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise RuntimeError(detail[-1][:400] if detail else "Lỗi thực thi lệnh người dùng.")
    return proc


def validate_tar_members(tar):
    for member in tar.getmembers():
        name = member.name
        if not name or name.startswith("/") or "\\" in name:
            raise ValueError(f"Đường dẫn không an toàn trong gói: {name}")
        if any(part == ".." for part in Path(name).parts):
            raise ValueError(f"Phát hiện path traversal trong gói: {name}")
        if member.issym() or member.islnk():
            link = member.linkname or ""
            if link.startswith("/") or ".." in Path(link).parts:
                raise ValueError(f"Liên kết không an toàn trong gói: {name}")
        elif not (member.isdir() or member.isfile()):
            raise ValueError(f"Loại tệp không hợp lệ trong gói: {name}")


def scan_pm2(login_user):
    apps = []
    seen = set()
    users = [login_user] if login_user and login_user != "root" else []
    users.append("root")
    for u in dict.fromkeys(users):
        proc = user_env_cmd(u, "command -v pm2 >/dev/null 2>&1 && pm2 jlist || echo '[]'", timeout=30, check=False)
        if proc.returncode != 0 or not proc.stdout.strip():
            continue
        try:
            rows = json.loads(proc.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            continue
        if not isinstance(rows, list):
            continue
        for row in rows:
            name = row.get("name") or ""
            env = row.get("pm2_env") or {}
            cwd = env.get("pm_cwd") or ""
            if not name or not cwd or (name, cwd) in seen:
                continue
            seen.add((name, cwd))
            apps.append({
                "name": name,
                "cwd": cwd,
                "script": env.get("pm_exec_path") or "",
                "args": env.get("args") or [],
                "interpreter": env.get("exec_interpreter") or "",
                "status": env.get("status") or "unknown",
                "port": env.get("PORT") or (env.get("env") or {}).get("PORT") or "",
                "user": u,
            })
    return apps


def scan_compose():
    if not shutil.which("docker"):
        return []
    proc = run_cmd(["docker", "--host", "unix:///var/run/docker.sock", "compose", "ls", "--format", "json"], timeout=20, check=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    try:
        rows = json.loads(proc.stdout)
    except ValueError:
        return []
    projects = []
    for row in rows:
        name = row.get("Name") or ""
        cfg = row.get("ConfigFiles") or ""
        if name and cfg:
            first_cfg = cfg.split(",")[0].strip()
            projects.append({
                "name": name,
                "status": row.get("Status") or "",
                "config_file": first_cfg,
                "dir": str(Path(first_cfg).parent),
            })
    return projects


def scan_nginx():
    root = Path("/etc/nginx")
    if not root.is_dir():
        return []
    sites = []
    enabled_targets = set()
    se_dir = root / "sites-enabled"
    if se_dir.is_dir():
        for p in se_dir.iterdir():
            if p.is_symlink() or p.is_file():
                try:
                    enabled_targets.add(str(p.resolve()))
                except OSError:
                    pass
    candidates = []
    if (root / "conf.d").is_dir():
        candidates.extend((p, True, True) for p in sorted((root / "conf.d").glob("*.conf")))
    if (root / "sites-available").is_dir():
        for p in sorted((root / "sites-available").iterdir()):
            if p.is_file() and p.name != "default":
                candidates.append((p, False, str(p.resolve()) in enabled_targets))
    for path, in_conf_d, enabled in candidates:
        content = path.read_text(errors="replace")
        domains = []
        for match in re.findall(r"server_name\s+([^;]+);", content):
            for token in match.split():
                if token and token != "_" and token not in domains:
                    domains.append(token)
        certs = sorted(set(re.findall(r"/etc/letsencrypt/live/([^/\s;]+)/", content)))
        sites.append({
            "filename": path.name,
            "source": str(path),
            "in_conf_d": in_conf_d,
            "enabled": enabled,
            "domains": domains,
            "ssl_certs": certs,
        })
    return sites


def scan_mongo():
    has_mongod = bool(shutil.which("mongod"))
    has_dump = bool(shutil.which("mongodump"))
    has_restore = bool(shutil.which("mongorestore"))
    active = False
    if shutil.which("systemctl"):
        proc = run_cmd(["systemctl", "is-active", "mongod"], timeout=10, check=False)
        active = proc.stdout.strip() == "active"
    dbs = []
    if active and shutil.which("mongosh"):
        proc = run_cmd(
            ["mongosh", "--quiet", "--eval", "JSON.stringify(db.adminCommand({listDatabases:1}).databases.map(d=>({name:d.name,sizeOnDisk:d.sizeOnDisk})))"],
            timeout=15,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            try:
                rows = json.loads(proc.stdout.strip().splitlines()[-1])
                dbs = [d for d in rows if d.get("name") not in {"admin", "local", "config"}]
            except (ValueError, IndexError):
                pass
    return {
        "installed": has_mongod,
        "active": active,
        "has_tools": has_dump and has_restore,
        "databases": dbs,
    }


def add_dir_to_tar(tar, src_dir: Path, arc_prefix: str):
    if not src_dir.is_dir():
        return
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        rel_root = Path(root).relative_to(src_dir)
        for fname in files:
            fpath = Path(root) / fname
            if fpath.is_symlink() or not fpath.is_file():
                continue
            if fname.endswith(".log") or fpath.stat().st_size > 100 * 1024 * 1024:
                continue
            arcname = str(Path(arc_prefix) / rel_root / fname)
            tar.add(fpath, arcname=arcname, recursive=False)


def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".zm-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, path)
    except Exception:
        Path(tmp).unlink(missing_ok=True)
        raise


def do_export(p):
    login_user = p.get("login_user") or "root"
    bundle_id = p.get("bundle_id") or f"zm-stack-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.tar.gz"
    remote_path = f"/tmp/{bundle_id}"

    all_pm2 = scan_pm2(login_user)
    wanted_pm2 = set(p.get("pm2_apps") or [])
    sel_pm2 = [a for a in all_pm2 if a["name"] in wanted_pm2]

    all_compose = scan_compose()
    wanted_compose = set(p.get("compose_projects") or [])
    sel_compose = [c for c in all_compose if c["name"] in wanted_compose]

    all_nginx = scan_nginx()
    wanted_nginx = set(p.get("nginx_files") or [])
    sel_nginx = [s for s in all_nginx if s["filename"] in wanted_nginx]

    include_ssl = bool(p.get("include_ssl", True))
    include_mongo = bool(p.get("include_mongo", False))
    mongo_uri = (p.get("mongo_uri") or "").strip()

    with tempfile.TemporaryDirectory(prefix="zm-export-") as tmpdir:
        tmp = Path(tmpdir)
        manifest = {
            "version": 1,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "source_user": login_user,
            "pm2_apps": [],
            "compose_projects": [],
            "nginx_sites": [],
            "ssl_certs": [],
            "mongodb": {"included": False},
        }

        with tarfile.open(remote_path, "w:gz") as tar:
            for app in sel_pm2:
                emit(f"Đóng gói PM2 app · {app['name']}")
                cwd = Path(app["cwd"])
                if cwd.is_dir():
                    add_dir_to_tar(tar, cwd, f"projects/pm2/{app['name']}")
                manifest["pm2_apps"].append({
                    "name": app["name"],
                    "cwd": app["cwd"],
                    "script": app["script"],
                    "args": app["args"],
                    "interpreter": app["interpreter"],
                    "port": app["port"],
                })

            for proj in sel_compose:
                emit(f"Đóng gói Compose · {proj['name']}")
                pdir = Path(proj["dir"])
                if pdir.is_dir():
                    add_dir_to_tar(tar, pdir, f"projects/compose/{proj['name']}")
                manifest["compose_projects"].append({
                    "name": proj["name"],
                    "dir": proj["dir"],
                    "config_name": Path(proj["config_file"]).name,
                })

            ssl_seen = set()
            for site in sel_nginx:
                emit(f"Đóng gói Nginx · {site['filename']}")
                src = Path(site["source"])
                if src.is_file():
                    tar.add(src, arcname=f"nginx/sites/{site['filename']}")
                    manifest["nginx_sites"].append({
                        "filename": site["filename"],
                        "in_conf_d": site["in_conf_d"],
                        "enabled": site["enabled"],
                        "domains": site["domains"],
                    })
                    if include_ssl:
                        for cname in site["ssl_certs"]:
                            if cname in ssl_seen:
                                continue
                            cdir = Path("/etc/letsencrypt/live") / cname
                            if (cdir / "fullchain.pem").is_file() and (cdir / "privkey.pem").is_file():
                                ssl_seen.add(cname)
                                tar.add(cdir / "fullchain.pem", arcname=f"nginx/ssl/{cname}/fullchain.pem")
                                tar.add(cdir / "privkey.pem", arcname=f"nginx/ssl/{cname}/privkey.pem")
                                manifest["ssl_certs"].append(cname)

            if include_mongo:
                if not shutil.which("mongodump"):
                    raise RuntimeError("VPS nguồn chưa cài mongodump (mongodb-database-tools).")
                emit("Đang backup MongoDB (mongodump --gzip)…")
                dump_file = tmp / "dump.archive.gz"
                cmd = ["mongodump", "--gzip", f"--archive={dump_file}"]
                if mongo_uri:
                    cmd += [f"--uri={mongo_uri}"]
                run_cmd(cmd, timeout=1800)
                tar.add(dump_file, arcname="mongodb/dump.archive.gz")
                manifest["mongodb"] = {"included": True, "size": dump_file.stat().st_size}

            manifest_file = tmp / "zm-stack-manifest.json"
            manifest_file.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
            tar.add(manifest_file, arcname="zm-stack-manifest.json")

    return {"remote_path": remote_path, "bundle_id": bundle_id, "manifest": manifest, "size": Path(remote_path).stat().st_size}


def ensure_software(manifest, opts):
    need_nginx = bool(opts.get("restore_nginx") and manifest.get("nginx_sites"))
    need_pm2 = bool(opts.get("restore_apps") and manifest.get("pm2_apps"))
    need_compose = bool(opts.get("restore_apps") and manifest.get("compose_projects"))
    need_mongo = bool(opts.get("restore_mongo") and (manifest.get("mongodb") or {}).get("included"))

    apt = shutil.which("apt-get")
    if need_nginx and not shutil.which("nginx"):
        emit("Đang cài đặt Nginx…")
        if apt:
            run_cmd(["apt-get", "update", "-qq"], timeout=300)
            run_cmd(["apt-get", "install", "-y", "nginx"], timeout=300)
        run_cmd(["systemctl", "enable", "--now", "nginx"], timeout=30, check=False)

    if need_pm2 and not (shutil.which("node") and shutil.which("pm2")):
        emit("Đang cài đặt Node.js & PM2…")
        if apt and not shutil.which("node"):
            run_cmd(["apt-get", "update", "-qq"], timeout=300)
            run_cmd(["apt-get", "install", "-y", "nodejs", "npm"], timeout=300)
        if not shutil.which("pm2"):
            run_cmd(["npm", "install", "-g", "pm2"], timeout=300)

    if need_compose and not shutil.which("docker"):
        emit("Đang cài đặt Docker & Compose…")
        if apt:
            run_cmd(["apt-get", "update", "-qq"], timeout=300)
            run_cmd(["apt-get", "install", "-y", "docker.io", "docker-compose-plugin"], timeout=600)
            run_cmd(["systemctl", "enable", "--now", "docker"], timeout=30, check=False)

    if need_mongo and not shutil.which("mongorestore"):
        emit("Đang kiểm tra / cài đặt MongoDB tools…")
        if apt:
            run_cmd(["apt-get", "update", "-qq"], timeout=300)
            run_cmd(["apt-get", "install", "-y", "mongodb-database-tools"], timeout=300, check=False)


def do_deploy(p):
    remote_path = p["remote_path"]
    login_user = p.get("login_user") or "root"
    install_missing = bool(p.get("install_missing", True))
    restore_apps = bool(p.get("restore_apps", True))
    restore_nginx = bool(p.get("restore_nginx", True))
    overwrite_nginx = bool(p.get("overwrite_nginx", False))
    restore_mongo = bool(p.get("restore_mongo", True))
    mongo_drop = bool(p.get("mongo_drop", False))
    mongo_uri = (p.get("mongo_uri") or "").strip()
    open_firewall = bool(p.get("open_firewall", True))

    bundle = Path(remote_path)
    if not bundle.is_file():
        raise RuntimeError("Không tìm thấy file bundle trên VPS đích.")

    summary = {"pm2": [], "compose": [], "nginx": [], "mongodb": False}

    try:
        with tempfile.TemporaryDirectory(prefix="zm-deploy-") as tmpdir:
            tmp = Path(tmpdir)
            emit("Đang giải nén và kiểm tra gói bundle…")
            with tarfile.open(bundle, "r:gz") as tar:
                validate_tar_members(tar)
                tar.extractall(tmp)

        manifest_path = tmp / "zm-stack-manifest.json"
        if not manifest_path.is_file():
            raise RuntimeError("Thiếu zm-stack-manifest.json trong gói.")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        if install_missing:
            ensure_software(manifest, p)

        # 1. Restore MongoDB first so apps have database ready
        dump_file = tmp / "mongodb" / "dump.archive.gz"
        if restore_mongo and (manifest.get("mongodb") or {}).get("included") and dump_file.is_file():
            if not shutil.which("mongorestore"):
                raise RuntimeError("VPS đích chưa có mongorestore. Hãy cài MongoDB / Database Tools trước.")
            emit("Đang khôi phục dữ liệu MongoDB (mongorestore)…")
            cmd = ["mongorestore", "--gzip", f"--archive={dump_file}", "--stopOnError"]
            if mongo_drop:
                cmd.append("--drop")
            if mongo_uri:
                cmd.append(f"--uri={mongo_uri}")
            run_cmd(cmd, timeout=1800)
            summary["mongodb"] = True

        # 2. Restore & start PM2 apps + Docker Compose projects
        if restore_apps:
            uid_gid = None
            if login_user != "root":
                try:
                    pw = pwd.getpwnam(login_user)
                    uid_gid = (pw.pw_uid, pw.pw_gid)
                except KeyError:
                    uid_gid = None

            for app in manifest.get("pm2_apps") or []:
                name = app["name"]
                src_dir = tmp / "projects" / "pm2" / name
                dest_dir = Path(app["cwd"])
                if not src_dir.is_dir():
                    continue
                emit(f"Triển khai PM2 app · {name} -> {dest_dir}")
                dest_dir.mkdir(parents=True, exist_ok=True)
                shutil.copytree(src_dir, dest_dir, dirs_exist_ok=True)
                if uid_gid:
                    for root_d, dirs_d, files_d in os.walk(dest_dir):
                        os.chown(root_d, *uid_gid)
                        for f in files_d:
                            os.chown(Path(root_d) / f, *uid_gid)

                if (dest_dir / "package.json").is_file() and not (dest_dir / "node_modules").is_dir():
                    emit(f"Cài dependencies (npm install) · {name}")
                    user_env_cmd(login_user, f"cd {shlex.quote(str(dest_dir))} && npm install --omit=dev", timeout=600)

                script_path = app.get("script") or ""
                rel_or_abs = script_path if script_path else "index.js"
                if script_path and not Path(script_path).is_file():
                    candidate = dest_dir / Path(script_path).name
                    if candidate.is_file():
                        rel_or_abs = str(candidate)
                emit(f"Khởi động PM2 · {name}")
                user_env_cmd(
                    login_user,
                    f"cd {shlex.quote(str(dest_dir))} && pm2 delete {shlex.quote(name)} >/dev/null 2>&1 || true; "
                    f"pm2 start {shlex.quote(rel_or_abs)} --name {shlex.quote(name)} && pm2 save",
                    timeout=120,
                )
                summary["pm2"].append(name)

            for proj in manifest.get("compose_projects") or []:
                name = proj["name"]
                src_dir = tmp / "projects" / "compose" / name
                dest_dir = Path(proj.get("dir") or f"/opt/zm-stacks/{name}")
                if not src_dir.is_dir():
                    continue
                emit(f"Triển khai Docker Compose · {name} -> {dest_dir}")
                dest_dir.mkdir(parents=True, exist_ok=True)
                shutil.copytree(src_dir, dest_dir, dirs_exist_ok=True)
                cfg = dest_dir / (proj.get("config_name") or "compose.yaml")
                run_cmd(["docker", "--host", "unix:///var/run/docker.sock", "compose", "-f", str(cfg), "up", "-d", "--build"], timeout=1200)
                summary["compose"].append(name)

        # 3. Restore Nginx & SSL
        if restore_nginx and (manifest.get("nginx_sites") or []):
            nginx_root = Path("/etc/nginx")
            created = []
            for cname in manifest.get("ssl_certs") or []:
                src_cert = tmp / "nginx" / "ssl" / cname
                if (src_cert / "fullchain.pem").is_file() and (src_cert / "privkey.pem").is_file():
                    cdir = Path("/etc/letsencrypt/live") / Path(cname).name
                    cdir.mkdir(parents=True, exist_ok=True)
                    atomic_write(cdir / "fullchain.pem", (src_cert / "fullchain.pem").read_text())
                    atomic_write(cdir / "privkey.pem", (src_cert / "privkey.pem").read_text())
                    os.chmod(cdir / "privkey.pem", 0o600)

            for site in manifest.get("nginx_sites") or []:
                fname = Path(site["filename"]).name
                src_conf = tmp / "nginx" / "sites" / fname
                if not src_conf.is_file():
                    continue
                dest = (nginx_root / "conf.d" / fname) if site.get("in_conf_d") else (nginx_root / "sites-available" / fname)
                existed = dest.exists()
                if existed and not overwrite_nginx:
                    summary["nginx"].append(f"{fname} (bỏ qua: đã tồn tại)")
                    continue
                atomic_write(dest, src_conf.read_text())
                if not existed:
                    created.append(dest)
                if not site.get("in_conf_d") and site.get("enabled", True):
                    link = nginx_root / "sites-enabled" / fname
                    if not link.exists():
                        link.symlink_to(dest)
                        created.append(link)
                summary["nginx"].append(fname)

            emit("Kiểm tra & reload Nginx…")
            try:
                run_cmd(["nginx", "-t"], timeout=30)
                run_cmd(["systemctl", "reload", "nginx"], timeout=30)
            except Exception:
                for cp in reversed(created):
                    cp.unlink(missing_ok=True)
                raise

        # 4. Open HTTP/HTTPS on UFW if active
        if open_firewall and shutil.which("ufw"):
            ufw_state = run_cmd(["ufw", "status"], timeout=10, check=False)
            if "Status: active" in (ufw_state.stdout or ""):
                emit("Mở port 80, 443 trên UFW…")
                run_cmd(["ufw", "allow", "80/tcp"], timeout=15, check=False)
                run_cmd(["ufw", "allow", "443/tcp"], timeout=15, check=False)

        return summary
    finally:
        bundle.unlink(missing_ok=True)


def execute(action, p):
    if action == "stack-scan":
        return {
            "pm2": scan_pm2(p.get("login_user") or "root"),
            "compose": scan_compose(),
            "nginx": scan_nginx(),
            "mongodb": scan_mongo(),
        }
    if action == "stack-export":
        return do_export(p)
    if action == "stack-deploy":
        return do_deploy(p)
    raise ValueError("Thao tác Portable Stack không hợp lệ.")


def serve(request):
    try:
        print(json.dumps({"result": execute(request["action"], request["params"])}), flush=True)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    serve(json.load(sys.stdin))
