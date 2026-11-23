"""Fixed, allowlisted worker sent to a local host or over SSH; JSON on stdin/stdout.

Never execute the legacy interactive scripts from a web request.
"""
import base64
import datetime
import gzip
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


def event(message):
    print(json.dumps({"event": message}, ensure_ascii=False), flush=True)


def run(args, timeout=60, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
    if check and result.returncode:
        if args[0] in {"mongodump", "mongorestore"}:
            message = result.stderr.lower()
            for marker, explanation in [
                ("duplicate key", "Document trùng khóa ở đích. Chọn đích trống hoặc xác nhận thay thế collection."),
                ("authentication failed", "Xác thực thất bại. Kiểm tra tài khoản, mật khẩu và auth database."),
                ("unauthorized", "Tài khoản thiếu quyền hoặc phiên xác thực đã thay đổi. Kiểm tra quyền backup/restore và replay oplog."),
                ("no space left", "Máy thực thi hoặc cụm đích hết dung lượng."),
                ("server selection", "Máy thực thi không kết nối được cụm. Kiểm tra seed, DNS, TLS và firewall."),
            ]:
                if marker in message:
                    raise RuntimeError(f"{args[0]}: {explanation}")
        # Commands may contain secrets. Never print argv or tool stderr blindly.
        raise RuntimeError(f"{Path(args[0]).name} thất bại (exit {result.returncode}). Kiểm tra journal/log trên máy đích.")
    return result.stdout.strip()


def linux_info():
    info = {}
    if Path("/etc/os-release").exists():
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                info[k] = v.strip('"')
    return info


def preflight(p):
    info = linux_info()
    disk = shutil.disk_usage("/")
    tools = {name: bool(shutil.which(name)) for name in ["mongod", "mongosh", "mongodump", "mongorestore", "systemctl"]}
    version = run(["mongod", "--version"], check=False) if tools["mongod"] else "Chưa cài"
    service = p.get("service", "mongod")
    active = run(["systemctl", "is-active", service], check=False) if tools["systemctl"] else "Không có systemd"
    mem = ""
    if Path("/proc/meminfo").exists():
        mem = Path("/proc/meminfo").read_text().splitlines()[0]
    services = []
    if tools["systemctl"]:
        services = [line.split()[0] for line in run(["systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager"], check=False).splitlines()
                    if line.startswith("mongod") and line.split()[0].endswith(".service")]
    installed = tools["mongod"] or bool(services)
    next_step = "adopt" if installed else "provision"
    return {"os": info.get("PRETTY_NAME", platform.platform()), "codename": info.get("VERSION_CODENAME", ""),
            "architecture": platform.machine(), "kernel": platform.release(), "hostname": socket.gethostname(),
            "disk_free_gb": round(disk.free / 1024**3, 1), "disk_total_gb": round(disk.total / 1024**3, 1),
            "memory": mem, "tools": tools, "version": version, "service": service, "service_state": active,
            "services": services, "mongodb_detected": installed, "next_step": next_step,
            "recommendation": "Đã phát hiện MongoDB. Tiếp nhận cụm hiện có bằng endpoint và tài khoản MongoDB; không chạy khởi tạo lại." if installed else "Chưa phát hiện package/service MongoDB trên máy. Có thể cài cụm mới hoặc chuẩn bị node cho cụm đang có. Docker/container cần kiểm tra riêng."}


def install(p):
    info = linux_info()
    codename = info.get("VERSION_CODENAME")
    series = p["series"]
    supported = {"8.0": {"jammy", "noble"}, "9.0": {"jammy", "noble", "resolute"}}
    if info.get("ID") != "ubuntu" or codename not in supported.get(series, set()):
        raise RuntimeError("Tổ hợp Ubuntu/MongoDB chưa được hỗ trợ. Không thay repository.")
    if shutil.which("mongod"):
        raise RuntimeError("MongoDB đã được cài. Tác vụ cài mới không thay hoặc nâng phiên bản hiện có.")
    arch = run(["dpkg", "--print-architecture"])
    if arch not in {"amd64", "arm64"}:
        raise RuntimeError("Chỉ hỗ trợ amd64/arm64 có package chính thức.")
    base = f"https://repo.mongodb.org/apt/ubuntu/dists/{codename}/mongodb-org/{series}/multiverse/binary-{arch}/Packages.gz"
    import gzip
    event("Kiểm tra package chính thức và phiên bản tương thích…")
    with urllib.request.urlopen(base, timeout=30) as response:
        packages = gzip.decompress(response.read()).decode()
    names = ["mongodb-org", "mongodb-org-database", "mongodb-org-server", "mongodb-org-shell", "mongodb-org-mongos", "mongodb-org-tools", "mongodb-org-database-tools-extra"]
    version = install_version(packages, names, series, codename)
    event(f"Cài MongoDB {version} cho Ubuntu {codename} / {arch}.")
    run(["apt-get", "update"], timeout=600)
    run(["apt-get", "-o", "DPkg::Lock::Timeout=120", "install", "-y", "gnupg", "ca-certificates"], timeout=600)
    key_version = "9" if series == "9.0" else "8.0"
    with urllib.request.urlopen(f"https://pgp.mongodb.com/server-{key_version}.asc", timeout=30) as response:
        key_data = response.read()
    with tempfile.TemporaryDirectory() as tmp:
        asc = Path(tmp) / "key.asc"
        asc.write_bytes(key_data)
        keypath = f"/usr/share/keyrings/mongodb-server-{series}.gpg"
        run(["gpg", "--batch", "--yes", "--dearmor", "--output", keypath, str(asc)])
    Path(keypath).chmod(0o644)
    repo = Path(f"/etc/apt/sources.list.d/mongodb-org-{series}.list")
    repo.write_text(f"deb [arch={arch} signed-by={keypath}] https://repo.mongodb.org/apt/ubuntu {codename}/mongodb-org/{series} multiverse\n")
    run(["apt-get", "update"], timeout=600)
    run(["apt-get", "-o", "DPkg::Lock::Timeout=120", "install", "-y", *[f"{n}={version}" for n in names], "mongodb-mongosh", "mongodb-database-tools"], timeout=1200)
    return {"version": version, "message": "Đã cài package. Tiếp tục wizard tạo replica set."}


def install_version(packages, names, series, codename):
    common = set.intersection(*(set(package_versions(packages, name)) for name in names))
    stable = [v for v in common if re.fullmatch(re.escape(series) + r"\.\d+", v)]
    if codename == "resolute":
        stable = [v for v in stable if int(v.split(".")[-1]) >= 4]
    if not stable:
        raise RuntimeError(f"Repository chưa có đủ bộ package MongoDB {series} tương thích với Ubuntu {codename}.")
    return max(stable, key=lambda v: int(v.split(".")[-1]))


def package_versions(packages, name):
    versions = []
    for block in packages.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line and not line.startswith(" "))
        if fields.get("Package") == name and "Version" in fields:
            versions.append(fields["Version"])
    return versions


