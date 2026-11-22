"""Single administrator, scrypt password hash, opaque server-side sessions."""
import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

SESSION_AGE = 8 * 3600
IDLE_AGE = 30 * 60


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


class Auth:
    def __init__(self, store):
        self.store = store
        path = store.directory / 'admin.json'
        self.admin = json.loads(path.read_text()) if path.exists() else None
        deployment = store.directory / 'deployment.json'
        settings = json.loads(deployment.read_text()) if deployment.exists() else {}
        self.origin = public_origin(os.environ.get('MONGO_MANAGER_PUBLIC_URL', settings.get('public_url', '')))
        if self.origin and not self.admin:
            raise RuntimeError('Cần tạo tài khoản quản trị bằng python -m web.manage create-admin trước khi bật domain.')
        self.cookie = '__Host-mongo_manager' if self.origin else 'mongo_manager_session'
        self.version = hashlib.sha256(json.dumps(self.admin, sort_keys=True).encode()).hexdigest()
        self.failures = {}
        self.lock = threading.Lock()
        for session in store.all('sessions'):
            if session['expires'] <= time.time() or session.get('version') != self.version:
                store.delete('sessions', session['id'])

    @property
    def enabled(self):
        return self.admin is not None

    def allowed_request(self, request):
        if self.origin:
            return request.url.scheme == 'https' and request.headers.get('host', '').lower() == urlsplit(self.origin).netloc
        return request.url.hostname in {'localhost', '127.0.0.1', '::1'}

    def session(self, request):
        token = request.cookies.get(self.cookie, '')
        if not token or len(token) > 200:
            return None
        record_id = hashlib.sha256(token.encode()).hexdigest()
        try:
            value = self.store.get('sessions', record_id)
        except KeyError:
            return None
        now = time.time()
        if value['expires'] <= now or value['seen'] + IDLE_AGE <= now or value.get('version') != self.version:
            self.store.delete('sessions', record_id)
            return None
        if now - value['seen'] > 60:
            value['seen'] = now
            self.store.save('sessions', value, record_id)
        return value

    def login(self, username, password, client_ip):
        # Limit all usernames together because this is a single-admin service.
        with self.lock:
            now = time.time()
            self.failures = {ip: times for ip, times in self.failures.items() if times and times[-1] > now - 900}
            recent = [t for t in self.failures.get(client_ip, []) if t > now - 900]
            if len(recent) >= 5 or sum(len(v) for v in self.failures.values()) >= 100:
                return None, True
            valid = self.enabled and password_matches(password, self.admin['password_hash']) and hmac.compare_digest(username.encode(), self.admin['username'].encode())
            if not valid:
                self.failures[client_ip] = recent + [now]
                return None, False
            self.failures.pop(client_ip, None)
            for old in self.store.all('sessions'):
                if old['expires'] <= now or old['seen'] + IDLE_AGE <= now:
                    self.store.delete('sessions', old['id'])
            # Bound active sessions and retain the most recent logins.
            sessions = sorted(self.store.all('sessions'), key=lambda s: s['seen'])
            for old in sessions[:-9]:
                self.store.delete('sessions', old['id'])
            token = secrets.token_urlsafe(48)
            session = {'username': self.admin['username'], 'csrf': secrets.token_urlsafe(32), 'expires': now + SESSION_AGE, 'seen': now, 'version': self.version}
            self.store.save('sessions', session, hashlib.sha256(token.encode()).hexdigest())
            return (token, session), False
