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


def test_apply_requires_backup_and_plan_can_only_run_once(tmp_path, monkeypatch, sign_in_new_manager):
    from fastapi.testclient import TestClient
    from web.app import create_app

    info = dict(os="Ubuntu", arch="amd64", series="9.0", current="noble", target="resolute",
                path=["resolute"], version="9.0.8")
    monkeypatch.setattr("web.app.host_run", lambda *args: info)
    monkeypatch.setattr(ubuntu, "host_run", lambda *args: {})
    monkeypatch.setattr(ubuntu, "mongo_state", lambda *args: ("Standalone", {}))
    monkeypatch.setattr(ubuntu, "advance", lambda *args: {"ubuntu": "26.04"})
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        sign_in_new_manager(api)
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
        {"pm2": "6.0.0"},
    ])
    monkeypatch.setattr(ubuntu, "host_run", remote)
    monkeypatch.setattr(ubuntu, "inspect", lambda *_: dict(expected, current="resolute"))
    result = ubuntu.advance(Mock(), {"id": "123"}, {}, None, ctx, threading.Event(), Mock())
    assert result["ubuntu"] == "26.04"
    assert [call.args[1] for call in remote.call_args_list] == ["ubuntu_status", "ubuntu_finalize", "ubuntu_status", "ubuntu_tools"]


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


def test_read_only_compatibility_without_primary(tmp_path, monkeypatch, sign_in_new_manager):
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
        sign_in_new_manager(api)
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


def test_resolute_reports_mongodb_upgrade_on_same_ubuntu(monkeypatch):
    monkeypatch.setattr(worker, "preflight", lambda _: dict(os="Ubuntu 26.04.1", architecture="amd64",
        hostname="arbiter", codename="resolute", tools={"systemctl": False}, version="db version v8.0.38",
        service="mongod", service_state="active", services=["mongod"]))
    monkeypatch.setattr(worker.shutil, "which", lambda _: None)
    monkeypatch.setattr(worker, "ubuntu_architecture", lambda: "amd64")
    monkeypatch.setattr(worker, "linux_info", lambda: {"ID": "ubuntu"})
    packages = Mock(return_value="9.0.8")
    monkeypatch.setattr(worker, "package_version", packages)
    report = worker.ubuntu_compatibility({"service": "mongod", "series": "9.0", "live_version": "8.0.38"})
    assert (report["status"], report["version"], report["package"]) == ("mongo_upgrade", "8.0.38", "9.0.8")
    assert report["target"] == "26.04" and report["path"] == []
    packages.assert_called_once_with("9.0", "resolute", "amd64")


@pytest.mark.parametrize("quorum_lost", [False, True])
def test_arbiter_upgrade_rechecks_before_install(monkeypatch, quorum_lost):
    from web import operations
    old = dict(current="8.0.38", process_id="process", port=27017)
    probe = Mock(side_effect=[old, ValueError("quorum") if quorum_lost else old, dict(old, current="9.0.8")])
    remote = Mock()
    monkeypatch.setattr(operations, "arbiter_upgrade_target", probe)
    monkeypatch.setattr(operations, "host_run", remote)
    args = ("arbiter_upgrade", {"version": "9.0.8"}, {}, {"mongo_endpoint": "arbiter:27017"}, Mock())
    if quorum_lost:
        with pytest.raises(ValueError, match="quorum"):
            operations.execute(*args)
        assert [c.args[1] for c in remote.call_args_list] == ["package_recover", "arbiter_packages"]
    else:
        assert operations.execute(*args)["role"] == "ARBITER"
        assert [c.args[1] for c in remote.call_args_list] == ["package_recover", "arbiter_packages", "arbiter_install"]


def test_arbiter_version_restricted(tmp_path, monkeypatch, sign_in_new_manager):
    from fastapi.testclient import TestClient
    from pymongo.errors import OperationFailure
    from unittest.mock import MagicMock
    from web.app import create_app

    db = MagicMock()
    db.__enter__.return_value.admin.command.side_effect = [
        OperationFailure("authentication failed", 18), {"arbiterOnly": True, "setName": "rs0"},
        OperationFailure("unauthorized", 13),
    ]
    monkeypatch.setattr("web.app.client", Mock(return_value=db))
    monkeypatch.setattr("web.app.host_run", Mock(return_value={"version": "9.0.8", "status": "compatible"}))
    app = create_app(tmp_path)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        sign_in_new_manager(api)
        store = app.state.store
        profile = store.save("profiles", {"name": "test", "replica_set": "rs0"})
        machine = store.save("machines", {"profile_id": profile["id"], "mongo_endpoint": "example.test:27017"})
        result = api.get(f"/api/machines/{machine['id']}/compatibility").json()
        assert result["role"] == "ARBITER" and result["arbiter_version_restricted"]
        assert result["version"] == "9.0.8" and not result["live"] and not result["endpoint_error"]


