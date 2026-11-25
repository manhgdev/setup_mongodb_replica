import pytest
from fastapi.testclient import TestClient

from apps.vps_manager.backend import firewall_service as svc, firewall_worker as fw, oci_firewall as oci
from apps.vps_manager.backend.app import create_app

UFW = """Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80                         ALLOW       Anywhere
8000:8100/tcp              ALLOW       10.0.0.0/8
22/tcp (v6)                ALLOW       Anywhere (v6)
"""


class Done:
    def __init__(self, out="", code=0):
        self.stdout, self.stderr, self.returncode = out, "", code


def test_ufw_parse_and_idempotent_open(monkeypatch):
    calls = []
    def run(args, timeout=30):
        calls.append(args)
        return Done(UFW if args[:2] == ["ufw", "status"] else "")
    monkeypatch.setattr(fw, "run", run)
    monkeypatch.setattr(fw.shutil, "which", lambda name: "/usr/sbin/" + name)
    monkeypatch.setattr(fw, "ssh_ports", lambda hint: [22])
    rules = fw.ufw_rules()["rules"]
    assert {"tcp", "udp"} == {r["proto"] for r in rules if r["min"] == 80}
    assert any(r["min"] == 8000 and r["source"] == "10.0.0.0/8" for r in rules)
    out = fw.change({"op": "open", "port": "80", "protocols": ["tcp", "udp"], "source": "any"})
    assert [r["status"] for r in out["results"]] == ["exists", "exists"]
    out = fw.change({"op": "open", "port": "443", "protocols": ["tcp"], "source": "203.0.113.0/24"})
    assert out["results"][0]["status"] == "created"
    assert ["ufw", "allow", "proto", "tcp", "from", "203.0.113.0/24", "to", "any", "port", "443"] in calls
    with pytest.raises(ValueError, match="SSH"):
        fw.change({"op": "close", "port": "20-30", "protocols": ["tcp"], "source": "any"})


def test_ssh_close_refused_by_service():
    machine = {"mode": "ssh", "port": 22}
    call = lambda action, params: {"ssh_ports": [22], "oracle": {"detected": False}}
    with pytest.raises(ValueError, match="SSH"):
        svc.run_change(machine, None, "m", dict(op="close", port="22", protocols=["tcp"], source="", layers=["ufw"]), call, lambda _: None)


def rule(proto, lo, hi, source="0.0.0.0/0", **extra):
    return dict({"id": "", "proto": proto, "min": lo, "max": hi, "source": source, "source_type": "CIDR_BLOCK", "container": "sl-1"}, **extra)


def test_detects_ufw_open_but_oracle_blocked():
    ufw = {"installed": True, "active": True, "rules": [dict(rule("tcp", 80, 80), action="allow")]}
    listening = [{"proto": "tcp", "port": 80, "process": "nginx", "local_only": False, "internal": True, "addresses": ["*"]}]
    rows = svc.build_rows(ufw, listening, [rule("tcp", 22, 22)], "host", probe=lambda host, port: "closed")
    row = next(r for r in rows if r["min"] == 80)
    assert (row["ufw"], row["oci"]) == ("open", "closed")
    assert "oci_blocked" in row["warnings"]


def test_oci_cover_dedupes_wider_sources_and_rejects_bad_input():
    vnic = {"security_lists": [{"rules": [rule("tcp", 1000, 2000, "10.0.0.0/8")]}], "nsgs": []}
    assert oci.find_cover(oci.all_rules(vnic), "tcp", 1500, 1600, "10.1.0.0/16")
    assert not oci.find_cover(oci.all_rules(vnic), "tcp", 1500, 1600, "0.0.0.0/0")
    assert not oci.find_cover(oci.all_rules(vnic), "udp", 1500, 1600, "10.1.0.0/16")
    with pytest.raises(ValueError):
        svc.parse_range("70000")
    with pytest.raises(ValueError):
        svc.parse_source("not-a-cidr")


def test_open_both_layers_and_failure_reporting(tmp_path, monkeypatch):
    from shared.manager_core.store import Store
    store = Store(tmp_path)
    store.save("oci-accounts", {"auth": "instance_principal", "name": "a", "region": "ap-singapore-1"}, "acc")
    store.save("oci-links", {"account_id": "acc", "region": ""}, "m")
    vnic = {"security_lists": [{"id": "sl", "name": "Default", "rules": []}], "nsgs": []}
    monkeypatch.setattr(svc, "cached_inspect", lambda *a, **k: {"vnics": [vnic]})
    added = []
    monkeypatch.setattr(oci, "add_rule", lambda *a: added.append(a) or {"layer": "oci", "status": "created", "detail": "ok"})
    def call(action, params):
        if action == "fw-info":
            return {"ssh_ports": [22], "oracle": {"detected": True, "region": "ap-singapore-1", "instance_id": "ocid1.instance.x"}}
        return {"results": [{"layer": "ufw", "status": "created", "detail": "ufw ok"}]}
    events = []
    out = svc.run_change({"mode": "ssh", "port": 22}, store, "m", dict(op="open", port="443", protocols=["tcp"], source="", layers=["ufw", "oci"]), call, events.append)
    assert [r["layer"] for r in out["results"]] == ["ufw", "oci"] and added[0][4:] == ("tcp", 443, 443, "0.0.0.0/0")
    with pytest.raises(ValueError, match="không phải Oracle"):
        svc.run_change({"mode": "ssh", "port": 22}, store, "m", dict(op="open", port="1", protocols=["tcp"], source="", layers=["oci"]),
                       lambda a, p: {"ssh_ports": [22], "oracle": {"detected": False}}, events.append)


def test_account_secrets_never_returned(tmp_path, monkeypatch):
    monkeypatch.setattr(oci, "key_fingerprint", lambda pem, pw="": "aa:bb")
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        assert client.get("/api/vps/oci/accounts").status_code == 401
        auth = client.post("/api/auth/setup", json={"username": "fixture", "password": "fixture-pass"}).json()
        client.headers["X-CSRF-Token"] = auth["csrf"]
        body = {"name": "main", "auth": "api_key", "region": "ap-singapore-1", "tenancy": "ocid1.tenancy.oc1..a", "user": "ocid1.user.oc1..b",
                "private_key": "-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----", "passphrase": "pp-secret"}
        saved = client.post("/api/vps/oci/accounts", json=body)
        assert saved.status_code == 201 and "SECRET" not in saved.text and saved.json()["has_key"]
        listing = client.get("/api/vps/oci/accounts")
        assert "SECRET" not in listing.text and "pp-secret" not in listing.text
        ident = saved.json()["id"]
        body["private_key"] = ""
        assert client.put("/api/vps/oci/accounts/" + ident, json=body).json()["has_key"]
        assert client.post("/api/vps/machines/none/firewall/change", json={"op": "open", "port": "80"}).status_code == 404



def test_generate_oci_keypair(tmp_path):
    with TestClient(create_app(tmp_path), base_url="http://127.0.0.1", headers={"X-MongoDB-Manager": "1"}) as client:
        auth = client.post("/api/auth/setup", json={"username": "fixture", "password": "fixture-pass"}).json()
        client.headers["X-CSRF-Token"] = auth["csrf"]
        res = client.post("/api/vps/oci/generate-key", json={})
        assert res.status_code == 200
        data = res.json()
        assert "BEGIN PRIVATE KEY" in data["private_key"]
        assert "BEGIN PUBLIC KEY" in data["public_key"]
        assert len(data["fingerprint"].split(":")) == 16
