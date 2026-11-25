import json
import os
import time
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from apps.mongodb_manager.backend.app import create_app
from apps.mongodb_manager.backend.host_worker import package_versions
from apps.mongodb_manager.backend.models import Machine, Profile, endpoint
from apps.mongodb_manager.backend.operations import check_quorum, validate_params
from shared.manager_core.store import Store


@pytest.fixture
def api(tmp_path, sign_in_new_manager):
    app = create_app(tmp_path / "state")
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        sign_in_new_manager(client)
        yield client


def profile(api):
    return api.post("/api/profiles", json={"name": "Test", "seeds": ["127.0.0.1:27017"], "username": "admin", "password": 'test-secret-"$123'}).json()


def machine(api):
    return api.post("/api/machines", json={"name": "Test VPS", "mode": "local"}).json()


def test_secrets_encrypted_and_redacted(api):
    p = profile(api)
    assert p["has_password"]
    assert "password" not in p
    assert "test-secret" not in api.get("/api/state").text
    directory = api.app.state.store.directory
    assert b"test-secret" not in (directory / "manager.sqlite3").read_bytes()
    assert os.stat(directory / "secret.key").st_mode & 0o777 == 0o600
    update = {k: v for k, v in p.items() if k not in ("id", "has_password")}
    update["password"] = None
    api.put("/api/profiles/" + p["id"], json=update).raise_for_status()
    assert api.app.state.store.get("profiles", p["id"])["password"] == 'test-secret-"$123'


def test_origin_and_host_checks(api):
    assert api.get("/api/state", headers={"Origin": "https://evil.invalid"}).status_code == 403
    assert api.get("/api/state", headers={"Host": "evil.invalid"}).status_code == 403
    assert api.get("/api/state", headers={"X-MongoDB-Manager": ""}).status_code == 403
    assert api.get("/api/state", headers={"Origin": "http://127.0.0.1"}).status_code == 200
    assert "frame-ancestors 'none'" in api.get("/").headers["content-security-policy"]


@pytest.mark.parametrize("value", ["x; touch /tmp/foo:27017", "-oProxyCommand=x:27017", "localhost:70000", "localhost", "a:1:2"])
def test_invalid_endpoints(value):
    with pytest.raises(ValueError):
        endpoint(value)


def test_ipv6_and_ssh_validation():
    assert endpoint("[::1]:27017") == "[::1]:27017"
    with pytest.raises(ValidationError):
        Machine(name="x", service="mongod;reboot")
    with pytest.raises(ValidationError):
        Machine(name="x", user="root -o ProxyCommand=bad")


def test_sensitive_validation_and_service_scope(api):
    response = api.post('/api/profiles', json={"name": "", "seeds": [], "password": "private-secret"})
    assert response.status_code == 422
    assert "private-secret" not in response.text
    with pytest.raises(ValidationError):
        Machine(name="x", service="sshd")
    with pytest.raises(ValueError):
        validate_params("backup", {"collection": "users"})
    with pytest.raises(ValueError):
        validate_params("setup", {"instance": []})


def test_ssh_password_storage_and_updates(api):
    secret = 'ssh-private-$"secret123'
    body = {"name": "VPS", "host": "8.8.4.10", "ssh_auth": "password", "ssh_password": secret}
    response = api.post('/api/machines', json=body)
    assert response.status_code == 200
    saved = response.json()
    assert saved['has_ssh_password'] and 'ssh_password' not in saved
    assert secret not in api.get('/api/state').text
    assert secret.encode() not in (api.app.state.store.directory / 'manager.sqlite3').read_bytes()
    body['ssh_password'] = None
    assert api.put('/api/machines/' + saved['id'], json=body).status_code == 200
    assert api.app.state.store.get('machines', saved['id'])['ssh_password'] == secret
    body['ssh_auth'] = 'key'
    assert not api.put('/api/machines/' + saved['id'], json=body).json()['has_ssh_password']
    assert not api.app.state.store.get('machines', saved['id'])['ssh_password']
    body['ssh_auth'] = 'password'
    assert api.post('/api/machines', json=body).status_code == 400


def test_ssh_job_failure_redacts_password(api):
    secret = 'private-ssh-secret'
    m = api.post('/api/machines', json={"name": "VPS", "host": "8.8.4.10", "ssh_auth": "password", "ssh_password": secret}).json()
    plan = api.post('/api/plans', json={"action": "preflight", "machine_id": m['id']}).json()
    assert secret not in json.dumps(plan)
    with patch('apps.mongodb_manager.backend.app.execute', side_effect=RuntimeError('failed ' + secret)):
        job = api.post('/api/jobs', json={"plan_id": plan['id']}).json()
        for _ in range(100):
            result = api.get('/api/jobs/' + job['id']).json()
            if result['status'] == 'failed':
                break
            time.sleep(.01)
    assert result['status'] == 'failed'
    assert secret not in json.dumps(result)


def test_restore_compatibility():
    from apps.mongodb_manager.backend.host_worker import check_restore_compatibility
    check_restore_compatibility({"version": "9.0.4", "fcv": "9.0"}, {"version": "9.0.7", "fcv": "9.0"})
    for source in [None, {"version": "8.0.9", "fcv": "8.0"}, {"version": "9.0.4", "fcv": "8.0"}]:
        with pytest.raises(RuntimeError):
            check_restore_compatibility(source, {"version": "9.0.7", "fcv": "9.0"})


