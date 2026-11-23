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
        with patch('web.app.client') as connect:
            assert api.put(path, json={'username':'reader','password':'saved-example'}).status_code == 200
            assert connect.call_args.args[0]['auth_db'] == 'shop'
            connect.return_value.__enter__.return_value.admin.command.assert_called_once_with('ping')
        assert api.post(path).json() == {'password':'saved-example'}
        assert api.post(path, headers={'X-CSRF-Token':''}).status_code == 403
        with patch('web.app.query', return_value=[{'user':'reader','db':'shop'}]):
            listed = api.get(root + '/query/users')
            assert listed.json()[0]['has_password'] and 'saved-example' not in listed.text
        assert 'saved-example' not in api.get('/api/state').text
        for action, params in [('password', {'database':'shop','username':'reader','password':'new-example-secret'}),
                               ('password', {'database':'admin','username':'admin','password':'new-admin-secret'}),
                               ('drop_user', {'database':'shop','username':'reader'})]:
            with patch('web.app.execute', return_value={'ok':1}):
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