def test_compatibility_stream(tmp_path, monkeypatch, sign_in_new_manager):
    import json
    from fastapi.testclient import TestClient
    from web.app import create_app

    def inspect(machine, action, params, emit):
        if action == "ubuntu_inventory":
            return {"hostname": "linux1929", "version": "8.0.32"}
        assert params["inventory"]["hostname"] == "linux1929"
        return {"status": "compatible", "version": "8.0.32"}

    monkeypatch.setattr("web.app.host_run", inspect)
    app = create_app(tmp_path)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        sign_in_new_manager(api)
        machine = app.state.store.save("machines", {"name": "linux1929"})
        response = api.get(f"/api/machines/{machine['id']}/compatibility?stream=true")
        updates = [json.loads(line) for line in response.iter_lines()]
        assert {u["stage"] for u in updates[:2]} == {"endpoint", "host"}
        assert updates[2]["stage"] == "complete"
        assert updates[2]["value"]["status"] == "compatible"


def test_data_node_upgrade_rechecks_before_install(monkeypatch):
    from web import operations
    node = dict(role="SECONDARY", current="8.0.15", port=27017, process_id="a")
    plan = dict(node=node, version="9.0.8", series="9.0")
    probe = Mock(side_effect=[node, node, node, dict(node, current="9.0.8")])
    worker = Mock()
    monkeypatch.setattr(operations, "mongo_upgrade_node", probe)
    monkeypatch.setattr(operations, "host_run", worker)
    machine = {"mongo_endpoint": "host:27017"}
    result = operations.execute("mongo_upgrade", plan, {}, machine, Mock())
    assert result["version"] == "9.0.8" and result["role"] == "SECONDARY"
    assert [call.args[1] for call in worker.call_args_list] == ["package_recover", "arbiter_packages", "arbiter_install"]
    worker.reset_mock()
    probe.side_effect = [node, node, dict(node, role="PRIMARY")]
    with pytest.raises(ValueError, match="đã đổi"):
        operations.execute("mongo_upgrade", plan, {}, machine, Mock())
    assert [call.args[1] for call in worker.call_args_list] == ["package_recover", "arbiter_packages"]


def test_release_catalog_accepts_future_community_release():
    from web.releases import parse
    ubuntu = "Dist: future\nVersion: 28.04.1 LTS\n"
    pkg = "https://repo.mongodb.org/apt/ubuntu/dists/future/mongodb-org/10.0/multiverse/binary-arm64/mongodb-org-server_10.0.1_arm64.deb"
    mongo = {"versions": [{"version": "10.0.1", "downloads": [{"packages": [pkg]}]}]}
    assert parse(ubuntu, mongo) == {"lts": {"future": "28.04"}, "supported": {"10.0": ["future"]}}


def test_os_only_plan_without_mongodb(monkeypatch):
    monkeypatch.setattr(worker, "linux_info", lambda: {"ID": "ubuntu", "VERSION_CODENAME": "jammy", "PRETTY_NAME": "Ubuntu 22.04"})
    monkeypatch.setattr(worker.shutil, "which", lambda _: None)
    monkeypatch.setattr(worker, "run", lambda *_: "amd64")
    monkeypatch.setattr(worker.Path, "read_bytes", lambda _: b"machine")
    result = worker.ubuntu_inspect({"target": "noble"})
    assert (result["series"], result["version"], result["path"]) == ("", "", ["noble"])


def test_find_active_upgrade_by_host_and_kind(tmp_path, sign_in_new_manager):
    from fastapi.testclient import TestClient
    from web.app import create_app

    app = create_app(tmp_path)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as api:
        sign_in_new_manager(api)
        store = app.state.store
        for ident, machine, kind, status in [
            ("a", "one", "mongo_upgrade", "running"), ("b", "two", "ubuntu_upgrade", "queued"),
            ("c", "one", "ubuntu_upgrade", "failed"), ("d", "two", "arbiter_upgrade", "running"),
        ]:
            store.save("jobs", dict(machine_id=machine, action=kind, status=status), ident)
        def find(machine, action):
            return api.get(f"/api/machines/{machine}/active-upgrade", params={"action": action}).json()
        assert find("one", "mongo_upgrade")["id"] == "a"
        assert find("one", "ubuntu_upgrade") is None
        assert find("two", "ubuntu_upgrade")["id"] == "b"
        assert find("two", "mongo_upgrade")["id"] == "d"


def test_inactive_mongo_allows_ubuntu_without_replica_connection(monkeypatch):
    monkeypatch.setattr(worker, "linux_info", lambda: {"ID": "ubuntu", "VERSION_CODENAME": "noble", "PRETTY_NAME": "Ubuntu 24.04"})
    monkeypatch.setattr(worker.shutil, "which", lambda name: name)
    def read(cmd, **kwargs):
        if cmd[0] == "systemctl":
            return "inactive" if cmd[1] == "is-active" else "0"
        return {"dpkg": "amd64", "pgrep": "", "dpkg-query": "9.0.8"}[cmd[0]]
    monkeypatch.setattr(worker, "run", read)
    monkeypatch.setattr(worker.Path, "read_bytes", lambda _: b"machine")
    params = {"target": "resolute", "service": "mongod-test"}
    for preview in (True, False):
        result = worker.ubuntu_inspect(params, preview=preview)
        assert result["offline"] and not result["blocked"] and result["path"] == ["resolute"]
        assert ubuntu.mongo_state({}, None, result, verify=True)[1] == {}
