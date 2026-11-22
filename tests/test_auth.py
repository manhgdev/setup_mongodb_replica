import os
import time

import pytest
from fastapi.testclient import TestClient

from web.app import create_app
from web.auth import password_hash, password_matches, private_json


@pytest.fixture
def directory(tmp_path):
    private_json(tmp_path / 'admin.json', {'username': 'testadmin', 'password_hash': password_hash('test-only-password')})
    return tmp_path


def client_for(directory, public=False):
    if public:
        private_json(directory / 'deployment.json', {'public_url': 'https://mongo.example.com'})
    return TestClient(create_app(directory), base_url='https://mongo.example.com' if public else 'http://127.0.0.1',
                      headers={'X-MongoDB-Manager': '1'})


def login(client):
    response = client.post('/api/auth/login', json={'username': 'testadmin', 'password': 'test-only-password'})
    assert response.status_code == 200
    client.headers['X-CSRF-Token'] = response.json()['csrf']
    return response


def test_password_hash_not_plaintext(directory):
    raw = (directory / 'admin.json').read_text()
    assert 'test-only-password' not in raw
    assert os.stat(directory / 'admin.json').st_mode & 0o777 == 0o600
    assert password_matches('test-only-password', password_hash('test-only-password'))
    assert not password_matches('wrong', password_hash('test-only-password'))


def test_protected_routes_csrf_and_logout(directory):
    with client_for(directory) as api:
        assert not api.get('/api/auth/status').json()['authenticated']
        assert api.get('/api/state').status_code == 401
        assert api.post('/api/machines', json={'name': 'x'}).status_code == 401
        response = login(api)
        cookie = response.headers['set-cookie']
        assert 'HttpOnly' in cookie and 'SameSite=strict' in cookie
        assert 'test-only-password' not in response.text
        assert api.get('/api/state').status_code == 200
        assert api.post('/api/machines', json={'name': 'x'}, headers={'X-CSRF-Token': ''}).status_code == 403
        assert api.post('/api/machines', json={'name': 'x'}, headers={'X-CSRF-Token': 'bad-token'}).status_code == 403
        assert api.post('/api/machines', json={'name': 'x'}).status_code == 200
        old_cookie = api.cookies.get('mongo_manager_session')
        assert api.post('/api/auth/logout').status_code == 200
        api.cookies.set('mongo_manager_session', old_cookie, domain='127.0.0.1', path='/')
        assert api.get('/api/state').status_code == 401


def test_expired_and_rotated_sessions(directory):
    with client_for(directory) as api:
        login(api)
        value = api.app.state.store.all('sessions')[0]
        value['seen'] = time.time() - 1801
        api.app.state.store.save('sessions', value, value['id'])
        assert api.get('/api/state').status_code == 401
        login(api)
        cookie = api.cookies.get('mongo_manager_session')
    private_json(directory / 'admin.json', {'username': 'testadmin', 'password_hash': password_hash('another-password')})
    with client_for(directory) as api:
        api.cookies.set('mongo_manager_session', cookie, domain='127.0.0.1', path='/')
        assert api.get('/api/state').status_code == 401


def test_public_domain_https_origin_secure_cookie(directory):
    with client_for(directory, public=True) as api:
        assert api.get('/api/auth/status').status_code == 200
        assert api.get('/api/auth/status', headers={'Host': 'evil.invalid'}).status_code == 403
        assert api.get('http://mongo.example.com/api/auth/status').status_code == 403
        assert api.post('/api/auth/login', json={'username': 'testadmin', 'password': 'test-only-password'}, headers={'Origin': 'https://evil.invalid'}).status_code == 403
        response = login(api)
        assert '__Host-mongo_manager=' in response.headers['set-cookie']
        assert '; Secure' in response.headers['set-cookie']
        assert 'max-age=' in response.headers['strict-transport-security']
        assert api.get('/api/state').status_code == 200


def test_rate_limit_does_not_echo_password(directory):
    with client_for(directory) as api:
        for _ in range(5):
            response = api.post('/api/auth/login', json={'username': 'testadmin', 'password': 'wrong-secret'})
            assert response.status_code == 401
            assert 'wrong-secret' not in response.text
        assert api.post('/api/auth/login', json={'username': 'testadmin', 'password': 'wrong-secret'}).status_code == 429
        assert api.post('/api/auth/login', json={'username': 'testadmin', 'password': []}).status_code == 422


def test_public_mode_without_admin_refuses_startup(tmp_path):
    private_json(tmp_path / 'deployment.json', {'public_url': 'https://mongo.example.com'})
    with pytest.raises(RuntimeError, match='tài khoản'):
        with client_for(tmp_path):
            pass
