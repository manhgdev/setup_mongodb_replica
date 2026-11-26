import pytest

from apps.vps_manager.backend import worker


def test_installed_pages_include_held_packages_and_exclude_removed(monkeypatch):
    lines = ["hi \ttool-held\t2", "rc \ttool-removed\t0"]
    lines.extend(f"ii \ttool-{n:02}\t1" for n in range(35))
    monkeypatch.setattr(worker, "command", lambda args: "\n".join(lines))
    result = worker.package_query("installed", "tool", 30, True, False)
    assert result["total"] == 36
    assert result["items"][-1] == {"name": "tool-held", "version": "2"}


def test_repository_install_rechecks_candidate_before_changes(monkeypatch):
    calls = []

    def command(args):
        calls.append(args)
        return "  Candidate: 2.0" if args[0] == "apt-cache" else "simulation"

    monkeypatch.setattr(worker, "command", command)
    monkeypatch.setattr(worker.shutil, "which", lambda tool: tool == "apt-get")
    with pytest.raises(ValueError, match="đã đổi"):
        worker.execute("native-install", {"catalog": [], "name": "tree", "target": "tree=1.0"})
    assert calls[-1] == ["apt-get", "-s", "--no-remove", "install", "tree=2.0"]


@pytest.mark.parametrize("value", ["--option", "/local/file.deb", "https://example.org/a.rpm"])
def test_native_install_only_accepts_repository_names(value):
    with pytest.raises(ValueError):
        worker.native_plan(value, True, False)


def test_service_query_parses_units_and_memory(monkeypatch):
    monkeypatch.setattr(worker.shutil, "which", lambda tool: "/bin/systemctl" if tool == "systemctl" else None)

    def fake_run_systemctl(args):
        if args[0] == "list-unit-files":
            return "nginx.service enabled\nredis-server.service disabled\naccounts-daemon.service enabled\nssh.service enabled\n"
        if args[0] == "list-units":
            return "  nginx.service loaded active running A high performance web server\n  accounts-daemon.service loaded active running Accounts Service\n● ssh.service loaded active running OpenBSD Secure Shell server\n"
        if args[0] == "show":
            return "Id=nginx.service\nMainPID=101\nMemoryCurrent=52428800\n\nId=ssh.service\nMainPID=88\nMemoryCurrent=10485760\n"
        raise AssertionError(args)

    monkeypatch.setattr(worker, "_run_systemctl", fake_run_systemctl)
    rows = worker.service_query()["items"]
    assert [r["name"] for r in rows[:2]] == ["nginx.service", "redis-server.service"]
    assert rows[0]["category"] == "app"
    items = {item["name"]: item for item in rows}
    assert items["accounts-daemon.service"]["category"] == "system"
    assert items["ssh.service"]["category"] == "system"
    assert items["nginx.service"]["active"] == "active"
    assert items["nginx.service"]["memory_bytes"] == 52428800
    assert items["nginx.service"]["protected"] is False
    assert items["ssh.service"]["protected"] is True
    assert items["redis-server.service"]["enabled"] == "disabled"


def test_service_control_blocks_protected_and_invalid(monkeypatch):
    monkeypatch.setattr(worker.shutil, "which", lambda tool: "/bin/systemctl" if tool == "systemctl" else None)
    calls = []
    monkeypatch.setattr(worker, "command", lambda args, timeout=60: calls.append(args) or "")

    with pytest.raises(ValueError, match="quan trọng"):
        worker.service_control("ssh.service", "stop")
    with pytest.raises(ValueError, match="không hợp lệ"):
        worker.service_control("../bad.service", "stop")

    res = worker.service_control("redis-server.service", "disable")
    assert res == {"unit": "redis-server.service", "operation": "disable"}
    assert calls == [["systemctl", "disable", "--now", "redis-server.service"]]