def shell_js(source, values, timeout=120):
    # Script contains secrets; only the random file path appears in the process list.
    with tempfile.TemporaryDirectory(prefix="mongo-manager-") as directory:
        script = Path(directory) / "task.js"
        script.write_text("const input = " + json.dumps(values) + ";\n" + source)
        script.chmod(0o600)
        result = run(["mongosh", "--quiet", "--nodb", "--file", str(script)], timeout=timeout)
        return json.loads(result.splitlines()[-1])


def check_instance_target(p):
    instance = p["instance"]
    for base in ("/etc/mongodb-manager", "/var/lib/mongodb-manager", "/var/log/mongodb-manager"):
        if (Path(base) / instance).exists():
            raise RuntimeError("Instance hoặc dữ liệu đã tồn tại. Kiểm tra máy và tiếp nhận cấu hình, không chạy lại khởi tạo.")
    with socket.socket() as listener:
        try:
            listener.bind(("0.0.0.0", p["port"]))
        except OSError as exc:
            if exc.errno == 98:
                raise RuntimeError('Port ' + str(p['port']) + ' đang được service khác sử dụng. Kiểm tra MongoDB đang chạy; dùng chế độ node đã chuẩn bị nếu cấu hình đúng, hoặc chọn port khác để tạo instance riêng. Không tự dừng/xóa instance đang có.') from None
            raise