def test_plan_secrets_confirmation_and_replay(api):
    p = profile(api)
    payload = {"action": "create_user", "profile_id": p["id"], "params": {"username": "app", "database": "app", "role": "readWrite", "password": "long-secret-1234"}}
    plan = api.post("/api/plans", json=payload).json()
    assert "long-secret" not in json.dumps(plan)
    assert api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": "wrong"}).status_code == 400
    with patch("apps.mongodb_manager.backend.app.execute", return_value={"ok": 1}):
        response = api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": "Test"})
        assert response.status_code == 202
        task_id = response.json()["id"]
        job = wait_job(api, task_id)
        assert job["status"] == "succeeded"
    assert api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": "Test"}).status_code == 409


def wait_job(api, task_id):
    for _ in range(100):
        job = api.get("/api/jobs/" + task_id).json()
        if job["status"] not in ("queued", "running"):
            return job
        time.sleep(0.01)
    pytest.fail("job timed out")


def test_failure_is_persisted_without_password(api):
    p = profile(api)
    plan = api.post("/api/plans", json={"action": "upgrade_check", "profile_id": p["id"]}).json()
    with patch("apps.mongodb_manager.backend.app.execute", side_effect=RuntimeError('test-secret-"$123')):
        task = api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": ""}).json()
        job = wait_job(api, task["id"])
    assert job["status"] == "failed"
    assert "test-secret" not in json.dumps(job)


def test_single_job_and_local_preflight(api):
    m = machine(api)
    plan = api.post("/api/plans", json={"action": "preflight", "machine_id": m["id"]}).json()
    task = api.post("/api/jobs", json={"plan_id": plan["id"]}).json()
    job = wait_job(api, task["id"])
    assert job["status"] == "succeeded", job
    assert "architecture" in job["result"]
    api.app.state.slots.reserve("test", set(), {("machine", m["id"])})
    try:
        plan = api.post("/api/plans", json={"action": "preflight", "machine_id": m["id"]}).json()
        assert api.post("/api/jobs", json={"plan_id": plan["id"]}).status_code == 409
        assert api.delete("/api/machines/" + m["id"]).status_code == 409
    finally:
        api.app.state.slots.release("test")


def test_interrupted_jobs_are_not_replayed(tmp_path, sign_in_new_manager):
    store = Store(tmp_path)
    job = store.save("jobs", {"status": "running", "events": []})
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        sign_in_new_manager(api)
        assert api.get("/api/jobs/" + job["id"]).json()["status"] == "interrupted"


@pytest.mark.parametrize("action,params", [
    ("drop_database", {"database": "admin"}), ("restore", {"backup_id": "../../"}),
    ("service", {"operation": "reboot"}), ("install", {"series": "9.0;curl"}),
    ("preflight", {"command": "whoami"}), ("member_options", {"host": "a:27017", "votes": 0, "priority": 1, "hidden": False}),
    ("create_user", {"username": "a", "password": "long-password", "database": "app", "role": "root"}),
])
def test_invalid_dangerous_parameters(action, params):
    with pytest.raises(ValueError):
        validate_params(action, params)


def test_quorum_and_primary_protection():
    cfg = {"members": [{"_id": 0, "votes": 1, "priority": 1}, {"_id": 1, "votes": 1, "priority": 1}, {"_id": 2, "votes": 1, "priority": 0, "arbiterOnly": True}]}
    check_quorum(cfg, {0: {"state": 1, "health": 1}, 1: {"state": 2, "health": 1}})
    with pytest.raises(ValueError):
        check_quorum(cfg, {0: {"state": 1, "health": 1}})
    with pytest.raises(ValueError):
        check_quorum(cfg, {2: {"state": 7, "health": 1}})


def test_real_debian_package_field_order():
    packages = "Package: mongodb-org\nArchitecture: amd64\nVersion: 9.0.7\nDescription: text\n\nPackage: mongodb-mongosh\nVersion: 2.14.2\n"
    assert package_versions(packages, "mongodb-org") == ["9.0.7"]


def test_invalid_body_and_missing_target(api):
    assert api.post("/api/plans", json={"action": "unknown"}).status_code == 400
    assert api.post("/api/plans", json={"action": "preflight"}).status_code == 400
    assert api.post("/api/profiles", json={"name": "x", "seeds": ["bad:wrong"]}).status_code == 422
    assert api.get("/api/jobs/missing").status_code == 404


def test_adopt_and_probe_only_save_after_verification(api):
    body = {'name': 'Existing', 'seeds': ['127.0.0.1:27018'], 'replica_set': '', 'password': 'private-secret'}
    detected = dict(body, replica_set='existing-rs', seeds=['127.0.0.1:27017', '127.0.0.1:27018'])
    status = {'checked_at': '2026-11-12T00:00:00Z', 'members': [{'state': 'PRIMARY'}, {'state': 'SECONDARY'}]}
    with patch('apps.mongodb_manager.backend.app.discover', return_value=(detected, status)):
        probe = api.post('/api/profiles/probe', json=body)
        assert probe.status_code == 200
        assert not api.get('/api/state').json()['profiles']
        response = api.post('/api/profiles/adopt', json=body)
        assert response.status_code == 200
        assert 'private-secret' not in response.text
        assert response.json()['profile']['replica_set'] == 'existing-rs'
        assert len(response.json()['profile']['seeds']) == 2
    with patch('apps.mongodb_manager.backend.app.discover', side_effect=ValueError('Not connected')):
        assert api.post('/api/profiles/adopt', json=body).status_code == 400
    assert len(api.get('/api/state').json()['profiles']) == 1


