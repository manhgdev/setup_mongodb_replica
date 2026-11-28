import asyncio
import hashlib
import time
import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
from typing import Literal
from .hostname_worker import valid_hostname
from . import firewall_service, oci_firewall, sftp_service, stack_transfer
from .terminal import run_terminal_session

from fastapi import FastAPI, HTTPException, Query, Request, WebSocket
from fastapi.responses import FileResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, SecretStr
from shared.manager_core.ssh_transport import fingerprint, probe_host_key, enroll_host_key
from shared.manager_core.auth import Auth
from shared.manager_core.http import register_auth
from shared.manager_core.storage_api import register_storage_routes
from shared.manager_core.job_slots import Busy, JobSlots, machine_keys
from shared.manager_core.machines import Machine
from shared.manager_core.paths import DATA_DIR
from shared.manager_core.store import Store
from shared.manager_core.workspaces import WorkspaceRegistry, WorkspaceStoreProxy, current_workspace_id, use_store
from shared.manager_core.transport import run_worker

ROOT = Path(__file__).resolve().parents[1]
CATALOG = json.loads((ROOT / "manifests/packages.json").read_text())


KITS = json.loads((ROOT / "manifests/kits.json").read_text())
INSTALL = json.loads((ROOT / "manifests/install.json").read_text())


class ImportedSshKey(BaseModel):
    filename: str = Field(default="id_key", max_length=128)
    content: str = Field(min_length=1, max_length=65536)


class WebsiteConfig(BaseModel):
    gzip: bool = False
    brotli: bool = False
    cache: bool = False
    allow_ips: str = Field(default="", max_length=2048)
    auth_file: str = Field(default="", max_length=512)
    cors: str = Field(default="", max_length=512)
    headers: str = Field(default="", max_length=4096)
    rate: int = Field(default=0, ge=0, le=10000)
    kind: str = "proxy"
    backend: str = Field(default="", max_length=2048)
    directory: str = Field(default="", max_length=1024)
    redirect: str = Field(default="", max_length=1024)
    location: str = Field(default="/", max_length=512)
    algorithm: str = "round-robin"
    names: list[str] = Field(default_factory=list, max_length=100)
    domain: str = Field(default="", max_length=253)
    port: int = Field(default=3000, ge=1, le=65535)
    save_dir: Literal["conf.d", "sites-available"] = "conf.d"
    conf_name: str = Field(default="", max_length=120)
    raw_conf: str = Field(default="", max_length=250000)


class Operation(WebsiteConfig):
    container: str = Field(default="", max_length=64)
    filename: str = Field(default="", max_length=4096)
    pull: bool = False
    name: str = Field(default="", max_length=100)
    target: str = Field(default="", max_length=512)
    force_https: bool = False
    http2: bool = False
    http3: bool = False
    source: str = Field(default="", max_length=250000)
    file_id: str = Field(default="", max_length=64)
    snapshot: str = Field(default="", max_length=50)
    revision: str = Field(default="", max_length=64)
    operation: str = "save"
    method: str = "http"
    email: str = Field(default="", max_length=254)
    token: str = Field(default="", max_length=256, repr=False)
    packages: list[str] = Field(default_factory=list, max_length=len(CATALOG))
    websites: list[WebsiteConfig] = Field(default_factory=list, max_length=50)
    sites: list[dict] = Field(default_factory=list, max_length=100)
    overwrite: bool = False
    update_renewal: bool = True


class BatchOperation(BaseModel):
    machines: list[str] = Field(min_length=1, max_length=100)
    operation: Operation


def now():
    return datetime.now(timezone.utc).isoformat()


def worker(machine, action, params, emit):
    if action=="hostname":
        return run_worker(machine,ROOT/"backend/hostname_worker.py",{"params":params},True,emit)
    if action.startswith("git-"):
        params = dict(params)
        secret = params.pop("passphrase", None)
        if secret:
            params["passphrase"] = secret.get_secret_value()
        return run_worker(machine, ROOT/"backend/git_worker.py",
                          {"action": action[4:], "params": params}, action in {"git-install","git-update"}, emit)
    if action.startswith("fw-"):
        return run_worker(machine,ROOT/"backend/firewall_worker.py",{"action":action,"params":params},True,emit)
    if action.startswith("docker-"):
        return run_worker(machine,ROOT/"backend/docker_worker.py",{"action":action,"params":params},True,emit)
    if action.startswith("stack-"):
        import getpass
        params = dict(params, login_user=machine["user"] if machine["mode"] == "ssh" else getpass.getuser())
        return run_worker(machine, ROOT / "backend/stack_worker.py", {"action": action, "params": params}, True, emit)
    if action in {"overview","install","uninstall"}:
        import getpass
        params=dict(params,entries=INSTALL,login_user=machine["user"] if machine["mode"]=="ssh" else getpass.getuser())
    return run_worker(
        machine,
        ROOT / "backend/worker.py",
        {"action": action, "params": dict(params, catalog=list(CATALOG))},
        action in {"native-install", "install", "uninstall", "maintain", "service-control", "site", "sites", "inventory", "detail", "logs", "apply", "diff", "check", "repair-link", "lifecycle", "ssl-status","external-certificate","renew-ssl","renew-test","ssl-renew-enable","ssl-renew-test","cloudflare-token"},
        emit,
    )


class ConnectionTest(Machine):
    expected: str = ""


class HostnameChange(BaseModel):
    hostname: str = Field(min_length=1,max_length=63)
    expected: str = Field(min_length=1,max_length=64)
    confirmed: Literal[True]


GIT_ACTIONS = {
    "restore-public": "Khôi phục public key", "import": "Thêm public key", "install": "Cài Git & OpenSSH", "update": "Cập nhật Git & OpenSSH",
    "identity": "Cấu hình Git", "create": "Tạo SSH key", "load": "Nạp SSH key",
    "delete": "Xóa SSH key", "alias": "Thêm SSH alias", "unalias": "Gỡ SSH alias",
    "test": "Kiểm tra SSH đến Git provider",
}