def provision(p):
    check_instance_target(p)
    if not shutil.which("mongod"):
        install(p)
    if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", run(["mongod", "--version"])):
        raise RuntimeError("Binary MongoDB đích không cùng nhánh đã chọn. Không tự thay phiên bản đang có.")
    return setup(p)


def setup(p, bootstrap=True):
    if linux_info().get("ID") != "ubuntu" or not shutil.which("systemctl"):
        raise RuntimeError("Setup service chỉ hỗ trợ Ubuntu dùng systemd.")
    if not shutil.which("mongod") or not shutil.which("mongosh"):
        raise RuntimeError("Cần cài MongoDB Server và mongosh trước.")
    instance = p["instance"]
    port = p["port"]
    service = f"mongod-manager-{instance}"
    root = Path("/etc/mongodb-manager") / instance
    data = Path("/var/lib/mongodb-manager") / instance
    check_instance_target(p)
    import pwd
    account = pwd.getpwnam("mongodb")
    logdir = Path("/var/log/mongodb-manager") / instance
    for directory in (root, data, logdir):
        try:
            directory.parent.mkdir(mode=0o711)
        except FileExistsError:
            pass
        else:
            directory.parent.chmod(0o711)
        directory.mkdir(mode=0o750)

        os.chown(directory, account.pw_uid, account.pw_gid)
    keyfile = root / "keyfile"
    keyfile.touch(mode=0o600, exist_ok=False)
    keyfile.write_text(base64.b64decode(p["keyfile_b64"]).decode() if not bootstrap else base64.b64encode(secrets.token_bytes(512)).decode())
    keyfile.chmod(0o400)
    os.chown(keyfile, account.pw_uid, account.pw_gid)
    config = {"storage": {"dbPath": str(data)}, "systemLog": {"destination": "file", "path": str(logdir / "mongod.log"), "logAppend": True},
              "net": {"port": port, "bindIp": p["bind_ip"]}, "replication": {"replSetName": p["replica_set"]},
              "security": {"authorization": "enabled", "keyFile": str(keyfile)}}
    # Direct IP endpoints are supported by this manager, without split-horizon DNS.
    config["setParameter"] = {"disableSplitHorizonIPCheck": True}
    configpath = root / "mongod.conf"
    configpath.write_text(json.dumps(config, indent=2))
    os.chown(configpath, account.pw_uid, account.pw_gid)
    configpath.chmod(0o600)
    unit = Path(f"/etc/systemd/system/{service}.service")
    unit.write_text(f"[Unit]\nDescription=MongoDB Manager {instance}\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nUser=mongodb\nGroup=mongodb\nExecStart=/usr/bin/mongod --config {configpath}\nRestart=on-failure\nLimitNOFILE=64000\nTimeoutStopSec=120\n\n[Install]\nWantedBy=multi-user.target\n")
    event("Đã tạo cấu hình và service riêng. Khởi động với keyfile và auth…")
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "--now", service])
    if not bootstrap:
        event("Node mới dùng keyfile của cụm nguồn. Không chạy replSetInitiate hoặc tạo user trên node này.")
        return {"prepared": True, "service": service, "config": str(configpath), "data": str(data)}
    try:
        result = shell_js('''
let conn;
for(let i=0;i<60;i++) { try { conn=new Mongo("mongodb://127.0.0.1:"+input.port+"/?directConnection=true&serverSelectionTimeoutMS=1000"); conn.getDB("admin").runCommand({ping:1}); break; } catch(e) { sleep(1000); } }
if(!conn) throw new Error("MongoDB chưa sẵn sàng");
const admin=conn.getDB("admin");
let r=admin.runCommand({replSetInitiate:{_id:input.replica_set,members:[{_id:0,host:input.advertise}]}});
if(!r.ok) throw new Error("Không khởi tạo được replica set");
let ready=false;
for(let i=0;i<60;i++){if(admin.runCommand({hello:1}).isWritablePrimary){ready=true;break;} sleep(1000);}
if(!ready) throw new Error("Chưa bầu được primary");
r=admin.runCommand({createUser:input.username,pwd:input.password,roles:[{role:"root",db:"admin"}]});
if(!r.ok) throw new Error("Không tạo được user");
if(!admin.auth(input.username,input.password)) throw new Error("Xác thực thất bại");
print(JSON.stringify({ready:true,primary:input.advertise}));
''', p, timeout=180)
    except Exception:
        event(f"Bootstrap chưa hoàn tất. Đã giữ lại cấu hình tại {root}; xem journal của {service}.")
        raise
    return {**result, "service": service, "config": str(configpath), "data": str(data), "keyfile": str(keyfile)}