def test_join_fresh_requires_distinct_source_and_explicit_confirmation(api):
    p = profile(api)
    source = api.post('/api/machines', json={'name': 'Primary VPS', 'host': '8.8.4.10', 'mongo_endpoint': '8.8.4.10:27017', 'profile_id': p['id']}).json()
    target = api.post('/api/machines', json={'name': 'Fresh VPS', 'host': '8.8.4.11'}).json()
    params = {'instance': 'secondary', 'port': 27017, 'advertise': '8.8.4.11:27017', 'bind_ip': '0.0.0.0'}
    body = {'action': 'join_fresh', 'profile_id': p['id'], 'machine_id': target['id'], 'params': params}
    with patch("apps.mongodb_manager.backend.app.client") as connect:
        connect.return_value.__enter__.return_value.admin.command.return_value = {
            "me": source["mongo_endpoint"], "isWritablePrimary": True, "setName": p["replica_set"],
        }
        plan = api.post('/api/plans', json=body)
        assert plan.status_code == 200
        assert plan.json()['confirmation'] == 'Fresh VPS → Test'
        assert api.post('/api/jobs', json={'plan_id': plan.json()['id']}).status_code == 400
        body['machine_id'] = source['id']
        assert api.post('/api/plans', json=body).status_code == 400
    with pytest.raises(ValueError):
        validate_params('join_fresh', dict(params, advertise='8.8.4.11:27018'))


def test_new_vps_refuses_existing_instance_before_install(tmp_path):
    from apps.mongodb_manager.backend.host_worker import provision
    existing = tmp_path / 'etc/mongodb-manager/production'
    existing.mkdir(parents=True)
    with patch('apps.mongodb_manager.backend.host_worker.Path', side_effect=lambda value: tmp_path / str(value).lstrip('/')):
        with patch('apps.mongodb_manager.backend.host_worker.install') as installer:
            with pytest.raises(RuntimeError, match='đã tồn tại'):
                provision({'instance': 'production', 'port': 27017, 'series': '9.0'})
            installer.assert_not_called()


def test_topology_seed_refresh_preserves_concurrent_profile_edits(api):
    p = profile(api)
    original = api.app.state.store.get('profiles', p['id'])
    detected = {'replica_set': 'rs0', 'seeds': ['127.0.0.1:27017', '127.0.0.1:27018'], 'members': []}
    with patch('apps.mongodb_manager.backend.app.snapshot', return_value=detected):
        assert api.get('/api/profiles/' + p['id'] + '/status').status_code == 200
    updated = api.app.state.store.get('profiles', p['id'])
    assert updated['seeds'] == detected['seeds']
    assert updated['password'] == original['password']
    # A late observation cannot overwrite a seed list edited while reading status.
    result = api.app.state.store.update_fields('profiles', p['id'], {'seeds': ['stale:27017']}, expected={'seeds': original['seeds']})
    assert result is None
    assert api.app.state.store.get('profiles', p['id'])['seeds'] == detected['seeds']


def test_seed_without_port_and_invalid_seed_messages(api):
    assert Profile(name='IP', seeds=['160.191.87.38', 'db.example.com', '[::1]', '::1']).seeds == ['160.191.87.38:27017', 'db.example.com:27017', '[::1]:27017']
    response = api.post('/api/profiles/probe', json={'name': 'IP', 'seeds': ['bad:port'], 'password': 'secret-validation-value'})
    assert response.status_code == 422
    assert 'Seed MongoDB' in response.text
    assert 'secret-validation-value' not in response.text
    assert 'bad:port' not in response.text


def test_adopt_with_ssh_credentials_commits_and_preserves_password(api):
    status = {'checked_at': '2026-11-12T00:00:00Z', 'members': [{'host': '8.8.4.10:27017'}]}
    body = {'name': 'Existing', 'seeds': ['8.8.4.10'], 'replica_set': '', 'password': 'mongo-secret'}
    machine_body = {'name': 'Member VPS', 'host': '8.8.4.10', 'mongo_endpoint': '8.8.4.10', 'ssh_auth': 'password', 'ssh_password': 'ssh-private-secret'}
    detected = dict(body, seeds=['8.8.4.10:27017'], replica_set='rsExisting')
    with patch('apps.mongodb_manager.backend.app.discover', return_value=(detected, status)):
        response = api.post('/api/profiles/adopt', json=dict(body, machines=[{'machine': machine_body}]))
    assert response.status_code == 200, response.text
    data = response.json()
    assert 'ssh-private-secret' not in response.text and 'mongo-secret' not in response.text
    saved_machine = data['machines'][0]
    assert saved_machine['profile_id'] == data['profile']['id']
    assert saved_machine['mongo_endpoint'] == '8.8.4.10:27017'
    assert saved_machine['has_ssh_password']
    assert api.app.state.store.get('machines', saved_machine['id'])['ssh_password'] == 'ssh-private-secret'
    update = dict(body, record_id=data['profile']['id'], machines=[{'record_id': saved_machine['id'], 'machine': dict(machine_body, ssh_password=None)}])
    with patch('apps.mongodb_manager.backend.app.discover', return_value=(detected, status)):
        assert api.post('/api/profiles/adopt', json=update).status_code == 200
    assert len(api.get('/api/state').json()['machines']) == 1
    assert api.app.state.store.get('machines', saved_machine['id'])['ssh_password'] == 'ssh-private-secret'


