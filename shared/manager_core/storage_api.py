"""Shared FastAPI routes for inspecting, testing, migrating, and switching app storage (SQLite <-> MongoDB)."""
from urllib.parse import quote
from fastapi import HTTPException, Request
from pydantic import BaseModel, Field
from typing import Literal

from .store import mask_uri, migrate_store, test_mongo_storage
from .workspaces import current_store


def _profile_uri(profile: dict) -> str:
    seeds = ",".join(profile.get("seeds") or [])
    if not seeds:
        raise ValueError("Cụm MongoDB chưa có seed list.")
    options = []
    if profile.get("username"):
        options.append("authSource=" + quote(profile.get("auth_db") or "admin", safe=""))
    if profile.get("replica_set"):
        options.append("replicaSet=" + quote(profile["replica_set"], safe=""))
    if profile.get("tls"):
        options.append("tls=true")
    auth = ""
    if profile.get("username"):
        u = quote(profile["username"], safe="")
        p = quote(profile.get("password") or "", safe="")
        auth = f"{u}:{p}@" if p else f"{u}@"
    qs = ("?" + "&".join(options)) if options else ""
    return f"mongodb://{auth}{seeds}/{qs}"


class StorageTestRequest(BaseModel):
    uri: str = Field(default="", max_length=2048)
    database: str = Field(default="zm_manager", max_length=128)
    profile_id: str = Field(default="", max_length=64)


class StorageSwitchRequest(BaseModel):
    backend: Literal["sqlite", "mongodb"]
    uri: str = Field(default="", max_length=2048)
    database: str = Field(default="zm_manager", max_length=128)
    profile_id: str = Field(default="", max_length=64)
    auto_sync: bool = True
    scope: Literal["both", "single"] = "both"


class StorageMigrateRequest(BaseModel):
    direction: Literal["sqlite_to_mongo", "mongo_to_sqlite"] = "sqlite_to_mongo"
    uri: str = Field(default="", max_length=2048)
    database: str = Field(default="zm_manager", max_length=128)
    profile_id: str = Field(default="", max_length=64)


def register_storage_routes(app):
    def resolve_uri(store, uri: str, profile_id: str) -> str:
        clean = (uri or "").strip()
        if clean:
            return clean
        if profile_id:
            return _profile_uri(store.get("profiles", profile_id))
        return ""

    @app.get("/api/storage/config")
    def get_storage_config(request: Request):
        store = current_store(request)
        info = store.storage_info()
        presets = []
        for p in store.all("profiles"):
            try:
                full_uri = _profile_uri(p)
                presets.append({
                    "id": p["id"],
                    "name": p.get("name") or p["id"],
                    "uri": full_uri,
                    "uri_masked": mask_uri(full_uri),
                })
            except Exception:
                continue
        info["presets"] = presets
        return info

    @app.post("/api/storage/test")
    def test_storage(body: StorageTestRequest, request: Request):
        store = current_store(request)
        try:
            uri = resolve_uri(store, body.uri, body.profile_id)
            mb = store.get_mongo_backend(uri, body.database)
            try:
                return test_mongo_storage(mb.uri, mb.database_name, client=mb.client)
            finally:
                mb.close()
        except Exception as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/storage/migrate")
    def migrate_storage(body: StorageMigrateRequest, request: Request):
        store = current_store(request)
        try:
            uri = resolve_uri(store, body.uri, body.profile_id)
            mb = store.get_mongo_backend(uri, body.database)
            try:
                test_mongo_storage(mb.uri, mb.database_name, client=mb.client)
                if body.direction == "sqlite_to_mongo":
                    res = migrate_store(store.sqlite_backend(), mb)
                else:
                    res = migrate_store(mb, store.sqlite_backend())
                return res
            finally:
                mb.close()
        except Exception as exc:
            raise HTTPException(422, str(exc)) from None

    @app.post("/api/storage/switch")
    def switch_storage(body: StorageSwitchRequest, request: Request):
        store = current_store(request)
        if body.backend == "mongodb":
            try:
                uri = resolve_uri(store, body.uri, body.profile_id)
                mb = store.get_mongo_backend(uri, body.database)
                try:
                    test_mongo_storage(mb.uri, mb.database_name, client=mb.client)
                    if body.auto_sync and store._backend_name == "sqlite":
                        migrate_store(store.sqlite_backend(), mb)
                finally:
                    mb.close()
                store.save_storage_config("mongodb", mb.uri, body.database, scope=body.scope)
            except Exception as exc:
                raise HTTPException(422, str(exc)) from None
        else:
            if body.auto_sync and store._backend_name == "mongodb":
                try:
                    mb = store.get_mongo_backend("", body.database)
                    try:
                        migrate_store(mb, store.sqlite_backend())
                    finally:
                        mb.close()
                except Exception:
                    pass
            store.save_storage_config("sqlite", "", body.database, scope=body.scope)
        return store.storage_info()
