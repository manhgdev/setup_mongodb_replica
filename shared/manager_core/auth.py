"""Multi-user authentication, RBAC (admin, manager, user), scrypt password hash, opaque server-side sessions."""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

SESSION_AGE = 8 * 3600
IDLE_AGE = 30 * 60
ROLES = ("admin", "manager", "user")
ROLE_LEVEL = {"user": 1, "manager": 2, "admin": 3}
USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def password_hash(password):
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=32768, r=8, p=1, maxmem=64 * 1024**2)
    return 'scrypt$' + base64.b64encode(salt).decode() + '$' + base64.b64encode(digest).decode()


def password_matches(password, encoded):
    try:
        kind, salt, expected = encoded.split('$')
        if kind != 'scrypt':
            return False
        actual = hashlib.scrypt(password.encode(), salt=base64.b64decode(salt), n=32768, r=8, p=1, maxmem=64 * 1024**2)
        return hmac.compare_digest(actual, base64.b64decode(expected))
    except (ValueError, TypeError):
        return False


def private_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8))
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def public_origin(value):
    if not value:
        return ''
    parsed = urlsplit(value)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ('', '/') or parsed.query or parsed.fragment:
        raise ValueError('Public URL phải là https://ten-mien, không kèm path hay thông tin đăng nhập.')
    if parsed.hostname in {'localhost', '127.0.0.1', '::1'}:
        raise ValueError('Public URL cần tên miền HTTPS của VPS.')
    return 'https://' + parsed.netloc.lower()


def public_user(user: dict) -> dict:
    return {
        "id": user["id"],
        "username": user["username"],
        "role": user.get("role", "user"),
        "active": bool(user.get("active", True)),
        "workspace_id": user.get("workspace_id", "default"),
        "created_at": user.get("created_at", ""),
        "created_by": user.get("created_by", ""),
    }