def test_invalid_attached_ssh_does_not_partially_adopt(api):
    status = {'checked_at': '2026-11-12T00:00:00Z', 'members': []}
    body = {'name': 'Existing', 'seeds': ['8.8.4.10:27017'], 'replica_set': 'rs0'}
    for machine_body in [
        {'name': 'Wrong member', 'host': '8.8.4.11', 'mongo_endpoint': '8.8.4.11:27017'},
        {'name': 'Missing SSH password', 'host': '8.8.4.10', 'mongo_endpoint': '8.8.4.10:27017', 'ssh_auth': 'password'},
    ]:
        with patch('apps.mongodb_manager.backend.app.discover', return_value=(body, status)):
            response = api.post('/api/profiles/adopt', json=dict(body, machines=[{'machine': machine_body}]))
        assert response.status_code == 400, response.text
        state = api.get('/api/state').json()
        assert not state['profiles'] and not state['machines']


def test_ssh_can_be_saved_before_mongodb_is_reachable(api):
    body = [{'machine': {'name': 'Repair VPS', 'host': '8.8.4.10', 'ssh_auth': 'password', 'ssh_password': 'private-ssh', 'mongo_endpoint': '8.8.4.10'}}]
    with patch('apps.mongodb_manager.backend.app.discover', side_effect=AssertionError('MongoDB must not be contacted')):
        response = api.post('/api/machines/batch', json=body)
    assert response.status_code == 200
    assert 'private-ssh' not in response.text
    assert response.json()['machines'][0]['has_ssh_password']
    assert not api.get('/api/state').json()['profiles']
    assert len(api.get('/api/state').json()['machines']) == 1


def test_bulk_ssh_across_clusters_preserves_individual_passwords(api):
    first = profile(api)
    second = api.post('/api/profiles', json={'name': 'Other cluster', 'seeds': ['8.8.4.20'], 'replica_set': 'rsOther'}).json()
    records = [{'machine': {'name': p['name'], 'host': host, 'profile_id': p['id'], 'mongo_endpoint': host + ':27017',
                           'ssh_auth': 'password', 'ssh_password': 'bulk-private-secret'}} for p, host in [(first, '8.8.4.10'), (second, '8.8.4.20')]]
    response = api.post('/api/machines/batch', json=records)
    assert response.status_code == 200
    assert 'bulk-private-secret' not in response.text
    saved = response.json()['machines']
    assert {m['profile_id'] for m in saved} == {first['id'], second['id']}
    updated = []
    for m in saved:
        value = {k: v for k, v in m.items() if k not in ('id', 'has_ssh_password')}
        value.update(user='ubuntu', ssh_password=None)
        updated.append({'record_id': m['id'], 'machine': value})
    assert api.post('/api/machines/batch', json=updated).status_code == 200
    for m in saved:
        stored = api.app.state.store.get('machines', m['id'])
        assert stored['ssh_password'] == 'bulk-private-secret' and stored['user'] == 'ubuntu'


def test_arbiter_diagnostics_uses_unauthenticated_hello_and_trusted_status():
    from unittest.mock import MagicMock
    from apps.mongodb_manager.backend.operations import query
    profile_data = {'seeds': ['arbiter:27017'], 'username': 'admin', 'password': 'secret'}
    cluster, arbiter = MagicMock(), MagicMock()
    cluster.admin.command.side_effect = [
        {'config': {'_id': 'rs0', 'members': [{'_id': 1, 'host': 'arbiter:27017', 'arbiterOnly': True}]}},
        {'members': [{'name': 'arbiter:27017', 'health': 1, 'state': 7}]},
    ]
    arbiter.admin.command.return_value = {'setName': 'rs0', 'arbiterOnly': True}
    first, second = MagicMock(), MagicMock()
    first.__enter__.return_value = cluster
    second.__enter__.return_value = arbiter
    with patch('apps.mongodb_manager.backend.operations.client', side_effect=[first, second]) as connect:
        result = query(profile_data, 'diagnostics')
    assert result[0]['ok'] and result[0]['role'] == 'ARBITER'
    assert connect.call_args_list[1].args[0]['username'] == ''
    assert connect.call_args_list[1].args[0]['password'] == ''


def test_member_workflow_prepared_and_arbiter_validation():
    values = {'instance': 'member', 'port': 27017, 'advertise': '8.8.4.11:27017', 'bind_ip': '0.0.0.0',
              'source_machine_id': 'source', 'source_endpoint': '8.8.4.10:27017', 'arbiter': True}
    parsed = validate_params('join_fresh', values)
    assert parsed['arbiter'] and parsed['mode'] == 'prepare'
    with pytest.raises(ValueError, match='keyfile'):
        validate_params('join_fresh', dict(values, mode='prepared'))
    assert validate_params('join_fresh', dict(values, mode='prepared', target_keyfile='/etc/mongodb-keyfile'))['mode'] == 'prepared'
    with pytest.raises(ValueError):
        validate_params('join_fresh', dict(values, arbiter='true'))