class GitOperation(BaseModel):
    public_key: str = Field(default="", max_length=16384)
    name: str = Field(default="", max_length=64)
    username: str = Field(default="", max_length=128)
    email: str = Field(default="", max_length=254)
    kind: Literal["ed25519","rsa"] = "ed25519"
    passphrase: SecretStr = Field(default=SecretStr(""), max_length=1024)
    fingerprint: str = Field(default="", max_length=128)
    alias: str = Field(default="", max_length=64)
    provider: Literal["github.com","gitlab.com","bitbucket.org"] = "github.com"


class FirewallChange(BaseModel):
    op: Literal["open", "close", "enable"] = "open"
    port: str = Field(default="", max_length=20)
    protocols: list[Literal["tcp", "udp"]] = Field(default_factory=lambda: ["tcp"], max_length=2)
    source: str = Field(default="", max_length=64)
    layers: list[Literal["ufw", "oci"]] = Field(default_factory=lambda: ["ufw"], max_length=2)
    oci_target: str = Field(default="auto", max_length=200)


class OciAccount(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    auth: Literal["api_key", "instance_principal"] = "api_key"
    region: str = Field(max_length=64)
    tenancy: str = Field(default="", max_length=256)
    user: str = Field(default="", max_length=256)
    fingerprint: str = Field(default="", max_length=128)
    private_key: SecretStr = Field(default=SecretStr(""), max_length=16384)
    passphrase: SecretStr = Field(default=SecretStr(""), max_length=1024)


class OciLink(BaseModel):
    account_id: str = Field(min_length=1, max_length=64)
    region: str = Field(default="", max_length=64)


class PasswordChange(BaseModel):
    password: SecretStr = Field(min_length=1,max_length=1024)
    enable: bool = False
    set_root: bool = False


class SysUserAction(BaseModel):
    op: Literal["create", "update", "delete"]
    username: str = Field(min_length=1, max_length=32)
    password: str = Field(default="", max_length=1024)
    shell: str = Field(default="", max_length=64)
    home: str = Field(default="", max_length=256)
    groups: list[str] | None = None
    sudo: bool = False
    nopasswd: bool = False
    locked: bool | None = None
    ssh_keys: list[str] | None = None
    remove_home: bool = False


class StorageMountAction(BaseModel):
    op: Literal["mount", "unmount", "format", "partition"]
    device: str = Field(min_length=1, max_length=128)
    mountpoint: str = Field(default="", max_length=256)
    fstype: str = Field(default="ext4", max_length=16)
    persist_fstab: bool = True
    remove_fstab: bool = False
    confirm_device: str = Field(default="", max_length=128)
    owner: str = Field(default="", max_length=32)
    group: str = Field(default="", max_length=32)
    mode: str = Field(default="755", max_length=8)


class PathPermissionsAction(BaseModel):
    path: str = Field(min_length=1, max_length=512)
    create: bool = False
    owner: str = Field(default="", max_length=32)
    group: str = Field(default="", max_length=32)
    mode: str = Field(default="", max_length=8)
    recursive: bool = False
    set_root: bool = False


def account_call(machine, action, params=None, emit=lambda _:None):
    return run_worker(dict(machine,strict_key=True,fresh_key=True),ROOT/"backend/account_worker.py",
                      {"action":action,"params":params or {}},action!="identity",emit)


def account_info(machine):
    if machine["mode"]!="ssh":
        raise ValueError("Chọn VPS kết nối qua SSH.")
    identity = account_call(machine,"identity")
    if identity["user"]!=machine["user"] or not identity["connection"]:
        raise ValueError("User SSH thực tế khác với hồ sơ.")
    policy = account_call(machine,"policy",identity) if identity["sudo"] else {}
    return dict(identity,**policy,host=machine["host"],port=machine["port"],auth=machine.get("ssh_auth","key"))


def register(app):
    def record(kind, ident):
        try:
            return app.state.store.get(kind, ident)
        except KeyError:
            raise HTTPException(404, "Không tìm thấy mục đã chọn.") from None

    @app.post("/api/vps/connection-test")
    def test_connection(body: ConnectionTest):
        machine = body.model_dump(exclude={"expected"})
        try:
            if not body.expected:
                return {"fingerprint":fingerprint(probe_host_key(machine))}
            enroll_host_key(machine,body.expected)
            return account_info(machine)
        except (RuntimeError,ValueError,OSError) as exc:
            raise HTTPException(422,str(exc)) from None

    @app.get("/api/vps/machines/{ident}/account")
    def account(ident: str):
        try:
            return account_info(record("machines",ident))
        except (RuntimeError,ValueError,OSError) as exc:
            raise HTTPException(422,str(exc)) from None

    def sysadmin_call(machine, action, params=None):
        payload = dict(params or {}, current_user=machine.get("user") or "root")
        return run_worker(machine, ROOT / "backend/sysadmin_worker.py",
                          {"action": action, "params": payload}, True, lambda _: None)

    @app.get("/api/vps/machines/{ident}/sysadmin")
    def sysadmin_overview(ident: str):
        try:
            return sysadmin_call(record("machines", ident), "overview")
        except (RuntimeError, ValueError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/users")
    def sysadmin_users(ident: str, body: SysUserAction):
        try:
            action = {"create": "user_create", "update": "user_update", "delete": "user_delete"}[body.op]
            return sysadmin_call(record("machines", ident), action, body.model_dump())
        except (RuntimeError, ValueError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/storage/mount")
    def sysadmin_storage_mount(ident: str, body: StorageMountAction):
        try:
            return sysadmin_call(record("machines", ident), "storage_mount", body.model_dump())
        except (RuntimeError, ValueError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/storage/permissions")
    def sysadmin_storage_permissions(ident: str, body: PathPermissionsAction):
        try:
            return sysadmin_call(record("machines", ident), "path_permissions", body.model_dump())
        except (RuntimeError, ValueError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.websocket("/api/vps/machines/{ident}/terminal")
    async def machine_terminal(websocket: WebSocket, ident: str, cols: int = 100, rows: int = 30, workspace_user: str = ""):
        auth = app.state.auth
        if not auth.allowed_request(websocket):
            await websocket.close(code=4403)
            return
        session = await asyncio.to_thread(auth.session, websocket) if auth.enabled else None
        if auth.enabled and session is None:
            await websocket.close(code=4401)
            return
        ws_id = session.get("workspace_id", "default") if session else "default"
        if session and workspace_user and workspace_user != session["user_id"]:
            target = await asyncio.to_thread(auth.get_user, workspace_user)
            if not target or not auth.can_access_workspace(session, target):
                await websocket.close(code=4403)
                return
            ws_id = target.get("workspace_id", "default")
        ws_store = app.state.workspaces.get_store(ws_id) if hasattr(app.state, "workspaces") else app.state.store
        with use_store(ws_store, ws_id):
            try:
                machine = await asyncio.to_thread(ws_store.get, "machines", ident)
            except KeyError:
                await websocket.close(code=4404)
                return
            await websocket.accept()
            await run_terminal_session(websocket, machine, cols=cols, rows=rows, store=ws_store)

    @app.post("/api/vps/machines/{ident}/password",status_code=202)
    def password_change(ident: str,body: PasswordChange):
        machine=record("machines",ident)
        if machine["mode"]!="ssh" or machine["user"]=="root" or machine.get("ssh_auth","key")!="key":
            raise HTTPException(422,"Chọn hồ sơ SSH key của tài khoản thường có sudo.")
        return queue_job(ident,"password",body,machine)

    @app.post("/api/vps/machines/{ident}/hostname",status_code=202)
    def change_hostname(ident: str,body: HostnameChange,request: Request):
        if not valid_hostname(body.hostname):
            raise HTTPException(422,"Hostname không hợp lệ.")
        return queue_job(ident,"hostname",body,record("machines",ident),actor=request.state.session["username"])

    @app.get("/api/vps/machines")
    def machines():
        return [
            {"id": m["id"], "name": m["name"], "host": m.get("host") or "localhost"}
            for m in sorted(app.state.store.all("machines"), key=lambda x: bool(x.get("profile_id")))
        ]

    def public_machine(value):
        value = dict(value)
        value["has_ssh_password"] = bool(value.pop("ssh_password", None))
        return value

    @app.get("/api/vps/seeds")
    def seeds():
        out = []
        for prof in app.state.store.all("profiles"):
            for seed in prof.get("seeds") or []:
                out.append({"cluster": prof.get("name", ""), "seed": seed})
        return out

    @app.get("/api/vps/servers")
    def servers():
        return [public_machine(m) for m in app.state.store.all("machines")]

    @app.post("/api/vps/servers/{ident}/reveal-password")
    def reveal_server_password(ident: str):
        machine = record("machines", ident)
        return {"password": machine.get("ssh_password") or ""}

    @app.post("/api/vps/ssh-keys/import")
    def import_ssh_key(body: ImportedSshKey):
        from shared.manager_core.ssh_transport import save_ssh_key_to_store
        try:
            saved = save_ssh_key_to_store(app.state.store, body.filename, body.content)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        return {"path": saved["path"], "name": saved["name"], "id": saved["id"]}

    @app.put("/api/vps/servers/{ident}")
    def edit_server(ident: str, body: Machine):
        previous = record("machines", ident)
        values = body.model_dump()
        values.update(profile_id=previous.get("profile_id", ""), service=previous.get("service", "mongod"))
        if body.mode == "ssh" and body.ssh_auth == "password":
            if body.ssh_password is None:
                values["ssh_password"] = previous.get("ssh_password", "")
            if not values["ssh_password"]:
                raise HTTPException(422, "Thiếu mật khẩu SSH.")
        else:
            values["ssh_password"] = ""
        if body.mode == "ssh" and any(m["id"] != ident and m.get("mode") == "ssh" and m.get("host") == body.host and int(m.get("port", 22)) == body.port for m in app.state.store.all("machines")):
            raise HTTPException(422, f"Máy chủ {body.host}:{body.port} đã tồn tại.")
        return public_machine(app.state.store.save("machines", values, ident))

    @app.delete("/api/vps/servers/{ident}")
    def delete_server(ident: str):
        machine = record("machines", ident)
        if machine.get("profile_id"):
            raise HTTPException(422, "Máy này thuộc một cụm MongoDB. Xóa trong MongoDB Manager để kiểm tra dịch vụ trước.")
        app.state.store.delete("machines", ident)
        app.state.store.delete("vps-overviews", ident)
        app.state.store.delete("oci-links", ident)
        return {"ok": True}

    @app.post("/api/vps/machines", status_code=201)
    def add_machine(body: Machine):
        values = body.model_dump()
        if body.profile_id:
            raise HTTPException(
                422, "Tạo hồ sơ VPS độc lập rồi liên kết trong MongoDB Manager."
            )
        if body.mode == "ssh" and body.ssh_auth == "password" and not body.ssh_password:
            raise HTTPException(422, "Thiếu mật khẩu SSH.")
        if body.mode == "ssh" and any(m.get("mode") == "ssh" and m.get("host") == body.host and int(m.get("port", 22)) == body.port for m in app.state.store.all("machines")):
            raise HTTPException(422, f"Máy chủ {body.host}:{body.port} đã tồn tại.")
        saved = app.state.store.save("machines", values)
        return {"id": saved["id"], "name": saved["name"]}

    overview_locks = {}
    locks_guard = threading.Lock()
    catalog_version = hashlib.sha256(json.dumps([INSTALL,CATALOG],sort_keys=True).encode()).hexdigest()

    def overview_lock(ident):
        with locks_guard:
            return overview_locks.setdefault(ident,threading.Lock())

    @app.get("/api/vps/catalog")
    def catalog():
        return dict(catalog=CATALOG,kits=KITS,groups={key:value["group"] for key,value in INSTALL.items()},
                    dependencies={key:value["deps"] for key,value in INSTALL.items() if value.get("deps")},
                    hidden=[key for key,value in INSTALL.items() if value.get("hidden")])

    @app.get("/api/vps/machines/{ident}")
    def overview(ident: str, refresh: bool = False):
        machine = record("machines", ident)
        signature = [machine.get(k) for k in ("mode","host","port","user","ssh_auth","identity")]
        store = app.state.store
        with overview_lock(ident):
            try:
                cached = store.get("vps-overviews",ident)
            except KeyError:
                cached = None
            if cached and (cached["target"] != signature or cached["catalog_version"] != catalog_version):
                cached = None
            if refresh or not cached:
                try:
                    data = worker(machine,"overview",{},lambda _:None)
                    if machine.get("auto_name") and data.get("host") and data["host"] != machine.get("name"):
                        store.update_fields("machines", ident, {"name": data["host"]})
                    cached = store.save("vps-overviews",dict(target=signature,catalog_version=catalog_version,
                                       checked=time.time(),data=data),ident)
                except (RuntimeError,OSError) as exc:
                    raise HTTPException(422,str(exc)) from None
            active_install=any(j.get("machine_id")==ident and j.get("action")=="vps_install" and j["status"] in {"running","queued"} for j in store.all("jobs"))
            return dict(cached["data"], active_install=active_install, checked_at=cached["checked"],
                        stale=time.time()-cached["checked"]>=300,
                        **catalog())

    @app.get("/api/vps/machines/{ident}/git/status")
    def git_status(ident: str):
        try:
            return worker(record("machines",ident),"git-status",{},lambda _: None)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422,str(exc)) from None

    @app.post("/api/vps/machines/{ident}/git/{action}", status_code=202)
    def git_change(ident: str, action: str, body: GitOperation):
        if action not in GIT_ACTIONS:
            raise HTTPException(404)
        return queue_job(ident,"git-"+action,body,record("machines",ident))

    @app.get("/api/vps/machines/{ident}/docker/{section}")
    def docker_read(ident: str, section: str, container: str="", filename: str=""):
        if section not in {"status","logs","plan"}:
            raise HTTPException(404)
        try:
            return worker(record("machines",ident),"docker-"+section,{"container":container,"filename":filename},lambda _:None)
        except (OSError,ValueError,RuntimeError) as exc:
            raise HTTPException(422,str(exc)) from None

    @app.post("/api/vps/machines/{ident}/docker/{section}", status_code=202)
    def docker_change(ident: str, section: str, body: Operation):
        if section not in {"container","deploy"}:
            raise HTTPException(404)
        return queue_job(ident,"docker-"+section,body,record("machines",ident))

    def workspace_bundles_dir():
        ws_id = current_workspace_id() or "default"
        safe_ws = "".join(c if c.isalnum() or c in "-_" else "_" for c in ws_id)
        d = Path(app.state.workspaces.root_dir) / "bundles" / safe_ws
        d.mkdir(parents=True, exist_ok=True)
        return d

    class StackExport(BaseModel):
        pm2_apps: list[str] = Field(default_factory=list, max_length=100)
        compose_projects: list[str] = Field(default_factory=list, max_length=100)
        nginx_files: list[str] = Field(default_factory=list, max_length=100)
        include_ssl: bool = True
        include_mongo: bool = False
        mongo_uri: str = Field(default="", max_length=512, repr=False)
        bundle_name: str = Field(default="", max_length=64)

    class StackDeploy(BaseModel):
        bundle_id: str = Field(min_length=1, max_length=96)
        install_missing: bool = True
        restore_apps: bool = True
        restore_nginx: bool = True
        overwrite_nginx: bool = False
        restore_mongo: bool = True
        mongo_drop: bool = False
        mongo_uri: str = Field(default="", max_length=512, repr=False)
        open_firewall: bool = True

    @app.get("/api/vps/machines/{ident}/stack/scan")
    def stack_scan(ident: str):
        try:
            return worker(record("machines", ident), "stack-scan", {}, lambda _: None)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/docker/bundles")
    def list_bundles():
        bdir = workspace_bundles_dir()
        items = []
        for p in sorted(bdir.glob("*.tar.gz"), key=lambda x: x.stat().st_mtime, reverse=True):
            try:
                items.append(stack_transfer.inspect_bundle(p))
            except ValueError:
                continue
        return {"bundles": items}

    @app.post("/api/vps/docker/bundles/upload")
    async def upload_bundle(request: Request, filename: str = Query(default="zm-stack.tar.gz", max_length=128)):
        raw_name = Path(filename or "zm-stack.tar.gz").name
        safe_stem = "".join(c if c.isalnum() or c in "-_" else "-" for c in raw_name.removesuffix(".tar.gz").removesuffix(".tgz"))[:48].strip("-") or "stack"
        bundle_id = f"{safe_stem}-{uuid4().hex[:8]}.tar.gz"
        bdir = workspace_bundles_dir()
        dest = stack_transfer.safe_bundle_path(bdir, bundle_id)
        try:
            with dest.open("wb") as out:
                async for chunk in request.stream():
                    if chunk:
                        out.write(chunk)
            return stack_transfer.inspect_bundle(dest)
        except ValueError as exc:
            dest.unlink(missing_ok=True)
            raise HTTPException(422, str(exc)) from None
        except Exception as exc:
            dest.unlink(missing_ok=True)
            raise HTTPException(500, f"Tải lên thất bại: {exc}") from None

    @app.get("/api/vps/docker/bundles/{bundle_id}/download")
    def download_bundle(bundle_id: str):
        try:
            path = stack_transfer.safe_bundle_path(workspace_bundles_dir(), bundle_id)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        if not path.is_file():
            raise HTTPException(404, "Không tìm thấy gói bundle.")
        return FileResponse(path, media_type="application/gzip", filename=path.name)

    @app.delete("/api/vps/docker/bundles/{bundle_id}")
    def delete_bundle(bundle_id: str):
        try:
            path = stack_transfer.safe_bundle_path(workspace_bundles_dir(), bundle_id)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        if not path.is_file():
            raise HTTPException(404, "Không tìm thấy gói bundle.")
        path.unlink()
        return {"deleted": bundle_id}

    @app.post("/api/vps/machines/{ident}/stack/export", status_code=202)
    def stack_export(ident: str, body: StackExport):
        if not (body.pm2_apps or body.compose_projects or body.nginx_files or body.include_mongo):
            raise HTTPException(422, "Chọn ít nhất một thành phần (PM2, Compose, Nginx hoặc MongoDB) để đóng gói.")
        return queue_job(ident, "stack-export", body, record("machines", ident))

    @app.post("/api/vps/machines/{ident}/stack/deploy", status_code=202)
    def stack_deploy(ident: str, body: StackDeploy):
        try:
            path = stack_transfer.safe_bundle_path(workspace_bundles_dir(), body.bundle_id)
            stack_transfer.inspect_bundle(path)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return queue_job(ident, "stack-deploy", body, record("machines", ident))

    def fw_call(machine, emit=lambda _: None):
        return lambda action, params: worker(machine, action, params, emit)

    @app.get("/api/vps/machines/{ident}/firewall")
    def firewall(ident: str):
        machine = record("machines", ident)
        try:
            return firewall_service.status(machine, app.state.store, ident, fw_call(machine))
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/firewall/change", status_code=202)
    def firewall_change(ident: str, body: FirewallChange):
        machine = record("machines", ident)
        if body.op != "enable":
            try:
                firewall_service.parse_range(body.port)
                firewall_service.parse_source(body.source)
            except ValueError as exc:
                raise HTTPException(422, str(exc)) from None
        return queue_job(ident, "firewall", body, machine)

    @app.put("/api/vps/machines/{ident}/oci-link")
    def oci_link(ident: str, body: OciLink):
        record("machines", ident)
        record("oci-accounts", body.account_id)
        if body.region and not oci_firewall.REGION.match(body.region):
            raise HTTPException(422, "Region không hợp lệ.")
        app.state.store.save("oci-links", {"account_id": body.account_id, "region": body.region}, ident)
        return {"ok": True}

    @app.delete("/api/vps/machines/{ident}/oci-link")
    def oci_unlink(ident: str):
        app.state.store.delete("oci-links", ident)
        return {"ok": True}

    @app.post("/api/vps/oci/generate-key")
    def oci_generate_key():
        return oci_firewall.generate_keypair()

    @app.get("/api/vps/oci/accounts")
    def oci_accounts():
        return [oci_firewall.public_account(a) for a in app.state.store.all("oci-accounts")]

    def save_oci(body, ident=None):
        values = body.model_dump()
        values["private_key"] = body.private_key.get_secret_value().strip()
        values["passphrase"] = body.passphrase.get_secret_value()
        if ident:
            old = record("oci-accounts", ident)
            if not values["private_key"]:
                values["private_key"], values["passphrase"] = old.get("private_key", ""), old.get("passphrase", "")
        if values["auth"] == "instance_principal":
            values.update(tenancy="", user="", fingerprint="", private_key="", passphrase="")
        try:
            values = oci_firewall.validate_account(values)
        except oci_firewall.OciError as exc:
            raise HTTPException(422, str(exc)) from None
        return oci_firewall.public_account(app.state.store.save("oci-accounts", values, ident))

    @app.post("/api/vps/oci/accounts", status_code=201)
    def oci_add(body: OciAccount):
        return save_oci(body)

    @app.put("/api/vps/oci/accounts/{ident}")
    def oci_edit(ident: str, body: OciAccount):
        return save_oci(body, ident)

    @app.delete("/api/vps/oci/accounts/{ident}")
    def oci_delete(ident: str):
        record("oci-accounts", ident)
        for machine in app.state.store.all("machines"):
            try:
                if app.state.store.get("oci-links", machine["id"])["account_id"] == ident:
                    app.state.store.delete("oci-links", machine["id"])
            except KeyError:
                pass
        app.state.store.delete("oci-accounts", ident)
        return {"ok": True}

    @app.post("/api/vps/oci/accounts/{ident}/test")
    def oci_test(ident: str, region: str = Query("", max_length=64)):
        try:
            return oci_firewall.test(record("oci-accounts", ident), region or None)
        except oci_firewall.OciError as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/packages")
    def packages(ident: str, scope: str="installed", query: str=Query("",max_length=100), offset: int=Query(0,ge=0), limit: int=Query(30,ge=1,le=240)):
        try:
            return worker(record("machines",ident),"package-query",dict(scope=scope,query=query,offset=offset,limit=limit),lambda _:None)
        except (RuntimeError,OSError,ValueError) as exc:
            raise HTTPException(422,str(exc)) from None

    @app.get("/api/vps/machines/{ident}/package-plan")
    def package_plan(ident: str, name: str=Query(min_length=1,max_length=100)):
        try:
            return worker(record("machines",ident),"package-plan",{"name":name},lambda _:None)
        except (RuntimeError,OSError,ValueError) as exc:
            raise HTTPException(422,str(exc)) from None

    @app.get("/api/vps/machines/{ident}/services")
    def services(ident: str):
        try:
            return worker(record("machines", ident), "service-query", {}, lambda _: None)
        except (RuntimeError, OSError, ValueError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/nginx/test")
    def nginx_test(ident: str):
        try:
            return worker(record("machines", ident), "nginx-test", {}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/metrics")
    def machine_metrics(ident: str):
        try:
            return worker(record("machines", ident), "metrics", {}, lambda _: None)
        except (RuntimeError, ValueError, OSError) as exc:
            raise HTTPException(502, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/nginx")
    def inventory(ident: str):
        try:
            return worker(record("machines", ident), "inventory", {}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/nginx/{file_id}/{section}")
    def read_site(ident: str, file_id: str, section: str, domain: str = "", cursor: str = ""):
        if section not in {"detail", "logs", "ssl-status"}:
            raise HTTPException(404)
        try:
            return worker(record("machines", ident), section, {"file_id": file_id, "domain":domain,"cursor":cursor[:4096]}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/nginx/{file_id}/{preview_action}")
    def preview(ident: str, file_id: str, preview_action: str, body: Operation):
        if preview_action not in {"diff","check"}:
            raise HTTPException(404)
        try:
            return worker(record("machines", ident), preview_action, dict(body.model_dump(), file_id=file_id), lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/sites")
    def sites(ident: str):
        try:
            return worker(record("machines", ident), "sites", {}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/pm2")
    def pm2(ident: str):
        try:
            return worker(record("machines", ident), "pm2", {}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/jobs/{job_id}")
    def one_job(job_id: str):
        return record("jobs", job_id)

    @app.get("/api/vps/machines/{ident}/jobs")
    def jobs(ident: str):
        return [
            j
            for j in reversed(app.state.store.all("jobs"))
            if j.get("machine_id") == ident and str(j.get("action", "")).startswith("vps_")
        ][:50]

    def _saved_cloudflare_token():
        try:
            return app.state.store.get("secrets", "cloudflare_token")
        except KeyError:
            return {}

    @app.get("/api/vps/cloudflare-token")
    def get_cloudflare_token():
        saved = _saved_cloudflare_token()
        return {"token": saved.get("token", ""), "name": saved.get("name", "default")}

    @app.post("/api/vps/machines/{ident}/{action}", status_code=202)
    def submit(ident: str, action: str, body: Operation):
        if action not in {"site", "nginx-import", "nginx-reload", "install","uninstall","native-install","maintain","service-control","apply","lifecycle","repair-link","external-certificate","renew-ssl","renew-test","ssl-renew-enable","ssl-renew-test","cloudflare-token"}:
            raise HTTPException(404)
        if action in {"install","uninstall"} and (
            not body.packages or set(body.packages) - CATALOG.keys()
        ):
            raise HTTPException(422, "Chọn gói trong danh mục.")
        if action == "cloudflare-token" or (action in {"external-certificate", "site"} and body.method == "cloudflare"):
            token_val = body.token.strip()
            if token_val:
                app.state.store.save("secrets", {
                    "token": token_val,
                    "name": (body.name or "default").strip() or "default",
                    "updated_at": now(),
                }, "cloudflare_token")
            else:
                saved = _saved_cloudflare_token()
                if saved.get("token"):
                    body = body.model_copy(update={"token": saved["token"]})
        machine = record("machines", ident)
        return queue_job(ident,action,body,machine)

    def queue_job(ident,action,body,machine,actor=None):
        key = uuid4().hex
        try:
            app.state.slots.reserve(key, set(), machine_keys(machine), job_id=key)
        except Busy as exc:
            raise HTTPException(
                409,
                "VPS đang bận.",
                headers={"X-Active-Job": exc.job_id} if exc.job_id else {},
            ) from None
        labels={"hostname":"Đổi hostname","docker-deploy":"Docker Compose",
                "stack-export":"Đóng gói Portable Stack","stack-deploy":"Triển khai Portable Stack",
                "maintain":"Bảo trì gói hệ thống","install":"Cài phần mềm","uninstall":"Gỡ phần mềm","native-install":"Cài phần mềm","service-control":"Quản lý dịch vụ","password":"Đặt mật khẩu Linux","firewall":"Firewall","cloudflare-token":"Token Cloudflare"}
        labels.update({"git-"+k:v for k,v in GIT_ACTIONS.items()})
        if action=="docker-container":
            labels[action]="Docker · "+body.operation
        job = dict(
            id=key,
            machine_id=ident,
            profile_id=machine.get("profile_id", ""),
            target=machine["name"],
            action="vps_" + action,
            label=labels.get(action,"Cấu hình Nginx"),
            status="queued",
            created_at=now(),
            events=[],
        )
        if action in {"install","uninstall","native-install","maintain","git-install","git-update"}:
            job["resource"] = "packages"
        if actor:
            job["actor"]=actor
        ws_id = current_workspace_id()
        store = app.state.store.current() if hasattr(app.state.store, "current") else app.state.store

        def run():
            with use_store(store, ws_id):
                _run_vps_job()

        def _run_vps_job():
            def emit(message):
                job["events"].append({"time": now(), "message": message})
                store.save("jobs", job, key)

            try:
                job.update(started_at=now(), status="running")
                emit(job["label"]+(" · "+actor+" · "+body.expected+" → "+body.hostname if actor else ""))
                if action=="password":
                    info=account_info(machine)
                    if not info["sudo"]:
                        raise ValueError("User cần sudo -n.")
                    password=body.password.get_secret_value()
                    verified=False
                    def verify():
                        nonlocal verified
                        emit("Kiểm tra kết nối SSH mới bằng key và mật khẩu")
                        for auth in (machine,dict(machine,ssh_auth="password",ssh_password=password)):
                            if account_call(auth,"identity")["user"]!=info["user"]:
                                raise ValueError("User SSH không khớp.")
                        verified=True

                    def progress(message):
                        if not message.startswith("verify-ticket:"):
                            emit(message)
                            return
                        ticket=message.removeprefix("verify-ticket:")
                        try:
                            verify()
                            account_call(machine,"commit",dict(user=info["user"],ticket=ticket))
                        except Exception:
                            raise ValueError("Đã đặt mật khẩu Linux. Chưa xác minh được SSH. Timer trên VPS sẽ phục hồi cấu hình nếu chưa xác nhận.") from None

                    account_call(machine,"change",dict(user=info["user"],connection=info["connection"],
                                 password=password,enable=body.enable,set_root=body.set_root),progress)
                    if body.enable and not verified:
                        verify()
                    result={"user":info["user"],"root_password_changed":body.set_root,"linux_password_changed":True,"ssh_verified":body.enable}
                elif action=="firewall":
                    result=firewall_service.run_change(machine,store,ident,body.model_dump(),fw_call(machine,emit),emit)
                elif action == "stack-export":
                    params = body.model_dump()
                    raw_name = (params.get("bundle_name") or machine["name"] or "vps").strip()
                    safe_stem = "".join(c if c.isalnum() or c in "-_" else "-" for c in raw_name)[:36].strip("-") or "vps"
                    bundle_id = f"zm-stack-{safe_stem}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.tar.gz"
                    params["bundle_id"] = bundle_id
                    res = worker(machine, "stack-export", params, emit)
                    bdir = workspace_bundles_dir()
                    local_dest = stack_transfer.safe_bundle_path(bdir, bundle_id)
                    emit(f"Đang tải gói {bundle_id} về Manager…")
                    stack_transfer.transfer_bundle(machine, "get", local_dest, res["remote_path"])
                    if machine["mode"] != "local":
                        try:
                            Path(res["remote_path"])
                        except Exception:
                            pass
                    result = {"bundle_id": bundle_id, "size": local_dest.stat().st_size, "manifest": res["manifest"]}
                elif action == "stack-deploy":
                    params = body.model_dump()
                    bdir = workspace_bundles_dir()
                    local_src = stack_transfer.safe_bundle_path(bdir, params["bundle_id"])
                    remote_tmp = f"/tmp/zm-deploy-{uuid4().hex[:10]}.tar.gz"
                    emit(f"Đang đẩy gói {params['bundle_id']} lên VPS đích…")
                    stack_transfer.transfer_bundle(machine, "put", local_src, remote_tmp)
                    params["remote_path"] = remote_tmp
                    result = worker(machine, "stack-deploy", params, emit)
                else:
                    result = worker(machine, action, body.model_dump(), emit)
                job.update(status="succeeded", result=result)
            except Exception as exc:
                job.update(status="failed", error=str(exc))
            finally:
                try:
                    if action=="hostname":
                        with overview_lock(ident):
                            try:
                                cached=store.get("vps-overviews",ident)
                            except KeyError:
                                cached=None
                            if job["status"]=="succeeded":
                                new_host=job["result"]["hostname"]
                                store.update_fields("machines",ident,{"name":new_host})
                                if cached:
                                    cached["data"]["host"]=new_host
                                    store.save("vps-overviews",cached,ident)
                            elif cached:
                                store.delete("vps-overviews",ident)
                    if action in {"install","uninstall","native-install","maintain","git-install","git-update"}:
                        with overview_lock(ident):
                            store.delete("vps-overviews",ident)
                    job["finished_at"] = now()
                    store.save("jobs", job, key)
                finally:
                    app.state.slots.release(key)

        try:
            queued = store.save("jobs", job, key)
            app.state.pool.submit(run)
            return queued
        except Exception:
            app.state.slots.release(key)
            raise

    class NginxCopy(BaseModel):
        source_machine: str = Field(min_length=1, max_length=64)
        target_machines: list[str] = Field(min_length=1, max_length=50)
        file_ids: list[str] = Field(min_length=1, max_length=100)
        include_ssl: bool = True
        overwrite: bool = False
        reissue_ssl: bool = False
        email: str = Field(default="", max_length=254)
        token: str = Field(default="", max_length=256, repr=False)

    @app.post("/api/vps/nginx/copy", status_code=202)
    def nginx_copy(body: NginxCopy):
        src = record("machines", body.source_machine)
        try:
            exported = worker(src, "nginx-export", {"file_ids": body.file_ids, "include_ssl": body.include_ssl}, lambda _: None)
        except (RuntimeError, OSError) as exc:
            raise HTTPException(422, str(exc)) from None
        if not exported.get("sites"):
            raise HTTPException(422, "Không tìm thấy site nào để copy.")
        cf_token = body.token.strip() or _saved_cloudflare_token().get("token", "")
        if body.reissue_ssl and body.token.strip():
            app.state.store.save("secrets", {"token": cf_token, "name": "default", "updated_at": now()}, "cloudflare_token")
        results = []
        for ident in dict.fromkeys(body.target_machines):
            if ident == body.source_machine:
                continue
            try:
                m = record("machines", ident)
                job = queue_job(
                    ident,
                    "nginx-import",
                    Operation(
                        sites=exported["sites"],
                        overwrite=body.overwrite,
                        update_renewal=body.reissue_ssl,
                        email=body.email.strip(),
                        token=cf_token,
                    ),
                    m,
                )
                results.append({"machine": ident, "job": job["id"]})
            except HTTPException as exc:
                results.append({"machine": ident, "error": exc.detail})
        return results

    @app.post("/api/vps/batches/{action}", status_code=202)
    def batch(action: str, body: BatchOperation):
        if action not in {"install","uninstall","cloudflare-token","nginx-reload"} and not (action == "site" and body.operation.operation == "create"):
            raise HTTPException(422, "Chọn cài phần mềm, tạo website hoặc reload Nginx.")
        results = []
        for ident in dict.fromkeys(body.machines):
            try:
                job = submit(ident, action, body.operation)
                results.append({"machine": ident, "job": job["id"]})
            except HTTPException as exc:
                results.append({"machine": ident, "error": exc.detail})
        return results

    sftp_transfers = sftp_service.TransferManager()

    def sftp_machine(ident: str):
        if ident == "__local__":
            return {"id": "__local__", "name": "Local", "mode": "local"}
        return record("machines", ident)

    class SftpPathBody(BaseModel):
        path: str = Field(min_length=1, max_length=4096)

    class SftpRenameBody(BaseModel):
        old_path: str = Field(min_length=1, max_length=4096)
        new_path: str = Field(min_length=1, max_length=4096)

    class SftpDeleteBody(BaseModel):
        paths: list[str] = Field(min_length=1)

    class SftpChmodBody(BaseModel):
        path: str = Field(min_length=1, max_length=4096)
        mode: str = Field(min_length=1, max_length=8)
        recursive: bool = False

    class SftpWriteFileBody(BaseModel):
        path: str = Field(min_length=1, max_length=4096)
        content: str = ""

    class SftpTransferBody(BaseModel):
        source_machine: str = Field(min_length=1)
        target_machine: str = Field(min_length=1)
        paths: list[str] = Field(min_length=1)
        target_dir: str = Field(min_length=1, max_length=4096)
        op: Literal["copy", "move"] = "copy"

    @app.get("/api/vps/machines/{ident}/sftp/list")
    def sftp_list(ident: str, path: str = Query(default="", max_length=4096), show_hidden: bool = False):
        try:
            return sftp_service.list_dir(sftp_machine(ident), path=path, show_hidden=show_hidden, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/sftp/mkdir")
    def sftp_mkdir(ident: str, body: SftpPathBody):
        try:
            return sftp_service.mkdir(sftp_machine(ident), body.path, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/sftp/touch")
    def sftp_touch(ident: str, body: SftpPathBody):
        try:
            return sftp_service.touch(sftp_machine(ident), body.path, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/sftp/rename")
    def sftp_rename(ident: str, body: SftpRenameBody):
        try:
            return sftp_service.rename(sftp_machine(ident), body.old_path, body.new_path, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/sftp/delete")
    def sftp_delete(ident: str, body: SftpDeleteBody):
        try:
            return sftp_service.delete_paths(sftp_machine(ident), body.paths, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/machines/{ident}/sftp/chmod")
    def sftp_chmod(ident: str, body: SftpChmodBody):
        try:
            return sftp_service.chmod(sftp_machine(ident), body.path, body.mode, recursive=body.recursive, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/sftp/file")
    def sftp_read_file(ident: str, path: str = Query(min_length=1, max_length=4096)):
        try:
            return sftp_service.read_text_file(sftp_machine(ident), path, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.put("/api/vps/machines/{ident}/sftp/file")
    def sftp_write_file(ident: str, body: SftpWriteFileBody):
        try:
            return sftp_service.write_text_file(sftp_machine(ident), body.path, body.content, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/machines/{ident}/sftp/download")
    def sftp_download(ident: str, paths: list[str] = Query(min_length=1)):
        try:
            filename, media_type, iterator = sftp_service.prepare_download(sftp_machine(ident), paths, store=app.state.store)
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None
        safe_hdr = filename.replace('"', "")
        return StreamingResponse(
            iterator,
            media_type=media_type,
            headers={"Content-Disposition": f'attachment; filename="{safe_hdr}"'},
        )

    @app.post("/api/vps/machines/{ident}/sftp/upload")
    async def sftp_upload(
        ident: str,
        request: Request,
        path: str = Query(default="~", max_length=4096),
        filename: str = Query(min_length=1, max_length=255),
    ):
        try:
            return await sftp_service.upload_from_request_stream(
                sftp_machine(ident), path, filename, request, store=app.state.store
            )
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/vps/sftp/transfer", status_code=202)
    def sftp_transfer(body: SftpTransferBody):
        try:
            src = sftp_machine(body.source_machine)
            dst = sftp_machine(body.target_machine)
            return sftp_transfers.start(
                current_workspace_id(), src, dst, body.paths, body.target_dir, op=body.op, store=app.state.store
            )
        except (OSError, ValueError, RuntimeError) as exc:
            raise HTTPException(422, str(exc)) from None

    @app.get("/api/vps/sftp/transfers/{transfer_id}")
    def sftp_transfer_status(transfer_id: str):
        try:
            return sftp_transfers.get(transfer_id, current_workspace_id())
        except KeyError:
            raise HTTPException(404, "Không tìm thấy tác vụ truyền file.") from None

    @app.post("/api/vps/sftp/transfers/{transfer_id}/cancel")
    def sftp_transfer_cancel(transfer_id: str):
        try:
            return sftp_transfers.cancel(transfer_id, current_workspace_id())
        except KeyError:
            raise HTTPException(404, "Không tìm thấy tác vụ truyền file.") from None

    @app.get("/vps/")
    def index():
        return FileResponse(ROOT / "frontend/index.html")

    app.mount(
        "/vps/static", StaticFiles(directory=ROOT / "frontend"), name="vps-static"
    )


def create_app(data_dir=None):
    @asynccontextmanager
    async def lifespan(app):
        root_dir = data_dir or os.environ.get("MONGO_MANAGER_DATA", DATA_DIR)
        app.state.workspaces = WorkspaceRegistry(root_dir, app_name="vps")
        system_store = app.state.workspaces.get_store("default")
        app.state.system_store = system_store
        app.state.store = WorkspaceStoreProxy(app.state.workspaces)
        app.state.auth = Auth(system_store)
        app.state.slots = JobSlots()
        app.state.admin_lock = threading.Lock()
        app.state.plans = {}
        with ThreadPoolExecutor(max_workers=16) as app_pool:
            app.state.pool = app_pool
            ws_ids = ["default"] + [u.get("workspace_id") for u in app.state.auth.users() if u.get("workspace_id") and u.get("workspace_id") != "default"]
            for ws_id in dict.fromkeys(ws_ids):
                ws_store = app.state.workspaces.get_store(ws_id)
                for job in ws_store.all("jobs"):
                    if job["action"].startswith("vps_") and job["status"] in {
                        "queued",
                        "running",
                    }:
                        job.update(status="interrupted", finished_at=now())
                        ws_store.save("jobs", job, job["id"])
            yield

    app = FastAPI(
        title="ZM VPS Manager", lifespan=lifespan, docs_url=None, redoc_url=None
    )
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse

    @app.exception_handler(RequestValidationError)
    async def invalid(request, exc):
        return JSONResponse(
            {"detail": "Kiểm tra định dạng các trường đã nhập."}, status_code=422
        )

    register_auth(app, "/vps/static/manager.css")
    register_storage_routes(app)
    register(app)

    @app.get("/")
    def home():
        return RedirectResponse("/vps/")

    return app
