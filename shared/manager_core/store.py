import json
import os
import re
import sqlite3
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4

from cryptography.fernet import Fernet, InvalidToken

SECRET_FIELDS = frozenset({
    "ssh_password",
    "password",
    "private_key",
    "token",
    "recovery_code",
    "secret",
    "password_hash",
})
ENC_PREFIX = "enc:"


def mask_uri(uri: str) -> str:
    if not uri:
        return ""
    return re.sub(r"^(mongodb(?:\+srv)?://[^:/@]+):[^@]+@", r"\1:•••@", uri)


def _collection_name(kind: str) -> str:
    clean = re.sub(r"[^a-zA-Z0-9_]+", "_", (kind or "records").strip()).strip("_")
    return clean or "records"


def _encrypt_secrets(obj, cipher: Fernet):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in SECRET_FIELDS and isinstance(v, str) and v and not v.startswith(ENC_PREFIX):
                out[k] = ENC_PREFIX + cipher.encrypt(v.encode("utf-8")).decode("utf-8")
            else:
                out[k] = _encrypt_secrets(v, cipher)
        return out
    if isinstance(obj, list):
        return [_encrypt_secrets(item, cipher) for item in obj]
    return obj


def _decrypt_secrets(obj, cipher: Fernet):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in SECRET_FIELDS and isinstance(v, str) and v.startswith(ENC_PREFIX):
                try:
                    out[k] = cipher.decrypt(v[len(ENC_PREFIX):].encode("utf-8")).decode("utf-8")
                except InvalidToken:
                    out[k] = ""
            else:
                out[k] = _decrypt_secrets(v, cipher)
        return out
    if isinstance(obj, list):
        return [_decrypt_secrets(item, cipher) for item in obj]
    return obj


class _SqliteBackend:
    def __init__(self, path: Path, cipher: Fernet):
        self.path = path
        self.cipher = cipher
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS records (kind TEXT, id TEXT, value TEXT, PRIMARY KEY(kind,id))")
        os.chmod(self.path, 0o600)

    def connect(self):
        return sqlite3.connect(self.path, timeout=10)

    def list_kinds(self):
        with self.connect() as db:
            rows = db.execute("SELECT DISTINCT kind FROM records").fetchall()
        return [r[0] for r in rows]

    def count_all(self):
        with self.connect() as db:
            row = db.execute("SELECT COUNT(*) FROM records").fetchone()
        return int(row[0]) if row else 0

    def save(self, kind, value, record_id=None):
        record_id = record_id or uuid4().hex
        value = dict(value, id=record_id)
        encoded = self.cipher.encrypt(json.dumps(value, ensure_ascii=False, default=str).encode()).decode()
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO records VALUES (?,?,?)", (kind, record_id, encoded))
        return value

    def all(self, kind):
        with self.connect() as db:
            rows = db.execute("SELECT value FROM records WHERE kind=? ORDER BY rowid", (kind,)).fetchall()
        return [json.loads(self.cipher.decrypt(row[0].encode())) for row in rows]

    def save_many(self, records):
        saved = []
        with self.connect() as db:
            for kind, value, record_id in records:
                record_id = record_id or uuid4().hex
                value = dict(value, id=record_id)
                encoded = self.cipher.encrypt(json.dumps(value, ensure_ascii=False, default=str).encode()).decode()
                db.execute("INSERT OR REPLACE INTO records VALUES (?,?,?)", (kind, record_id, encoded))
                saved.append(value)
        return saved

    def get(self, kind, record_id):
        with self.connect() as db:
            row = db.execute("SELECT value FROM records WHERE kind=? AND id=?", (kind, record_id)).fetchone()
        if not row:
            raise KeyError("Không tìm thấy hồ sơ hoặc tác vụ.")
        return json.loads(self.cipher.decrypt(row[0].encode()))

    def delete(self, kind, record_id, expected=None):
        with self.connect() as db:
            if expected is not None:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT value FROM records WHERE kind=? AND id=?", (kind, record_id)).fetchone()
                if not row or json.loads(self.cipher.decrypt(row[0].encode())) != expected:
                    return False
            deleted = db.execute("DELETE FROM records WHERE kind=? AND id=?", (kind, record_id)).rowcount
            if kind == "profiles":
                db.execute("DELETE FROM records WHERE kind=?", ("user-passwords:" + record_id,))
            return bool(deleted)

    def update_fields(self, kind, record_id, changes, expected=None):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT value FROM records WHERE kind=? AND id=?", (kind, record_id)).fetchone()
            if not row:
                return None
            current = json.loads(self.cipher.decrypt(row[0].encode()))
            if expected and any(current.get(k) != v for k, v in expected.items()):
                return None
            current.update(changes)
            encoded = self.cipher.encrypt(json.dumps(current, ensure_ascii=False, default=str).encode()).decode()
            db.execute("UPDATE records SET value=? WHERE kind=? AND id=?", (encoded, kind, record_id))
            return current