def prepare_member(p):
    root = Path('/etc/mongodb-manager') / p['instance']
    data = Path('/var/lib/mongodb-manager') / p['instance']
    configpath = root / 'mongod.conf'
    existing = configpath.is_file() and data.is_dir()
    if not existing:
        check_instance_target(p)
    if not shutil.which("mongod"):
        install(p)
    version = run(["mongod", "--version"])
    if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", version):
        raise RuntimeError("Binary MongoDB đích không cùng nhánh với cụm nguồn. Không tự thay phiên bản đang có.")
    if existing:
        config = json.loads(configpath.read_text())
        keypath = root / 'keyfile'
        expected_key = base64.b64decode(p['keyfile_b64']).decode()
        if (config.get('replication', {}).get('replSetName') != p['replica_set']
                or config.get('net', {}).get('port') != p['port']
                or config.get('net', {}).get('bindIp') != p['bind_ip']
                or config.get('storage', {}).get('dbPath') != str(data)
                or config.get('security', {}).get('keyFile') != str(keypath)
                or config.get('security', {}).get('authorization') != 'enabled'
                or not keypath.is_file()
                or ''.join(keypath.read_text().split()) != ''.join(expected_key.split())):
            raise RuntimeError('Instance có sẵn không khớp cấu hình/keyfile nguồn. Không ghi đè. Chọn instance/port trống hoặc kiểm tra cấu hình đang dùng.')
        service = 'mongod-manager-' + p['instance']
        if run(['systemctl', 'is-active', service], check=False) != 'active':
            event('Instance do manager tạo đã khớp cấu hình. Khởi động lại service hiện có, giữ nguyên dữ liệu…')
            run(['systemctl', 'start', service])
        else:
            event('Instance do manager tạo đã chạy và khớp cấu hình. Tái sử dụng, không cài lại hoặc xóa dữ liệu.')
        return {'prepared': True, 'reused': True, 'service': service, 'config': str(configpath), 'data': str(data)}
    return setup(p, bootstrap=False)


def read_keyfile(p):
    path = Path(p["path"])
    if not path.is_absolute() or not path.is_file() or path.stat().st_size > 16384:
        raise RuntimeError("Keyfile nguồn không hợp lệ hoặc quá lớn.")
    return {"keyfile_b64": base64.b64encode(path.read_bytes()).decode()}


def member_network(p):
    # A node must reach its own advertised endpoint as well as existing members.
    failures = []
    for endpoint in p['endpoints']:
        host, port = endpoint.rsplit(':', 1)
        try:
            with socket.create_connection((host.strip('[]'), int(port)), timeout=5):
                pass
        except OSError:
            failures.append(endpoint)
    if failures:
        raise RuntimeError('VPS đích không kết nối được tới ' + ', '.join(failures) + '. Kiểm tra firewall, NAT và đường mạng; bao gồm kết nối tới chính endpoint quảng bá. Chưa thêm membership.')
    return {'reachable': True, 'checked': len(p['endpoints'])}


