from threading import Event
from fastapi.testclient import TestClient
from gateway.app import create_app
from apps.vps_manager.backend import app as vps


def test_two_views_share_login_machine_and_active_job(tmp_path, monkeypatch):
    started, finish = Event(), Event()

    def execute(machine, action, params, emit):
        started.set()
        finish.wait(5)
        return {"installed": True}

    monkeypatch.setattr(vps, "worker", execute)
    with TestClient(
        create_app(tmp_path),
        base_url="http://127.0.0.1",
        headers={"X-MongoDB-Manager": "1"},
    ) as client:
        assert client.get("/").status_code == client.get("/vps/").status_code == 200
        client.headers["X-CSRF-Token"] = client.post(
            "/api/auth/setup", json={"username": "operator", "password": "fixture-pass"}
        ).json()["csrf"]
        ident = client.post(
            "/api/vps/machines", json={"name": "Local", "mode": "local"}
        ).json()["id"]
        try:
            job = client.post(
                f"/api/vps/machines/{ident}/install", json={"packages": ["nginx"]}
            ).json()
            assert started.wait(2)
            assert client.get("/api/state").json()["jobs"][0]["id"] == job["id"]
            assert (
                client.get(f"/api/vps/machines/{ident}/jobs").json()[0]["id"]
                == job["id"]
            )
            preview = client.post(
                "/api/plans",
                json={
                    "action": "install",
                    "machine_id": ident,
                    "params": {"series": "9.0"},
                },
            )
            assert (
                preview.status_code == 409
                and preview.headers["X-Active-Job"] == job["id"]
            )
            conflict = client.post(
                f"/api/vps/machines/{ident}/install", json={"packages": ["git"]}
            )
            assert (
                conflict.status_code == 409
                and conflict.headers["X-Active-Job"] == job["id"]
            )
        finally:
            finish.set()


def test_login_assets_available_for_both_standalone_apps(tmp_path):
    from apps.mongodb_manager.backend.app import create_app as mongo_app

    for factory, stylesheet in [(mongo_app, "/static/styles.css"), (vps.create_app, "/vps/static/manager.css")]:
        with TestClient(factory(tmp_path), base_url="http://127.0.0.1") as client:
            assert "/manager-login/account.js" in client.get("/login").text
            assert client.get("/manager-login/account.js").status_code == 200
            assert client.get("/manager-login/session.js").status_code == 200
            css = client.get("/manager-login/styles.css")
            assert css.status_code == 200 and css.url.path == stylesheet
