import json
import os
import sqlite3
from pathlib import Path
from uuid import uuid4

from cryptography.fernet import Fernet


class Store:
    def __init__(self, directory):
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
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS records (kind TEXT, id TEXT, value TEXT, PRIMARY KEY(kind,id))")
        os.chmod(self.path, 0o600)

    def rename_generated_machines(self):
        machines = self.all("machines")
        for profile in self.all("profiles"):
            group = [m for m in machines if m.get("profile_id") == profile["id"]]
            used = {m["name"] for m in group}
            number = 1
            for machine in group:
                if machine["name"] != f"{profile['name']} · {machine['host']}":
                    continue
                while f"mongo-{number:02}" in used:
                    number += 1
                name = f"mongo-{number:02}"
                self.update_fields("machines", machine["id"], {"name": name}, expected={"name": machine["name"]})
                used.add(name)

    def connect(self):
        return sqlite3.connect(self.path, timeout=10)

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
        """Commit a cluster and its SSH machine associations together."""
        saved = []
        with self.connect() as db:
            for kind, value, record_id in records:
                record_id = record_id or uuid4().hex
                value = dict(value, id=record_id)
                encoded = self.cipher.encrypt(json.dumps(value, ensure_ascii=False, default=str).encode()).decode()
                db.execute('INSERT OR REPLACE INTO records VALUES (?,?,?)', (kind, record_id, encoded))
                saved.append(value)
        return saved

    def get(self, kind, record_id):
        with self.connect() as db:
            row = db.execute("SELECT value FROM records WHERE kind=? AND id=?", (kind, record_id)).fetchone()
        if not row:
            raise KeyError("Không tìm thấy hồ sơ hoặc tác vụ.")
        return json.loads(self.cipher.decrypt(row[0].encode()))

    def delete(self, kind, record_id):
        with self.connect() as db:
            db.execute("DELETE FROM records WHERE kind=? AND id=?", (kind, record_id))
            if kind == "profiles":
                db.execute("DELETE FROM records WHERE kind=?", ("user-passwords:" + record_id,))

    def update_fields(self, kind, record_id, changes, expected=None):
        """Merge topology metadata without replacing concurrent connection edits."""
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT value FROM records WHERE kind=? AND id=?', (kind, record_id)).fetchone()
            if not row:
                return None
            current = json.loads(self.cipher.decrypt(row[0].encode()))
            if expected and any(current.get(k) != v for k, v in expected.items()):
                return None
            current.update(changes)
            encoded = self.cipher.encrypt(json.dumps(current, ensure_ascii=False, default=str).encode()).decode()
            db.execute('UPDATE records SET value=? WHERE kind=? AND id=?', (encoded, kind, record_id))
            return current