def test_managed_member_resume_preserves_existing_files(tmp_path):
    from apps.mongodb_manager.backend.host_worker import prepare_member
    from pathlib import Path
    import base64
    root = tmp_path / 'etc/mongodb-manager/member'
    data = tmp_path / 'var/lib/mongodb-manager/member-rejoin'
    root.mkdir(parents=True)
    data.mkdir(parents=True)
    key = root / 'keyfile'
    key.write_text('shared-key')
    config = {'replication': {'replSetName': 'rs0'}, 'net': {'port': 27017, 'bindIp': '10.0.0.221'},
              'storage': {'dbPath': str(data)}, 'security': {'keyFile': str(key), 'authorization': 'enabled'}}
    (root / 'mongod.conf').write_text(json.dumps(config))
    marker = data / 'preserve'
    marker.write_text('real-data')
    params = {'instance': 'new-name', 'port': 27017, 'bind_ip': '0.0.0.0', 'replica_set': 'rs0', 'series': '9.0',
              'keyfile_b64': base64.b64encode(b'shared-key').decode()}
    def fake_run(args, **kwargs):
        if args[0] == 'mongod':
            return 'db version v9.0.8'
        if 'FragmentPath' in args:
            return '/etc/systemd/system/mongod-manager-member.service'
        if 'ExecStart' in args:
            return '{ argv[]=/usr/bin/mongod --config /etc/mongodb-manager/member/mongod.conf ; }'
        return 'inactive'
    with patch('apps.mongodb_manager.backend.host_worker.Path', side_effect=lambda value: tmp_path / str(value).lstrip('/')):
        with patch('apps.mongodb_manager.backend.host_worker.shutil.which', return_value='/usr/bin/mongod'), patch('apps.mongodb_manager.backend.host_worker.run', side_effect=fake_run) as command, patch('apps.mongodb_manager.backend.host_worker.setup') as setup:
            result = prepare_member(params)
            assert result['reused'] and result['service'] == 'mongod-manager-member'
            setup.assert_not_called()
            command.assert_any_call(['systemctl', 'enable', '--now', 'mongod-manager-member'])
            params['instance'] = 'member'
            params['replica_set'] = 'wrong-set'
            with pytest.raises(RuntimeError, match='Không ghi đè'):
                prepare_member(params)
    assert marker.read_text() == 'real-data'


def test_member_network_checks_self_before_membership():
    from apps.mongodb_manager.backend.host_worker import member_network
    from unittest.mock import MagicMock
    with patch('apps.mongodb_manager.backend.host_worker.socket.create_connection', return_value=MagicMock()) as connect:
        assert member_network({'endpoints': ['8.8.4.11:27018', '8.8.4.10:27017']})['checked'] == 2
        assert connect.call_args_list[0].args[0] == ('8.8.4.11', 27018)
    with patch('apps.mongodb_manager.backend.host_worker.socket.create_connection', side_effect=OSError('blocked')):
        with pytest.raises(RuntimeError, match='Chưa thêm membership'):
            member_network({'endpoints': ['8.8.4.11:27018']})


def test_port_conflict_reports_actionable_error(tmp_path):
    from apps.mongodb_manager.backend.host_worker import check_instance_target
    from unittest.mock import MagicMock
    sock = MagicMock()
    sock.__enter__.return_value.bind.side_effect = OSError(98, 'Address already in use')
    with patch('apps.mongodb_manager.backend.host_worker.Path', side_effect=lambda value: tmp_path / str(value).lstrip('/')), patch('apps.mongodb_manager.backend.host_worker.socket.socket', return_value=sock):
        with pytest.raises(RuntimeError, match='chọn port khác'):
            check_instance_target({'instance': 'fresh', 'port': 27017})


def test_installer_uses_latest_complete_stable_package_set():
    from apps.mongodb_manager.backend.host_worker import install_version

    versions = {"mongodb-org": ["9.0.10", "9.0.11", "9.0.12-rc0", "9.0.4"],
                "mongodb-org-server": ["9.0.10", "9.0.12-rc0", "9.0.4"]}
    packages = "\n\n".join(f"Package: {name}\nVersion: {version}"
                           for name, entries in versions.items() for version in entries)
    assert install_version(packages, versions, "9.0", "resolute") == "9.0.10"


def test_join_resolves_optional_member_address(monkeypatch):
    from apps.mongodb_manager.backend import operations
    params = dict(instance="secondary", port=27018, bind_ip="0.0.0.0",
                  source_machine_id="source", source_endpoint="source.example:27017")
    machine = {"host": "10.0.0.2", "mongo_endpoint": "mongo.example:27017"}
    assert operations.validate_params("join_fresh", params, machine)["advertise"] == "mongo.example:27018"
    machine.pop("mongo_endpoint")
    monkeypatch.setattr(operations, "host_run", lambda *args: {"ip": "8.8.8.8"})
    assert operations.validate_params("join_fresh", dict(params, advertise=""), machine)["advertise"] == "8.8.8.8:27018"


@pytest.mark.parametrize('action', ['add_member', 'join_fresh'])
def test_new_member_election_settings(action):
    params = dict(host='node:27018') if action == 'add_member' else dict(
        instance='secondary', port=27018, advertise='node:27018', bind_ip='0.0.0.0',
        source_machine_id='source', source_endpoint='source:27017')
    for options, expected in [({}, (1, 1)), ({'votes': 0}, (0, 0)), ({'votes': 1, 'priority': 2.5}, (1, 2.5)), ({'arbiter': True}, (1, 0))]:
        result = validate_params(action, dict(params, **options))
        assert (result['votes'], result['priority']) == expected
    for options in [{'votes': 2}, {'votes': 0, 'priority': 1}, {'arbiter': True, 'priority': 1}]:
        with pytest.raises(ValueError):
            validate_params(action, dict(params, **options))


