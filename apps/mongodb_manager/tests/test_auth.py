import os
import time

import pytest
from fastapi.testclient import TestClient

from apps.mongodb_manager.backend.app import create_app
from shared.manager_core.auth import password_hash, password_matches, private_json


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
        assert api.post('/api/machines', json={'name': 'x', 'mode': 'local'}).status_code == 401
        response = login(api)
        cookie = response.headers['set-cookie']
        assert 'HttpOnly' in cookie and 'SameSite=strict' in cookie
        assert 'test-only-password' not in response.text
        assert api.get('/api/state').status_code == 200
        assert api.post('/api/machines', json={'name': 'x', 'mode': 'local'}, headers={'X-CSRF-Token': ''}).status_code == 403
        assert api.post('/api/machines', json={'name': 'x', 'mode': 'local'}, headers={'X-CSRF-Token': 'bad-token'}).status_code == 403
        assert api.post('/api/machines', json={'name': 'x', 'mode': 'local'}).status_code == 200
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


@pytest.mark.parametrize(("kind", "field"), [("profiles", "password"), ("machines", "ssh_password")])
def test_admin_reveals_one_saved_password(directory, kind, field):
    with client_for(directory) as api:
        item = api.app.state.store.save(kind, {"name": "example", field: "example-only"})
        path = f"/api/{kind}/{item['id']}/reveal-password"
        assert api.post(path).status_code == 401
        login(api)
        assert api.post(path, headers={"X-CSRF-Token": ""}).status_code == 403
        response = api.post(path)
        assert response.json() == {"password": "example-only"}
        assert response.headers["cache-control"] == "no-store"
        assert "example-only" not in api.get("/api/state").text


def test_saved_mongo_account_password_lifecycle(directory):
    from unittest.mock import patch

    with client_for(directory) as api:
        login(api)
        db_profile = api.post('/api/profiles', json={'name':'Cluster', 'seeds':['localhost:27017'],
                              'username':'admin', 'password':'old-login'}).json()
        root = '/api/profiles/' + db_profile['id']
        path = root + '/user-password?database=shop&username=reader'
        with patch('apps.mongodb_manager.backend.app.client') as connect:
            assert api.put(path, json={'username':'reader','password':'saved-example'}).status_code == 200
            assert connect.call_args.args[0]['auth_db'] == 'shop'
            connect.return_value.__enter__.return_value.admin.command.assert_called_once_with('ping')
        assert api.post(path).json() == {'password':'saved-example'}
        assert api.post(path, headers={'X-CSRF-Token':''}).status_code == 403
        with patch('apps.mongodb_manager.backend.app.query', return_value=[{'user':'reader','db':'shop'}]):
            listed = api.get(root + '/query/users')
            assert listed.json()[0]['has_password'] and 'saved-example' not in listed.text
        assert 'saved-example' not in api.get('/api/state').text
        for action, params in [('password', {'database':'shop','username':'reader','password':'new-example-secret'}),
                               ('password', {'database':'admin','username':'admin','password':'new-admin-secret'}),
                               ('drop_user', {'database':'shop','username':'reader'})]:
            with patch('apps.mongodb_manager.backend.app.execute', return_value={'ok':1}):
                plan = api.post('/api/plans', json={'action':action,'profile_id':db_profile['id'],'params':params}).json()
                job = api.post('/api/jobs', json={'plan_id':plan['id'],'confirmation':plan['confirmation']}).json()
                for _ in range(100):
                    job = api.get('/api/jobs/' + job['id']).json()
                    if job['status'] == 'succeeded':
                        break
                    time.sleep(.01)
                assert job['status'] == 'succeeded'
                if action=='password':
                    assert api.post(root+'/user-password', params={k:params[k] for k in ('database','username')}).json()['password']==params['password']
        assert api.post(path).status_code==404
        assert api.post(root+'/reveal-password').json()['password']=='new-admin-secret'


