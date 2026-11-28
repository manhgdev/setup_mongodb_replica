from shared.manager_core.store import Store, _MongoBackend, mask_uri, migrate_store


class _FakeCursor(list):
    pass


class _FakeCollection:
    def __init__(self):
        self.docs = {}

    def find_one(self, flt, proj=None):
        doc = self.docs.get(flt.get("_id"))
        if not doc:
            return None
        if proj:
            return {k: doc[k] for k in proj if k in doc}
        return dict(doc)

    def find(self, flt=None):
        return _FakeCursor(dict(d) for d in self.docs.values())

    def replace_one(self, flt, doc, upsert=False):
        self.docs[flt["_id"]] = dict(doc)

    def bulk_write(self, ops, ordered=False):
        for op in ops:
            self.docs[op._filter["_id"]] = dict(op._doc)

    def delete_one(self, flt):
        existed = flt["_id"] in self.docs
        self.docs.pop(flt["_id"], None)
        return type("Res", (), {"deleted_count": 1 if existed else 0})()

    def count_documents(self, flt=None):
        return len(self.docs)

    def drop(self):
        self.docs.clear()


class _FakeDB:
    def __init__(self):
        self.cols = {}

    def __getitem__(self, name):
        return self.cols.setdefault(name, _FakeCollection())

    def list_collection_names(self):
        return list(self.cols.keys())


class _FakeClient:
    def __init__(self):
        self.dbs = {}

    def __getitem__(self, name):
        return self.dbs.setdefault(name, _FakeDB())

    def close(self):
        pass


def test_mask_uri():
    assert mask_uri("mongodb://admin:supersecret@10.0.0.1:27017/zm_manager") == "mongodb://admin:•••@10.0.0.1:27017/zm_manager"
    assert mask_uri("mongodb://127.0.0.1:27017") == "mongodb://127.0.0.1:27017"


def test_mongo_backend_encrypts_secrets_and_migrates(tmp_path):
    store = Store(tmp_path)
    saved = store.save("machines", {"name": "vps-1", "host": "1.2.3.4", "ssh_password": "my-secret-pw"})
    assert saved["ssh_password"] == "my-secret-pw"

    fake_client = _FakeClient()
    mb = _MongoBackend("mongodb://localhost:27017", "zm_manager", store.cipher, client=fake_client)
    res = migrate_store(store.sqlite_backend(), mb)
    assert res["migrated"] == 1

    raw_doc = fake_client["zm_manager"]["machines"].docs[saved["id"]]
    assert raw_doc["name"] == "vps-1"
    assert raw_doc["ssh_password"].startswith("enc:")
    assert raw_doc["ssh_password"] != "my-secret-pw"

    decoded = mb.get("machines", saved["id"])
    assert decoded["ssh_password"] == "my-secret-pw"

    updated = mb.update_fields("machines", saved["id"], {"name": "vps-renamed"}, expected={"name": "vps-1"})
    assert updated["name"] == "vps-renamed"
    assert mb.update_fields("machines", saved["id"], {"name": "nope"}, expected={"name": "wrong"}) is None
    assert mb.delete("machines", saved["id"]) is True


def test_identity_file_resolves_db_ssh_key_across_multiple_stores(tmp_path):
    import pytest
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519
    from shared.manager_core.ssh_transport import identity_file, save_ssh_key_to_store
    from shared.manager_core.workspaces import use_store

    private_key = ed25519.Ed25519PrivateKey.generate()
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.OpenSSH,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")

    store_a = Store(tmp_path / "ws_a")
    saved = save_ssh_key_to_store(store_a, "ssh-key-test.key", pem)
    # Register another workspace store afterwards that does not contain the key.
    store_b = Store(tmp_path / "ws_b")
    assert store_b is not store_a

    with use_store(store_a, "ws_a"):
        with identity_file({"identity": saved["path"]}) as path:
            assert path is not None
            with open(path, "r", encoding="utf-8") as f:
                assert "BEGIN OPENSSH PRIVATE KEY" in f.read()

    # Without _ACTIVE_STORE set, fallback still finds key in store_a without crashing on store_b KeyError.
    with identity_file({"identity": saved["path"]}) as path:
        assert path is not None

    with pytest.raises(RuntimeError, match="Không tìm thấy SSH key"):
        with identity_file({"identity": "db://ssh-keys/key_missing000"}):
            pass