class Auth:
    def __init__(self, store):
        self.store = store
        self.lock = threading.Lock()
        self.failures = {}
        self._sync_legacy_admin()

        deployment = store.directory / 'deployment.json'
        settings = json.loads(deployment.read_text()) if deployment.exists() else {}
        self.origin = public_origin(os.environ.get('MONGO_MANAGER_PUBLIC_URL', settings.get('public_url', '')))
        if self.origin and not self.enabled:
            raise RuntimeError('Cần tạo tài khoản quản trị bằng python -m web.manage create-admin trước khi bật domain.')
        self.cookie = '__Host-mongo_manager' if self.origin else 'mongo_manager_session'

        self.settings_path = store.directory / 'system_settings.json'
        self._prune_sessions()

    def _sync_legacy_admin(self):
        path = self.store.directory / 'admin.json'
        if not path.exists():
            return
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        legacy = json.loads(raw)
        users = self.store.all('users')
        default_admin = next((u for u in users if u.get('workspace_id') == 'default' and u.get('role') == 'admin'), None)
        if default_admin is None and not users:
            uid = uuid4().hex
            self.store.save('users', {
                'username': legacy['username'],
                'username_key': legacy['username'].strip().lower(),
                'password_hash': legacy['password_hash'],
                'recovery_hash': legacy.get('recovery_hash', ''),
                'role': 'admin',
                'active': True,
                'workspace_id': 'default',
                'created_at': _now_iso(),
                'created_by': 'system',
                'legacy_digest': digest,
            }, uid)
        elif default_admin is not None and not default_admin.get('password_hash') and legacy.get('password_hash'):
            default_admin['password_hash'] = legacy['password_hash']
            if not default_admin.get('recovery_hash') and legacy.get('recovery_hash'):
                default_admin['recovery_hash'] = legacy['recovery_hash']
            self.store.save('users', default_admin, default_admin['id'])
        elif default_admin is not None and default_admin.get('legacy_digest') != digest:
            self.store.update_fields('users', default_admin['id'], {
                'username': legacy['username'],
                'username_key': legacy['username'].strip().lower(),
                'password_hash': legacy['password_hash'],
                'recovery_hash': legacy.get('recovery_hash', ''),
                'active': True,
                'legacy_digest': digest,
            })

    def _prune_sessions(self):
        now = time.time()
        users_by_id = {u['id']: u for u in self.store.all('users')}
        for session in self.store.all('sessions'):
            user = users_by_id.get(session.get('user_id'))
            if (
                session['expires'] <= now
                or session['seen'] + IDLE_AGE <= now
                or user is None
                or not user.get('active', True)
                or session.get('version') != self.user_version(user)
            ):
                self.store.delete('sessions', session['id'])

    @property
    def admin(self):
        return next((u for u in self.store.all('users') if u.get('role') == 'admin' and u.get('active', True)), None)

    @property
    def enabled(self):
        return any(u.get('role') == 'admin' and u.get('active', True) for u in self.store.all('users'))

    @property
    def allow_registration(self) -> bool:
        if not self.settings_path.exists():
            return True
        try:
            data = json.loads(self.settings_path.read_text())
            return bool(data.get('allow_registration', True))
        except Exception:
            return True

    def set_allow_registration(self, allow: bool):
        private_json(self.settings_path, {'allow_registration': bool(allow)})

    def user_version(self, user: dict) -> str:
        payload = {
            'p': user.get('password_hash', ''),
            'r': user.get('role', 'user'),
            'a': bool(user.get('active', True)),
            'w': user.get('workspace_id', 'default'),
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()

    def users(self) -> list[dict]:
        return self.store.all('users')

    def get_user(self, user_id: str) -> dict | None:
        try:
            return self.store.get('users', user_id)
        except KeyError:
            return None

    def find_by_username(self, username: str) -> dict | None:
        key = (username or '').strip().lower()
        if not key:
            return None
        for u in self.store.all('users'):
            if u.get('username_key', u.get('username', '').lower()) == key:
                return u
        return None

    def allowed_request(self, request):
        if self.origin:
            return request.url.scheme in {'https', 'wss'} and request.headers.get('host', '').lower() == urlsplit(self.origin).netloc
        return request.url.hostname in {'localhost', '127.0.0.1', '::1'}

    def session(self, request):
        token = request.cookies.get(self.cookie, '')
        if not token or len(token) > 200:
            return None
        return self.session_from_token(token)

    def session_from_token(self, token: str):
        if not token or len(token) > 200:
            return None
        record_id = hashlib.sha256(token.encode()).hexdigest()
        try:
            value = self.store.get('sessions', record_id)
        except KeyError:
            return None
        now = time.time()
        user = self.get_user(value.get('user_id', ''))
        if (
            value['expires'] <= now
            or value['seen'] + IDLE_AGE <= now
            or user is None
            or not user.get('active', True)
            or value.get('version') != self.user_version(user)
        ):
            self.store.delete('sessions', record_id)
            return None
        if now - value['seen'] > 60:
            value['seen'] = now
            self.store.save('sessions', value, record_id)
        return value

    def _issue_session(self, user: dict, now: float) -> tuple[str, dict]:
        user_sessions = []
        for old in self.store.all('sessions'):
            if old['expires'] <= now or old['seen'] + IDLE_AGE <= now:
                self.store.delete('sessions', old['id'])
            elif old.get('user_id') == user['id']:
                user_sessions.append(old)
        user_sessions.sort(key=lambda s: s['seen'])
        for old in user_sessions[:-9]:
            self.store.delete('sessions', old['id'])
        token = secrets.token_urlsafe(48)
        session = {
            'user_id': user['id'],
            'username': user['username'],
            'role': user.get('role', 'user'),
            'workspace_id': user.get('workspace_id', 'default'),
            'csrf': secrets.token_urlsafe(32),
            'expires': now + SESSION_AGE,
            'seen': now,
            'version': self.user_version(user),
        }
        self.store.save('sessions', session, hashlib.sha256(token.encode()).hexdigest())
        return token, session

    def login(self, username, password, client_ip):
        with self.lock:
            now = time.time()
            key = (client_ip, (username or '').strip().lower())
            self.failures = {k: times for k, times in self.failures.items() if times and times[-1] > now - 900}
            recent = [t for t in self.failures.get(key, []) if t > now - 900]
            ip_total = sum(len(v) for k, v in self.failures.items() if k[0] == client_ip)
            if len(recent) >= 5 or ip_total >= 50 or sum(len(v) for v in self.failures.values()) >= 200:
                return None, True
            user = self.find_by_username(username)
            valid = (
                self.enabled
                and user is not None
                and user.get('active', True)
                and password_matches(password, user['password_hash'])
                and hmac.compare_digest(username.encode(), user['username'].encode())
            )
            if not valid:
                self.failures[key] = recent + [now]
                return None, False
            self.failures.pop(key, None)
            return self._issue_session(user, now), False

    def create_user(self, username: str, password: str, role: str = 'user', created_by: str = 'system', workspace_id: str | None = None, recovery_pin: str = '') -> tuple[dict, str]:
        if not USERNAME_RE.fullmatch(username):
            raise ValueError('Username chỉ gồm chữ, số, dấu chấm, gạch ngang hoặc gạch dưới (1-80 ký tự).')
        if role not in ROLES:
            raise ValueError('Vai trò không hợp lệ.')
        if len(password) < 6 or len(password) > 1000:
            raise ValueError('Mật khẩu cần từ 6 đến 1000 ký tự.')
        pin = (recovery_pin or '').strip()
        if pin and len(pin) < 4:
            raise ValueError('Mã PIN khôi phục cần ít nhất 4 ký tự.')
        with self.lock:
            if self.find_by_username(username) is not None:
                raise FileExistsError('Tên đăng nhập đã tồn tại.')
            code = secrets.token_urlsafe(32)
            uid = uuid4().hex
            ws_id = workspace_id or ('default' if (role == 'admin' and not self.users()) else uuid4().hex)
            user = {
                'username': username,
                'username_key': username.strip().lower(),
                'password_hash': password_hash(password),
                'recovery_hash': hashlib.sha256(code.encode()).hexdigest(),
                'pin_hash': password_hash(pin) if pin else '',
                'role': role,
                'active': True,
                'workspace_id': ws_id,
                'created_at': _now_iso(),
                'created_by': created_by,
            }
            saved = self.store.save('users', user, uid)
            if ws_id == 'default' and role == 'admin':
                self._sync_admin_json(saved)
            return saved, code

    def _sync_admin_json(self, user: dict):
        path = self.store.directory / 'admin.json'
        payload = {
            'username': user['username'],
            'password_hash': user['password_hash'],
            'recovery_hash': user.get('recovery_hash', ''),
        }
        private_json(path, payload)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.store.update_fields('users', user['id'], {'legacy_digest': digest})

    def update_own_account(self, user_id: str, username: str, password: str, current_password: str) -> tuple[dict, str]:
        with self.lock:
            user = self.get_user(user_id)
            if not user or not password_matches(current_password, user['password_hash']):
                raise PermissionError('Mật khẩu hiện tại chưa đúng.')
            if not USERNAME_RE.fullmatch(username):
                raise ValueError('Username chỉ gồm chữ, số, dấu chấm, gạch ngang hoặc gạch dưới (1-80 ký tự).')
            existing = self.find_by_username(username)
            if existing is not None and existing['id'] != user_id:
                raise FileExistsError('Tên đăng nhập đã được sử dụng.')
            code = secrets.token_urlsafe(32)
            changes = {
                'username': username,
                'username_key': username.strip().lower(),
                'password_hash': password_hash(password),
                'recovery_hash': hashlib.sha256(code.encode()).hexdigest(),
            }
            updated = self.store.update_fields('users', user_id, changes)
            if updated and updated.get('workspace_id') == 'default' and updated.get('role') == 'admin':
                self._sync_admin_json(updated)
            self._revoke_user_sessions(user_id)
            return updated, code

    def recover_password(self, username: str, recovery_code: str, new_password: str) -> tuple[dict, str]:
        with self.lock:
            user = self.find_by_username(username)
            secret = recovery_code.strip()
            digest = hashlib.sha256(secret.encode()).hexdigest()
            code_ok = bool(user and hmac.compare_digest(digest, user.get('recovery_hash', '')))
            pin_ok = bool(user and user.get('pin_hash') and password_matches(secret, user['pin_hash']))
            if not user or not user.get('active', True) or (not code_ok and not pin_ok) or username != user.get('username'):
                raise PermissionError('Tên đăng nhập, mã khôi phục hoặc mã PIN chưa đúng.')
            code = secrets.token_urlsafe(32)
            updated = self.store.update_fields('users', user['id'], {
                'password_hash': password_hash(new_password),
                'recovery_hash': hashlib.sha256(code.encode()).hexdigest(),
            })
            if updated and updated.get('workspace_id') == 'default' and updated.get('role') == 'admin':
                self._sync_admin_json(updated)
            self._revoke_user_sessions(user['id'])
            return updated, code

    def _revoke_user_sessions(self, user_id: str):
        for s in self.store.all('sessions'):
            if s.get('user_id') == user_id:
                self.store.delete('sessions', s['id'])

    def can_manage_target(self, actor_role: str, target_role: str) -> bool:
        if actor_role == 'admin':
            return True
        if actor_role == 'manager':
            return target_role == 'user'
        return False

    def can_access_workspace(self, actor_session: dict, target_user: dict) -> bool:
        if target_user['id'] == actor_session['user_id']:
            return True
        return self.can_manage_target(actor_session.get('role', 'user'), target_user.get('role', 'user'))

    def update_user_by_manager(self, actor_session: dict, target_id: str, role: str | None = None, active: bool | None = None, password: str | None = None) -> tuple[dict, str | None]:
        with self.lock:
            target = self.get_user(target_id)
            if not target:
                raise KeyError('Không tìm thấy tài khoản.')
            actor_role = actor_session.get('role', 'user')
            if not self.can_manage_target(actor_role, target.get('role', 'user')):
                raise PermissionError('Bạn không có quyền chỉnh sửa tài khoản này.')
            if role is not None:
                if role not in ROLES:
                    raise ValueError('Vai trò không hợp lệ.')
                if actor_role != 'admin' and role != target.get('role'):
                    raise PermissionError('Chỉ Admin mới có quyền thay đổi vai trò.')
            active_admins = [u for u in self.store.all('users') if u.get('role') == 'admin' and u.get('active', True)]
            if target.get('role') == 'admin' and len(active_admins) <= 1:
                if active is False or (role is not None and role != 'admin'):
                    raise ValueError('Không thể khóa hoặc hạ quyền Admin duy nhất đang hoạt động.')
            changes = {}
            new_code = None
            if role is not None:
                changes['role'] = role
            if active is not None:
                changes['active'] = bool(active)
            if password:
                if len(password) < 6 or len(password) > 1000:
                    raise ValueError('Mật khẩu cần từ 6 đến 1000 ký tự.')
                new_code = secrets.token_urlsafe(32)
                changes['password_hash'] = password_hash(password)
                changes['recovery_hash'] = hashlib.sha256(new_code.encode()).hexdigest()
            updated = self.store.update_fields('users', target_id, changes) if changes else target
            if updated and updated.get('workspace_id') == 'default' and updated.get('role') == 'admin':
                self._sync_admin_json(updated)
            if changes:
                self._revoke_user_sessions(target_id)
            return updated, new_code

    def delete_user_by_manager(self, actor_session: dict, target_id: str) -> dict:
        with self.lock:
            if target_id == actor_session['user_id']:
                raise ValueError('Không thể tự xóa tài khoản đang đăng nhập.')
            target = self.get_user(target_id)
            if not target:
                raise KeyError('Không tìm thấy tài khoản.')
            if not self.can_manage_target(actor_session.get('role', 'user'), target.get('role', 'user')):
                raise PermissionError('Bạn không có quyền xóa tài khoản này.')
            active_admins = [u for u in self.store.all('users') if u.get('role') == 'admin' and u.get('active', True)]
            if target.get('role') == 'admin' and len(active_admins) <= 1:
                raise ValueError('Không thể xóa Admin duy nhất đang hoạt động.')
            self._revoke_user_sessions(target_id)
            self.store.delete('users', target_id)
            return target
