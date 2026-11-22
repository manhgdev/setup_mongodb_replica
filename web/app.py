import copy
import hmac
import json
import os
import secrets
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from uuid import uuid4
from pydantic import BaseModel, ConfigDict, Field

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pymongo.errors import PyMongoError

from .models import Action, Apply, Machine, Profile, ProfileProbe, ProfileAdopt, AttachedMachine
from .operations import (HOST_ACTIONS, LABELS, PROFILE_ACTIONS, READ_ACTIONS, execute,
                         discover, mongo_error, query, redact, snapshot, validate_params)
from .store import Store
from .auth import Auth, SESSION_AGE

ROOT = Path(__file__).resolve().parent


class Login(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=1000)


def create_app(data_dir=None):
    @asynccontextmanager
    async def lifespan(app):
        app.state.store = Store(data_dir or os.environ.get("MONGO_MANAGER_DATA", ROOT.parent / ".web-data"))
        app.state.auth = Auth(app.state.store)
        app.state.pool = ThreadPoolExecutor(max_workers=1)
        app.state.lock = threading.Lock()
        app.state.plans = {}
        for job in app.state.store.all("jobs"):
            if job["status"] in {"queued", "running"}:
                job.update(status="interrupted", finished_at=now(), error="Ứng dụng đã dừng giữa tác vụ. Kiểm tra máy đích trước khi chạy lại.")
                app.state.store.save("jobs", job, job["id"])
        yield
        app.state.pool.shutdown(wait=True)

    app = FastAPI(title="MongoDB Manager", lifespan=lifespan, docs_url=None, redoc_url=None)

    @app.exception_handler(RequestValidationError)
    async def invalid_input(request, exc):
        # Validation errors must never echo submitted credentials.
        labels = {'seeds': 'Seed MongoDB', 'mongo_endpoint': 'Endpoint MongoDB', 'host': 'Địa chỉ SSH', 'port': 'Port SSH', 'user': 'User SSH', 'ssh_password': 'Mật khẩu SSH', 'password': 'Mật khẩu', 'name': 'Tên hiển thị', 'replica_set': 'Tên replica set'}
        errors = []
        for error in exc.errors():
            field = next((part for part in reversed(error['loc']) if isinstance(part, str) and part != 'body'), '')
            label = labels.get(field, 'Thông tin nhập')
            message = 'Dùng IP hoặc hostname, có thể kèm :port (mặc định 27017).' if field == 'seeds' else 'Kiểm tra định dạng hoặc giá trị bắt buộc.'
            errors.append(label + ': ' + message)
        return JSONResponse({"detail": ' '.join(dict.fromkeys(errors))}, status_code=422)

    @app.middleware("http")
    async def protect_access(request: Request, call_next):
        auth = app.state.auth
        def denied(message, code=403):
            response = JSONResponse({"detail": message}, status_code=code)
            response.headers['Cache-Control'] = 'no-store'
            return response
        if not auth.allowed_request(request):
            return denied("Host hoặc giao thức không được phép. Dùng localhost hoặc domain HTTPS đã cấu hình.")
        if request.url.path.startswith("/api/"):
            origin = request.headers.get("origin")
            if origin and origin != str(request.base_url).rstrip("/"):
                return denied("Origin không hợp lệ.")
            if request.headers.get("x-mongodb-manager") != "1":
                return denied("Thiếu header ứng dụng.")
            request.state.session = auth.session(request) if auth.enabled else None
            public = request.url.path in {'/api/auth/status', '/api/auth/login'}
            if auth.enabled and not public:
                session = request.state.session
                if session is None:
                    return denied('Cần đăng nhập quản trị.', 401)
                if request.method in {'POST', 'PUT', 'PATCH', 'DELETE'}:
                    token = request.headers.get('x-csrf-token', '')
                    if not hmac.compare_digest(token.encode(), session['csrf'].encode()):
                        return denied('Phiên xác nhận không hợp lệ. Tải lại trang và thử lại.')
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers['X-Frame-Options'] = 'DENY'
        if auth.origin:
            response.headers['Strict-Transport-Security'] = 'max-age=31536000'
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    @app.get('/api/auth/status')
    def auth_status(request: Request):
        auth = app.state.auth
        session = request.state.session
        return {'enabled': auth.enabled, 'authenticated': bool(session) or not auth.enabled,
                'username': session['username'] if session else '', 'csrf': session['csrf'] if session else '',
                'public_url': auth.origin}

    @app.post('/api/auth/login')
    def login(body: Login, request: Request):
        auth = app.state.auth
        if not auth.enabled:
            raise HTTPException(400, 'Chưa cấu hình tài khoản trên máy này.')
        result, limited = auth.login(body.username, body.password, request.client.host if request.client else 'unknown')
        if limited:
            raise HTTPException(429, 'Đăng nhập sai nhiều lần. Thử lại sau 15 phút.', headers={'Retry-After': '900'})
        if result is None:
            raise HTTPException(401, 'Username hoặc mật khẩu không đúng.')
        token, session = result
        response = JSONResponse({'authenticated': True, 'username': session['username'], 'csrf': session['csrf']})
        response.set_cookie(auth.cookie, token, max_age=SESSION_AGE, secure=bool(auth.origin), httponly=True, samesite='strict', path='/')
        return response

    @app.post('/api/auth/logout')
    def logout(request: Request):
        session = request.state.session
        if session:
            app.state.store.delete('sessions', session['id'])
        app.state.plans.clear()
        response = JSONResponse({'ok': True})
        response.delete_cookie(app.state.auth.cookie, secure=bool(app.state.auth.origin), httponly=True, samesite='strict', path='/')
        return response

    @app.exception_handler(KeyError)
    async def missing(request, exc):
        return JSONResponse({"detail": "Không tìm thấy hồ sơ hoặc tác vụ."}, status_code=404)

    @app.exception_handler(ValueError)
    async def invalid(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=400)

    @app.exception_handler(PyMongoError)
    async def mongo_failed(request, exc):
        return JSONResponse({"detail": mongo_error(exc)}, status_code=502)

    def public_profile(value):
        value = dict(value)
        value["has_password"] = bool(value.pop("password", None))
        return value

    def public_machine(value):
        value = dict(value)
        value["has_ssh_password"] = bool(value.pop("ssh_password", None))
        value.setdefault("ssh_auth", "key")
        return value

    @app.get("/api/state")
    def state():
        store = app.state.store
        return {"profiles": [public_profile(v) for v in store.all("profiles")], "machines": [public_machine(v) for v in store.all("machines")],
                "jobs": list(reversed(store.all("jobs")))[0:100], "local_only": not bool(app.state.auth.origin)}

    def save_profile(body, record_id=None):
        value = body.model_dump()
        if record_id:
            previous = app.state.store.get("profiles", record_id)
            if value["password"] is None:
                value["password"] = previous.get("password", "")
        value["password"] = value["password"] or ""
        return public_profile(app.state.store.save("profiles", value, record_id))

    @app.post("/api/profiles")
    def add_profile(body: Profile):
        return save_profile(body)

    @app.put("/api/profiles/{record_id}")
    def edit_profile(record_id: str, body: Profile):
        return save_profile(body, record_id)

    def probe_value(body):
        value = body.model_dump(exclude={"record_id", "machines"})
        if body.record_id and value["password"] is None:
            value["password"] = app.state.store.get("profiles", body.record_id).get("password", "")
        return discover(value)

    @app.post("/api/profiles/probe")
    def probe_profile(body: ProfileProbe):
        value, status = probe_value(body)
        return {"profile": public_profile(value), "status": status}

    @app.post("/api/profiles/adopt")
    def adopt_profile(body: ProfileAdopt):
        value, status = probe_value(body)
        value = dict(value)
        value["verified_at"] = status["checked_at"]
        profile_id = body.record_id or uuid4().hex
        records = [('profiles', value, profile_id)]
        seen = set()
        for attached in body.machines:
            machine = attached.machine
            if machine.mode != 'ssh' or machine.mongo_endpoint not in value['seeds']:
                raise ValueError('Mỗi hồ sơ SSH cần endpoint thuộc cụm vừa xác minh.')
            if attached.record_id and attached.record_id in seen:
                raise ValueError('Không liên kết trùng hồ sơ SSH trong cùng lần lưu.')
            seen.add(attached.record_id)
            previous = app.state.store.get('machines', attached.record_id) if attached.record_id else {}
            if previous.get('profile_id') and previous['profile_id'] != profile_id:
                raise ValueError('Hồ sơ SSH đang thuộc cụm khác. Chọn hoặc tạo hồ sơ phù hợp.')
            prepared = prepare_machine(machine, attached.record_id or None)
            prepared['profile_id'] = profile_id
            records.append(('machines', prepared, attached.record_id or None))
        saved = app.state.store.save_many(records)
        return {"profile": public_profile(saved[0]), "machines": [public_machine(m) for m in saved[1:]], "status": status}

    @app.delete("/api/profiles/{record_id}")
    def delete_profile(record_id: str):
        if app.state.lock.locked():
            raise HTTPException(409, "Chờ tác vụ hiện tại hoàn tất.")
        app.state.store.delete("profiles", record_id)
        return {"ok": True}

    def prepare_machine(body, record_id=None):
        value = body.model_dump()
        if value["profile_id"]:
            app.state.store.get("profiles", value["profile_id"])
        previous = app.state.store.get("machines", record_id) if record_id else {}
        if value["mode"] == "ssh" and value["ssh_auth"] == "password":
            if value["ssh_password"] is None:
                value["ssh_password"] = previous.get("ssh_password", "")
            if not value["ssh_password"]:
                raise ValueError("Nhập mật khẩu SSH để dùng xác thực bằng mật khẩu.")
        else:
            value["ssh_password"] = ""
        return value

    def save_machine(body, record_id=None):
        return public_machine(app.state.store.save("machines", prepare_machine(body, record_id), record_id))

    @app.post("/api/machines")
    def add_machine(body: Machine):
        return save_machine(body)

    @app.post('/api/machines/batch')
    def add_machines(body: list[AttachedMachine]):
        if not 1 <= len(body) <= 50:
            raise ValueError('Thêm từ 1 đến 50 hồ sơ VPS mỗi lần.')
        records = []
        ids = [m.record_id for m in body if m.record_id]
        if len(ids) != len(set(ids)):
            raise ValueError('Hồ sơ VPS bị trùng.')
        for attached in body:
            value = prepare_machine(attached.machine, attached.record_id or None)
            records.append(('machines', value, attached.record_id or None))
        return {'machines': [public_machine(m) for m in app.state.store.save_many(records)]}

    @app.put("/api/machines/{record_id}")
    def edit_machine(record_id: str, body: Machine):
        return save_machine(body, record_id)

    @app.delete("/api/machines/{record_id}")
    def delete_machine(record_id: str):
        if app.state.lock.locked():
            raise HTTPException(409, "Chờ tác vụ hiện tại hoàn tất.")
        app.state.store.delete("machines", record_id)
        return {"ok": True}

    @app.get("/api/profiles/{record_id}/status")
    def status(record_id: str):
        profile = app.state.store.get("profiles", record_id)
        result = snapshot(profile)
        remember_topology(profile, result)
        return result

    def remember_topology(profile, result):
        seeds = result.get('seeds')
        if seeds and profile.get('replica_set') == result.get('replica_set'):
            app.state.store.update_fields('profiles', profile['id'], {'seeds': seeds},
                                          expected={'seeds': profile['seeds'], 'replica_set': profile['replica_set']})

    @app.get("/api/profiles/{record_id}/query/{section}")
    def read_section(record_id: str, section: str, database: str = ""):
        return query(app.state.store.get("profiles", record_id), section, database)

    @app.post("/api/plans")
    def preview(body: Action):
        if body.action not in LABELS:
            raise ValueError("Tác vụ chưa được hỗ trợ.")
        params = validate_params(body.action, body.params)
        store = app.state.store
        profile = store.get("profiles", body.profile_id) if body.profile_id else None
        machine = store.get("machines", body.machine_id) if body.machine_id else None
        if body.action in PROFILE_ACTIONS and not profile:
            raise ValueError("Hãy chọn hồ sơ MongoDB.")
        if body.action in HOST_ACTIONS and not machine:
            raise ValueError("Hãy chọn máy thực thi.")
        target = machine["name"] if body.action in HOST_ACTIONS else profile["name"]
        if body.action in {"backup", "restore", "join_fresh"}:
            target += " → " + profile["name"]
        source_machine = None
        if body.action == "join_fresh":
            source_machine = store.get("machines", params["source_machine_id"])
            if source_machine["id"] == machine["id"] or (source_machine["mode"], source_machine["host"], source_machine["port"]) == (machine["mode"], machine["host"], machine["port"]):
                raise ValueError("VPS nguồn và VPS đích cần là hai máy khác nhau.")
        notices = []
        if body.action == "install":
            notices.append("Chỉ cài khi chưa có mongod. Package chính thức được kiểm tra theo Ubuntu và kiến trúc.")
        if body.action in {"setup", "provision"}:
            notices.append("Tạo instance, service và keyfile mới. Không ghi đè instance đang có; không tự mở firewall.")
        if body.action == "join_fresh":
            notices.append("Đọc keyfile từ máy nguồn " + source_machine["name"] + ", cài/cấu hình node mới rồi thêm vào cụm. Không khởi tạo replica set riêng. Secondary mới có votes=0, priority=0.")
        if body.action == "add_member":
            notices.append("Node phải được cấu hình cùng replSetName/keyfile và truy cập được từ các member. Secondary mới vào cụm với votes=0, priority=0.")
        if body.action in {"remove_member", "member_options", "step_down"}:
            notices.append("Kiểm tra lại quorum và cấu hình ngay trước khi thực hiện; không force reconfig.")
        if body.action == "service":
            notices.append("Chỉ tác động service đã chọn. Stop/restart có thể gián đoạn cụm một node; hãy kiểm tra quorum trước.")
        if body.action == "restore":
            notices.append("Ghi dữ liệu vào cụm đích. Kiểm tra phiên bản nguồn/đích và backup trước; mặc định không drop collection.")
        if body.action in {"drop_database", "drop_user"}:
            notices.append("Thao tác xóa không thể hoàn tác từ giao diện. Kiểm tra bản backup trước khi xác nhận.")
        plan_id = secrets.token_urlsafe(24)
        display = {k: ("••••••••" if k == "password" else v) for k, v in params.items()}
        plan = {"id": plan_id, "action": body.action, "label": LABELS[body.action], "target": target, "params": display,
                "notices": notices, "confirmation": "" if body.action in READ_ACTIONS else target, "expires_in": 600}
        current = time.monotonic()
        app.state.plans = {k: v for k, v in app.state.plans.items() if v["expires"] > current}
        if len(app.state.plans) >= 100:
            raise HTTPException(429, "Có quá nhiều bản xem trước; hãy chờ hết hạn.")
        app.state.plans[plan_id] = {"public": plan, "params": params, "profile": profile, "machine": machine, "source_machine": source_machine, "expires": current + 600}
        return plan

    def run_job(plan, job):
        store = app.state.store
        secret_values = [plan["params"].get("password", ""), (plan["profile"] or {}).get("password", ""), (plan["machine"] or {}).get("ssh_password", ""), (plan.get("source_machine") or {}).get("ssh_password", "")]
        def emit(message):
            job["events"].append({"time": now(), "message": redact(message, *secret_values)})
            store.save("jobs", job, job["id"])
        try:
            job.update(status="running", started_at=now())
            emit("Bắt đầu " + job["label"].lower() + ".")
            params = dict(plan["params"])
            if plan.get("source_machine"):
                params["_source_machine"] = plan["source_machine"]
            result = execute(job["action"], params, plan["profile"], plan["machine"], emit)
            if job["action"] in {"setup", "provision"}:
                machine = plan["machine"]
                machine["service"] = result["service"]
                store.save("machines", machine, machine["id"])
                p = plan["params"]
                profile = store.save("profiles", Profile(name=p["instance"], seeds=[p["advertise"]], replica_set=p["replica_set"], username=p["username"], password=p["password"]).model_dump())
                result["profile_id"] = profile["id"]
                machine.update(profile_id=profile["id"], mongo_endpoint=p["advertise"])
                store.save("machines", machine, machine["id"])
                emit("Đã lưu hồ sơ cụm. Xác minh kết nối từ máy quản trị…")
                result["status"] = snapshot(profile)
            if job["action"] == "join_fresh":
                machine = plan["machine"]
                machine.update(service=result["service"], profile_id=result["profile_id"], mongo_endpoint=result["mongo_endpoint"])
                store.save("machines", machine, machine["id"])
            if job['action'] in {'add_member', 'remove_member', 'join_fresh'}:
                # Seed lists are cluster membership, never a permanent primary IP.
                seeds = result.get('seeds') or [m['host'] for m in result.get('config', {}).get('members', [])]
                remember_topology(plan['profile'], {'seeds': seeds, 'replica_set': plan['profile']['replica_set']})
            def scrub(value):
                if isinstance(value, dict):
                    return {k: scrub(v) for k, v in value.items()}
                if isinstance(value, list):
                    return [scrub(v) for v in value]
                return redact(value, *secret_values) if isinstance(value, str) else value
            job.update(status="succeeded", result=scrub(result))
            emit("Tác vụ đã hoàn tất và trả về kết quả.")
        except Exception as exc:
            message = mongo_error(exc) if isinstance(exc, PyMongoError) else str(exc)
            job.update(status="failed", error=redact(message, *secret_values))
            emit("Tác vụ dừng: " + job["error"])
        finally:
            job["finished_at"] = now()
            store.save("jobs", job, job["id"])
            app.state.lock.release()

    @app.post("/api/jobs", status_code=202)
    def apply(body: Apply):
        plan = app.state.plans.get(body.plan_id)
        if not plan or plan["expires"] < time.monotonic():
            raise HTTPException(409, "Bản xem trước đã hết hạn. Tạo lại trước khi chạy.")
        if body.confirmation != plan["public"]["confirmation"]:
            raise ValueError("Tên xác nhận chưa khớp máy/cụm đích.")
        if plan['profile']:
            latest = app.state.store.get('profiles', plan['profile']['id'])
            for field in ('name', 'replica_set', 'username', 'password', 'auth_db', 'tls', 'tls_ca'):
                if latest.get(field) != plan['profile'].get(field):
                    raise HTTPException(409, 'Kết nối cụm đã đổi sau khi xem trước. Tạo lại kế hoạch thao tác.')
            plan['profile']['seeds'] = latest['seeds']
        if not app.state.lock.acquire(blocking=False):
            raise HTTPException(409, "Đang có tác vụ chạy. Chờ hoàn tất trước khi thực hiện thao tác khác.")
        app.state.plans.pop(body.plan_id)
        try:
            public = plan["public"]
            job = {"id": uuid4().hex, "action": public["action"], "label": public["label"], "target": public["target"],
                   "status": "queued", "created_at": now(), "events": [], "result": None, "error": None}
            app.state.store.save("jobs", job, job["id"])
            app.state.pool.submit(run_job, plan, job)
            return job
        except Exception:
            app.state.lock.release()
            raise

    @app.get("/api/jobs/{job_id}")
    def job_status(job_id: str):
        return app.state.store.get("jobs", job_id)

    @app.get("/")
    def index():
        return FileResponse(ROOT / "static" / "index.html")

    app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")
    return app


def now():
    return datetime.now(timezone.utc).isoformat()


app = create_app()
