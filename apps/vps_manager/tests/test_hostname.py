import pytest
from fastapi.testclient import TestClient
from apps.vps_manager.backend.app import create_app
from apps.vps_manager.backend import hostname_worker as worker


@pytest.mark.parametrize("value",["-host","bad..name","bad_name","$(id)","192.0.2.1","localhost","x"*64])
def test_reject_invalid_hostname(value):
    assert not worker.valid_hostname(value)


def test_hosts_preserves_other_addresses_and_comments():
    source="127.0.0.1 localhost\n127.0.1.1 old.example old alias # local\n::1 localhost\n"
    result=worker.hosts_content(source,"old.example","web.example")
    assert result=="127.0.0.1 localhost\n127.0.1.1\tweb.example web alias  # local\n::1 localhost\n"
    with pytest.raises(ValueError,match="ánh xạ"):
        worker.hosts_content(source+"192.0.2.4 web.example\n","old.example","web.example")


def test_rollback_on_hostnamectl_failure(tmp_path,monkeypatch):
    from pathlib import Path
    hosts=tmp_path/"etc/hosts"
    hosts.parent.mkdir();hosts.write_text("127.0.0.1 localhost\n")
    monkeypatch.setattr(worker,"Path",lambda path:tmp_path/path.lstrip("/") if str(path).startswith("/etc/") else Path(path))
    monkeypatch.setattr(worker.socket,"gethostname",lambda:"old")
    def ctl(*args):
        if len(args)==1:return "old"
        if args[-1]=="new":raise RuntimeError("set-hostname failed")
    monkeypatch.setattr(worker,"ctl",ctl)
    with pytest.raises(RuntimeError,match="set-hostname failed"):
        worker.rename("old","new",lambda msg:None)
    assert hosts.read_text()=="127.0.0.1 localhost\n"
    assert not (tmp_path/"etc/cloud/cloud.cfg.d/zz-zm-manager-hostname.cfg").exists()


def test_hostname_api_requires_session_csrf_and_confirmation(tmp_path):
    with TestClient(create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as client:
        path="/api/vps/machines/sample/hostname"
        body={"hostname":"web-01","expected":"old","confirmed":True}
        assert client.post(path,json=body).status_code==401
        auth=client.post("/api/auth/setup",json={"username":"admin","password":"fixture-pass"}).json()
        assert client.post(path,json=body).status_code==403
        client.headers["X-CSRF-Token"]=auth["csrf"]
        assert client.post(path,json={**body,"confirmed":False}).status_code==422
        assert client.post(path,json={**body,"hostname":";id"}).status_code==422