class _MongoBackend:
    """Mongoose-style MongoDB document backend storing each `kind` as its own collection."""

    def __init__(self, uri: str, database: str, cipher: Fernet, client=None):
        from pymongo import MongoClient

        self.uri = uri
        self.database_name = (database or "zm_manager").strip() or "zm_manager"
        self.cipher = cipher
        self.client = client or MongoClient(uri, serverSelectionTimeoutMS=5000, connectTimeoutMS=5000)
        self.db = self.client[self.database_name]
        self._cache_lock = threading.RLock()
        self._all_cache = {}
        self._item_cache = {}

    def _invalidate(self, kind: str = None):
        with self._cache_lock:
            if kind is None:
                self._all_cache.clear()
                self._item_cache.clear()
            else:
                self._all_cache.pop(kind, None)
                for k in [key for key in self._item_cache if key[0] == kind]:
                    self._item_cache.pop(k, None)

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass

    def _col(self, kind: str):
        return self.db[_collection_name(kind)]

    def _prepare_doc(self, kind: str, value: dict, record_id: str) -> dict:
        clean = json.loads(json.dumps(dict(value, id=record_id), ensure_ascii=False, default=str))
        encrypted = _encrypt_secrets(clean, self.cipher)
        encrypted["_id"] = record_id
        encrypted["_kind"] = kind
        return encrypted

    def _decode_doc(self, doc: dict) -> dict:
        out = {k: v for k, v in doc.items() if k not in ("_id", "_kind")}
        return _decrypt_secrets(out, self.cipher)

    def list_kinds(self):
        kinds = []
        for name in self.db.list_collection_names():
            if name.startswith("system.") or name == "_zm_probe":
                continue
            sample = self.db[name].find_one({}, {"_kind": 1})
            kinds.append(sample["_kind"] if sample and "_kind" in sample else name)
        return kinds

    def count_all(self):
        total = 0
        for name in self.db.list_collection_names():
            if name.startswith("system.") or name == "_zm_probe":
                continue
            total += self.db[name].count_documents({})
        return total

    def save(self, kind, value, record_id=None):
        record_id = record_id or uuid4().hex
        doc = self._prepare_doc(kind, value, record_id)
        self._col(kind).replace_one({"_id": record_id}, doc, upsert=True)
        self._invalidate(kind)
        return dict(value, id=record_id)

    def all(self, kind):
        now = time.monotonic()
        with self._cache_lock:
            cached = self._all_cache.get(kind)
            if cached and cached[0] > now:
                return [dict(item) for item in cached[1]]
        docs = [self._decode_doc(d) for d in self._col(kind).find({})]
        with self._cache_lock:
            self._all_cache[kind] = (time.monotonic() + 8.0, docs)
            for item in docs:
                if "id" in item:
                    self._item_cache[(kind, item["id"])] = (time.monotonic() + 8.0, item)
        return [dict(item) for item in docs]

    def save_many(self, records):
        from pymongo import ReplaceOne

        saved = []
        grouped = {}
        for kind, value, record_id in records:
            record_id = record_id or uuid4().hex
            doc = self._prepare_doc(kind, value, record_id)
            grouped.setdefault(kind, []).append(ReplaceOne({"_id": record_id}, doc, upsert=True))
            saved.append(dict(value, id=record_id))
        for kind, ops in grouped.items():
            if ops:
                self._col(kind).bulk_write(ops, ordered=False)
                self._invalidate(kind)
        return saved

    def get(self, kind, record_id):
        now = time.monotonic()
        with self._cache_lock:
            cached = self._item_cache.get((kind, record_id))
            if cached and cached[0] > now:
                return dict(cached[1])
        doc = self._col(kind).find_one({"_id": record_id})
        if not doc:
            raise KeyError("Không tìm thấy hồ sơ hoặc tác vụ.")
        decoded = self._decode_doc(doc)
        with self._cache_lock:
            self._item_cache[(kind, record_id)] = (time.monotonic() + 8.0, decoded)
        return dict(decoded)

    def delete(self, kind, record_id, expected=None):
        if expected is not None:
            doc = self._col(kind).find_one({"_id": record_id})
            if not doc or self._decode_doc(doc) != expected:
                return False
        res = self._col(kind).delete_one({"_id": record_id})
        self._invalidate(kind)
        if kind == "profiles":
            self.db[_collection_name("user-passwords:" + record_id)].drop()
            self._invalidate("user-passwords:" + record_id)
        return bool(res.deleted_count)

    def update_fields(self, kind, record_id, changes, expected=None):
        col = self._col(kind)
        doc = col.find_one({"_id": record_id})
        if not doc:
            return None
        current = self._decode_doc(doc)
        if expected and any(current.get(k) != v for k, v in expected.items()):
            return None
        current.update(changes)
        updated_doc = self._prepare_doc(kind, current, record_id)
        col.replace_one({"_id": record_id}, updated_doc, upsert=True)
        self._invalidate(kind)
        return current


