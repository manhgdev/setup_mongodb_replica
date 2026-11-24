import copy
import ipaddress
import json
import os
import re
import selectors
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from bson import BSON, json_util
from bson.errors import BSONError
from pymongo import MongoClient
from pymongo.errors import AutoReconnect, OperationFailure, PyMongoError

from .releases import catalog
from .models import endpoint, public_endpoint


def serial(value):
    return json.loads(json_util.dumps(value))


def redact(value, *secrets):
    text = str(value)
    text = re.sub(r"(mongodb(?:\+srv)?://)[^\s@]+@", r"\1***@", text)
    for secret in secrets:
        if secret:
            text = text.replace(secret, "***").replace(quote(secret, safe=""), "***")
    return text


def mongo_error(error):
    if isinstance(error, OperationFailure):
        return f"MongoDB từ chối thao tác (code {error.code}). Kiểm tra quyền, thông tin đăng nhập và trạng thái cụm."
    if isinstance(error, AutoReconnect):
        return "Chưa tìm được primary hoặc kết nối cụm bị gián đoạn. Chờ rồi kiểm tra lại mạng/quorum."
    return "Không kết nối được MongoDB. Kiểm tra seed, replica set, firewall và thông tin đăng nhập."


def client(profile, direct=None):
    options = dict(serverSelectionTimeoutMS=5000 if direct else 15000, connectTimeoutMS=5000, socketTimeoutMS=15000, timeoutMS=20000, appname="MongoDB Manager")
    if profile.get("username"):
        options.update(username=profile["username"], password=profile.get("password", ""), authSource=profile["auth_db"])
    if profile.get("tls"):
        options["tls"] = True
        if profile.get("tls_ca"):
            options["tlsCAFile"] = profile["tls_ca"]
    if profile.get("_restore_direct"):
        direct = profile["seeds"][0]
    if direct:
        options["directConnection"] = True
        seeds = [direct]
    else:
        seeds = profile["seeds"]
        if profile.get("replica_set"):
            options["replicaSet"] = profile["replica_set"]
    return MongoClient(seeds, **options)


def uri(profile):
    # Never persist a password in the URI or command-line arguments.
    options = ["authSource=" + quote(profile["auth_db"], safe="")] if profile.get("username") else []
    if profile.get("_restore_direct"):
        options.append("directConnection=true")
    if profile.get("replica_set"):
        options.append("replicaSet=" + quote(profile["replica_set"], safe=""))
    if profile.get("tls"):
        options.append("tls=true")
        if profile.get("tls_ca"):
            raise ValueError("Backup qua máy đích hiện yêu cầu CA hệ thống. Chứng chỉ CA local không tự chuyển sang VPS.")
    user = quote(profile["username"], safe="") + "@" if profile.get("username") else ""
    return "mongodb://" + user + ",".join(profile["seeds"]) + "/?" + "&".join(options)