def backups_root(create=True):
    root = Path("/var/backups/mongodb-manager")
    if root.is_symlink():
        raise RuntimeError("Thư mục backup không được là symlink.")
    if create:
        root.mkdir(parents=True, mode=0o700, exist_ok=True)
    return root


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def backup(p):
    root = backups_root()
    key = secrets.token_hex(16)
    directory = root / key
    directory.mkdir(mode=0o700)
    databases = p.get("databases") or ([p["database"]] if p.get("database") else [])
    oplog = not databases and p.get("replica", True)
    archives = []
    try:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "tools.json"
            cfg.write_text(json.dumps(p["connection"]))
            cfg.chmod(0o600)
            collections = p.get("collections") or ([p["collection"]] if p.get("collection") else [None])
            scopes = [(db, col) for db in databases or [None] for col in collections]
            for index, (database, collection) in enumerate(scopes):
                name = f"part-{index}.archive.gz"
                archive = directory / name
                output = "--out=" + str(directory / "dump") if oplog else "--archive=" + str(archive)
                cmd = ["mongodump", output, "--gzip", "--config=" + str(cfg)]
                if database:
                    cmd += ["--db", database]
                    if collection:
                        cmd.append("--collection=" + collection)
                elif oplog:
                    cmd.append("--oplog")
                event("Đang backup: " + (database or "toàn cụm") + ("." + collection if collection else ""))
                run(cmd, timeout=7200)
                if oplog:
                    file = directory / "dump" / "oplog.bson"
                    if not file.exists():
                        file = file.with_suffix(".bson.gz")
                    oplog_file = directory / "oplog.bson"
                    with file.open("rb") as stream:
                        compressed = stream.read(2) == b"\x1f\x8b"
                    if compressed:
                        with gzip.open(file, "rb") as src, oplog_file.open("wb") as dest:
                            shutil.copyfileobj(src, dest)
                        file.unlink()
                    else:
                        file.rename(oplog_file)
                    continue
                archives.append({"file": name, "database": database, "collection": collection, "sha256": checksum(archive), "size": archive.stat().st_size})
        meta = {"id": key, "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "application_only": p.get("application_only", False), "databases": databases, "database": ", ".join(databases) or "Tất cả", "archives": archives,
                "collections": p.get("collections", []), "collection": p.get("collection", ""), "oplog": oplog, "size": sum(a["size"] for a in archives),
                "source": p["source"], "source_id": p.get("source_id"), "verified_restore": False, "compatibility": p["compatibility"],
                "tools_version": run(["mongodump", "--version"])}
        if oplog:
            files = [f for f in (directory / "dump").rglob("*") if f.is_file()] + [oplog_file]
            meta["files"] = {str(f.relative_to(directory)): checksum(f) for f in files}
            meta["size"] = sum(f.stat().st_size for f in files)
        pending = directory / "manifest.tmp"
        pending.write_text(json.dumps(meta, indent=2))
        pending.replace(directory / "manifest.json")
        return meta
    except Exception:
        shutil.rmtree(directory)
        raise


def list_backups(p):
    return sorted([json.loads(f.read_text()) for f in backups_root(create=False).glob("*/manifest.json") if not f.is_symlink()], key=lambda b: b["time"], reverse=True)


def bson_frames(stream, archive=False):
    while True:
        prefix = stream.read(4)
        if not prefix:
            return
        if archive and prefix == b"\xff" * 4:
            yield None
            continue
        size = int.from_bytes(prefix, "little")
        if len(prefix) != 4 or not 5 <= size <= 32 * 1024 * 1024:
            raise ValueError("Kích thước BSON trong backup không hợp lệ.")
        body = stream.read(size - 4)
        if len(body) != size - 4 or body[-1:] != b"\x00":
            raise ValueError("Dữ liệu BSON trong backup bị thiếu.")
        yield prefix + body


