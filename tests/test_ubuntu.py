import threading
from unittest.mock import Mock

import pytest

from web import host_worker as worker
from web import ubuntu


@pytest.mark.parametrize("current,requested,target,path", [
    ("jammy", "auto", "jammy", []),
    ("focal", "auto", "jammy", ["jammy"]),
    ("bionic", "auto", "jammy", ["focal", "jammy"]),
    ("jammy", "resolute", "resolute", ["noble", "resolute"]),
])
def test_release_path(current, requested, target, path):
    assert worker.release_path(current, "9.0", "amd64", "", requested, Mock()) == (target, path)


def test_no_downgrade_or_unknown_packages():
    with pytest.raises(ValueError, match="đường nâng"):
        worker.release_path("resolute", "8.0", "amd64", "", "auto", Mock())
    with pytest.raises(ValueError, match="thiếu gói"):
        worker.release_path("jammy", "9.0", "arm64", "", "auto", Mock(side_effect=ValueError("thiếu gói")))
    check = Mock(side_effect=RuntimeError("lỗi mạng"))
    with pytest.raises(RuntimeError, match="mạng"):
        worker.release_path("jammy", "9.0", "arm64", "", "auto", check)
    assert check.call_count == 1


def test_disk_preflight(monkeypatch):
    monkeypatch.setattr(worker.os, "geteuid", lambda: 0)
    monkeypatch.setattr(worker.Path, "is_dir", lambda _: True)
    monkeypatch.setattr(worker.shutil, "disk_usage", lambda _: Mock(free=100))
    with pytest.raises(ValueError, match="5 GiB"):
        worker.check_upgrade("noble")


def test_resume_after_reboot_never_relaunches_stage(monkeypatch):
    expected = dict(path=["resolute"], target="resolute", version="", series="9.0")
    ctx = dict(info=expected, params={"target": "resolute"}, launching=True)
    remote = Mock(return_value=dict(phase="reboot", rebooted=True, current="resolute"))
    monkeypatch.setattr(ubuntu, "host_run", remote)
    monkeypatch.setattr(ubuntu, "inspect", lambda *_: dict(expected, current="resolute"))
    result = ubuntu.advance(Mock(), {"id": "123"}, {}, None, ctx, threading.Event(), Mock())
    assert result["ubuntu"] == "26.04" and ctx["index"] == 1
    assert [c.args[1] for c in remote.call_args_list] == ["ubuntu_status"]


def test_quorum_when_host_is_offline():
    cfg = {"members": [{"_id": 0}, {"_id": 1}, {"_id": 2}]}
    states = {1: {"health": 1, "state": 2}, 2: {"health": 1, "state": 2}}
    ubuntu.check_quorum(cfg, states)
    with pytest.raises(ValueError, match="quorum"):
        ubuntu.check_quorum(cfg, {1: states[1]})


