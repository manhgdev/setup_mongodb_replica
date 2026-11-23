"""Opt-in real authenticated replica set, isolated temporary data and ports.

MONGO_TEST_MONGOD=/absolute/path/to/mongod python -m pytest tests/test_live_mongo.py -q
"""
import base64
import os
import secrets
import socket
import subprocess
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pymongo import MongoClient
from pymongo.errors import PyMongoError

from web.app import create_app
from web.auth import password_hash, private_json


def wait_for(check, timeout=60):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        try:
            if result := check():
                return result
        except PyMongoError:
            pass
        time.sleep(.2)
    raise AssertionError('MongoDB integration condition not reached')


@pytest.fixture
def live_cluster(tmp_path):
    binary = os.environ.get('MONGO_TEST_MONGOD')
    if not binary:
        pytest.skip('Set MONGO_TEST_MONGOD to run real MongoDB integration')
    key = tmp_path / 'keyfile'
    key.write_text(base64.b64encode(secrets.token_bytes(512)).decode())
    key.chmod(0o400)
    listeners = [socket.socket() for _ in range(3)]
    for listener in listeners:
        listener.bind(('127.0.0.1', 0))
    ports = [listener.getsockname()[1] for listener in listeners]
    for listener in listeners:
        listener.close()
    hosts = [f'127.0.0.1:{port}' for port in ports]
    processes = []
    clients = []
    password = secrets.token_urlsafe(24)
    try:
        for index, port in enumerate(ports):
            data = tmp_path / str(index)
            data.mkdir()
            proc = subprocess.Popen([binary, '--dbpath', str(data), '--port', str(port), '--bind_ip', '127.0.0.1',
                                     '--replSet', 'managerLiveTest', '--keyFile', str(key), '--auth',
                                     '--setParameter', 'disableSplitHorizonIPCheck=true',
                                     '--oplogSize', '64', '--wiredTigerCacheSizeGB', '0.25',
                                     '--logpath', str(data / 'mongod.log')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(proc)
            node = MongoClient(hosts[index], directConnection=True, serverSelectionTimeoutMS=1000)
            clients.append(node)
            wait_for(lambda: node.admin.command('ping')['ok'])
        first = clients[0]
        first.admin.command({'replSetInitiate': {'_id': 'managerLiveTest', 'members': [
            {'_id': 0, 'host': hosts[0], 'priority': 2}, {'_id': 1, 'host': hosts[1], 'priority': 1}]}})
        wait_for(lambda: first.admin.command('hello').get('isWritablePrimary'))
        first.admin.command('createUser', 'managerAdmin', pwd=password, roles=[{'role': 'root', 'db': 'admin'}])
        root = MongoClient(hosts[:2], replicaSet='managerLiveTest', username='managerAdmin', password=password,
                           authSource='admin', serverSelectionTimeoutMS=3000)
        clients.append(root)
        wait_for(lambda: any(m['state'] == 2 for m in root.admin.command('replSetGetStatus')['members']))
        root.application.events.insert_one({'_id': 'preserved', 'value': 'real-data'})
        secondary = MongoClient(hosts[1], directConnection=True, username='managerAdmin', password=password,
                                authSource='admin', readPreference='secondary', serverSelectionTimeoutMS=1000)
        clients.append(secondary)
        wait_for(lambda: secondary.application.events.find_one({'_id': 'preserved'}))
        web_password = secrets.token_urlsafe(24)
        private_json(tmp_path / 'manager' / 'admin.json', {'username': 'webTestAdmin', 'password_hash': password_hash(web_password)})
        with TestClient(create_app(tmp_path / 'manager'), base_url='http://127.0.0.1', headers={'X-MongoDB-Manager': '1'}) as api:
            assert api.get('/api/state').status_code == 401
            session = api.post('/api/auth/login', json={'username': 'webTestAdmin', 'password': web_password})
            assert session.status_code == 200
            api.headers['X-CSRF-Token'] = session.json()['csrf']
            yield api, root, hosts, password
    finally:
        for client in clients:
            client.close()
        for proc in processes:
            proc.terminate()
        for proc in processes:
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def test_adopt_existing_secondary_and_expand_real_replica(live_cluster):
    api, root, hosts, password = live_cluster
    original = root.admin.command('replSetGetConfig')['config']
    body = {'name': 'Live integration', 'seeds': [hosts[1]], 'replica_set': '', 'username': 'managerAdmin', 'password': password}
    probe = api.post('/api/profiles/probe', json=body)
    assert probe.status_code == 200, probe.text
    assert probe.json()['profile']['replica_set'] == 'managerLiveTest'
    assert set(probe.json()['profile']['seeds']) == set(hosts[:2])
    assert len(probe.json()['status']['members']) == 2
    assert password not in probe.text
    saved = api.post('/api/profiles/adopt', json=dict(body, machines=[{'machine': {
        'name': 'Disposable SSH association', 'host': '127.0.0.1', 'mongo_endpoint': hosts[1],
        'ssh_auth': 'password', 'ssh_password': secrets.token_urlsafe(24)}}]))
    assert saved.status_code == 200, saved.text
    profile = saved.json()['profile']
    base = '/api/profiles/' + profile['id']
    namespaces = api.get(base + '/query/namespaces', params={'database': 'application'}).json()
    assert any(ns['name'] == 'events' for ns in namespaces)
    assert api.get(base + '/query/indexes', params={'database':'application','collection':'events'}).json()[0]['name'] == '_id_'
    root.application.events.insert_one({'_id':'nested','meta':{'values':[1, 2], 'active':True}})
    page = {'database':'application','collection':'events','limit':1}
    first = api.post(base + '/documents', json=page).json()
    assert first['more'] and first['records'][0]['meta']['values'][1] == {'$numberInt':'2'}
    second = api.post(base + '/documents', json=dict(page, offset=1)).json()
    assert second['records'][0]['_id'] == 'preserved' and not second['more']
    filtered = api.post(base + '/documents', json=dict(page, field='meta.active',value='true')).json()
    assert [d['_id'] for d in filtered['records']] == ['nested'] and not filtered['more']
    assert api.post(base + '/documents', json=dict(page, field='$where',value='true')).status_code == 400

    namespace = {"database": "application", "collection": "events"}
    write_url = base + '/documents/write'
    before = '{"_id":"edit-test","count":{"$numberLong":"9007199254740993"}}'
    after = '{"_id":"edit-test","count":{"$numberLong":"9007199254740994"}}'
    assert api.post(write_url, json=dict(namespace, action="insert", document=before)).status_code == 200
    assert api.post(write_url, json=dict(namespace, action="replace", original=before, document=after)).status_code == 200
    assert api.post(write_url, json=dict(namespace, action="delete", original=before)).status_code == 400
    assert root.application.events.find_one({"_id":"edit-test"})["count"] == 9007199254740994
    assert api.post(write_url, json=dict(namespace, action="delete", original=after)).status_code == 200
    assert root.application.events.find_one({"_id":"edit-test"}) is None

    assert saved.json()['machines'][0]['profile_id'] == profile['id']
    assert saved.json()['machines'][0]['has_ssh_password']
    assert 'ssh_password' not in saved.json()['machines'][0]
    # Adoption must preserve both data and replica configuration/version.
    assert root.application.events.find_one({'_id': 'preserved'})['value'] == 'real-data'
    assert root.admin.command('replSetGetConfig')['config'] == original
    assert api.get('/api/profiles/' + profile['id'] + '/query/databases').status_code == 200
    assert api.get('/api/profiles/' + profile['id'] + '/query/users').status_code == 200
    wrong = api.post('/api/profiles/adopt', json=dict(body, password='incorrect-password'))
    assert wrong.status_code == 502
    assert len(api.get('/api/state').json()['profiles']) == 1
    plan = api.post('/api/plans', json={'action': 'add_member', 'profile_id': profile['id'], 'params': {'host': hosts[2], 'votes': 1, 'priority': 0.5}}).json()
    job = api.post('/api/jobs', json={'plan_id': plan['id'], 'confirmation': plan['confirmation']}).json()
    result = wait_for(lambda: (j if (j := api.get('/api/jobs/' + job['id']).json())['status'] in ('succeeded', 'failed') else None), timeout=120)
    assert result['status'] == 'succeeded', result
    assert result['result']['ready']
    config = root.admin.command('replSetGetConfig')['config']
    new = next(m for m in config['members'] if m['host'] == hosts[2])
    assert new['votes'] == 1 and new['priority'] == 0.5
    with MongoClient(hosts[2], directConnection=True, username='managerAdmin', password=password, authSource='admin',
                     readPreference='secondary', serverSelectionTimeoutMS=3000) as secondary:
        wait_for(lambda: secondary.application.events.find_one({'_id': 'preserved'}), timeout=30)
    assert password not in api.get('/api/state').text
    # Seed membership must be retained for new connections after a failover.
    persisted = api.get('/api/state').json()['profiles'][0]
    assert set(persisted['seeds']) == set(hosts)

    def run_action(action, params):
        preview = api.post('/api/plans', json={'action': action, 'profile_id': profile['id'], 'params': params})
        assert preview.status_code == 200, preview.text
        plan = preview.json()
        response = api.post('/api/jobs', json={'plan_id': plan['id'], 'confirmation': plan['confirmation']})
        assert response.status_code == 202, response.text
        job_id = response.json()['id']
        final = wait_for(lambda: (j if (j := api.get('/api/jobs/' + job_id).json())['status'] in ('succeeded', 'failed') else None), timeout=120)
        assert final['status'] == 'succeeded', final
        return final['result']

    # Make the third node electable so the cluster can survive loss of old primary.
    run_action('member_options', {'host': hosts[2], 'priority': 1, 'votes': 1, 'hidden': False})
    pending = api.post('/api/plans', json={'action': 'create_user', 'profile_id': profile['id'], 'params': {
        'username': 'afterElection', 'password': secrets.token_urlsafe(24), 'database': 'application', 'role': 'readWrite'}}).json()
    # Exercise a moving oplog and a second handoff to a recently frozen candidate.
    stop = threading.Event()
    wrote = threading.Event()

    def write_during_handoff():
        while not stop.is_set():
            try:
                root.application.handoff.update_one({'_id': 'counter'}, {'$inc': {'n': 1}}, upsert=True)
                wrote.set()
            except PyMongoError:
                pass  # Elections can briefly interrupt writes.
            stop.wait(.02)

    writer = threading.Thread(target=write_during_handoff)
    writer.start()
    try:
        assert wrote.wait(10)
        for previous, target in [(hosts[0], hosts[1]), (hosts[1], hosts[2])]:
            moved = run_action('step_down', {'host': target})
            assert moved == {'previous_primary': previous, 'primary': target}
    finally:
        stop.set()
        writer.join(15)
    with MongoClient(hosts[0], directConnection=True, username='managerAdmin', password=password,
                     authSource='admin', serverSelectionTimeoutMS=3000) as old_primary:
        try:
            old_primary.admin.command({'shutdown': 1})
        except PyMongoError:
            pass
    # A fresh API client connection must find the new primary with old primary offline.
    status = wait_for(lambda: (r.json() if (r := api.get('/api/profiles/' + profile['id'] + '/status')).status_code == 200 else None), timeout=45)
    assert status['primary'] != hosts[0]
    assert next(m for m in status['members'] if m['host'] == status['primary'])['state'] == 'PRIMARY'
    response = api.post('/api/jobs', json={'plan_id': pending['id'], 'confirmation': pending['confirmation']})
    assert response.status_code == 202
    job_id = response.json()['id']
    final = wait_for(lambda: (j if (j := api.get('/api/jobs/' + job_id).json())['status'] in ('succeeded', 'failed') else None), timeout=60)
    assert final['status'] == 'succeeded', final
    users = api.get('/api/profiles/' + profile['id'] + '/query/users')
    assert any(u['user'] == 'afterElection' for u in users.json())
    assert root.application.events.find_one({'_id': 'preserved'})['value'] == 'real-data'


def test_ubuntu_maintenance_handoff(live_cluster):
    from web.ubuntu import mongo_state

    _, root, hosts, password = live_cluster
    config = root.admin.command('replSetGetConfig')['config']
    current = root.admin.command('hello')['me']
    status = root.admin.command('serverStatus')
    info = {'version': status['version'], 'hostname': status['host'].split(':')[0], 'pid': status['pid']}
    profile = dict(seeds=hosts, replica_set='managerLiveTest', username='managerAdmin', auth_db='admin', password=password)
    machine = dict(mongo_endpoint=current)
    with pytest.raises(ValueError, match='quorum'):
        mongo_state(machine, profile, info, handoff=True)
    config['members'].append({'_id': 2, 'host': hosts[2]})
    config['version'] += 1
    root.admin.command({'replSetReconfig': config})
    wait_for(lambda: sum(m['state'] == 2 for m in root.admin.command('replSetGetStatus')['members']) == 2)
    wait_for(lambda: not any(m.get('newlyAdded') for m in root.admin.command('replSetGetConfig')['config']['members']))
    mongo_state(machine, profile, info, handoff=True)
    assert root.admin.command('hello')['me'] != current
    assert root.application.events.find_one({'_id': 'preserved'})['value'] == 'real-data'