def test_first_account_then_edit(tmp_path):
    original = {"username": "first", "password": "first-password"}
    updated = {"username": "updated", "password": "updated-password"}
    with client_for(tmp_path) as api:
        assert not api.get('/api/auth/status').json()['authenticated']
        assert api.get('/api/state').status_code == 401
        assert api.post('/api/auth/admin', json=original).status_code == 401
        session = api.post('/api/auth/setup', json=original).json()
        assert session['authenticated'] and api.get('/api/state').status_code == 200
        assert api.post('/api/auth/setup', json=updated).status_code == 409
        api.headers['X-CSRF-Token'] = session['csrf']
        assert api.post('/api/auth/admin', json=dict(updated,current_password='wrong')).status_code == 403
        assert api.post('/api/auth/admin', json=dict(updated,current_password=original['password'])).status_code == 200
        assert api.get('/api/state').status_code == 401
        assert api.post('/api/auth/login', json=original).status_code == 401
        assert api.post('/api/auth/login', json=updated).status_code == 200


def test_recovery_rotates_code_and_invalidates_session(tmp_path):
    original = {"username": "admin", "password": "old-password"}
    with client_for(tmp_path) as api:
        code = api.post('/api/auth/setup', json=original).json()['recovery_code']
        body = dict(original, password='new-password', recovery_code=code)
        assert api.post('/api/auth/recover', json=dict(body, recovery_code='invalid')).status_code == 403
        assert api.post('/api/auth/recover', json=dict(body, username='other')).status_code == 403
        api.cookies.clear()
        result = api.post('/api/auth/recover', json=body)
        assert result.status_code == 200 and result.json()['recovery_code'] != code
        assert code not in (tmp_path / 'admin.json').read_text()
        assert api.post('/api/auth/recover', json=body).status_code == 403
        assert api.post('/api/auth/login', json=original).status_code == 401
        assert api.post('/api/auth/login', json=dict(original,password='new-password')).status_code == 200


def test_user_registration_and_toggle(directory):
    with client_for(directory) as user_api, client_for(directory) as admin_api:
        # Public user registration creates a 'user' role with recovery code
        reg = user_api.post('/api/auth/register', json={'username': 'alice', 'password': 'alice-password'})
        assert reg.status_code == 200
        body = reg.json()
        assert body['authenticated'] and body['role'] == 'user' and body['recovery_code']
        user_api.headers['X-CSRF-Token'] = body['csrf']
        assert user_api.get('/api/users').status_code == 403

        # Duplicate username (case-insensitive) is rejected
        assert user_api.post('/api/auth/register', json={'username': 'Alice', 'password': 'alice-password'}).status_code == 409

        # User with recovery PIN can reset password automatically
        pin_reg = user_api.post('/api/auth/register', json={'username': 'pinuser', 'password': 'old-password', 'recovery_pin': '246810'})
        assert pin_reg.status_code == 200
        assert user_api.post('/api/auth/recover', json={'username': 'pinuser', 'recovery_code': '246810', 'password': 'new-password'}).status_code == 200
        assert user_api.post('/api/auth/login', json={'username': 'pinuser', 'password': 'new-password'}).status_code == 200

        # Admin disables self-registration
        login(admin_api)
        assert admin_api.post('/api/auth/settings', json={'allow_registration': False}).status_code == 200
        assert user_api.post('/api/auth/register', json={'username': 'bob', 'password': 'bob-password'}).status_code == 403