def test_apply_requires_backup_and_plan_can_only_run_once(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from web.app import create_app

    info = dict(os="Ubuntu", arch="amd64", series="9.0", current="noble", target="resolute",
                path=["resolute"], version="9.0.8")
    monkeypatch.setattr("web.app.host_run", lambda *args: info)
    monkeypatch.setattr(ubuntu, "host_run", lambda *args: {})
    monkeypatch.setattr(ubuntu, "mongo_state", lambda *args: ("Standalone", {}))
    monkeypatch.setattr(ubuntu, "advance", lambda *args: {"ubuntu": "26.04"})
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        machine = api.post("/api/machines", json={"name": "VM", "mode": "local"}).json()
        plan = api.post("/api/plans", json={"action": "ubuntu_upgrade", "machine_id": machine["id"],
                                           "params": {"series": "9.0", "target": "resolute"}}).json()
        apply = dict(plan_id=plan["id"], confirmation=plan["confirmation"])
        assert api.post("/api/jobs", json=apply).status_code == 400
        assert api.post("/api/jobs", json=dict(apply, backup_confirmed=True)).status_code == 202
        assert api.post("/api/jobs", json=dict(apply, backup_confirmed=True)).status_code == 409


@pytest.mark.parametrize("remaining,stepdowns", [(1, 0), (2, 1)])
def test_primary_handoff_only_with_surviving_quorum(remaining, stepdowns):
    from unittest.mock import MagicMock, patch

    machine = {"mongo_endpoint": "mongo-1:27017"}
    info = dict(version="9.0.8", hostname="mongo-1", pid=42)
    profile = {"replica_set": "rs0"}
    cfg = {"members": [{"_id": n} for n in range(5 if remaining == 1 else 3)]}
    states = {0: {"_id": 0, "self": True, "state": 1, "health": 1}}
    states.update({n: {"_id": n, "state": 2, "health": 1} for n in range(1, remaining + 1)})
    direct, cluster = MagicMock(), MagicMock()
    count = 0

    def command(value):
        nonlocal count
        if isinstance(value, dict) and "replSetStepDown" in value:
            count += 1
            return {"ok": 1}
        return {"hello": {"setName": "rs0", "secondary": count > 0, "me": "mongo-1"},
                "serverStatus": {"pid": 42, "host": "mongo-1:27017", "version": "9.0.8"},
                "getCmdLineOpts": {"parsed": {}}}[value]

    direct.admin.command.side_effect = command
    cluster.admin.command.return_value = {"me": "mongo-2", "isWritablePrimary": True}
    with patch.object(ubuntu, "client", side_effect=lambda _, direct=None: contexts[bool(direct)]), patch.object(
            ubuntu, "healthy_config", return_value=(cfg, states)):
        contexts = [MagicMock(), MagicMock()]
        contexts[1].__enter__.return_value = direct
        contexts[0].__enter__.return_value = cluster
        if remaining == 1:
            with pytest.raises(ValueError, match="quorum"):
                ubuntu.mongo_state(machine, profile, info, handoff=True)
        else:
            ubuntu.mongo_state(machine, profile, info, handoff=True)
    assert count == stepdowns


def test_repository_distinguishes_missing_architecture_from_network_error(monkeypatch):
    from urllib.error import HTTPError, URLError

    for error, message, expected in [
        (HTTPError("https://repo.mongodb.org", 404, "missing", {}, None), "chưa có gói", ValueError),
        (URLError("offline"), "Tạm thời", RuntimeError),
    ]:
        monkeypatch.setattr(worker.urllib.request, "urlopen", Mock(side_effect=error))
        with pytest.raises(expected, match=message):
            worker.package_version("9.0", "noble", "arm64")
    with pytest.raises(ValueError, match="Kiến trúc"):
        worker.package_version("9.0", "noble", "i386")


def test_installed_mongo_requires_exact_version_on_each_release(monkeypatch):
    import gzip
    from io import BytesIO

    archive = gzip.compress("\n\n".join(f"Package: {name}\nVersion: 9.0.8" for name in worker.MONGO_PACKAGES).encode())
    monkeypatch.setattr(worker.urllib.request, "urlopen", lambda *a, **kw: BytesIO(archive))
    assert worker.package_version("9.0", "resolute", "amd64", "9.0.8") == "9.0.8"
    with pytest.raises(ValueError, match="đang chạy"):
        worker.package_version("9.0", "resolute", "amd64", "9.0.7")


def test_retry_after_distribution_upgrade_only_finishes_packages(monkeypatch):
    expected = dict(current="noble", target="resolute", path=["resolute"], series="9.0",
                    version="", machine_token="vm")
    ctx = dict(info=expected, params={"target": "resolute"}, launching=True, retry_finalize=True)
    remote = Mock(side_effect=[
        {"phase": "failed", "log": "upgrade.log", "can_finalize": True},
        {"started": True},
        {"phase": "reboot", "rebooted": True, "current": "resolute"},
    ])
    monkeypatch.setattr(ubuntu, "host_run", remote)
    monkeypatch.setattr(ubuntu, "inspect", lambda *_: dict(expected, current="resolute"))
    result = ubuntu.advance(Mock(), {"id": "123"}, {}, None, ctx, threading.Event(), Mock())
    assert result["ubuntu"] == "26.04"
    assert [call.args[1] for call in remote.call_args_list] == ["ubuntu_status", "ubuntu_finalize", "ubuntu_status"]


def test_compatibility_uses_endpoint_version_on_multi_instance_host(monkeypatch):
    monkeypatch.setattr(worker, "preflight", lambda _: dict(os="Ubuntu", architecture="aarch64", hostname="vm",
                        codename="resolute", tools={"systemctl": True}, version="db version v8.0.1",
                        service="mongod-test", service_state="active", services=["mongod.service", "mongod-test.service"]))
    monkeypatch.setattr(worker, "run", lambda cmd, **kw: {"systemctl": "42", "dpkg": "arm64", "pgrep": "41\n42"}[cmd[0]])
    monkeypatch.setattr(worker.shutil, "which", lambda _: True)
    monkeypatch.setattr(worker, "ubuntu_architecture", lambda: "arm64")
    monkeypatch.setattr(worker, "linux_info", lambda: {"ID": "ubuntu"})
    packages = Mock(return_value="9.0.8")
    monkeypatch.setattr(worker, "package_version", packages)
    result = worker.ubuntu_compatibility({"service": "mongod-test", "series": "8.0", "live_version": "9.0.8"})
    assert (result["status"], result["processes"], result["package"]) == ("compatible", 2, "9.0.8")
    packages.assert_called_once_with("9.0", "resolute", "arm64", "9.0.8")


def test_read_only_compatibility_without_primary(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from unittest.mock import MagicMock
    from web.app import create_app

    db = MagicMock()
    db.__enter__.return_value.admin.command.side_effect = [
        {"version": "9.0.8"}, {"isreplicaset": True}, {"pid": 42},
    ]
    direct = Mock(return_value=db)
    inspect = Mock(return_value={"pid": "42", "status": "compatible"})
    monkeypatch.setattr("web.app.client", direct)
    monkeypatch.setattr("web.app.host_run", inspect)
    app = create_app(tmp_path)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        store = app.state.store
        profile = store.save("profiles", {"name": "test"})
        machine = store.save("machines", {"profile_id": profile["id"], "mongo_endpoint": "example.test:27017"})
        response = api.get(f"/api/machines/{machine['id']}/compatibility")
        assert response.status_code == 200
        assert response.json()["role"] == "uninitialized"
        assert response.json()["pid_match"] is True
        direct.assert_called_once_with(profile, direct=machine["mongo_endpoint"])
        assert inspect.call_args.args[1:3] == ("ubuntu_compatibility", {"series": "9.0", "live_version": "9.0.8"})
        assert store.all("jobs") == []
