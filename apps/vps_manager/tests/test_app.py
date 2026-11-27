from fastapi.testclient import TestClient
from apps.vps_manager.backend.app import create_app


def test_independent_auth_and_machine(tmp_path):
    app = create_app(tmp_path)
    with TestClient(
        app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}
    ) as client:
        assert client.get("/vps/").status_code == 200
        assert client.get("/api/vps/machines").status_code == 401
        auth = client.post(
            "/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}
        ).json()
        machine = {"mode": "local", "name": "Local"}
        assert client.post("/api/vps/machines", json=machine).status_code == 403
        client.headers["X-CSRF-Token"] = auth["csrf"]
        ident = client.post("/api/vps/machines", json=machine).json()["id"]
        assert client.get("/api/vps/machines").json()[0]["id"] == ident
        assert (
            client.post(
                f"/api/vps/machines/{ident}/install", json={"packages": ["other"]}
            ).status_code
            == 422
        )
        assert client.post("/api/auth/logout", json={}).status_code == 200
        assert client.get("/api/vps/machines").status_code == 401


def test_batch_queues_distinct_targets_and_reports_missing(tmp_path, monkeypatch):
    from apps.vps_manager.backend import app as module
    monkeypatch.setattr(module, "worker", lambda machine, action, params, emit: {"packages":params["packages"]})
    with TestClient(create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as client:
        auth = client.post("/api/auth/setup",json={"username":"operator","password":"fixture-pass"}).json()
        client.headers["X-CSRF-Token"]=auth["csrf"]
        ids=[client.post("/api/vps/machines",json={"name":host,"host":host}).json()["id"] for host in ["web-a.test","web-b.test"]]
        results=client.post("/api/vps/batches/install",json={"machines":[*ids,ids[0],"gone"],"operation":{"packages":["nginx"]}}).json()
        assert [row["machine"] for row in results]==[*ids,"gone"]
        for row in results[:2]:
            assert client.get("/api/vps/jobs/"+row["job"]).json()["machine_id"]==row["machine"]
        assert "error" in results[2]


def test_account_job_failure_keeps_stage_and_redacts_password(tmp_path, monkeypatch):
    import time
    from apps.vps_manager.backend import app as module
    secret = "test-secret-only-in-memory"
    def account_call(machine, action, params=None, emit=None):
        if action=="identity":
            if machine.get("ssh_auth")=="password":
                raise RuntimeError("test authentication failed")
            return {"user":"opc","connection":"192.0.2.1 1000 192.0.2.2 22","sudo":True}
        if action=="policy":
            return {"password":"no","pubkey":"yes"}
        if action=="change":
            assert params["password"]==secret
            emit("Đã đặt mật khẩu Linux cho opc")
            emit("verify-ticket:"+"a"*32)
        raise AssertionError(action)
    monkeypatch.setattr(module,"account_call",account_call)
    with TestClient(create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as client:
        auth=client.post("/api/auth/setup",json={"username":"admin","password":"fixture-pass"}).json()
        client.headers["X-CSRF-Token"]=auth["csrf"]
        machine=client.post("/api/vps/machines",json={"name":"Oracle","host":"oracle.test","user":"opc"}).json()["id"]
        job=client.post(f"/api/vps/machines/{machine}/password",json={"password":secret,"enable":True}).json()["id"]
        for _ in range(100):
            result=client.get("/api/vps/jobs/"+job).json()
            if result["status"]=="failed":
                break
            time.sleep(.02)
        assert "Timer" in result["error"]
        assert secret not in str(result) and "verify-ticket" not in str(result)
        assert secret not in str(client.app.state.store.all("machines"))


def test_install_catalog_dependencies_and_shell_syntax():
    import subprocess
    from apps.vps_manager.backend.app import INSTALL,CATALOG,KITS
    from apps.vps_manager.backend.worker import UNINSTALL_RECIPES
    assert set(INSTALL)==set(CATALOG)
    def visit(item,path):
        assert item not in path
        for dep in INSTALL[item].get("deps",[]):
            visit(dep,path+[item])
    for item,entry in INSTALL.items():
        visit(item,[])
        for key in ("probe","install"):
            if key in entry:
                subprocess.run(["bash","-n"],input=entry[key],text=True,check=True)
        if "install" in entry:
            assert item in UNINSTALL_RECIPES
    kit_items={pkg for items in KITS.values() for pkg in items}
    assert {item for item,entry in INSTALL.items() if not entry.get("hidden")} <= kit_items
    assert INSTALL["libasound2"]["apt"]==["libasound2t64","libasound2"]
    assert INSTALL["g++"]["dnf"]==["gcc-c++"]


def test_overview_snapshot(tmp_path, monkeypatch):
    from apps.vps_manager.backend import app as module
    from unittest.mock import Mock
    probe=Mock(side_effect=[{"host":"one"},{"host":"two"}])
    monkeypatch.setattr(module,"worker",probe)
    with TestClient(create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as client:
        auth=client.post("/api/auth/setup",json={"username":"admin","password":"fixture-pass"}).json()
        client.headers["X-CSRF-Token"]=auth["csrf"]
        ident=client.post("/api/vps/machines",json={"name":"Test","host":"vm.test"}).json()["id"]
        path="/api/vps/machines/"+ident
        assert client.get(path).json()["host"]=="one"
        assert client.get(path).json()["host"]=="one"
        assert client.get(path+"?refresh=true").json()["host"]=="two"
        assert probe.call_count==2


def test_machine_accepts_shared_mongo_fields(tmp_path):
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        auth = client.post("/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}).json()
        client.headers["X-CSRF-Token"] = auth["csrf"]
        body = {"name": "vps-1", "auto_name": True, "mode": "ssh", "host": "203.0.113.5", "port": 22, "user": "root", "ssh_auth": "password",
                "ssh_password": "x", "votes": 1, "priority": 1, "mongo_endpoint": "203.0.113.5:27017"}
        assert client.post("/api/vps/machines", json=body).status_code == 201
        assert client.post("/api/vps/machines", json=dict(body, profile_id="p")).status_code == 422


def test_server_list_edit_delete(tmp_path):
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        auth = client.post("/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}).json()
        client.headers["X-CSRF-Token"] = auth["csrf"]
        body = {"name": "a", "mode": "ssh", "host": "203.0.113.5", "ssh_auth": "password", "ssh_password": "secret-pw"}
        ident = client.post("/api/vps/machines", json=body).json()["id"]
        listing = client.get("/api/vps/servers")
        assert "secret-pw" not in listing.text and listing.json()[0]["has_ssh_password"]
        edited = dict(body, name="b", ssh_password=None)
        assert client.put(f"/api/vps/servers/{ident}", json=edited).json()["name"] == "b"
        assert client.delete(f"/api/vps/servers/{ident}").status_code == 200
        assert client.get("/api/vps/servers").json() == []


def test_cloudflare_token_saved_and_loaded_per_workspace(tmp_path):
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        auth = client.post("/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}).json()
        client.headers["X-CSRF-Token"] = auth["csrf"]
        assert client.get("/api/vps/cloudflare-token").json() == {"token": "", "name": "default"}

        ident = client.post("/api/vps/machines", json={
            "name": "vps-cf", "mode": "ssh", "host": "203.0.113.5", "ssh_auth": "password", "ssh_password": "pw",
        }).json()["id"]
        res = client.post("/api/vps/batches/cloudflare-token", json={
            "machines": [ident],
            "operation": {"token": "cfut_saved_token_1234567890", "name": "zm", "update_renewal": True},
        })
        assert res.status_code == 202
        assert client.get("/api/vps/cloudflare-token").json() == {
            "token": "cfut_saved_token_1234567890",
            "name": "zm",
        }