def test_rbac_manager_and_admin_permissions(directory):
    with client_for(directory) as admin_api, client_for(directory) as mgr_api, client_for(directory) as user_api:
        login(admin_api)
        mgr = admin_api.post('/api/users', json={'username': 'mod1', 'password': 'mod1-password', 'role': 'manager'})
        assert mgr.status_code == 200 and mgr.json()['user']['role'] == 'manager'
        mgr_id = mgr.json()['user']['id']

        # Manager logs in
        m_login = mgr_api.post('/api/auth/login', json={'username': 'mod1', 'password': 'mod1-password'})
        assert m_login.status_code == 200
        mgr_api.headers['X-CSRF-Token'] = m_login.json()['csrf']

        # Manager can create 'user', cannot create 'manager' or 'admin'
        assert mgr_api.post('/api/users', json={'username': 'u1', 'password': 'u1-password', 'role': 'manager'}).status_code == 403
        u1 = mgr_api.post('/api/users', json={'username': 'u1', 'password': 'u1-password', 'role': 'user'})
        assert u1.status_code == 200
        u1_id = u1.json()['user']['id']

        # Manager cannot lock/delete admin, can lock/unlock user
        admin_id = admin_api.get('/api/auth/status').json()['user_id']
        assert mgr_api.patch(f'/api/users/{admin_id}', json={'active': False}).status_code == 403
        assert mgr_api.patch(f'/api/users/{u1_id}', json={'active': False}).status_code == 200
        assert user_api.post('/api/auth/login', json={'username': 'u1', 'password': 'u1-password'}).status_code == 401
        assert mgr_api.patch(f'/api/users/{u1_id}', json={'active': True}).status_code == 200
        assert user_api.post('/api/auth/login', json={'username': 'u1', 'password': 'u1-password'}).status_code == 200

        # Last active admin cannot lock or demote self
        assert admin_api.patch(f'/api/users/{admin_id}', json={'active': False}).status_code == 422
        assert admin_api.patch(f'/api/users/{admin_id}', json={'role': 'user'}).status_code == 422

        # Manager can delete user, cannot delete self or admin
        assert mgr_api.delete(f'/api/users/{mgr_id}').status_code == 422
        assert mgr_api.delete(f'/api/users/{u1_id}?delete_data=true').status_code == 200


def test_workspace_isolation_and_cross_access(directory):
    with client_for(directory) as admin_api, client_for(directory) as alice_api, client_for(directory) as bob_api:
        login(admin_api)
        admin_api.post('/api/machines', json={'name': 'admin-local', 'mode': 'local'})
        mgr = admin_api.post('/api/users', json={'username': 'mgr', 'password': 'mgr-password', 'role': 'manager'}).json()['user']

        r_a = alice_api.post('/api/auth/register', json={'username': 'alice', 'password': 'alice-password'}).json()
        alice_api.headers['X-CSRF-Token'] = r_a['csrf']
        alice_api.post('/api/machines', json={'name': 'alice-local', 'mode': 'local'})

        r_b = bob_api.post('/api/auth/register', json={'username': 'bob', 'password': 'bob-password'}).json()
        bob_api.headers['X-CSRF-Token'] = r_b['csrf']

        # Bob only sees his own empty workspace, not Alice's or Admin's
        assert bob_api.get('/api/state').json()['machines'] == []
        # Bob cannot access Alice's workspace
        assert bob_api.get('/api/state', headers={'X-Workspace-User': r_a['user_id']}).status_code == 403

        # Admin can inspect Alice's workspace via X-Workspace-User
        alice_machines = admin_api.get('/api/state', headers={'X-Workspace-User': r_a['user_id']}).json()['machines']
        assert [m['name'] for m in alice_machines] == ['alice-local']

        # Manager can inspect Alice's workspace, but NOT Admin's workspace
        with client_for(directory) as mgr_api:
            m_login = mgr_api.post('/api/auth/login', json={'username': 'mgr', 'password': 'mgr-password'}).json()
            mgr_api.headers['X-CSRF-Token'] = m_login['csrf']
            assert mgr_api.get('/api/state', headers={'X-Workspace-User': r_a['user_id']}).status_code == 200
            admin_id = admin_api.get('/api/auth/status').json()['user_id']
            assert mgr_api.get('/api/state', headers={'X-Workspace-User': admin_id}).status_code == 403
