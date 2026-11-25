import base64
import subprocess
import time

import pytest
from fastapi.testclient import TestClient
from apps.vps_manager.backend import git_worker as worker
from apps.vps_manager.backend import app as backend


def test_public_import_preserves_files_and_hides_comments(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    fixture = tmp_path/"fixture"
    subprocess.run(["ssh-keygen","-q","-t","ed25519","-N","","-f",str(fixture)],check=True)
    public = fixture.with_suffix(".pub").read_text().split()
    params = dict(name="release",public_key=" ".join(public[:2]+["sensitive-comment"]))
    worker.apply("import",params)
    with pytest.raises(ValueError,match="tồn tại"):
        worker.apply("import",params)
    ssh = tmp_path/".ssh"
    (ssh/"linked.pub").symlink_to(fixture)
    (ssh/"private.pub").write_bytes(fixture.read_bytes())
    state = worker.apply("status",{})
    assert [(key["name"],key["paired"]) for key in state["keys"]]==[("release",False)]
    assert "PRIVATE KEY" not in str(state) and "sensitive-comment" not in str(state)
    with pytest.raises(ValueError,match="thay đổi"):
        worker.apply("delete",dict(name="release",fingerprint="stale"))
    worker.apply("delete",dict(name="release",fingerprint=state["keys"][0]["fingerprint"]))
    assert (ssh/"linked.pub").is_symlink() and fixture.is_file()
    assert not (ssh/"config").exists()


@pytest.mark.parametrize("name",["../outside","config","authorized_keys","known_hosts","other.pub","$(id)"])
def test_reserved_names(name):
    with pytest.raises(ValueError):
        worker.safe_name(name)


def test_provider_rejects_untrusted_key_before_auth(monkeypatch):
    tag=b"ssh-ed25519"
    blob=len(tag).to_bytes(4,"big")+tag+b"fixture"
    row="github.com ssh-ed25519 "+base64.b64encode(blob).decode()
    def scan(*args,**kwargs):
        assert args[0]=="ssh-keyscan"
        return subprocess.CompletedProcess(args,0,stdout=row,stderr="")
    monkeypatch.setattr(worker,"command",scan)
    with pytest.raises(ValueError,match="Fingerprint SSH"):
        worker.test_connection("github.com","unused",{})


def test_key_job_auth_and_secret_redaction(tmp_path,monkeypatch):
    secret="fixture-only-phrase"
    def transport(machine,worker_path,payload,elevated,emit):
        assert not elevated and payload["params"]["passphrase"]==secret
        emit("Tạo cặp SSH key")
        return {}
    monkeypatch.setattr(backend,"run_worker",transport)
    with TestClient(backend.create_app(tmp_path),base_url="http://127.0.0.1",headers={"X-MongoDB-Manager":"1"}) as c:
        assert c.get("/api/vps/machines/local/git/status").status_code==401
        auth=c.post("/api/auth/setup",json={"username":"admin","password":"fixture-pass"}).json()
        assert c.post("/api/vps/machines/local/git/create",json={}).status_code==403
        c.headers["X-CSRF-Token"]=auth["csrf"]
        machine=c.post("/api/vps/machines",json={"name":"sample","host":"example.test"}).json()["id"]
        job=c.post(f"/api/vps/machines/{machine}/git/create",json={"name":"release","passphrase":secret})
        assert job.status_code==202 and secret not in job.text
        for _ in range(100):
            result=c.get("/api/vps/jobs/"+job.json()["id"]).json()
            if result["status"]=="succeeded":
                break
            time.sleep(.02)
        assert result["status"]=="succeeded" and secret not in str(result)


def test_recover_missing_public_file(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME",str(tmp_path))
    ssh=tmp_path/".ssh"
    ssh.mkdir(mode=0o700)
    key=ssh/"id_work"
    subprocess.run(["ssh-keygen","-q","-t","ed25519","-N","","-f",str(key)],check=True)
    pub=key.with_suffix(".pub")
    original=worker.public(pub)
    pub.unlink()
    assert worker.apply("status",{})["missing_public"]==["id_work"]
    worker.apply("restore-public",{"name":"id_work"})
    assert worker.public(pub)["fingerprint"]==original["fingerprint"]
