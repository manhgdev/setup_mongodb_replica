import hashlib
import hmac
import secrets
import os
from pathlib import Path
from fastapi.responses import FileResponse
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from .auth import Auth, SESSION_AGE, private_json, password_hash, password_matches

class Login(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=1000)


class AdminCredentials(Login):
    username: str = Field(pattern=r"^[A-Za-z0-9_.-]{1,80}$")
    password: str = Field(min_length=6, max_length=1000)
    current_password: str = Field(default="", max_length=1000)


class RecoveryCredentials(Login):
    password: str = Field(min_length=6, max_length=1000)
    recovery_code: str = Field(min_length=1, max_length=128)


def register_auth(app, stylesheet_url="/static/styles.css"):
    from fastapi.responses import RedirectResponse

    frontend = Path(__file__).parent / "frontend"

    @app.get("/login")
    def login_page():
        return FileResponse(frontend / "login.html")

    @app.get("/manager-login/styles.css")
    def login_styles():
        return RedirectResponse(stylesheet_url)

    @app.get("/manager-login/{script}")
    def login_script(script: str):
        if script not in {"account.js", "session.js"}:
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
            public = request.url.path in {'/api/auth/status', '/api/auth/login', '/api/auth/recover'}
            first_setup = not auth.enabled and request.url.path == '/api/auth/setup' and request.method == 'POST'
            if not auth.enabled and not public and not first_setup:
                return denied('Cần tạo tài khoản quản trị đầu tiên.', 401)
            if auth.enabled and not public and request.url.path != '/api/auth/setup':
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
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    @app.get('/api/auth/status')
    def auth_status(request: Request):
        auth = app.state.auth
        session = request.state.session
        return {'enabled': auth.enabled, 'authenticated': bool(session),
                'username': session['username'] if session else '', 'csrf': session['csrf'] if session else '',
                'public_url': auth.origin}

    @app.post('/api/auth/login')
    def login(body: Login, request: Request):
        return login_response(body, request)

    def login_response(body, request, recovery_code=None):
        auth = app.state.auth
        if not auth.enabled:
            raise HTTPException(400, 'Chưa cấu hình tài khoản trên máy này.')
        result, limited = auth.login(body.username, body.password, request.client.host if request.client else 'unknown')
        if limited:
            raise HTTPException(429, 'Đăng nhập sai nhiều lần. Thử lại sau 15 phút.', headers={'Retry-After': '900'})
        if result is None:
            raise HTTPException(401, 'Username hoặc mật khẩu không đúng.')
        token, session = result
        response = JSONResponse({'authenticated': True, 'username': session['username'], 'csrf': session['csrf'],
                                 **({'recovery_code': recovery_code} if recovery_code else {})})
        response.set_cookie(auth.cookie, token, max_age=SESSION_AGE, secure=bool(auth.origin), httponly=True, samesite='strict', path='/')
        return response

    @app.post('/api/auth/setup')
    @app.post('/api/auth/admin')
    def set_admin(body: AdminCredentials, request: Request):
        with app.state.admin_lock:
            auth = app.state.auth
            if request.url.path == '/api/auth/setup' and auth.enabled:
                raise HTTPException(409, 'Tài khoản quản trị đã được tạo. Hãy đăng nhập.')
            if request.url.path == '/api/auth/admin' and (not auth.enabled or not request.state.session or not password_matches(body.current_password, auth.admin['password_hash'])):
                raise HTTPException(403, 'Mật khẩu quản trị hiện tại chưa đúng.')
            code = save_credentials(body)
            if request.url.path == '/api/auth/setup':
                return login_response(body, request, code)
        return {'saved': True, 'recovery_code': code}

    def save_credentials(body):
        code = secrets.token_urlsafe(32)
        private_json(app.state.store.directory / 'admin.json',
                     {'username': body.username, 'password_hash': password_hash(body.password),
                      'recovery_hash': hashlib.sha256(code.encode()).hexdigest()})
        app.state.auth = Auth(app.state.store)
        app.state.plans.clear()
        return code

    @app.post('/api/auth/recover')
    def recover_admin(body: RecoveryCredentials):
        with app.state.admin_lock:
            admin = app.state.auth.admin or {}
            digest = hashlib.sha256(body.recovery_code.strip().encode()).hexdigest()
            if not hmac.compare_digest(digest, admin.get('recovery_hash', '')) or body.username != admin.get('username'):
                raise HTTPException(403, 'Tên đăng nhập hoặc mã khôi phục chưa đúng.')
            return {'saved': True, 'recovery_code': save_credentials(body)}

    @app.post('/api/auth/logout')
    def logout(request: Request):
        session = request.state.session
        if session:
            app.state.store.delete('sessions', session['id'])
        app.state.plans.clear()
        response = JSONResponse({'ok': True})
        response.delete_cookie(app.state.auth.cookie, secure=bool(app.state.auth.origin), httponly=True, samesite='strict', path='/')
        return response

    @app.get("/api/manager-links")
    def links():
        return {"mongo": os.environ.get("ZM_MONGO_URL", "/"), "vps": os.environ.get("ZM_VPS_URL", "/vps/")}