def archive_namespace(frame):
    # Both MongoDB archive metadata and block headers begin with these BSON strings.
    pos = 4
    names = []
    for field in (b"db", b"collection"):
        tag = b"\x02" + field + b"\x00"
        if not frame.startswith(tag, pos):
            raise ValueError("Định dạng header archive chưa được hỗ trợ.")
        pos += len(tag)
        size = int.from_bytes(frame[pos:pos+4], "little")
        pos += 4
        if not size or pos + size > len(frame) or frame[pos+size-1] != 0:
            raise ValueError("Tên namespace trong archive không hợp lệ.")
        names.append(frame[pos:pos+size-1].decode())
        pos += size
    return tuple(names)


def preview_backup(p):
    key = p["backup_id"]
    if not re.fullmatch(r"[a-f0-9]{32}", key):
        raise ValueError("ID backup không hợp lệ.")
    directory = backups_root(create=False) / key

    def checked(name):
        path = directory / name
        if (Path(name).is_absolute() or ".." in Path(name).parts or directory.is_symlink()
                or path.resolve() != directory.resolve() / name or not path.is_file()):
            raise ValueError("File backup không hợp lệ.")
        return path

    meta = json.loads(checked("manifest.json").read_text())
    selected = (p.get("database"), p.get("collection"))
    listing = not any(selected)
    namespaces = set()
    records = []
    skip = p.get("offset", 0)
    total = 0

    def visible(ns):
        return ns[0] not in {"local", "config"} and not ns[1].startswith("system.") and all(ns)

    def accept(frame):
        nonlocal skip, total
        if skip:
            skip -= 1
        elif len(records) >= 25 or (records and total + len(frame) > 2_000_000):
            return False
        else:
            records.append(base64.b64encode(frame).decode())
            total += len(frame)
        return True

    more = False
    if "files" in meta:
        for name in meta["files"]:
            rel = Path(name)
            if len(rel.parts) != 3 or rel.parts[0] != "dump" or not name.endswith(".bson.gz"):
                continue
            coll = rel.name[:-len(".bson.gz")]
            metadata = str(rel.with_name(coll + ".metadata.json.gz"))
            if metadata in meta["files"]:
                with gzip.open(checked(metadata), "rt") as stream:
                    coll = json.load(stream).get("collectionName", coll)
            ns = (rel.parts[1], coll)
            if not visible(ns):
                continue
            namespaces.add(ns)
            if ns == selected:
                with gzip.open(checked(name), "rb") as stream:
                    more = not all(accept(frame) for frame in bson_frames(stream))
                break
    else:
        for part in meta.get("archives") or [{"file":"backup.archive.gz"}]:
            if not re.fullmatch(r"(backup|part-[0-9]+)\.archive\.gz", part["file"]):
                raise ValueError("Tên archive không hợp lệ.")
            with gzip.open(checked(part["file"]), "rb") as stream:
                if stream.read(4) != bytes.fromhex("6de29981"):
                    raise ValueError("File không phải MongoDB archive.")
                frames = bson_frames(stream, archive=True)
                next(frames)  # archive version header
                members = set()
                for frame in frames:
                    if frame is None:
                        break
                    ns = archive_namespace(frame)
                    if visible(ns):
                        members.add(ns)
                namespaces.update(members)
                if listing or selected not in members:
                    continue
                for header in frames:
                    if header is None:
                        raise ValueError("Thiếu header của khối BSON.")
                    ns = archive_namespace(header)
                    for frame in frames:
                        if frame is None:
                            break
                        if ns == selected and not accept(frame):
                            more = True
                            break
                    if more:
                        break
                break
    if not listing and selected not in namespaces:
        raise ValueError("Collection không có trong bản backup.")
    return {"namespaces": sorted(namespaces) if listing else [], "records": records, "more": more}


def check_restore_compatibility(source, target):
    if not source or source.get("fcv") != target.get("fcv") or source.get("version", "").split(".")[:2] != target.get("version", "").split(".")[:2]:
        raise RuntimeError("Restore yêu cầu cùng nhánh MongoDB và FCV với nguồn. Backup cũ thiếu metadata cần kiểm tra và restore thủ công.")


