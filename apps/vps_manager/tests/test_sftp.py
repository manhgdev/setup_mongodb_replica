import io
import tarfile
import time
from fastapi.testclient import TestClient

from apps.vps_manager.backend.app import create_app


def _setup_client(tmp_path):
    app = create_app(tmp_path / "data")
    client = TestClient(app, base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"})
    client.__enter__()
    auth = client.post("/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}).json()
    client.headers["X-CSRF-Token"] = auth["csrf"]
    m1 = client.post("/api/vps/machines", json={"mode": "local", "name": "Local-A"}).json()["id"]
    m2 = client.post("/api/vps/machines", json={"mode": "local", "name": "Local-B"}).json()["id"]
    return client, m1, m2


def test_sftp_crud_editor_chmod_upload_download_and_transfer(tmp_path):
    root_a = tmp_path / "vps_a"
    root_b = tmp_path / "vps_b"
    root_a.mkdir()
    root_b.mkdir()
    (root_a / ".secret").write_text("hidden=1\n")

    client, m1, m2 = _setup_client(tmp_path)
    try:
        # 0. Built-in __local__ target works without a saved machine record
        local_list = client.get("/api/vps/machines/__local__/sftp/list", params={"path": str(root_a)})
        assert local_list.status_code == 200
        assert local_list.json()["cwd"] == str(root_a)

        # 1. List without & with hidden
        res = client.get(f"/api/vps/machines/{m1}/sftp/list", params={"path": str(root_a)}).json()
        assert res["cwd"] == str(root_a)
        assert [e["name"] for e in res["entries"]] == []

        res_hidden = client.get(
            f"/api/vps/machines/{m1}/sftp/list", params={"path": str(root_a), "show_hidden": "true"}
        ).json()
        assert [e["name"] for e in res_hidden["entries"]] == [".secret"]

        # 2. mkdir, touch, rename
        assert client.post(f"/api/vps/machines/{m1}/sftp/mkdir", json={"path": str(root_a / "app")}).status_code == 200
        assert client.post(f"/api/vps/machines/{m1}/sftp/touch", json={"path": str(root_a / "app/run.sh")}).status_code == 200
        assert (
            client.post(
                f"/api/vps/machines/{m1}/sftp/rename",
                json={"old_path": str(root_a / "app/run.sh"), "new_path": str(root_a / "app/start.sh")},
            ).status_code
            == 200
        )
        assert (root_a / "app/start.sh").is_file()

        # 3. Read/write text file + binary guard
        assert (
            client.put(
                f"/api/vps/machines/{m1}/sftp/file",
                json={"path": str(root_a / "app/start.sh"), "content": "#!/bin/bash\necho ok\n"},
            ).status_code
            == 200
        )
        opened = client.get(f"/api/vps/machines/{m1}/sftp/file", params={"path": str(root_a / "app/start.sh")}).json()
        assert "echo ok" in opened["content"]

        (root_a / "bin.dat").write_bytes(b"\x00\x01\x02")
        assert client.get(f"/api/vps/machines/{m1}/sftp/file", params={"path": str(root_a / "bin.dat")}).status_code == 422

        # 4. Chmod + invalid mode
        ch = client.post(
            f"/api/vps/machines/{m1}/sftp/chmod", json={"path": str(root_a / "app/start.sh"), "mode": "0755"}
        )
        assert ch.status_code == 200
        assert ch.json()["octal"] == "0755"
        assert (
            client.post(
                f"/api/vps/machines/{m1}/sftp/chmod", json={"path": str(root_a / "app/start.sh"), "mode": "999"}
            ).status_code
            == 422
        )

        # 5. Stream upload & download (single file + folder tar.gz)
        up = client.post(
            f"/api/vps/machines/{m1}/sftp/upload",
            params={"path": str(root_a / "app"), "filename": "config.json"},
            content=b'{"port": 8080}',
        )
        assert up.status_code == 200
        assert up.json()["size"] == 14

        dl_file = client.get(f"/api/vps/machines/{m1}/sftp/download", params={"paths": [str(root_a / "app/config.json")]})
        assert dl_file.status_code == 200
        assert dl_file.content == b'{"port": 8080}'

        dl_dir = client.get(f"/api/vps/machines/{m1}/sftp/download", params={"paths": [str(root_a / "app")]})
        assert dl_dir.status_code == 200
        with tarfile.open(fileobj=io.BytesIO(dl_dir.content), mode="r:gz") as tar:
            names = tar.getnames()
            assert "app/config.json" in names
            assert "app/start.sh" in names

        # 6. Cross-machine copy transfer
        xfer = client.post(
            "/api/vps/sftp/transfer",
            json={
                "source_machine": m1,
                "target_machine": m2,
                "paths": [str(root_a / "app")],
                "target_dir": str(root_b),
                "op": "copy",
            },
        )
        assert xfer.status_code == 202
        tid = xfer.json()["id"]
        for _ in range(40):
            st = client.get(f"/api/vps/sftp/transfers/{tid}").json()
            if st["status"] != "running":
                break
            time.sleep(0.05)
        assert st["status"] == "succeeded"
        assert (root_b / "app/config.json").read_text() == '{"port": 8080}'

        # 7. Delete recursive + root guard
        assert client.post(f"/api/vps/machines/{m1}/sftp/delete", json={"paths": ["/"]}).status_code == 422
        assert (
            client.post(f"/api/vps/machines/{m1}/sftp/delete", json={"paths": [str(root_a / "app")]}).status_code
            == 200
        )
        assert not (root_a / "app").exists()
    finally:
        client.__exit__(None, None, None)
