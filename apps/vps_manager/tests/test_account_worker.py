from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from apps.vps_manager.backend import account_worker as worker


def test_pam_failure_never_echoes_password(tmp_path, monkeypatch):
    monkeypatch.setattr(worker.os,"getuid",lambda:0)
    monkeypatch.setattr(worker.pwd,"getpwnam",lambda _:SimpleNamespace(pw_uid=1001))
    monkeypatch.setattr(worker,"Path",lambda _:tmp_path/"state")
    run=Mock(return_value=SimpleNamespace(returncode=1))
    monkeypatch.setattr(worker,"run",run)
    with pytest.raises(ValueError,match="PAM") as error:
        worker.execute("change",{"user":"opc","password":"marker-unique","enable":False})
    run.assert_called_once_with("chpasswd",input="opc:marker-unique\n")
    assert "marker-unique" not in str(error.value)


def test_pending_rollback_blocks_second_change(tmp_path,monkeypatch):
    (tmp_path/"pending").write_text("fixture")
    monkeypatch.setattr(worker.os,"getuid",lambda:0)
    monkeypatch.setattr(worker.pwd,"getpwnam",lambda _:SimpleNamespace(pw_uid=1001))
    monkeypatch.setattr(worker,"Path",lambda _:tmp_path)
    run=Mock()
    monkeypatch.setattr(worker,"run",run)
    with pytest.raises(ValueError,match="chờ xác minh"):
        worker.execute("change",{"user":"opc","password":"another-marker","enable":False})
    run.assert_not_called()