def test_transfer_plan_binds_archive_host_and_destination(api):
    src = profile(api)
    dst = api.post("/api/profiles", json={"name": "Recovery", "seeds": ["backup.test:27017"]}).json()
    host = api.post("/api/machines", json={"name": "Archive host", "mode": "local", "profile_id": src["id"]}).json()
    body = {"action": "sync_backup", "profile_id": src["id"], "machine_id": host["id"],
            "params": {"destination_id": dst["id"], "databases": ["one", "two"], "drop": True}}
    plan = api.post("/api/plans", json=body)
    assert plan.status_code == 200 and "Recovery" in plan.json()["target"]
    body["params"]["destination_id"] = src["id"]
    assert api.post("/api/plans", json=body).status_code == 400
    body["action"] = "restore"
    body["params"] = {"destination_id": dst["id"], "backup_id": "a"*32}
    plan = api.post("/api/plans", json=body).json()
    with patch("apps.mongodb_manager.backend.app.execute", return_value={"restored": True}) as execute:
        job = api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": plan["confirmation"]}).json()
        for _ in range(100):
            if api.get("/api/jobs/"+job["id"]).json()["status"] == "succeeded":
                break
            time.sleep(.01)
        assert execute.call_args.args[2]["id"] == dst["id"]
        assert execute.call_args.args[3]["id"] == host["id"]


def test_backup_schedule_lifecycle(api):
    from datetime import datetime, timedelta, timezone

    profile_id = profile(api)["id"]
    host = api.post("/api/machines", json={"name": "Local", "mode": "local", "profile_id": profile_id}).json()
    path = f"/api/profiles/{profile_id}/backup-schedule"
    params = {"databases": ["orders"], "collections": ["invoices"]}
    body = {"cron": "0 2 * * *", "params": params, "machine_id": host["id"]}
    assert api.put(path, json=dict(body, cron="bad")).status_code == 400
    assert api.put(path, json=dict(body, machine_id=machine(api)["id"])).status_code == 400
    saved = api.put(path, json=body).json()
    due = datetime.fromisoformat(saved["next_run"])
    assert due.hour == 19 and due.minute == 0  # 02:00 Vietnam is 19:00 UTC.
    scheduler = api.app.state.scheduler
    current = due + timedelta(days=2)
    with patch("apps.mongodb_manager.backend.app.execute", return_value={"id": "test-archive"}) as execute:
        api.app.state.slots.reserve("test", set(), {("machine", host["id"])})
        scheduler.tick(current)
        api.app.state.slots.release("test")
        assert not api.app.state.store.all("jobs")
        scheduler.tick(current)
        for _ in range(100):
            jobs = api.app.state.store.all("jobs")
            if jobs and jobs[0]["status"] == "succeeded":
                break
            time.sleep(0.01)
        assert len(jobs) == 1 and jobs[0]["scheduled"] and jobs[0]["status"] == "succeeded"
        assert execute.call_args.args[:2] == ("backup", params)
        scheduler.tick(current)
        assert execute.call_count == 1
        fresh = api.get("/api/state").json()["backup_schedules"][0]
        assert datetime.fromisoformat(fresh["next_run"]) > current
        assert api.post(path+"/pause").json()["next_run"] is None
        scheduler.tick(datetime.now(timezone.utc)+timedelta(days=90))
        assert execute.call_count == 1
    assert api.put(path, json=body).json()["enabled"]


def test_restore_machine_keeps_archive_on_original_host(api):
    from apps.mongodb_manager.backend.operations import uri

    cluster = profile(api)
    archive = machine(api)
    endpoint = "127.0.0.1:37027"
    receiver = api.post("/api/machines", json={"name": "Receiver", "mode": "local",
                        "profile_id": cluster["id"], "mongo_endpoint": endpoint}).json()
    response = api.post("/api/plans", json={"action": "restore", "profile_id": cluster["id"],
                        "machine_id": archive["id"], "params": {"backup_id": "a"*32, "destination_machine_id": receiver["id"]}})
    response.raise_for_status()
    plan = api.app.state.plans[response.json()["id"]]
    assert plan["machine"]["id"] == archive["id"]
    assert plan["destination"]["seeds"] == [endpoint]
    assert "directConnection=true" in uri(plan["destination"])


def test_delete_backup_only_on_selected_host(api, tmp_path, monkeypatch):
    from apps.mongodb_manager.backend import host_worker
    cluster = profile(api)
    host = api.post("/api/machines", json={"name":"Archive", "mode":"local", "profile_id":cluster["id"]}).json()
    keys = ["a"*32, "b"*32]
    for key in keys:
        directory = tmp_path / key
        directory.mkdir()
        (directory / "manifest.json").write_text(json.dumps({"id":key}))
    monkeypatch.setattr(host_worker, "backups_root", lambda create=False: tmp_path)
    monkeypatch.setattr("apps.mongodb_manager.backend.app.host_run", lambda machine, action, params, emit: host_worker.delete_backup(params))
    path = f'/api/profiles/{cluster["id"]}/machines/{host["id"]}/backups/'
    api.app.state.slots.reserve("test", set(), {("machine", host["id"])})
    assert api.delete(path+keys[0]).status_code == 409
    api.app.state.slots.release("test")
    assert api.delete(path+"invalid").status_code == 400
    assert api.delete(path.replace(cluster["id"], "other")+keys[0]).status_code == 404
    assert api.delete(path+keys[0]).json() == {"deleted":keys[0]}
    assert not (tmp_path / keys[0]).exists()
    assert (tmp_path / keys[1] / "manifest.json").exists()


def test_member_rename_is_scoped_and_updates_workspace_machine(api):
    p = profile(api)
    saved = api.post("/api/machines", json={"name": "mongo-01", "mode": "ssh", "host": "example.test",
                     "profile_id": p["id"], "ssh_auth": "password", "ssh_password": "fixture-secret"}).json()
    route = f'/api/profiles/{p["id"]}/machines/{saved["id"]}/name'
    assert api.patch(route.replace(p["id"], "other"), json={"name": "Other"}).status_code == 404
    assert api.patch(route, json={"name": " "}).status_code == 422
    response = api.patch(route, json={"name": " Shop VPS "})
    response.raise_for_status()
    assert "ssh_password" not in response.json()
    assert api.get("/api/state").json()["machines"][0]["name"] == "Shop VPS"
    record = api.app.state.store.get("machines", saved["id"])
    assert record["auto_name"] is False
    assert record["ssh_password"] == "fixture-secret"