class _DualBackend:
    """Dual-write backend: reads from MongoDB (with SQLite fallback) and mirrors all writes to both."""

    def __init__(self, mongo: _MongoBackend, sqlite: _SqliteBackend):
        self.mongo = mongo
        self.sqlite = sqlite

    def save(self, kind, value, record_id=None):
        res = self.mongo.save(kind, value, record_id)
        self.sqlite.save(kind, res, res["id"])
        return res

    def all(self, kind):
        return self.mongo.all(kind)

    def save_many(self, records):
        saved = self.mongo.save_many(records)
        normalized = [(kind, val, val["id"]) for (kind, _, _), val in zip(records, saved)]
        if normalized:
            self.sqlite.save_many(normalized)
        return saved

    def get(self, kind, record_id):
        return self.mongo.get(kind, record_id)

    def delete(self, kind, record_id, expected=None):
        ok = self.mongo.delete(kind, record_id, expected)
        if ok or expected is None:
            self.sqlite.delete(kind, record_id)
        return ok

    def update_fields(self, kind, record_id, changes, expected=None):
        res = self.mongo.update_fields(kind, record_id, changes, expected)
        if res is not None:
            self.sqlite.save(kind, res, record_id)
        return res


def test_mongo_storage(uri: str, database: str = "zm_manager", client=None) -> dict:
    from pymongo import MongoClient

    own_client = client is None
    mc = client or MongoClient(uri, serverSelectionTimeoutMS=5000, connectTimeoutMS=5000)
    try:
        t0 = time.monotonic()
        info = mc.admin.command("ping")
        if not info.get("ok"):
            raise RuntimeError("MongoDB ping thất bại.")
        build = mc.admin.command("buildInfo")
        db_name = (database or "zm_manager").strip() or "zm_manager"
        db = mc[db_name]
        probe_id = f"probe_{uuid4().hex[:8]}"
        db["_zm_probe"].replace_one({"_id": probe_id}, {"_id": probe_id, "ok": True}, upsert=True)
        db["_zm_probe"].delete_one({"_id": probe_id})
        cols = [c for c in db.list_collection_names() if not c.startswith("system.") and c != "_zm_probe"]
        return {
            "ok": True,
            "database": db_name,
            "version": build.get("version", ""),
            "latency_ms": round((time.monotonic() - t0) * 1000, 1),
            "collections": cols,
        }
    finally:
        if own_client:
            mc.close()


def migrate_store(source, target) -> dict:
    """Copy all records from source backend into target backend (idempotent upsert)."""
    total = 0
    kinds = source.list_kinds()
    batch = []
    for kind in kinds:
        for item in source.all(kind):
            batch.append((kind, item, item.get("id")))
            total += 1
    if batch:
        target.save_many(batch)
    return {"migrated": total, "kinds": len(kinds)}