def snapshot(profile):
    with client(profile) as db:
        hello = db.admin.command("hello")
        version = db.admin.command("buildInfo")["version"]
        output = {"connected": True, "version": version, "replica_set": hello.get("setName", "Standalone"),
                  "primary": hello.get("primary", hello.get("me", "")), "members": [], "warnings": [], "checked_at": datetime.now(timezone.utc).isoformat()}
        try:
            status = db.admin.command("replSetGetStatus")
            cfg = db.admin.command("replSetGetConfig")["config"]
            output["seeds"] = [m["host"] for m in cfg["members"]]
            configs = {member["_id"]: member for member in cfg["members"]}
            primary_time = next((m.get("optimeDate") for m in status["members"] if m["state"] == 1), None)
            for m in status["members"]:
                member_cfg = configs.get(m["_id"], {})
                when = m.get("optimeDate")
                lag = max(0, round((primary_time - when).total_seconds(), 1)) if primary_time and when and m["state"] in (1, 2) else None
                output["members"].append({"id": m["_id"], "host": m["name"], "state": m["stateStr"], "health": m["health"],
                    "uptime": m.get("uptime", 0), "lag": lag, "priority": member_cfg.get("priority", 1),
                    "votes": member_cfg.get("votes", 1), "hidden": member_cfg.get("hidden", False)})
            voters = sum(m.get("votes", 1) for m in cfg["members"])
            healthy = sum(m["votes"] for m in output["members"] if m["health"] == 1)
            output.update(voters=voters, majority=voters // 2 + 1, healthy_voters=healthy, quorum=healthy >= voters // 2 + 1)
            if len(cfg["members"]) == 1:
                output["warnings"].append("Cụm một node: chưa có bản sao dự phòng trên máy khác.")
        except OperationFailure as exc:
            output["warnings"].append(f"Không đọc được replica status/config (code {exc.code}).")
        try:
            output["fcv"] = db.admin.command({"getParameter": 1, "featureCompatibilityVersion": 1})["featureCompatibilityVersion"]["version"]
        except OperationFailure:
            output["fcv"] = None
        return output


def discover(profile):
    """Read-only adoption, including when the supplied seed is a secondary."""
    hello = None
    last_error = None
    for seed in profile["seeds"]:
        try:
            with client(profile, direct=seed) as node:
                node.admin.command("ping")
                hello = node.admin.command("hello")
            break
        except PyMongoError as exc:
            last_error = exc
    if hello is None:
        raise last_error
    if hello.get("msg") == "isdbgrid":
        raise ValueError("Đây là mongos/sharded cluster. Chức năng này tiếp nhận replica set hoặc standalone.")
    actual = hello.get("setName", "")
    if profile.get("replica_set") and profile["replica_set"] != actual:
        raise ValueError("Tên replica set không khớp. Để trống trường tên replica set để tự nhận diện.")
    members = hello.get("hosts", []) + hello.get("passives", []) + hello.get("arbiters", [])
    from .models import endpoint
    normalized = dict(profile, replica_set=actual, seeds=list(dict.fromkeys(endpoint(host) for host in members)) or profile["seeds"])
    state = snapshot(normalized)
    if actual and not state["members"]:
        raise ValueError("Đã đăng nhập nhưng chưa đọc được trạng thái/cấu hình cụm. Dùng tài khoản có quyền giám sát replica set.")
    return normalized, state


def read_documents(profile, page):
    if "\x00" in page.database + page.collection:
        raise ValueError("Tên database hoặc collection không hợp lệ.")
    if page.collection in {"system.users", "system.keys", "system.keyvault"}:
        raise ValueError("Collection chứa thông tin xác thực.")
    criteria = {}
    if page.field:
        if any(not part or part.startswith("$") or "\x00" in part for part in page.field.split(".")):
            raise ValueError("Tên trường lọc không hợp lệ.")
        try:
            value = json_util.loads(page.value)
        except (ValueError, TypeError, KeyError, OverflowError) as exc:
            raise ValueError("Giá trị lọc cần là JSON hoặc MongoDB Extended JSON hợp lệ.") from exc
        criteria[page.field] = {"$eq": value}
    elif page.value:
        raise ValueError("Nhập tên trường cần lọc.")
    records = []
    total_bytes = 0
    with client(profile) as db:
        cursor = db[page.database][page.collection].find(criteria).sort("_id", 1).skip(page.offset)
        with cursor.limit(page.limit + 1).max_time_ms(5000).batch_size(2) as rows:
            for row in rows:
                if len(records) == page.limit:
                    return {"records": records, "more": True}
                encoded = json_util.dumps(row, json_options=json_util.CANONICAL_JSON_OPTIONS, ensure_ascii=False)
                total_bytes += len(encoded.encode())
                if records and total_bytes > 2_000_000:
                    return {"records": records, "more": True}
                records.append(json.loads(encoded))
    return {"records": records, "more": False}


def parse_document(raw):
    try:
        value = json_util.loads(raw or "")
        if isinstance(value, dict):
            BSON.encode(value)
            return value
    except (ValueError, TypeError, KeyError, OverflowError, BSONError):
        pass
    raise ValueError("Document phải là một object JSON hoặc Extended JSON hợp lệ.")


def write_document(profile, change):
    if (change.database in {"admin", "config", "local"} or change.collection.startswith("system.")
            or "\x00" in change.database + change.collection):
        raise ValueError("Chỉ sửa được collection dữ liệu ứng dụng.")
    document = parse_document(change.document) if change.action != "delete" else None
    if change.action != "insert":
        original = parse_document(change.original)
        if "_id" not in original:
            raise ValueError("Thiếu _id của document gốc.")
        if document is not None and ("_id" not in document or
                BSON.encode({"id": original["_id"]}) != BSON.encode({"id": document["_id"]})):
            raise ValueError("Giữ nguyên _id khi sửa document.")
        criteria = {"_id": {"$eq": original["_id"]},
                    "$expr": {"$eq": ["$$ROOT", {"$literal": original}]}}
    with client(profile) as connection:
        db = connection[change.database]
        namespace = next(db.list_collections(filter={"name": change.collection}, nameOnly=True), None)
        if not namespace or namespace["type"] != "collection":
            raise ValueError("Cần chọn một collection đang tồn tại để ghi dữ liệu.")
        collection = db[change.collection]
        if change.action == "insert":
            collection.insert_one(document)
        else:
            if change.action == "delete":
                count = collection.delete_one(criteria, collation={"locale": "simple"}).deleted_count
            else:
                count = collection.replace_one(criteria, document, collation={"locale": "simple"}).matched_count
            if not count:
                raise ValueError("Document đã thay đổi hoặc đã bị xóa. Hãy tải lại trước khi tiếp tục.")
    return {"ok": True}


def query(profile, section, database="", collection=""):
    with client(profile) as db:
        if section == "users":
            return serial(db.admin.command({"usersInfo": {"forAllDBs": True}, "showCredentials": False})["users"])
        if section == "databases":
            return serial(db.admin.command("listDatabases")["databases"])
        if section == "config":
            result = db.admin.command("replSetGetConfig")
            result["writeConcern"] = db.admin.command("getDefaultRWConcern")
            return serial(result)
        if section == "namespaces":
            return [{"name": c["name"], "type": c["type"]} for c in db[database].list_collections(nameOnly=True)]
        if section == "indexes":
            return serial(list(db[database][collection].list_indexes()))
        if section == "collections":
            return [{"name": c["name"], "type": c["type"], "indexes": serial(list(db[database][c["name"]].list_indexes())) if c["type"] == "collection" else []} for c in db[database].list_collections()]
        if section == "diagnostics":
            cfg = db.admin.command('replSetGetConfig')['config']
            status = db.admin.command('replSetGetStatus')
            states = {m['name']: m for m in status['members']}
            results = []
            for member in cfg['members']:
                host = member['host']
                try:
                    # Arbiters have no replicated user database. Verify hello
                    # without client credentials, then cross-check trusted topology.
                    arbiter = bool(member.get('arbiterOnly'))
                    connection = dict(profile, username='', password='') if arbiter else profile
                    with client(connection, direct=host) as node:
                        hello = node.admin.command("hello")
                    if arbiter:
                        healthy = hello.get('arbiterOnly') and hello.get('setName') == cfg['_id'] and states.get(host, {}).get('health') == 1 and states[host].get('state') == 7
                        results.append({'host': host, 'ok': bool(healthy), 'role': 'ARBITER', 'error': '' if healthy else 'Hello/trạng thái arbiter không khớp cụm.', 'note': 'Kiểm tra hello và trạng thái từ cụm đã xác thực; arbiter không dùng đăng nhập user dữ liệu.'})
                    else:
                        results.append({"host": host, "ok": True, "role": "PRIMARY" if hello.get("isWritablePrimary") else "SECONDARY" if hello.get("secondary") else "OTHER"})
                except PyMongoError:
                    results.append({"host": host, "ok": False, "error": "Kết nối/xác thực thất bại từ máy quản trị."})
            return results
    raise ValueError("Màn hình không hợp lệ.")


def host_run(machine, action, params, emit):
    worker = Path(__file__).with_name("host_worker.py")
    elevated = action in {"package_recover", "role_storage", "role_restart", "retire_member", "check_service_stopped", "arbiter_check", "arbiter_packages", "arbiter_install", "ubuntu_start", "ubuntu_repair_key", "ubuntu_finalize", "ubuntu_status", "ubuntu_precheck", "ubuntu_tools", "ubuntu_restore_service", "install", "setup", "provision", "prepare_member", "read_keyfile", "service", "backup", "backups", "restore", "preview_backup", "delete_backup", "logs"}
    params = dict(params, service=machine["service"])
    payload = {"action": action, "params": params}
    if action.startswith(("ubuntu_", "arbiter_")) or action in {"mongo_latest", "install", "prepare_member", "provision", "setup"}:
        payload["release_catalog"] = catalog()
    if machine["mode"] == "local":
        cmd = [sys.executable, "-u", str(worker)]
        if elevated and os.geteuid() != 0:
            cmd = ["sudo", "-n", *cmd]
    else:
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-p", str(machine["port"])]
        if machine.get("identity"):
            cmd += ["-i", str(Path(machine["identity"]).expanduser())]
        # Send source through stdin. SSH multiplexers impose a small command-size limit.
        payload["_worker"] = worker.read_text()
        loader = ("import json,sys; request=json.load(sys.stdin); scope={'__name__':'host_worker'}; "
                  "exec(compile(request.pop('_worker'),'host_worker.py','exec'),scope); scope['serve'](request)")
        remote = ["python3", "-u", "-c", loader]
        if elevated and machine["user"] != "root":
            remote = ["sudo", "-n", *remote]
        if machine.get("ssh_auth") == "password":
            from .ssh_transport import run_password
            return run_password(machine, shlex.join(remote), payload, emit)
        cmd += [machine["user"] + "@" + machine["host"], shlex.join(remote)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    # Payload includes secrets, sent only through stdin (SSH encrypts transport).
    try:
        with proc.stdin:
            proc.stdin.write(json.dumps(payload))
    except BrokenPipeError:
        # A failed SSH connection can close stdin before the source upload finishes.
        # Drain stderr below to report the host-key, authentication or sudo error.
        pass
    result = None
    error = None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    selector.register(proc.stderr, selectors.EVENT_READ)
    start = time.monotonic()
    try:
        while selector.get_map():
            if time.monotonic() - start > 7500:
                raise TimeoutError("Tác vụ quá thời gian; kiểm tra máy đích trước khi thử lại.")
            for key, _ in selector.select(timeout=1):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                if key.fileobj is proc.stderr:
                    # No remote raw stderr (might contain secrets); give useful SSH hints.
                    if any(s in line for s in ("Host key verification failed", "Permission denied", "password is required", "Connection refused", "Could not resolve")):
                        error = "SSH/sudo chưa sẵn sàng. Kiểm tra known_hosts, SSH key và quyền sudo không hỏi mật khẩu."
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "event" in message:
                    emit(message["event"])
                if "error" in message:
                    error = message["error"]
                if "result" in message:
                    result = message["result"]
        if proc.wait(timeout=10) != 0 or result is None:
            raise RuntimeError(error or "Worker thất bại. Kiểm tra SSH, sudo, Python 3 và công cụ trên máy đích.")
        return result
    finally:
        selector.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()


LABELS = {
    "convert_role": "Đổi vai trò thành viên",
    "mongo_upgrade": "Nâng cấp MongoDB", "arbiter_upgrade": "Nâng MongoDB trên arbiter", "ubuntu_upgrade": "Kiểm tra và nâng Ubuntu",
    "preflight": "Kiểm tra môi trường", "logs": "Đọc nhật ký", "install": "Cài MongoDB", "setup": "Tạo replica set một node",
    "service": "Điều khiển dịch vụ MongoDB", "add_member": "Thêm thành viên", "remove_member": "Gỡ thành viên",
    "member_options": "Sửa cấu hình thành viên", "step_down": "Step down Primary", "create_user": "Tạo user", "password": "Đổi mật khẩu",
    "drop_user": "Xóa user", "write_concern": "Đặt write concern", "backup": "Tạo backup", "backups": "Liệt kê backup",
    "sync_backup": "Đồng bộ bản mới từ nguồn", "restore": "Restore backup", "drop_database": "Xóa database", "upgrade_check": "Kiểm tra nâng cấp 9.0",
    "provision": "Cài và tạo cụm mới", "join_fresh": "Kiểm tra VPS và thêm member"}
HOST_ACTIONS = {"mongo_upgrade", "arbiter_upgrade", "ubuntu_upgrade", "preflight", "logs", "install", "setup", "provision", "join_fresh", "service", "backup", "backups", "restore", "sync_backup"}
PROFILE_ACTIONS = set(LABELS) - HOST_ACTIONS | {"mongo_upgrade", "arbiter_upgrade", "backup", "restore", "sync_backup", "join_fresh"}
READ_ACTIONS = {"preflight", "logs", "backups", "upgrade_check"}


def member_address(machine, port):
    saved = machine.get("mongo_endpoint")
    if saved:
        host = public_endpoint(saved).rsplit(":", 1)[0]
    else:
        try:
            address = ipaddress.ip_address(machine["host"])
            if not address.is_global or address.is_multicast:
                raise ValueError
        except ValueError:
            try:
                result = host_run(machine, "public_address", {}, lambda _: None)
                address = ipaddress.ip_address(result["ip"])
                if not address.is_global or address.is_multicast:
                    raise ValueError
            except (RuntimeError, OSError, ValueError, KeyError) as exc:
                raise ValueError("Không xác định được IP public của VPS. Nhập địa chỉ MongoDB mà các member truy cập được.") from exc
        host = f"[{address}]" if address.version == 6 else str(address)
    return f"{host}:{port}"


def validate_params(action, params, machine=None):
    allowed = {
        "preflight": [], "logs": [], "backups": [], "upgrade_check": [], "step_down": ["host"],
        "install": ["series"], "setup": ["instance", "port", "replica_set", "advertise", "bind_ip", "username", "password"],
        "service": ["operation"], "add_member": ["host", "arbiter", "votes", "priority"], "remove_member": ["host"],
        "member_options": ["host", "priority", "votes", "hidden"], "create_user": ["username", "password", "database", "role"],
        "password": ["username", "password", "database"], "drop_user": ["username", "database"],
        "write_concern": ["w"], "backup": ["database", "databases", "collection", "collections", "application_only"], "restore": ["backup_id", "drop", "destination_id", "destination_machine_id"], "drop_database": ["database"]}
    allowed["convert_role"] = ["host", "role"]
    allowed["mongo_upgrade"] = ["series"]
    if action == "mongo_upgrade" and params.get("series") not in catalog()["supported"]:
        raise ValueError("Chọn nhánh trong danh mục MongoDB.")
    allowed["arbiter_upgrade"] = ["version"]
    allowed["ubuntu_upgrade"] = ["series", "target"]
    allowed["sync_backup"] = allowed["backup"] + ["destination_id", "drop"]
    allowed["provision"] = allowed["setup"] + ["series"]
    allowed["join_fresh"] = ["instance", "port", "advertise", "bind_ip", "source_machine_id", "source_endpoint", "arbiter", "mode", "target_keyfile", "votes", "priority"]
    if action not in allowed or set(params) - set(allowed[action]):
        raise ValueError("Tác vụ hoặc tham số không hợp lệ.")
    p = copy.deepcopy(params)
    if action == "arbiter_upgrade" and not re.fullmatch(r"9\.0\.\d+", str(p.get("version", ""))):
        raise ValueError("Chọn gói MongoDB 9.0 trong kết quả kiểm tra.")
    required = {"install": ["series"], "setup": allowed["setup"], "service": ["operation"], "add_member": ["host"], "remove_member": ["host"],
                "member_options": ["host", "priority", "votes", "hidden"], "create_user": allowed["create_user"], "password": allowed["password"],
                "drop_user": allowed["drop_user"], "write_concern": ["w"], "restore": ["backup_id"], "drop_database": ["database"]}
    required["convert_role"] = allowed["convert_role"]
    if action == "convert_role" and p.get("role") not in ("ARBITER", "SECONDARY"):
        raise ValueError("Chọn vai trò ARBITER hoặc SECONDARY.")
    required.update(provision=allowed["provision"], join_fresh=["instance", "port", "bind_ip"])
    if action == "ubuntu_upgrade" and ((p.get("series") and p["series"] not in catalog()["supported"]) or p.get("target") not in {"auto", *catalog()["lts"]}):
        raise ValueError("Chọn nhánh MongoDB và bản Ubuntu đích hợp lệ.")
    if action == 'join_fresh':
        p.setdefault('arbiter', False)
        p.setdefault('mode', 'prepare')
        if p['mode'] not in {'prepare', 'prepared', 'replace_empty'}:
            raise ValueError('Chọn chuẩn bị instance mới hoặc kiểm tra node đã chuẩn bị.')
        if p['mode'] == 'prepared' and (not isinstance(p.get('target_keyfile'), str) or not p['target_keyfile'].startswith('/')):
            raise ValueError('Nhập đường dẫn keyfile thực tế trên node đã chuẩn bị để đối chiếu nguồn.')
    for key in required.get(action, []):
        if key not in p or p[key] is None or p[key] == "":
            raise ValueError("Thiếu thông tin: " + key)
    if action in {"sync_backup", "restore"} and "drop" in p and type(p["drop"]) is not bool:
        raise ValueError("Giá trị drop không hợp lệ.")
    if action == "sync_backup" and not p.get("destination_id"):
        raise ValueError("Chọn cụm đích.")
    if "application_only" in p:
        if type(p["application_only"]) is not bool or (p["application_only"] and any(p.get(k) for k in ("database","databases","collection"))):
            raise ValueError("Phạm vi tất cả database ứng dụng không hợp lệ.")
    if "databases" in p:
        names = p["databases"]
        if not isinstance(names, list) or any(not isinstance(n, str) or not re.fullmatch(r"[\w-]{1,63}", n) for n in names):
            raise ValueError("Danh sách database không hợp lệ.")
        if p.get("database") or (p.get("collection") and len(names) != 1):
            raise ValueError("Chọn đúng một database khi chỉ định collection.")
        p["databases"] = list(dict.fromkeys(names))
    if "collections" in p:
        names = p["collections"]
        if (not isinstance(names, list) or not names or p.get("collection") or p.get("application_only")
                or len(p.get("databases", [])) != 1 or
                any(not isinstance(n, str) or not n or "\x00" in n or len(n.encode()) > 255 for n in names)):
            raise ValueError("Chọn một database và ít nhất một collection hợp lệ.")
        p["collections"] = list(dict.fromkeys(names))
    for key, value in p.items():
        if key in {"databases", "collections", "application_only"}:
            continue
        if key not in {"port", "priority", "votes", "arbiter", "hidden", "drop"} and not isinstance(value, str):
            raise ValueError("Kiểu dữ liệu không hợp lệ: " + key)
        if isinstance(value, str) and (len(value) > 1000 or "\x00" in value):
            raise ValueError("Giá trị quá dài hoặc chứa ký tự không hợp lệ.")
    if "host" in p:
        p["host"] = (public_endpoint if action == "add_member" else endpoint)(p["host"])
    if "source_endpoint" in p:
        p["source_endpoint"] = endpoint(p["source_endpoint"])
    for key in ("database", "collection"):
        if p.get(key) and (not isinstance(p[key], str) or not re.fullmatch(r"[\w.-]{1,120}", p[key])):
            raise ValueError("Tên database/collection chỉ được chứa chữ, số, dấu chấm, gạch ngang và gạch dưới.")
    if action == "drop_database" and p["database"] in {"admin", "local", "config"}:
        raise ValueError("Không cho xóa database hệ thống.")
    if action in {"backup", "sync_backup"} and p.get("collection") and not (p.get("database") or p.get("databases")):
        raise ValueError("Chọn database trước khi backup collection.")
    if action in {"install", "provision"} and p["series"] not in catalog()["supported"]:
        raise ValueError("Nhánh chưa có trong danh mục MongoDB cho Ubuntu.")
    if action == "service" and p["operation"] not in {"diagnose", "repair_keyfile", "start", "stop", "restart", "enable", "disable"}:
        raise ValueError("Thao tác dịch vụ không hợp lệ.")
    if action in {"setup", "provision", "join_fresh"}:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", p["instance"]):
            raise ValueError("Instance chỉ gồm chữ thường, số và dấu gạch ngang.")
        if action != "join_fresh" and not re.fullmatch(r"[A-Za-z0-9_-]{1,50}", p["replica_set"]):
            raise ValueError("Tên replica set không hợp lệ.")
        if type(p["port"]) is not int or not 1024 <= p["port"] <= 65535:
            raise ValueError("Port phải từ 1024 đến 65535.")
        if action == "join_fresh" and not p.get("advertise", "").strip():
            if not machine:
                raise ValueError("Chọn VPS đích để xác định địa chỉ MongoDB.")
            p["advertise"] = member_address(machine, p["port"])
        p["advertise"] = (endpoint if machine and machine.get("mode") == "local" else public_endpoint)(p["advertise"])
        if not p["advertise"].endswith(":" + str(p["port"])):
            raise ValueError("Port quảng bá phải khớp port instance.")
        from .models import hostname
        for ip in p["bind_ip"].split(","):
            hostname(ip)
        if "127.0.0.1" not in p["bind_ip"].split(",") and "0.0.0.0" not in p["bind_ip"].split(","):
            raise ValueError("Bind address cần bao gồm 127.0.0.1 để bootstrap.")
    if "password" in p and (not isinstance(p["password"], str) or len(p["password"]) < 12):
        raise ValueError("Mật khẩu mới phải có ít nhất 12 ký tự.")
    if "username" in p and (not isinstance(p["username"], str) or len(p["username"]) > 100):
        raise ValueError("Username không hợp lệ.")
    if action == "create_user" and p["role"] not in {"read", "readWrite", "dbAdmin", "backup", "clusterMonitor", "root"}:
        raise ValueError("Role không hợp lệ.")
    if action == "create_user" and p["role"] in {"backup", "clusterMonitor", "root"} and p["database"] != "admin":
        raise ValueError("Role này cần tạo ở database admin.")
    for key in ("arbiter", "hidden", "drop"):
        if key in p and type(p[key]) is not bool:
            raise ValueError(key + " phải là boolean.")
    if action in {"add_member", "join_fresh"}:
        p.setdefault("votes", 1)
        p.setdefault("priority", 0 if p.get("arbiter") else p["votes"])
        if p.get("arbiter") and (p["votes"] != 1 or p["priority"] != 0):
            raise ValueError("Arbiter cần Votes = 1 và Ưu tiên = 0.")
    if action in {"member_options", "add_member", "join_fresh"}:
        if type(p["priority"]) not in (int, float) or not 0 <= p["priority"] <= 1000 or type(p["votes"]) is not int or p["votes"] not in (0, 1):
            raise ValueError("Priority/votes không hợp lệ.")
        if (p.get("hidden") or p["votes"] == 0) and p["priority"] != 0:
            raise ValueError("Hidden hoặc non-voting member cần priority = 0.")
    if action == "write_concern" and p["w"] not in ("majority", "1"):
        raise ValueError("Write concern không hợp lệ.")
    if action == "restore" and not re.fullmatch(r"[a-f0-9]{32}", p["backup_id"]):
        raise ValueError("ID backup không hợp lệ.")
    return p


def check_new_vote(cfg, params):
    if params.get("votes", 1) and sum(m.get("votes", 1) for m in cfg["members"]) >= 7:
        raise ValueError("Replica set đã có 7 voting member. Hãy chọn Votes = 0 cho secondary mới.")


def healthy_config(db):
    cfg = db.admin.command("replSetGetConfig")["config"]
    status = db.admin.command("replSetGetStatus")
    states = {m["_id"]: m for m in status["members"]}
    return cfg, states


def check_quorum(cfg, states):
    votes = sum(m.get("votes", 1) for m in cfg["members"])
    available = sum(m.get("votes", 1) for m in cfg["members"] if states.get(m["_id"], {}).get("health") == 1)
    electable = any(m.get("priority", 1) > 0 and not m.get("arbiterOnly") and states.get(m["_id"], {}).get("state") in (1, 2) and states.get(m["_id"], {}).get("health") == 1 for m in cfg["members"])
    if not electable or available < votes // 2 + 1:
        raise ValueError("Cấu hình này không còn đủ quorum hoặc node có thể làm primary.")


def arbiter_upgrade_target(profile, machine):
    endpoint = machine.get("mongo_endpoint")
    if not endpoint or machine.get("profile_id") != profile["id"]:
        raise ValueError("Cần hồ sơ VPS liên kết đúng cụm và endpoint của arbiter.")
    with client(profile) as db:
        cfg, states = healthy_config(db)
        member = next((m for m in cfg["members"] if m["host"] == endpoint and m.get("arbiterOnly")), None)
        if not member or states.get(member["_id"], {}).get("state") != 7:
            raise ValueError("Endpoint đã chọn phải là arbiter đang hoạt động trong cấu hình cụm.")
        peers = {i: m for i, m in states.items() if i != member["_id"] and m.get("state") in (1, 2, 7)}
        check_quorum(cfg, peers)
        fcv = db.admin.command({"getParameter": 1, "featureCompatibilityVersion": 1})["featureCompatibilityVersion"]
        if fcv != {"version": "8.0"}:
            raise ValueError("Cụm cần FCV 8.0 ổn định trước khi nâng binary.")
    with client(dict(profile, username="", password=""), direct=endpoint) as db:
        hello = db.admin.command("hello")
        if not hello.get("arbiterOnly") or hello.get("setName") != cfg["_id"]:
            raise ValueError("Endpoint trực tiếp không khớp arbiter trong cụm.")
        return dict(process_id=str(hello["topologyVersion"]["processId"]), port=int(endpoint.rsplit(":", 1)[1]),
                    current=db.admin.command("buildInfo")["version"])


def mongo_upgrade_node(profile, machine, series):
    endpoint = machine.get("mongo_endpoint")
    if not endpoint or machine.get("profile_id") != profile["id"]:
        raise ValueError("Cần liên kết VPS với đúng endpoint và hồ sơ MongoDB.")
    stopped = host_run(machine, "mongo_stopped_package", {"port": int(endpoint.rsplit(":", 1)[1])}, lambda _: None)
    if stopped.get("role") == "NOT_INSTALLED":
        return stopped
    if stopped:
        if stopped["current"].rsplit(".", 1)[0] != series:
            raise ValueError("Dịch vụ đã dừng. Chọn cùng nhánh để nâng gói. Đổi nhánh cần xác minh FCV của dữ liệu.")
        return stopped
    try:
        with client(dict(profile, username="", password=""), direct=endpoint) as probe:
            hello = probe.admin.command("hello")
    except AutoReconnect as exc:
        raise ValueError(f"Không kết nối được endpoint đích {endpoint}. Kiểm tra dịch vụ "
                         f"{machine.get('service', 'mongod')} và cổng MongoDB trên máy đã chọn.") from exc
    if hello.get("arbiterOnly"):
        node = arbiter_upgrade_target(profile, machine)
        source = node["current"].rsplit(".", 1)[0]
        if source != series and (source, series) != ("8.0", "9.0"):
            raise ValueError("Chưa hỗ trợ đường nâng nhánh này trên arbiter.")
        return dict(node, role="ARBITER")
    if hello.get("msg") == "isdbgrid" or hello.get("isreplicaset") or hello.get("setName", "") != (profile.get("replica_set") or ""):
        raise ValueError("Endpoint chưa sẵn sàng hoặc không khớp replica set trong hồ sơ.")
    with client(profile, direct=endpoint) as db:
        current = db.admin.command("buildInfo")["version"]
        options = db.admin.command("getCmdLineOpts")["parsed"]
        if options.get("sharding", {}).get("clusterRole"):
            raise ValueError("Node thuộc sharded cluster cần quy trình nâng riêng.")
        fcv = db.admin.command({"getParameter": 1, "featureCompatibilityVersion": 1})["featureCompatibilityVersion"]
        source = current.rsplit(".", 1)[0]
        if source != series and (source, series) != ("8.0", "9.0"):
            raise ValueError("Chưa hỗ trợ tự động chuyển giữa hai nhánh này. Có thể cập nhật trong cùng nhánh.")
        if source != series and fcv != {"version": "8.0"}:
            raise ValueError("Nâng nhánh yêu cầu FCV 8.0 ổn định.")
    role = "STANDALONE"
    if hello.get("setName"):
        with client(profile) as cluster:
            cfg, states = healthy_config(cluster)
        member = next((m for m in cfg["members"] if m["host"] == endpoint), None)
        state = states.get(member["_id"], {}) if member else {}
        if state.get("state") not in (1, 2) or not state.get("health"):
            raise ValueError("Cần member PRIMARY hoặc SECONDARY khỏe mạnh.")
        role = "PRIMARY" if state["state"] == 1 else "SECONDARY"
        if len(cfg["members"]) > 1:
            if role == "PRIMARY":
                raise ValueError("Nâng secondary trước, sau đó chuyển primary trong mục Replica rồi thử lại.")
            check_quorum(cfg, {i: m for i, m in states.items() if i != member["_id"] and m.get("state") in (1, 2, 7)})
    return dict(current=current, role=role, port=int(endpoint.rsplit(":", 1)[1]),
                process_id=str(hello["topologyVersion"]["processId"]))


def upgrade_mongo(p, profile, machine, emit):
    node = mongo_upgrade_node(profile, machine, p["series"])
    if node != p["node"]:
        raise ValueError("Instance, phiên bản hoặc vai trò đã đổi. Mở lại kế hoạch.")
    host_run(machine, "package_recover", {}, emit)
    if mongo_upgrade_node(profile, machine, p["series"]) != node:
        raise ValueError("Instance hoặc vai trò đã đổi sau khi kiểm tra dpkg.")
    args = dict(node, version=p["version"])
    emit("Tải trước các gói đã chọn.")
    host_run(machine, "arbiter_packages", args, emit)
    if mongo_upgrade_node(profile, machine, p["series"]) != node:
        raise ValueError("Trạng thái máy đã đổi trong lúc tải gói.")
    emit("Cập nhật gói và giữ dịch vụ đang dừng." if node["role"] == "INACTIVE" else "Dừng dịch vụ, cập nhật gói và khởi động lại MongoDB.")
    host_run(machine, "arbiter_install", args, emit)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            observed = mongo_upgrade_node(profile, machine, p["series"])
            if observed["current"] == p["version"] and observed["role"] == node["role"]:
                return dict(version=p["version"], role=node["role"], endpoint=machine["mongo_endpoint"])
        except (ValueError, PyMongoError):
            pass
        time.sleep(2)
    raise ValueError("Chưa xác minh được phiên bản hoặc vai trò sau khi khởi động lại.")


def upgrade_arbiter(p, profile, machine, emit):
    target = arbiter_upgrade_target(profile, machine)
    if target["current"] != p["version"]:
        if not target["current"].startswith("8.0."):
            raise ValueError("Tác vụ dành cho arbiter đang chạy MongoDB 8.0.")
        params = dict(target, version=p["version"])
        emit("Kiểm tra instance và tải trước các gói MongoDB.")
        host_run(machine, "package_recover", {}, emit)
        host_run(machine, "arbiter_packages", params, emit)
        if arbiter_upgrade_target(profile, machine) != target:
            raise ValueError("Arbiter đã đổi trong khi tải gói. Vui lòng kiểm tra lại.")
        emit("Đã kiểm tra lại quorum. Dừng dịch vụ, cài gói và khởi động arbiter.")
        host_run(machine, "arbiter_install", params, emit)
    emit("Chờ replica set nhận lại arbiter và xác minh phiên bản trực tiếp.")
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            if arbiter_upgrade_target(profile, machine)["current"] == p["version"]:
                return dict(endpoint=machine["mongo_endpoint"], role="ARBITER", version=p["version"])
        except (ValueError, PyMongoError):
            pass
        time.sleep(2)
    raise ValueError("Chưa xác minh được phiên bản và vai trò sau khi nâng. Kiểm tra nhật ký dịch vụ.")


def stop_member_service(profile, machine, host, member_present, storage_pid=None):
    if not machine or machine.get("mongo_endpoint") != host:
        raise ValueError("Cần hồ sơ SSH khớp endpoint của node trước khi gỡ.")
    process_id = None
    identity = {}
    try:
        with client(dict(profile, username="", password=""), direct=host) as target:
            hello = target.admin.command("hello")
        role_matches = (hello.get("setName") == profile["replica_set"]
                        and (hello.get("secondary") or hello.get("arbiterOnly"))) if member_present else (
                            hello.get("isreplicaset") and not hello.get("setName"))
        if hello.get("isWritablePrimary") or not role_matches or not hello.get("topologyVersion"):
            raise ValueError("Endpoint không khớp node cần dừng. Kiểm tra vai trò và cấu hình.")
        process_id = str(hello["topologyVersion"]["processId"])
    except AutoReconnect:
        # Allow retry only if the SSH worker confirms that the service and port are idle.
        pass
    if process_id and not hello.get("arbiterOnly"):
        try:
            with client(profile, direct=host) as target:
                status = target.admin.command("serverStatus")
                current = target.admin.command("hello")
            if current.get("isWritablePrimary") or str(current.get("topologyVersion", {}).get("processId")) != process_id:
                raise ValueError("Endpoint vừa đổi tiến trình hoặc lên Primary. Kiểm tra lại trước khi gỡ.")
            if status.get("process") == "mongod" and isinstance(status.get("pid"), int) and status.get("host"):
                identity = {"expected_pid": status["pid"], "expected_hostname": status["host"]}
        except PyMongoError:
            pass  # Accounts without serverStatus permission use the local hello check.
    return host_run(machine, "retire_member", {"port": int(host.rsplit(":", 1)[1]),
                    "process_id": process_id, "member_present": member_present, "storage_pid": storage_pid, **identity}, lambda _: None)


def execute(action, p, profile, machine, emit):
    if action == "convert_role":
        host = p["host"]
        arbiter = p["role"] == "ARBITER"
        with client(profile) as db:
            cfg, states = healthy_config(db)
            member = next((m for m in cfg["members"] if m["host"] == host), None)
            if not member or states.get(member["_id"], {}).get("state") != (2 if arbiter else 7):
                raise ValueError("Vai trò nguồn đã thay đổi. Mở lại danh sách thành viên.")
            remaining = {k:v for k,v in states.items() if k != member["_id"]}
            check_quorum(cfg, remaining)
            peers = [m for m in cfg["members"] if m != member]
            check_new_vote({"members": peers}, {"votes": 1})
            if arbiter and any(m.get("arbiterOnly") for m in peers):
                raise ValueError("Cụm đã có arbiter.")
            if arbiter and "defaultWriteConcern" not in db.admin.command("getDefaultRWConcern"):
                raise ValueError("Đặt default write concern trước khi chuyển sang Arbiter.")
            source_version = db.admin.command("buildInfo")["version"]
            required_bytes = 0 if arbiter else db.admin.command("listDatabases")["totalSize"]
        with client(dict(profile, username="", password=""), direct=host) as target:
            hello = target.admin.command("hello")
            if hello.get("setName") != cfg["_id"] or not hello.get("secondary" if arbiter else "arbiterOnly"):
                raise ValueError("Endpoint trực tiếp không khớp vai trò nguồn.")
        storage = host_run(machine, "role_storage", {"required_bytes": required_bytes}, emit)
        if storage["version"].split(".")[:2] != source_version.split(".")[:2]:
            raise ValueError("Phiên bản binary của VPS khác nhánh của primary.")
        emit("Đã xác minh thư mục dữ liệu. Đang gỡ vai trò cũ của " + host)
        execute("remove_member", {"host": host, "_expected_version": cfg["version"], "_storage_pid": storage["pid"]},
                dict(profile, replica_set=cfg["_id"]), machine, emit)
        restarted = host_run(machine, "role_restart", {**storage, "port": int(host.rsplit(":", 1)[1])}, emit)
        emit("Đã giữ thư mục dữ liệu cũ tại " + restarted["archive"])
        for attempt in range(30):
            try:
                with client(dict(profile, username="", password=""), direct=host) as node:
                    hello = node.admin.command("hello")
                if not hello.get("isreplicaset") or hello.get("setName"):
                    raise ValueError("Instance vừa bật chưa ở trạng thái replica set trống.")
                break
            except AutoReconnect:
                if attempt == 29:
                    raise
                time.sleep(1)
        result = execute("add_member", {"host": host, "arbiter": arbiter, "votes": 1,
                         "priority": 0 if arbiter else 1, "_member_id": member["_id"], "_verified_version": storage["version"]}, profile, machine, emit)
        if not result.get("ready"):
            raise RuntimeError("Membership đã đổi đồng thời. Kiểm tra vai trò thực tế.")
        return {**result, **restarted, "role": p["role"]}
    if action == "mongo_upgrade":
        return upgrade_mongo(p, profile, machine, emit)
    if action == "arbiter_upgrade":
        return upgrade_arbiter(p, profile, machine, emit)
    if action == "join_fresh":
        emit('Bước 1/6: Kiểm tra SSH và môi trường VPS đích…')
        environment = host_run(machine, 'preflight', {}, emit)
        emit('VPS đích: ' + environment['os'] + '. MongoDB: ' + ('đã có binary' if environment['tools']['mongod'] else 'chưa cài, sẽ cài từ repository chính thức') + '.')
        if profile.get("tls"):
            raise ValueError("Wizard node mới hiện dành cho cụm keyfile không TLS. Cụm TLS cần chuẩn bị certificate/node riêng trước khi thêm member.")
        emit('Bước 2/6: Kết nối cụm nguồn, kiểm tra primary/quorum và phiên bản…')
        with client(profile) as db:
            cfg, states = healthy_config(db)
            check_quorum(cfg, states)
            if not any(s.get("name") == p["source_endpoint"] and s.get("state") == 1 for s in states.values()):
                raise ValueError("Primary đã thay đổi. Mở lại thao tác để Manager nhận diện primary mới.")
            if p["advertise"] in {m["host"] for m in cfg["members"]}:
                member = next(m for m in cfg["members"] if m["host"] == p["advertise"])
                state = states.get(member["_id"], {})
                if bool(member.get("arbiterOnly")) != bool(p.get("arbiter")) or state.get("state") not in (1, 2, 7) or state.get("health") != 1:
                    raise ValueError("Member đã có trong cấu hình. Kiểm tra vai trò và trạng thái trước khi xử lý.")
                emit("Member đã hoạt động trong cụm: " + state["stateStr"] + ". Giữ cấu hình đang dùng.")
                return dict(reused=True, service=machine["service"], profile_id=profile["id"], mongo_endpoint=p["advertise"])
            check_new_vote(cfg, p)
            if p.get('arbiter') and any(m.get('arbiterOnly') for m in cfg['members']):
                raise ValueError('Cụm đã có arbiter. Không cài thêm arbiter trước khi xử lý cấu hình hiện có.')
            if p.get('arbiter') and 'defaultWriteConcern' not in db.admin.command('getDefaultRWConcern'):
                raise ValueError('Đặt default write concern rõ ràng trước khi thêm arbiter.')
            version = db.admin.command("buildInfo")["version"]
            series = ".".join(version.split(".")[:2])
            if series not in catalog()["supported"]:
                raise ValueError("Nhánh của nguồn chưa có trong danh mục Community cho Ubuntu.")
        with client(profile, direct=p["source_endpoint"]) as node:
            if not node.admin.command("hello").get("isWritablePrimary"):
                raise ValueError("VPS nguồn đã nhường primary. Mở lại thao tác để chọn nguồn hiện tại.")
            opts = node.admin.command("getCmdLineOpts")["parsed"]
            security = opts.get("security", {})
            keypath = security.get("keyFile")
            if not keypath or security.get("clusterAuthMode", "keyFile") != "keyFile":
                raise ValueError("Nguồn không dùng xác thực keyFile được hỗ trợ. Cần chuẩn bị member thủ công.")
        emit("Bước 3/6: Đọc keyfile nguồn qua SSH; chuyển trong bộ nhớ, không ghi vào lịch sử.")
        key = host_run(p["_source_machine"], "read_keyfile", {"path": keypath}, lambda _: None)
        params = {k: p[k] for k in ("instance", "port", "advertise", "bind_ip")}
        params.update(replica_set=cfg["_id"], series=series, keyfile_b64=key["keyfile_b64"])
        emit('Bước 4/6: Kiểm tra phiên bản/cấu hình đích, cài nếu thiếu hoặc tái sử dụng node đã chuẩn bị…')
        if p.get('mode') == 'prepared':
            if not environment['tools']['mongod']:
                raise ValueError('Node được chọn đã chuẩn bị nhưng chưa có mongod. Chọn chế độ cài/cấu hình instance mới.')
            target_key = host_run(machine, 'read_keyfile', {'path': p['target_keyfile']}, lambda _: None)
            import base64
            def normalized(value):
                return ''.join(base64.b64decode(value).decode().split())
            if normalized(target_key['keyfile_b64']) != normalized(key['keyfile_b64']):
                raise ValueError('Keyfile đích không khớp nguồn. Chưa thêm member; kiểm tra cấu hình hoặc chuẩn bị instance mới với port/thư mục trống.')
            prepared = {'prepared': True, 'service': machine['service'], 'reused': True}
            emit('Đã đối chiếu keyfile nguồn/đích. Giữ nguyên cấu hình và dữ liệu node đã chuẩn bị.')
        else:
            prepared = host_run(machine, "prepare_member", params, emit)
        emit("Service node đích: " + prepared["service"] + ". Kiểm tra endpoint từ máy quản trị…")
        for attempt in range(30):
            try:
                with client(dict(profile, username="", password=""), direct=p["advertise"]) as node:
                    node.admin.command("hello")
                break
            except PyMongoError:
                if attempt == 29:
                    raise RuntimeError("Node đã được chuẩn bị nhưng endpoint chưa truy cập được. Kiểm tra firewall/địa chỉ quảng bá; dùng Thêm node đã chuẩn bị sau khi sửa mạng.") from None
                time.sleep(1)
        emit('Kiểm tra VPS đích kết nối tới các member và chính endpoint quảng bá…')
        host_run(machine, 'member_network', {'endpoints': [p['advertise']] + [m['host'] for m in cfg['members']]}, emit)
        emit('Bước 5/6: Thêm membership bằng reconfig thông thường…')
        match = re.search(r'\bv(\d+\.\d+\.\d+)', environment.get('version', ''))
        result = execute("add_member", {"host": p["advertise"], "arbiter": p.get('arbiter', False), "votes": p["votes"], "priority": p["priority"], '_verified_version': match.group(1) if match else ''}, profile, machine, emit)
        emit('Bước 6/6: Đã xác minh trạng thái member và cấu hình bầu chọn.')
        return {**prepared, **result, "profile_id": profile["id"], "mongo_endpoint": p["advertise"]}
    if action == "sync_backup":
        destination = p["_destination"]
        with client(profile) as source, client(destination) as target:
            source_hello = source.admin.command("hello")
            target_hello = target.admin.command("hello")
            if source_hello["topologyVersion"]["processId"] == target_hello["topologyVersion"]["processId"] or (
                source_hello.get("setName") and target_hello.get("setName") and
                source.admin.command("replSetGetConfig")["config"]["settings"]["replicaSetId"] ==
                target.admin.command("replSetGetConfig")["config"]["settings"]["replicaSetId"]
            ):
                raise ValueError("Cụm nguồn và đích trùng nhau.")
        scope = {k: p[k] for k in ("databases", "database", "collection", "collections", "application_only") if k in p}
        fresh = execute("backup", scope, profile, machine, emit)
        emit("Đã lưu backup " + fresh["id"] + ". Đang khôi phục sang " + destination["name"])
        return execute("restore", {"backup_id": fresh["id"], "drop": p.get("drop", False)}, destination, machine, emit)
    if action in HOST_ACTIONS:
        if action in {"backup", "restore"}:
            with client(profile) as db:
                hello = db.admin.command("hello")
                if profile.get("_restore_direct") and hello.get("isreplicaset") and not hello.get("setName"):
                    raise ValueError("Máy nhận vẫn chạy ở chế độ replica set nhưng chưa có cấu hình hợp lệ. Gỡ member không tự chuyển máy thành standalone. Để restore ở cổng này, cần chuyển đúng instance sang chế độ độc lập trước.")
                if profile.get("_restore_direct") and (not hello.get("isWritablePrimary") or hello.get("arbiterOnly") or hello.get("msg") == "isdbgrid"):
                    raise ValueError("Máy nhận cần là MongoDB standalone hoặc primary có thể ghi. Muốn thử riêng trên VPS secondary, dùng một instance độc lập trên cổng khác.")
                replica = bool(hello.get("setName"))
                if action == "backup" and p.get("application_only"):
                    names = sorted(set(db.list_database_names()) - {"admin", "local", "config"})
                    if not names:
                        raise ValueError("Không có database ứng dụng để sao lưu.")
                    p = dict(p, databases=names)
                if action == "backup" and (p.get("database") or p.get("databases")):
                    requested = p.get("databases") or [p["database"]]
                    if set(requested) - set(db.list_database_names()):
                        raise ValueError("Database đã chọn không tồn tại hoặc không đọc được.")
                    selected = p.get("collections") or ([p["collection"]] if p.get("collection") else [])
                    if selected and set(selected) - set(db[requested[0]].list_collection_names()):
                        raise ValueError("Collection đã chọn không tồn tại.")
                version = db.admin.command("buildInfo")["version"]
                fcv = db.admin.command({"getParameter": 1, "featureCompatibilityVersion": 1})["featureCompatibilityVersion"]
                if "targetVersion" in fcv or "previousVersion" in fcv:
                    raise ValueError("Chờ chuyển đổi FCV hoàn tất trước khi backup/restore.")
            p = dict(p, replica=replica, connection={"uri": uri(profile), **({"password": profile["password"]} if profile.get("username") else {})}, source=profile["name"], source_id=profile.get("id"), compatibility={"version": version, "fcv": fcv["version"]})
        if action == "service":
            endpoint = machine.get("mongo_endpoint")
            port = int(endpoint.rsplit(":", 1)[1]) if endpoint else None
            result = host_run(machine, action, dict(p, mongo_port=port), emit)
            if endpoint and p["operation"] in {"start", "restart", "repair_keyfile"}:
                try:
                    with client(profile or {}, direct=endpoint) as db:
                        hello = db.admin.command("hello")
                    result.update(endpoint=endpoint, replica_set=hello.get("setName"),
                                  primary=hello.get("primary"), secondary=bool(hello.get("secondary")),
                                  writable=bool(hello.get("isWritablePrimary")), arbiter=bool(hello.get("arbiterOnly")))
                except PyMongoError as exc:
                    raise RuntimeError("systemd đã báo active nhưng chưa xác minh được MongoDB tại endpoint. " + mongo_error(exc)) from None
            return result
        return host_run(machine, action, p, emit)
    emit('Kết nối cụm nguồn và tìm primary hiện tại…')
    with client(profile) as db:
        if action == "upgrade_check":
            state = snapshot(profile)
            checks = [{"name": "FCV nguồn là 8.0 hoặc 8.3", "ok": state.get("fcv") in {"8.0", "8.3"}},
                      {"name": "Tất cả member khỏe, không initial sync/rollback/recovering", "ok": bool(state["members"]) and all(m["health"] == 1 and m["state"] in {"PRIMARY", "SECONDARY", "ARBITER"} for m in state["members"])}]
            return {"checks": checks, "current": state, "manual_steps": ["Kiểm tra driver/ứng dụng và restore thử backup.", "Xác minh package 9.0 cho từng hệ điều hành.", "Nâng secondary tuần tự, step down rồi nâng primary cũ.", "Kiểm thử ứng dụng; hoàn tất FCV ở bước riêng."], "automated_upgrade": False}
        if action in {"create_user", "password", "drop_user"}:
            database = db[p["database"]]
            if action == "create_user":
                result = database.command("createUser", p["username"], pwd=p["password"], roles=[{"role": p["role"], "db": p["database"]}])
            elif action == "password":
                result = database.command("updateUser", p["username"], pwd=p["password"])
            else:
                if p["username"] == profile["username"] and p["database"] == profile["auth_db"]:
                    raise ValueError("Không xóa tài khoản đang dùng để quản trị.")
                result = database.command("dropUser", p["username"])
            return {"ok": result["ok"]}
        if action == "drop_database":
            db.drop_database(p["database"])
            return {"deleted": p["database"]}
        if action == "write_concern":
            return serial(db.admin.command({"setDefaultRWConcern": 1, "defaultWriteConcern": {"w": "majority" if p["w"] == "majority" else 1, "wtimeout": 10000}}))
        if action == "step_down":
            cfg, states = healthy_config(db)
            primary_id = next(m["_id"] for m in states.values() if m["state"] == 1)
            check_quorum(cfg, states)
            # The stepping-down member remains online and can still vote.
            candidates = {m["host"] for m in cfg["members"]
                          if states.get(m["_id"], {}).get("state") == 2 and states[m["_id"]].get("health") == 1
                          and m.get("priority", 1) > 0 and m.get("votes", 1) == 1 and not m.get("arbiterOnly")}
            target = p.get("host")
            if not candidates or (target and target not in candidates):
                raise ValueError("Cần secondary đang khỏe, votes=1 và priority lớn hơn 0 để bầu primary.")
            if target:
                with client(profile, direct=target) as candidate:
                    hello = candidate.admin.command("hello")
                    if hello.get("setName") != cfg["_id"] or not hello.get("secondary"):
                        raise ValueError("Node đã chọn không còn là secondary của cụm.")
                    emit("Chờ secondary áp dụng đến mốc oplog hiện tại của primary…")
                    reference = db.admin.command("replSetGetStatus")["optimes"]["appliedOpTime"]["ts"]
                    for _ in range(30):
                        applied = candidate.admin.command("replSetGetStatus")["optimes"]["appliedOpTime"]["ts"]
                        if applied >= reference:
                            break
                        time.sleep(1)
                    else:
                        raise ValueError("Secondary chưa bắt kịp mốc oplog của primary sau 30 giây. Kiểm tra replication lag trước khi bầu lại.")
                    # A recent step-down may still prevent the chosen secondary from standing.
                    candidate.admin.command({"replSetFreeze": 0})
                old = states[primary_id]["name"]
                started = time.monotonic()
                for host in sorted(candidates - {target}):
                    with client(profile, direct=host) as peer:
                        hello = peer.admin.command("hello")
                        if hello.get("setName") != cfg["_id"] or not hello.get("secondary"):
                            raise ValueError("Vai trò member đã thay đổi trước khi bàn giao: " + host)
                        peer.admin.command({"replSetFreeze": 45})
                        emit("Tạm hoãn ứng cử 45 giây trên " + host + "; node vẫn bỏ phiếu.")
                with client(profile, direct=old) as incumbent:
                    hello = incumbent.admin.command("hello")
                    if (not hello.get("isWritablePrimary") or hello.get("setName") != cfg["_id"]
                            or time.monotonic() - started > 10):
                        raise ValueError("Trạng thái cụm đã đổi hoặc chuẩn bị quá lâu. Chưa gửi lệnh nhường primary.")
                    emit("Bàn giao từ " + old + " sang " + target + ". Chờ MongoDB đồng bộ trước khi nhường vai trò…")
                    try:
                        incumbent.admin.command({"replSetStepDown": 45, "secondaryCatchUpPeriodSecs": 10, "force": False})
                    except AutoReconnect:
                        pass
                    except OperationFailure as exc:
                        raise ValueError(f"Primary từ chối bàn giao (code {exc.code}): {(exc.details or {}).get('errmsg', '')}") from None
            else:
                try:
                    db.admin.command({"replSetStepDown": 60, "secondaryCatchUpPeriodSecs": 15})
                except AutoReconnect:
                    pass
            deadline = time.monotonic() + 60
            observed = None
            while time.monotonic() < deadline:
                try:
                    new = db.admin.command("hello")
                    observed = new.get("primary")
                    old = states[primary_id]["name"]
                    if new.get("isWritablePrimary") and new.get("primary") != old and (not target or new.get("primary") == target):
                        return {"previous_primary": old, "primary": new["primary"]}
                except PyMongoError:
                    pass
                time.sleep(2)
            if target:
                raise RuntimeError(f"Chưa xác minh được {target} làm primary. Primary quan sát gần nhất: {observed or 'chưa có'}. Kiểm tra quorum, trạng thái và replication lag.")
            raise RuntimeError("Đã gửi step down nhưng chưa xác minh được primary mới; kiểm tra trạng thái.")
        cfg, states = healthy_config(db)
        check_quorum(cfg, states)
        old_cfg = copy.deepcopy(cfg)
        member = next((m for m in cfg["members"] if m["host"] == p["host"]), None)
        if action == "add_member":
            if member:
                return {"message": "Node đã tồn tại; không thêm trùng."}
            check_new_vote(cfg, p)
            # A fresh member has not replicated users yet. hello is intentionally
            # unauthenticated here; the reconfiguration itself uses cluster credentials.
            emit('Kiểm tra node đã chuẩn bị tại ' + p['host'] + '…')
            try:
                with client(dict(profile, username="", password=""), direct=p["host"]) as node:
                    hello = node.admin.command("hello")
            except PyMongoError:
                raise ValueError('Không kết nối được endpoint node đích ' + p['host'] + '. Nếu VPS chưa cài/cấu hình MongoDB, dùng Thêm node → Cài và cấu hình qua SSH. Nếu đã chuẩn bị, kiểm tra service, bind address và firewall port MongoDB.') from None
            if (hello.get('setName') and hello['setName'] != cfg['_id']) or (not hello.get('setName') and not hello.get('isreplicaset')):
                raise ValueError('Node đích chưa cấu hình đúng replica set ' + cfg['_id'] + '. Dùng luồng cài/cấu hình VPS qua SSH; không thêm trực tiếp instance standalone hoặc cụm khác.')
            source_version = db.admin.command('buildInfo')['version']
            target_version = p.get('_verified_version', '')
            if not target_version:
                try:
                    with client(profile, direct=p['host']) as authenticated:
                        target_version = authenticated.admin.command('buildInfo')['version']
                except OperationFailure as exc:
                    if exc.code not in (13, 18):
                        raise
                    source_hello = db.admin.command('hello')
                    if hello.get('maxWireVersion') != source_hello.get('maxWireVersion'):
                        raise ValueError('Node chưa có user đồng bộ và wire version khác nguồn. Dùng kiểm tra qua SSH trước khi thêm.') from None
                    emit('Node chưa đồng bộ user: đã đối chiếu wire version; phiên bản binary đầy đủ cần kiểm tra qua SSH.')
            if target_version and target_version.split('.')[:2] != source_version.split('.')[:2]:
                raise ValueError('Phiên bản MongoDB đích ' + target_version + ' khác nhánh nguồn ' + source_version + '. Chưa thêm member. Dùng quy trình nâng/hạ phiên bản riêng, không cài đè tự động.')
            if target_version:
                emit('Đã đối chiếu nhánh MongoDB nguồn/đích qua SSH hoặc xác thực: ' + target_version + '.')
            arbiter = p.get("arbiter", False)
            if arbiter and any(m.get("arbiterOnly") for m in cfg["members"]):
                raise ValueError("Cụm đã có arbiter.")
            if arbiter and "defaultWriteConcern" not in db.admin.command("getDefaultRWConcern"):
                raise ValueError("Hãy chọn write concern rõ ràng trước khi thêm arbiter.")
            member_id = p.get("_member_id", max(m["_id"] for m in cfg["members"]) + 1)
            if any(m["_id"] == member_id for m in cfg["members"]):
                raise ValueError("ID thành viên đã được sử dụng.")
            member = {"_id": member_id, "host": p["host"], "priority": p.get("priority", 0 if arbiter else p.get("votes", 1)), "votes": p.get("votes", 1)}
            if arbiter:
                member["arbiterOnly"] = True
            cfg["members"].append(member)
        elif "_expected_version" in p and cfg["version"] != p["_expected_version"]:
            raise ValueError("Cấu hình cụm đã thay đổi. Mở lại thao tác.")
        elif not member:
            if action == "remove_member":
                emit("Endpoint đã rời cấu hình. Tiếp tục xác minh tài nguyên trên VPS.")
                return {"config": serial(cfg), "service_cleanup": stop_member_service(profile, machine, p["host"], False)}
            raise ValueError("Node không có trong replica set.")
        elif action == "remove_member":
            if states.get(member["_id"], {}).get("state") == 1:
                raise ValueError("Step down primary trước khi gỡ node.")
            remaining = {i: state for i, state in states.items() if i != member["_id"]}
            check_quorum(cfg, remaining)
            emit("Đủ quorum khi dừng node. Đang dừng mongod và tắt tự khởi động…")
            cleanup = stop_member_service(profile, machine, p["host"], True, p["_storage_pid"]) if "_storage_pid" in p else stop_member_service(profile, machine, p["host"], True)
            emit("Đã xác minh dịch vụ dừng. Đang gỡ node khỏi cấu hình cụm…")
            cfg["members"].remove(member)
            check_quorum(cfg, states)
        elif action == "member_options":
            if member.get("arbiterOnly") and (p["priority"] != 0 or p["hidden"]):
                raise ValueError("Arbiter cần priority 0 và không hidden.")
            member.update(priority=p["priority"], votes=p["votes"], hidden=p["hidden"])
            check_quorum(cfg, states)
        else:
            raise ValueError("Thao tác chưa được hỗ trợ.")
        cfg["version"] += 1
        emit("Đã đọc cấu hình mới nhất. Áp dụng reconfig thông thường…")
        try:
            db.admin.command({"replSetReconfig": cfg, "maxTimeMS": 30000})
        except AutoReconnect:
            emit("Kết nối đổi trong lúc reconfig; đang kiểm tra kết quả…")
        expected = {m["host"] for m in cfg["members"]}
        final_cfg = db.admin.command("replSetGetConfig")["config"]
        if {m["host"] for m in final_cfg["members"]} != expected:
            raise RuntimeError("Chưa xác minh được cấu hình sau reconfig.")
        if action == "member_options":
            actual = next(m for m in final_cfg["members"] if m["host"] == p["host"])
            if any(actual.get(k, False if k == "hidden" else 1) != p[k] for k in ("priority", "votes", "hidden")):
                raise RuntimeError("Chưa xác minh được votes/priority sau reconfig. Cụm có thể vừa đổi primary; kiểm tra trạng thái trước khi thử lại.")
        if action == "add_member":
            emit("Đã thêm member. Chờ SECONDARY/ARBITER, tối đa 5 phút…")
            actual = next(m for m in final_cfg["members"] if m["host"] == p["host"])
            if any(actual.get(k, 1) != member[k] for k in ("votes", "priority")):
                raise RuntimeError("Cấu hình votes/priority sau khi thêm khác giá trị đã chọn.")
            target_states = {7} if p.get("arbiter") else {1, 2}
            for _ in range(100):
                status = db.admin.command("replSetGetStatus")
                if any(m["name"] == p["host"] and m["state"] in target_states and m["health"] == 1 for m in status["members"]):
                    return {"ready": True, "host": p["host"], "seeds": [m["host"] for m in final_cfg["members"]], "votes": member["votes"], "priority": member["priority"], "previous_config": serial(old_cfg)}
                time.sleep(3)
            raise RuntimeError("Member đã được thêm nhưng còn đang đồng bộ. Theo dõi trạng thái; không thêm lại.")
        result = {"config": serial(final_cfg), "previous_config": serial(old_cfg)}
        if action == "remove_member":
            result["service_cleanup"] = cleanup
        return result
