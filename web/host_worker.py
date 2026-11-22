"""Fixed, allowlisted worker sent to a local host or over SSH; JSON on stdin/stdout.

Never execute the legacy interactive scripts from a web request.
"""
import base64
import datetime
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
    candidates = package_versions(packages, "mongodb-org")
    if not candidates:
        raise RuntimeError("Repository không có package mongodb-org cho tổ hợp đã chọn.")
    def ver(v):
        return tuple(int(n) for n in re.findall(r"\d+", v))
    version = max(candidates, key=ver)
    names = ["mongodb-org", "mongodb-org-database", "mongodb-org-server", "mongodb-org-shell", "mongodb-org-mongos", "mongodb-org-tools", "mongodb-org-database-tools-extra"]
    if any(version not in package_versions(packages, name) for name in names):
        raise RuntimeError("Repository thiếu package đồng bộ cho phiên bản đã chọn.")
    if codename == "resolute" and ver(version) < (9, 0, 4):
        raise RuntimeError("Ubuntu 26.04 yêu cầu MongoDB >= 9.0.4.")
    event(f"Cài MongoDB {version} cho Ubuntu {codename} / {arch}.")
    run(["apt-get", "update"], timeout=600)
    run(["apt-get", "install", "-y", "gnupg", "ca-certificates"], timeout=600)
    key_version = "9" if series == "9.0" else "8.0"
    with urllib.request.urlopen(f"https://pgp.mongodb.com/server-{key_version}.asc", timeout=30) as response:
        key_data = response.read()
    with tempfile.TemporaryDirectory() as tmp:
        asc = Path(tmp) / "key.asc"
        asc.write_bytes(key_data)
        keypath = f"/usr/share/keyrings/mongodb-server-{series}.gpg"
        run(["gpg", "--batch", "--yes", "--dearmor", "--output", keypath, str(asc)])
    repo = Path(f"/etc/apt/sources.list.d/mongodb-org-{series}.list")
    repo.write_text(f"deb [arch={arch} signed-by={keypath}] https://repo.mongodb.org/apt/ubuntu {codename}/mongodb-org/{series} multiverse\n")
    run(["apt-get", "update"], timeout=600)
    run(["apt-get", "install", "-y", *[f"{n}={version}" for n in names], "mongodb-mongosh", "mongodb-database-tools"], timeout=1200)
    return {"version": version, "message": "Đã cài package. Tiếp tục wizard tạo replica set."}


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
    root.mkdir(parents=True, mode=0o750)
    data.mkdir(parents=True, mode=0o750)
    logdir = Path("/var/log/mongodb-manager") / instance
    logdir.mkdir(parents=True, mode=0o750)
    for directory in (root, data, logdir):
        os.chown(directory, account.pw_uid, account.pw_gid)
    keyfile = root / "keyfile"
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


def backups_root():
    root = Path("/var/backups/mongodb-manager")
    if root.is_symlink():
        raise RuntimeError("Thư mục backup không được là symlink.")
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
    filename = directory / "backup.archive.gz.partial"
    opts = p["connection"]
    command = ["mongodump", "--archive=" + str(filename), "--gzip"]
    if p.get("database"):
        command += ["--db", p["database"]]
        if p.get("collection"):
            command += ["--collection", p["collection"]]
    else:
        command.append("--oplog")
    event("Đang dump dữ liệu. Giữ phiên bản/FCV và cấu trúc dữ liệu ổn định trong thời gian backup.")
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "tools.json"
        cfg.write_text(json.dumps(opts))
        cfg.chmod(0o600)
        run([*command, "--config=" + str(cfg)], timeout=7200)
    target = filename.with_suffix("")
    filename.rename(target)
    digest = checksum(target)
    meta = {"id": key, "time": datetime.datetime.now(datetime.timezone.utc).isoformat(), "database": p.get("database") or "Tất cả",
            "collection": p.get("collection", ""), "oplog": not bool(p.get("database")), "sha256": digest,
            "size": target.stat().st_size, "path": str(target), "source": p.get("source", ""), "verified_restore": False,
            "compatibility": p["compatibility"], "tools_version": run(["mongodump", "--version"])}
    (directory / "manifest.json").write_text(json.dumps(meta, indent=2))
    return meta


def list_backups(p):
    return sorted([json.loads(f.read_text()) for f in backups_root().glob("*/manifest.json") if not f.is_symlink()], key=lambda b: b["time"], reverse=True)


def check_restore_compatibility(source, target):
    if not source or source.get("fcv") != target.get("fcv") or source.get("version", "").split(".")[:2] != target.get("version", "").split(".")[:2]:
        raise RuntimeError("Restore yêu cầu cùng nhánh MongoDB và FCV với nguồn. Backup cũ thiếu metadata cần kiểm tra và restore thủ công.")


def restore(p):
    directory = backups_root() / p["backup_id"]
    if directory.is_symlink():
        raise RuntimeError("Đường dẫn backup không hợp lệ.")
    meta = json.loads((directory / "manifest.json").read_text())
    check_restore_compatibility(meta.get("compatibility"), p["compatibility"])
    archive = directory / "backup.archive.gz"
    if archive.is_symlink():
        raise RuntimeError("Đường dẫn archive không hợp lệ.")
    digest = checksum(archive)
    if digest != meta["sha256"]:
        raise RuntimeError("Checksum backup không khớp.")
    command = ["mongorestore", "--archive=" + str(archive), "--gzip", "--stopOnError"]
    if meta["oplog"]:
        command.append("--oplogReplay")
    if p.get("drop"):
        command.append("--drop")
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "tools.json"
        cfg.write_text(json.dumps(p["connection"]))
        cfg.chmod(0o600)
        event("Checksum hợp lệ. Đang restore vào cụm đích đã chọn…")
        run([*command, "--config=" + str(cfg)], timeout=7200)
    return {"restored": True, "backup_id": p["backup_id"], "message": "mongorestore hoàn tất. Kiểm tra dữ liệu ứng dụng trên cụm đích."}


def main(request):
    p = request["params"]
    action = request["action"]
    if action == "preflight":
        return preflight(p)
    if action == "logs":
        return {"log": run(["journalctl", "-u", p["service"], "--no-pager", "-n", "100"], check=False)}
    if action == "service":
        run(["systemctl", p["operation"], p["service"]], timeout=180)
        return {"state": run(["systemctl", "is-active", p["service"]], check=False), "operation": p["operation"]}
    handlers = {"install": install, "setup": setup, "provision": provision, "prepare_member": prepare_member,
                "read_keyfile": read_keyfile, "member_network": member_network, "backup": backup, "backups": list_backups, "restore": restore}
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
