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