def test_busy_submission_identifies_running_job(api):
    from threading import Event
    entered, finish = Event(), Event()

    def slow_check(action, params, profile, machine, emit):
        emit("checking host")
        entered.set()
        assert finish.wait(5)
        return {}

    m = machine(api)
    request = {"action": "preflight", "machine_id": m["id"]}
    first, second = [api.post("/api/plans", json=request).json()["id"] for _ in range(2)]
    with patch("apps.mongodb_manager.backend.app.execute", side_effect=slow_check):
        try:
            active = api.post("/api/jobs", json={"plan_id": first}).json()["id"]
            assert entered.wait(2)
            busy = api.post("/api/jobs", json={"plan_id": second})
            assert busy.status_code == 409
            assert busy.headers["X-Active-Job"] == active
            log = api.get("/api/jobs/" + active).json()
            assert log["status"] == "running" and log["events"][-1]["message"] == "checking host"
        finally:
            finish.set()
        assert wait_job(api, active)["status"] == "succeeded"


def test_independent_hosts_run_concurrently_and_conflict_points_to_owner(api):
    from threading import Event

    machines = [api.post("/api/machines", json={"name": host, "mode": "ssh", "host": host}).json()
                for host in ("one.example", "two.example")]
    entered = {m["id"]: Event() for m in machines}
    finish = Event()

    def check(action, params, profile, machine, emit):
        entered[machine["id"]].set()
        assert finish.wait(5)
        return {}

    def submit(machine):
        plan = api.post("/api/plans", json={"action": "preflight", "machine_id": machine["id"]}).json()
        return api.post("/api/jobs", json={"plan_id": plan["id"]})

    with patch("apps.mongodb_manager.backend.app.execute", side_effect=check):
        try:
            jobs = [submit(m).json()["id"] for m in machines]
            assert all(event.wait(2) for event in entered.values())
            for m, job in zip(machines, jobs):
                conflict = submit(m)
                assert conflict.status_code == 409
                assert conflict.headers["X-Active-Job"] == job
        finally:
            finish.set()
        for job in jobs:
            assert wait_job(api, job)["status"] == "succeeded"


def test_remove_member_retires_node_and_preserves_machine_profile(api):
    p = profile(api)
    host = "example.test:27017"
    api.app.state.store.update_fields("profiles", p["id"], {
        "seeds": [*p["seeds"], host], "member_hostnames": {host: "old-node"},
    })
    m = api.post("/api/machines", json={
        "name": "old-node", "host": "example.test", "mongo_endpoint": host,
        "profile_id": p["id"], "service": "mongod-manager-old-node",
    }).json()
    api.app.state.store.save("backup-schedules", {"machine_id": m["id"], "enabled": False}, p["id"])
    plan = api.post("/api/plans", json={
        "action": "remove_member", "profile_id": p["id"], "params": {"host": host},
    }).json()
    with patch("apps.mongodb_manager.backend.app.execute", return_value={"seeds": p["seeds"], "service_cleanup": {"state": "inactive"}}) as execute:
        task = api.post("/api/jobs", json={"plan_id": plan["id"], "confirmation": plan["confirmation"]}).json()
        job = wait_job(api, task["id"])
    assert job["status"] == "succeeded", job
    execute.assert_called_once()
    assert execute.call_args.args[3]["id"] == m["id"]
    store = api.app.state.store
    assert store.get("profiles", p["id"])["seeds"] == p["seeds"]
    assert store.get("profiles", p["id"])["member_hostnames"] == {}
    saved = store.get("machines", m["id"])
    assert saved["profile_id"] == p["id"]
    assert saved["mongo_endpoint"] == host


@pytest.mark.parametrize("address", ["10.0.0.221", "192.168.0.5", "100.64.0.1", "127.0.0.1", "[fd00::1]"])
def test_vps_rejects_nonpublic_endpoint(api, address):
    machine = {"name": "VPS", "host": "8.8.4.10", "mongo_endpoint": address + ":27017"}
    assert api.post("/api/machines", json=machine).status_code == 400
    with pytest.raises(ValueError, match="public"):
        validate_params("add_member", {"host": machine["mongo_endpoint"]})


def test_remove_member_stops_service_before_reconfig(monkeypatch):
    from unittest.mock import MagicMock
    from apps.mongodb_manager.backend import operations

    hosts = ["primary:27017", "secondary:27017", "arbiter:27017"]
    config = {"_id": "rs0", "version": 1, "members": [
        {"_id": i, "host": host} for i, host in enumerate(hosts)
    ]}
    states = {i: {"health": 1, "state": state} for i, state in enumerate((1, 2, 7))}
    client = MagicMock()
    admin = client.return_value.__enter__.return_value.admin
    called = []

    def command(value):
        if isinstance(value, dict) and "replSetReconfig" in value:
            called.append("reconfig")
        if value == "replSetGetConfig":
            return {"config": config}

    def stop(*args):
        called.append("stop")
        return {"state": "inactive"}

    admin.command.side_effect = command
    monkeypatch.setattr(operations, "client", client)
    monkeypatch.setattr(operations, "healthy_config", lambda db: (config, states))
    monkeypatch.setattr(operations, "stop_member_service", stop)
    result = operations.execute("remove_member", {"host": hosts[1]}, {"replica_set": "rs0"}, {}, lambda _: None)
    assert called == ["stop", "reconfig"]
    assert result["service_cleanup"]["state"] == "inactive"