def restore(p):
    directory = backups_root(create=False) / p["backup_id"]
    if directory.is_symlink():
        raise RuntimeError("Đường dẫn backup không hợp lệ.")
    manifest = directory / "manifest.json"
    if not manifest.is_file():
        raise ValueError("Không tìm thấy manifest của bản backup trên máy lưu đã chọn. Làm mới danh sách trên máy đã tạo backup rồi nhấn Restore ở đúng dòng.")
    meta = json.loads(manifest.read_text())
    check_restore_compatibility(meta.get("compatibility"), p["compatibility"])
    if "files" in meta:
        dump = directory / "dump"
        oplog = directory / "oplog.bson"
        files = list(dump.rglob("*")) + [oplog]
        if dump.is_symlink() or any(f.is_symlink() for f in files):
            raise RuntimeError("Đường dẫn bản backup không hợp lệ.")
        actual = {str(f.relative_to(directory)): checksum(f) for f in files if f.is_file()}
        if not oplog.is_file() or actual != meta["files"]:
            raise RuntimeError("Checksum backup không khớp.")
        parts = []
    else:
        parts = meta.get("archives") or [{"file": "backup.archive.gz", "sha256": meta["sha256"]}]
    archives = []
    for part in parts:
        name = part["file"]
        if not re.fullmatch(r"(?:backup|part-[0-9]+)\.archive\.gz", name):
            raise RuntimeError("Tên archive không hợp lệ.")
        archive = directory / name
        if archive.is_symlink() or checksum(archive) != part["sha256"]:
            raise RuntimeError("Checksum backup không khớp.")
        archives.append(archive)
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "tools.json"
        cfg.write_text(json.dumps(p["connection"]))
        cfg.chmod(0o600)
        if "files" in meta:
            base = ["mongorestore", "--gzip", "--stopOnError", "--config=" + str(cfg)]
            event("Đang restore dữ liệu và tài khoản từ bản toàn cụm.")
            run(base + (["--drop", "--preserveUUID"] if p.get("drop") else []) + [str(dump)], timeout=7200)
            # Restoring admin can invalidate the authenticated session; replay with a new connection.
            empty = Path(tmp) / "replay"
            empty.mkdir()
            event("Đang kết nối lại để replay oplog trên cụm đích.")
            replay = ["mongorestore", "--stopOnError", "--config=" + str(cfg), "--oplogReplay", "--oplogFile=" + str(oplog)]
            run(replay + [str(empty)], timeout=7200)
        for part, archive in zip(parts, archives):
            command = ["mongorestore", "--archive=" + str(archive), "--gzip", "--stopOnError", "--config=" + str(cfg)]
            if meta["oplog"]:
                command.append("--oplogReplay")
            if p.get("drop"):
                command.append("--drop")
            event("Đang restore: " + (part.get("database") or meta["database"]))
            run(command, timeout=7200)
    return {"restored": True, "backup_id": p["backup_id"], "message": "mongorestore hoàn tất. Kiểm tra dữ liệu ứng dụng trên cụm đích."}


def main(request):
    p = request["params"]
    action = request["action"]
    if action == "public_address":
        direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with direct.open("https://api.ipify.org", timeout=8) as response:
            return {"ip": response.read(64).decode("ascii").strip()}
    if action == "preflight":
        return preflight(p)
    if action == "logs":
        return {"log": run(["journalctl", "-u", p["service"], "--no-pager", "-n", "100"], check=False)}
    if action == "service":
        run(["systemctl", p["operation"], p["service"]], timeout=180)
        return {"state": run(["systemctl", "is-active", p["service"]], check=False), "operation": p["operation"]}
    handlers = {"install": install, "setup": setup, "provision": provision, "prepare_member": prepare_member,
                "read_keyfile": read_keyfile, "member_network": member_network, "backup": backup, "backups": list_backups, "preview_backup": preview_backup, "restore": restore}
    if action not in handlers:
        raise RuntimeError("Tác vụ không được hỗ trợ.")
    return handlers[action](p)


if __name__ == "__main__":
    try:
        result = main(json.load(sys.stdin))
        print(json.dumps({"result": result}, ensure_ascii=False), flush=True)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), flush=True)
        sys.exit(1)