class Store:
    def __init__(self, directory, app_name: str = "shared"):
        self.app_name = app_name
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        key = self.directory / "secret.key"
        if not key.exists():
            fd = os.open(key, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "wb") as output:
                output.write(Fernet.generate_key())
        self.cipher = Fernet(key.read_bytes())
        self.path = self.directory / "manager.sqlite3"
        self.config_path = self.directory / "storage_config.json"
        self._lock = threading.RLock()
        self._config_mtime = None
        self._sqlite = _SqliteBackend(self.path, self.cipher)
        self._mongo = None
        self._active = self._sqlite
        self._backend_name = "sqlite"
        self.reload()

    def _read_config(self) -> dict:
        if not self.config_path.exists():
            return {"backend": "sqlite", "database": "zm_manager", "mongo_uri_enc": ""}
        try:
            return json.loads(self.config_path.read_text(encoding="utf-8"))
        except Exception:
            return {"backend": "sqlite", "database": "zm_manager", "mongo_uri_enc": ""}

    def _write_config(self, cfg: dict):
        fd = os.open(self.config_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        os.chmod(self.config_path, 0o600)

    def _decrypt_uri(self, cfg: dict) -> str:
        enc = cfg.get("mongo_uri_enc") or ""
        if not enc:
            return ""
        try:
            return self.cipher.decrypt(enc.encode("utf-8")).decode("utf-8")
        except Exception:
            return ""

    def _effective_cfg(self, cfg: dict) -> dict:
        apps = cfg.get("apps") or {}
        if self.app_name in apps:
            return apps[self.app_name]
        return cfg

    def reload(self):
        with self._lock:
            self._config_mtime = self.config_path.stat().st_mtime if self.config_path.exists() else None
            cfg = self._effective_cfg(self._read_config())
            if self._mongo is not None:
                self._mongo.close()
                self._mongo = None
            uri = self._decrypt_uri(cfg)
            if cfg.get("backend") == "mongodb" and uri:
                self._mongo = _MongoBackend(uri, cfg.get("database") or "zm_manager", self.cipher)
                self._active = self._mongo
                self._backend_name = "mongodb"
            else:
                self._active = self._sqlite
                self._backend_name = "sqlite"

    def storage_info(self) -> dict:
        cfg = self._effective_cfg(self._read_config())
        uri = self._decrypt_uri(cfg)
        info = {
            "app_name": self.app_name,
            "backend": self._backend_name,
            "database": cfg.get("database") or "zm_manager",
            "has_uri": bool(uri),
            "uri_masked": mask_uri(uri),
            "sqlite_count": self._sqlite.count_all(),
            "mongo_count": None,
        }
        if self._mongo is not None:
            try:
                info["mongo_count"] = self._mongo.count_all()
            except Exception:
                info["mongo_count"] = None
        return info

    def save_storage_config(self, backend: str, uri: str = "", database: str = "zm_manager", scope: str = "both"):
        raw = self._read_config()
        cur = self._effective_cfg(raw)
        entry = {
            "backend": backend,
            "database": (database or "zm_manager").strip() or "zm_manager",
            "mongo_uri_enc": self.cipher.encrypt(uri.strip().encode("utf-8")).decode("utf-8") if uri else (cur.get("mongo_uri_enc") or ""),
        }
        apps = dict(raw.get("apps") or {})
        if scope == "both":
            apps["mongo"] = dict(entry)
            apps["vps"] = dict(entry)
            raw = {**entry, "apps": apps}
        else:
            apps[self.app_name] = dict(entry)
            raw["apps"] = apps
        self._write_config(raw)
        self.reload()

    def get_mongo_backend(self, uri: str = "", database: str = "") -> _MongoBackend:
        cfg = self._effective_cfg(self._read_config())
        real_uri = (uri or "").strip() or self._decrypt_uri(cfg)
        real_db = (database or "").strip() or cfg.get("database") or "zm_manager"
        if not real_uri:
            raise ValueError("Chưa nhập chuỗi kết nối MongoDB (URI).")
        return _MongoBackend(real_uri, real_db, self.cipher)

    def sqlite_backend(self) -> _SqliteBackend:
        return self._sqlite

    def _ensure_fresh(self):
        mtime = self.config_path.stat().st_mtime if self.config_path.exists() else None
        if mtime != self._config_mtime:
            self.reload()

    def connect(self):
        return self._sqlite.connect()

    def save(self, kind, value, record_id=None):
        self._ensure_fresh()
        return self._active.save(kind, value, record_id)

    def all(self, kind):
        self._ensure_fresh()
        return self._active.all(kind)

    def save_many(self, records):
        self._ensure_fresh()
        return self._active.save_many(records)

    def get(self, kind, record_id):
        self._ensure_fresh()
        return self._active.get(kind, record_id)

    def delete(self, kind, record_id, expected=None):
        self._ensure_fresh()
        return self._active.delete(kind, record_id, expected)

    def update_fields(self, kind, record_id, changes, expected=None):
        self._ensure_fresh()
        return self._active.update_fields(kind, record_id, changes, expected)