def test_delete_stopped_service_disables_autostart(monkeypatch):
    from apps.mongodb_manager.backend import host_worker

    run = monkeypatch.setattr
    calls = []

    def command(args, **kwargs):
        calls.append(args)
        if args[1] == "is-active":
            return "inactive"
        if args[1] == "is-enabled":
            return "disabled" if ["systemctl", "disable", "mongod"] in calls else "enabled"
        return ""

    run(host_worker, "run", command)
    assert host_worker.check_service_stopped({"service": "mongod", "port": 27017})["state"] == "inactive"
    assert ["systemctl", "disable", "mongod"] in calls


def test_delete_stopped_service_allows_other_local_service(monkeypatch, tmp_path):
    from pathlib import Path
    from apps.mongodb_manager.backend import host_worker

    group = tmp_path / "863227" / "cgroup"
    group.parent.mkdir()
    group.write_text("0::/system.slice/mongod.service\n")
    monkeypatch.setattr(host_worker, "Path", lambda _: tmp_path)
    monkeypatch.setattr(host_worker, "run", lambda args, **kwargs: {
        "is-active": "inactive",
        "is-enabled": "disabled",
        "-Hlnpt": 'LISTEN 0 4096 127.0.0.1:27017 0.0.0.0:* users:(("mongod",pid=863227,fd=9))',
    }[args[1]])
    p = {"service": "mongod-manager-old", "port": 27017}
    assert host_worker.check_service_stopped(p)["state"] == "inactive"
    with pytest.raises(ValueError, match="dịch vụ khác"):
        host_worker.check_service_stopped(dict(p, service="mongod"))


def test_remove_member_allows_distinct_loopback_listener(monkeypatch, tmp_path):
    from apps.mongodb_manager.backend import host_worker

    group = tmp_path / "99" / "cgroup"
    group.parent.mkdir()
    group.write_text("0::/system.slice/mongod.service\n")
    monkeypatch.setattr(host_worker, "Path", lambda _: tmp_path)
    stopped = []

    def run(args, **kwargs):
        if args[0] == "mongosh":
            assert args[2].startswith("mongodb://10.0.0.221:27017/admin?")
            return json.dumps({"primary": False, "process_id": "member-id"})
        if args[0] == "ss":
            loopback = 'LISTEN 0 4096 127.0.0.1:27017 0.0.0.0:* users:(("mongod",pid=99,fd=9))'
            member = 'LISTEN 0 4096 10.0.0.221:27017 0.0.0.0:* users:(("mongod",pid=42,fd=9))'
            return loopback if stopped else loopback + "\n" + member
        if args[1] == "disable":
            stopped.append(args[-1])
        return {"show": "42", "is-active": "inactive" if stopped else "active", "is-enabled": "disabled"}.get(args[1], "")

    monkeypatch.setattr(host_worker, "run", run)

    params = {"service": "mongod-manager-old", "port": 27017, "process_id": "member-id", "member_present": True}
    assert host_worker.retire_member(params)["state"] == "inactive"
    assert stopped == [params["service"]]


def test_role_restart_preserves_data_and_rejects_replay(tmp_path, monkeypatch):
    from apps.mongodb_manager.backend import host_worker
    path = tmp_path / "node"
    path.mkdir()
    (path / "WiredTiger.wt").write_bytes(b"old data")
    stat = path.stat()
    params = dict(path=str(path), inode=stat.st_ino, device=stat.st_dev, service="mongod")
    monkeypatch.setattr(host_worker, "check_service_stopped", lambda _: None)
    monkeypatch.setattr(host_worker, "run", lambda *args, **kwargs: "")
    monkeypatch.setattr(os, "chown", lambda *args: None)
    result = host_worker.role_restart(params)
    from pathlib import Path
    assert (Path(result["archive"]) / "WiredTiger.wt").read_bytes() == b"old data"
    assert list(path.iterdir()) == []
    with pytest.raises(ValueError):
        host_worker.role_restart(params)


def test_add_ssh_machine_with_election_defaults(api):
    body = dict(name="mongo-01", auto_name=True, mode="ssh", host="161.118.198.188",
                mongo_endpoint="161.118.198.188:27017", port=22, user="root", ssh_auth="password",
                ssh_password="fixture-password", votes=1, priority=1, service="mongod")
    with patch("apps.mongodb_manager.backend.app.host_run", return_value={"hostname": "fixture-host"}):
        response = api.post("/api/machines", json=body)
    assert response.status_code == 200
    assert response.json()["name"] == "fixture-host"
    assert response.json()["votes"] == response.json()["priority"] == 1
    invalid = api.post("/api/machines", json={**body, "votes": 2})
    assert invalid.status_code == 422 and "Votes" in invalid.json()["detail"]
    assert body["ssh_password"] not in invalid.text


def test_role_storage_ignores_wiredtiger_spill_database(tmp_path):
    from apps.mongodb_manager.backend.host_worker import wiredtiger_directory
    database = tmp_path / "db"
    spill = database / "_tmp" / "spilldb"
    spill.mkdir(parents=True)
    files = [database / "mongod.lock", database / "WiredTiger.wt", spill / "WiredTiger.wt"]
    for path in files:
        path.touch()
    assert wiredtiger_directory(files) == database
