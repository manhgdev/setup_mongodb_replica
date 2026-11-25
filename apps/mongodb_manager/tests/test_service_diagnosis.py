import pytest

from apps.mongodb_manager.backend import host_worker as worker


def test_diagnosis_classifies_without_echoing_journal(monkeypatch):
    def fake_run(args, **kwargs):
        if args[0] == "journalctl":
            return "Address already in use. secret-marker"
        return "MainPID=0"

    monkeypatch.setattr(worker, "run", fake_run)
    report = worker.service_operation({"service": "mongod", "operation": "diagnose"})
    assert "Cổng bị chiếm" in report["findings"][0]
    assert "secret-marker" not in str(report)


def test_repair_refuses_package_service():
    with pytest.raises(ValueError, match="Manager"):
        worker.repair_keyfile("mongod")


def test_failed_start_collects_findings(monkeypatch):
    def fake_run(args, **kwargs):
        if args[:2] == ["systemctl", "start"]:
            raise RuntimeError("exit 1")
        return "no space left" if args[0] == "journalctl" else "MainPID=0"

    monkeypatch.setattr(worker, "run", fake_run)
    monkeypatch.setattr(worker, "event", lambda msg: None)
    with pytest.raises(RuntimeError, match="Hết dung lượng"):
        worker.service_operation({"service": "mongod", "operation": "start"})
