import pytest


@pytest.fixture
def sign_in_new_manager():
    def sign_in(client):
        credentials = {"username": "testadmin", "password": "test-password"}
        assert client.post("/api/auth/setup", json=credentials).status_code == 200
        response = client.post("/api/auth/login", json=credentials)
        assert response.status_code == 200
        client.headers["X-CSRF-Token"] = response.json()["csrf"]
    return sign_in
