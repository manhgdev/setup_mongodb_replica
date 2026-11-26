import hmac
from pathlib import Path
from typing import Literal
from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field
from .auth import Auth, SESSION_AGE, public_user
from .workspaces import current_store, reset_active_store, set_active_store


class Login(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=1000)


class AdminCredentials(Login):
    username: str = Field(pattern=r"^[A-Za-z0-9_.-]{1,80}$")
    password: str = Field(min_length=6, max_length=1000)
    current_password: str = Field(default="", max_length=1000)


class RegisterCredentials(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(pattern=r"^[A-Za-z0-9_.-]{1,80}$")
    password: str = Field(min_length=6, max_length=1000)
    recovery_pin: str = Field(default="", max_length=128)


class RecoveryCredentials(Login):
    password: str = Field(min_length=6, max_length=1000)
    recovery_code: str = Field(min_length=1, max_length=128)


class UserCreateRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(pattern=r"^[A-Za-z0-9_.-]{1,80}$")
    password: str = Field(min_length=6, max_length=1000)
    role: Literal["admin", "manager", "user"] = "user"


class UserUpdateRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    role: Literal["admin", "manager", "user"] | None = None
    active: bool | None = None
    password: str | None = Field(default=None, min_length=6, max_length=1000)


class AuthSettingsRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    allow_registration: bool


def register_auth(app, stylesheet_url="/static/styles.css"):
    frontend = Path(__file__).parent / "frontend"

    @app.get("/login")
    def login_page():
        return FileResponse(frontend / "login.html")

    @app.get("/manager-login/styles.css")
    def login_styles():
        return RedirectResponse(stylesheet_url)

    @app.get("/manager-login/{script}")
    def login_script(script: str):
        if script not in {"account.js", "session.js", "users.js"}:
            raise HTTPException(404)
        return FileResponse(frontend / script, media_type="application/javascript")

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
            public = request.url.path in {'/api/auth/status', '/api/auth/login', '/api/auth/register', '/api/auth/recover'}
            first_setup = not auth.enabled and request.url.path == '/api/auth/setup' and request.method == 'POST'
            if not auth.enabled and not public and not first_setup:
                return denied('Cần tạo tài khoản quản trị đầu tiên.', 401)
            tokens = None
            if auth.enabled and not public and request.url.path != '/api/auth/setup':
                session = request.state.session
                if session is None:
                    return denied('Cần đăng nhập để tiếp tục.', 401)
                if request.method in {'POST', 'PUT', 'PATCH', 'DELETE'}:
                    token = request.headers.get('x-csrf-token', '')
                    if not hmac.compare_digest(token.encode(), session['csrf'].encode()):
                        return denied('Phiên xác nhận không hợp lệ. Tải lại trang và thử lại.')
                workspace_id = session.get('workspace_id', 'default')
                workspace_owner = {
                    'id': session['user_id'],
                    'username': session['username'],
                    'role': session.get('role', 'user'),
                    'workspace_id': workspace_id,
                }
                target_user_id = request.headers.get('x-workspace-user', '').strip()
                if target_user_id and target_user_id != session['user_id']:
                    target_user = auth.get_user(target_user_id)
                    if not target_user or not auth.can_access_workspace(session, target_user):
                        return denied('Bạn không có quyền truy cập workspace của người dùng này.', 403)
                    workspace_id = target_user.get('workspace_id', 'default')
                    workspace_owner = public_user(target_user)
                request.state.workspace_id = workspace_id
                request.state.workspace_owner = workspace_owner
                if hasattr(app.state, 'workspaces'):
                    resolved_store = app.state.workspaces.get_store(workspace_id)
                    request.state.store = resolved_store
                    tokens = set_active_store(resolved_store, workspace_id)
                else:
                    request.state.store = app.state.store
            try:
                response = await call_next(request)
            finally:
                if tokens is not None:
                    reset_active_store(tokens)
        else:
            response = await call_next(request)
        is_static = request.url.path.startswith(("/static/", "/vps/static/", "/manager-login/"))
        response.headers["Cache-Control"] = "public, max-age=300" if is_static else "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers['X-Frame-Options'] = 'DENY'
        if auth.origin:
            response.headers['Strict-Transport-Security'] = 'max-age=31536000'
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    def login_response(username: str, password: str, request: Request, recovery_code: str | None = None):
        auth = app.state.auth
        if not auth.enabled:
            raise HTTPException(400, 'Chưa cấu hình tài khoản trên máy này.')
        result, limited = auth.login(username, password, request.client.host if request.client else 'unknown')
        if limited:
            raise HTTPException(429, 'Đăng nhập sai nhiều lần. Thử lại sau 15 phút.', headers={'Retry-After': '900'})
        if result is None:
            raise HTTPException(401, 'Username hoặc mật khẩu không đúng.')
        token, session = result
        response = JSONResponse({
            'authenticated': True,
            'user_id': session['user_id'],
            'username': session['username'],
            'role': session.get('role', 'user'),
            'workspace_id': session.get('workspace_id', 'default'),
            'csrf': session['csrf'],
            **({'recovery_code': recovery_code} if recovery_code else {}),
        })
        response.set_cookie(auth.cookie, token, max_age=SESSION_AGE, secure=bool(auth.origin), httponly=True, samesite='strict', path='/')
        return response

    @app.get('/api/auth/status')
    def auth_status(request: Request):
        auth = app.state.auth
        session = request.state.session
        return {
            'enabled': auth.enabled,
            'authenticated': bool(session),
            'user_id': session['user_id'] if session else '',
            'username': session['username'] if session else '',
            'role': session.get('role', 'user') if session else '',
            'workspace_id': getattr(request.state, 'workspace_id', session.get('workspace_id', 'default') if session else ''),
            'workspace_owner': getattr(request.state, 'workspace_owner', None),
            'allow_registration': auth.allow_registration,
            'can_manage_users': bool(session and session.get('role') in {'admin', 'manager'}),
            'csrf': session['csrf'] if session else '',
            'public_url': auth.origin,
        }

    @app.post('/api/auth/login')
    def login(body: Login, request: Request):
        return login_response(body.username, body.password, request)

    @app.post('/api/auth/register')
    def register_user(body: RegisterCredentials, request: Request):
        auth = app.state.auth
        if not auth.enabled:
            raise HTTPException(400, 'Hệ thống chưa được khởi tạo Admin.')
        if not auth.allow_registration:
            raise HTTPException(403, 'Tính năng tự đăng ký hiện đang tắt.')
        try:
            _, code = auth.create_user(body.username, body.password, role='user', created_by='self', recovery_pin=body.recovery_pin)
        except FileExistsError as exc:
            raise HTTPException(409, str(exc)) from None
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return login_response(body.username, body.password, request, code)

    @app.post('/api/auth/setup')
    @app.post('/api/auth/account')
    @app.post('/api/auth/admin')
    def set_account(body: AdminCredentials, request: Request):
        with app.state.admin_lock:
            auth = app.state.auth
            if request.url.path == '/api/auth/setup':
                if auth.enabled:
                    raise HTTPException(409, 'Tài khoản quản trị đã được tạo. Hãy đăng nhập.')
                try:
                    _, code = auth.create_user(body.username, body.password, role='admin', created_by='setup', workspace_id='default')
                except (ValueError, FileExistsError) as exc:
                    raise HTTPException(422, str(exc)) from None
                app.state.plans.clear()
                return login_response(body.username, body.password, request, code)
            session = request.state.session
            if not auth.enabled or not session:
                raise HTTPException(401, 'Cần đăng nhập.')
            try:
                _, code = auth.update_own_account(session['user_id'], body.username, body.password, body.current_password)
            except PermissionError as exc:
                raise HTTPException(403, str(exc)) from None
            except FileExistsError as exc:
                raise HTTPException(409, str(exc)) from None
            except ValueError as exc:
                raise HTTPException(422, str(exc)) from None
            app.state.plans.clear()
            return {'saved': True, 'recovery_code': code}

    @app.post('/api/auth/recover')
    def recover_account(body: RecoveryCredentials):
        with app.state.admin_lock:
            try:
                _, code = app.state.auth.recover_password(body.username, body.recovery_code, body.password)
            except PermissionError as exc:
                raise HTTPException(403, str(exc)) from None
            except ValueError as exc:
                raise HTTPException(422, str(exc)) from None
            app.state.plans.clear()
            return {'saved': True, 'recovery_code': code}

    @app.post('/api/auth/logout')
    def logout(request: Request):
        session = request.state.session
        if session:
            app.state.auth.store.delete('sessions', session['id'])
        app.state.plans.clear()
        response = JSONResponse({'authenticated': False})
        response.delete_cookie(app.state.auth.cookie, path='/')
        return response

    def _require_manager(request: Request) -> dict:
        session = request.state.session
        if not session or session.get('role') not in {'admin', 'manager'}:
            raise HTTPException(403, 'Chỉ Admin hoặc Quản trị mới có quyền quản lý người dùng.')
        return session

    @app.get('/api/users')
    def list_users(request: Request):
        session = _require_manager(request)
        auth = app.state.auth
        role = session.get('role')
        visible = []
        for u in auth.users():
            if role == 'admin' or u.get('role') == 'user' or u['id'] == session['user_id']:
                visible.append(public_user(u))
        return {'users': visible, 'allow_registration': auth.allow_registration}

    @app.post('/api/users')
    def create_user_route(body: UserCreateRequest, request: Request):
        session = _require_manager(request)
        if session.get('role') != 'admin' and body.role != 'user':
            raise HTTPException(403, 'Quản trị chỉ có quyền tạo tài khoản User.')
        try:
            user, code = app.state.auth.create_user(
                body.username,
                body.password,
                role=body.role,
                created_by=session['username'],
            )
        except FileExistsError as exc:
            raise HTTPException(409, str(exc)) from None
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return {'user': public_user(user), 'recovery_code': code}

    @app.patch('/api/users/{user_id}')
    def update_user_route(user_id: str, body: UserUpdateRequest, request: Request):
        session = _require_manager(request)
        try:
            user, code = app.state.auth.update_user_by_manager(
                session,
                user_id,
                role=body.role,
                active=body.active,
                password=body.password,
            )
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from None
        except PermissionError as exc:
            raise HTTPException(403, str(exc)) from None
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return {'user': public_user(user), **({'recovery_code': code} if code else {})}

    @app.delete('/api/users/{user_id}')
    def delete_user_route(user_id: str, request: Request, delete_data: bool = False):
        session = _require_manager(request)
        try:
            deleted = app.state.auth.delete_user_by_manager(session, user_id)
        except KeyError as exc:
            raise HTTPException(404, str(exc)) from None
        except PermissionError as exc:
            raise HTTPException(403, str(exc)) from None
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        if delete_data and hasattr(app.state, 'workspaces'):
            app.state.workspaces.delete_workspace(deleted.get('workspace_id', ''))
        return {'deleted': True, 'id': user_id}

    @app.get('/api/auth/settings')
    def get_auth_settings(request: Request):
        session = request.state.session
        if not session or session.get('role') != 'admin':
            raise HTTPException(403, 'Chỉ Admin mới có quyền xem cấu hình hệ thống.')
        return {'allow_registration': app.state.auth.allow_registration}

    @app.post('/api/auth/settings')
    def save_auth_settings(body: AuthSettingsRequest, request: Request):
        session = request.state.session
        if not session or session.get('role') != 'admin':
            raise HTTPException(403, 'Chỉ Admin mới có quyền thay đổi cấu hình hệ thống.')
        app.state.auth.set_allow_registration(body.allow_registration)
        return {'allow_registration': app.state.auth.allow_registration}
