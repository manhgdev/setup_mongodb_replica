import json
import pytest
from fastapi.testclient import TestClient

from apps.vps_manager.backend import docker_worker
from apps.vps_manager.backend.app import CATALOG, INSTALL, KITS, create_app


def test_kits_reference_catalog():
    assert set(CATALOG)==set(INSTALL)
    assert all(len(ids)==len(set(ids)) and set(ids)<=CATALOG.keys() for ids in KITS.values())
    assert KITS["Docker"]==["docker-engine","docker-service","docker-compose"]


def test_compose_recheck_and_secret_handling(tmp_path, monkeypatch):
    path=tmp_path/"compose.yaml"
    path.write_text("services: {}")
    calls=[]
    config={"name":"web","services":{"app":{"image":"nginx","environment":{"PASS":"private-value"}}}}
    def cli(args,*unused):
        calls.append(args)
        return json.dumps(config) if args[-1]=="json" else ""
    monkeypatch.setattr(docker_worker,"cli",cli)
    plan=docker_worker.execute("docker-plan",{"filename":str(path)})
    assert "private-value" not in str(plan)
    config["services"]["app"]["image"]="redis"
    with pytest.raises(ValueError,match="đã đổi"):
        docker_worker.execute("docker-deploy",dict(filename=str(path),revision=plan["revision"],pull=True))
    assert all("pull" not in args and "up" not in args for args in calls)


def test_docker_access_and_validation(tmp_path):
    with TestClient(create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as client:
        assert client.get("/api/vps/machines/demo/docker/status").status_code==401
        client.post("/api/auth/setup",json={"username":"fixture","password":"fixture-pass"})
        assert client.post("/api/vps/machines/demo/docker/deploy",json={}).status_code==403
    with pytest.raises(ValueError,match="ID container"):
        docker_worker.execute("docker-logs",{"container":"--help"})
    with pytest.raises(ValueError,match="Thao tác"):
        docker_worker.execute("docker-container",{"container":"a"*12,"operation":"rm"})
