"""Opt-in integration with disposable replica sets and MongoDB Database Tools."""
import json
import os
import secrets
import shutil
import socket
import subprocess
from contextlib import ExitStack

import pytest
from pymongo import MongoClient

from apps.mongodb_manager.backend import host_worker, operations
from test_live_mongo import wait_for


def test_transfer_fresh_and_archived_data(tmp_path, monkeypatch):
    binary = os.environ.get("MONGO_TEST_MONGOD")
    if not binary or not all(shutil.which(tool) for tool in ("mongodump", "mongorestore")):
        pytest.skip("Set MONGO_TEST_MONGOD and put MongoDB Database Tools on PATH")
    backups = tmp_path / "backups"
    backups.mkdir()
    monkeypatch.setattr(host_worker, "backups_root", lambda create=True: backups)
    monkeypatch.setattr(operations, "host_run", lambda machine, action, params, emit: getattr(host_worker, action)(params))
    keyfile = tmp_path / "keyfile"
    keyfile.write_text(secrets.token_hex(64))
    keyfile.chmod(0o400)
    password = secrets.token_urlsafe(24)
    with ExitStack() as stack:
        def start(name):
            data = tmp_path / name
            data.mkdir()
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            host = f"127.0.0.1:{port}"
            proc = subprocess.Popen([binary, "--dbpath", str(data), "--bind_ip", "127.0.0.1", "--port", str(port),
                                     "--replSet", name, "--keyFile", str(keyfile), "--auth", "--oplogSize", "64", "--wiredTigerCacheSizeGB", "0.25",
                                     "--logpath", str(data / "mongod.log")], stdout=subprocess.DEVNULL)
            stack.callback(proc.wait, timeout=30)
            stack.callback(proc.terminate)
            db = stack.enter_context(MongoClient(host, directConnection=True, serverSelectionTimeoutMS=500))
            wait_for(lambda: db.admin.command("ping"))
            db.admin.command("replSetInitiate", {"_id": name, "members": [{"_id": 0, "host": host}]})
            wait_for(lambda: db.admin.command("hello").get("isWritablePrimary"))
            db.admin.command("createUser", "archiver", pwd=password, roles=[{"role":"root","db":"admin"}])
            authenticated = stack.enter_context(MongoClient(host, replicaSet=name, username="archiver", password=password))
            authenticated.admin.command("createRole", "oplogTest", privileges=[{"resource":{"anyResource":True},"actions":["anyAction"]}], roles=[])
            authenticated.admin.command("grantRolesToUser", "archiver", roles=["oplogTest"])
            return authenticated, dict(id=name, name=name, seeds=[host], replica_set=name, username="archiver", password=password, auth_db="admin")

        source, src = start("source")
        target, dst = start("destination")
        for name in ("orders", "customers", "unselected"):
            source[name].items.insert_one({"_id": "a", "value": 1})
        def run(action, params, profile):
            return operations.execute(action, params, profile, {}, lambda message: None)
        archive = run("backup", {"databases": ["orders", "customers"]}, src)
        last_part = backups / archive["id"] / archive["archives"][-1]["file"]
        original = last_part.read_bytes()
        last_part.write_bytes(original + b"damaged")
        with pytest.raises(RuntimeError, match="Checksum"):
            run("restore", {"backup_id": archive["id"]}, dst)
        assert target.orders.items.count_documents({}) == 0
        last_part.write_bytes(original)
        run("restore", {"backup_id": archive["id"]}, dst)
        assert target.customers.items.count_documents({}) == 1
        assert target.orders.items.find_one()["value"] == 1
        assert target.unselected.items.count_documents({}) == 0
        legacy = run("backup", {"database": "orders", "collection": "items"}, src)
        part = legacy.pop("archives")[0]
        folder = backups / legacy["id"]
        (folder / part["file"]).rename(folder / "backup.archive.gz")
        legacy["sha256"] = part["sha256"]
        (folder / "manifest.json").write_text(json.dumps(legacy))
        run("restore", {"backup_id": legacy["id"], "drop": True}, dst)
        assert target.orders.items.find_one()["value"] == 1
        source.orders.items.update_one({}, {"$set": {"value": 2}})
        run("sync_backup", {"_destination": dst, "databases": ["orders"], "drop": True}, src)
        assert target.orders.items.find_one()["value"] == 2
        assert target.customers.items.count_documents({}) == 1
        source.orders.notes.insert_one({"_id": 1})
        source.orders.omitted.insert_one({"_id": 2})
        subset = run("backup", {"databases": ["orders"], "collections": ["items", "notes"]}, src)
        assert [part["collection"] for part in subset["archives"]] == ["items", "notes"]
        run("restore", {"backup_id": subset["id"], "drop": True}, dst)
        run("restore", {"backup_id": subset["id"], "drop": False}, dst)
        target.orders.notes.update_one({"_id": 1}, {"$set": {"local": True}})
        with pytest.raises(RuntimeError, match="khác bản backup"):
            run("restore", {"backup_id": subset["id"], "drop": False}, dst)
        assert target.orders.notes.find_one({"_id": 1})["local"] is True
        assert target.orders.notes.count_documents({}) == 1
        assert "omitted" not in target.orders.list_collection_names()
        applications = run("backup", {"application_only": True}, src)
        assert applications["databases"] == ["customers", "orders", "unselected"]
        source.orders.pages.insert_many([{"_id": i} for i in range(28)])
        paged = run("backup", {"database":"orders", "collection":"pages"}, src)
        def verify_preview(backup_id):
            args = {"backup_id":backup_id}
            assert ("orders","pages") in host_worker.preview_backup(args)["namespaces"]
            args.update(database="orders",collection="pages")
            first = host_worker.preview_backup(args)
            second = host_worker.preview_backup(dict(args,offset=25))
            assert len(first["records"]) == 25 and first["more"]
            assert len(second["records"]) == 3 and not second["more"]
        verify_preview(paged["id"])
        archive = run("backup", {}, src)
        verify_preview(archive["id"])
        assert archive["oplog"]
        run("restore", {"backup_id": archive["id"], "drop": True}, dst)
        with operations.client(dst) as reconnected:
            assert reconnected.unselected.items.count_documents({}) == 1
