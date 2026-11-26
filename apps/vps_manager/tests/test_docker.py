import io
import json
import tarfile
import pytest
from fastapi.testclient import TestClient

from apps.vps_manager.backend import docker_worker, stack_transfer, stack_worker
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


def _make_bundle(path, manifest=None, extra_members=None):
    with tarfile.open(path, "w:gz") as tar:
        if manifest is not None:
            raw = json.dumps(manifest).encode("utf-8")
            info = tarfile.TarInfo("zm-stack-manifest.json")
            info.size = len(raw)
            tar.addfile(info, io.BytesIO(raw))
        for item in extra_members or []:
            tar.addfile(*item)


def test_stack_bundle_validation_and_traversal(tmp_path):
    good = tmp_path / "good.tar.gz"
    _make_bundle(good, manifest={"version": 1, "pm2_apps": [{"name": "api"}], "nginx_sites": [], "mongodb": {"included": False}})
    inspected = stack_transfer.inspect_bundle(good)
    assert inspected["id"] == "good.tar.gz"
    assert inspected["manifest"]["pm2_apps"][0]["name"] == "api"

    missing = tmp_path / "missing.tar.gz"
    _make_bundle(missing, manifest=None)
    with pytest.raises(ValueError, match="zm-stack-manifest.json"):
        stack_transfer.inspect_bundle(missing)

    evil = tmp_path / "evil.tar.gz"
    evil_info = tarfile.TarInfo("../etc/passwd")
    evil_info.size = 4
    _make_bundle(evil, manifest={"version": 1}, extra_members=[(evil_info, io.BytesIO(b"root"))])
    with pytest.raises(ValueError, match="path traversal"):
        stack_transfer.inspect_bundle(evil)

    with pytest.raises(ValueError, match="không hợp lệ"):
        stack_transfer.safe_bundle_path(tmp_path, "../bad.tar.gz")


def test_stack_bundle_upload_list_delete_and_scan(tmp_path, monkeypatch):
    bundle_src = tmp_path / "upload.tar.gz"
    _make_bundle(bundle_src, manifest={"version": 1, "pm2_apps": [], "compose_projects": [], "nginx_sites": [], "mongodb": {"included": True, "size": 128}})

    with TestClient(create_app(tmp_path / "data"), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        assert client.get("/api/vps/docker/bundles").status_code == 401
        res = client.post("/api/auth/setup", json={"username": "fixture", "password": "fixture-pass"})
        csrf = res.json()["csrf"]
        headers = {"X-CSRF-Token": csrf}

        up = client.post(
            "/api/vps/docker/bundles/upload?filename=my-stack.tar.gz",
            headers={**headers, "Content-Type": "application/gzip"},
            content=bundle_src.read_bytes(),
        )
        assert up.status_code == 200
        bid = up.json()["id"]
        assert bid.startswith("my-stack-") and bid.endswith(".tar.gz")

        listed = client.get("/api/vps/docker/bundles").json()["bundles"]
        assert [b["id"] for b in listed] == [bid]

        dl = client.get(f"/api/vps/docker/bundles/{bid}/download")
        assert dl.status_code == 200

        deleted = client.delete(f"/api/vps/docker/bundles/{bid}", headers=headers)
        assert deleted.status_code == 200
        assert client.get("/api/vps/docker/bundles").json()["bundles"] == []

    monkeypatch.setattr(stack_worker, "scan_pm2", lambda u: [{"name": "web", "cwd": "/srv/web"}])
    monkeypatch.setattr(stack_worker, "scan_compose", lambda: [])
    monkeypatch.setattr(stack_worker, "scan_nginx", lambda: [])
    monkeypatch.setattr(stack_worker, "scan_mongo", lambda: {"installed": True, "active": True, "has_tools": True, "databases": []})
    scanned = stack_worker.execute("stack-scan", {"login_user": "ubuntu"})
    assert scanned["pm2"][0]["name"] == "web"
    assert scanned["mongodb"]["active"] is True
