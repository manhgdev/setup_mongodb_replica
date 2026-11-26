"""Per-user workspace Store registry, context-bound store proxy, and request store resolution."""
import contextlib
import contextvars
import shutil
import threading
from pathlib import Path

from fastapi import Request

from .store import Store

_ACTIVE_STORE: contextvars.ContextVar[Store | None] = contextvars.ContextVar("zm_active_store", default=None)
_ACTIVE_WORKSPACE: contextvars.ContextVar[str] = contextvars.ContextVar("zm_active_workspace", default="default")


def set_active_store(store: Store, workspace_id: str = "default"):
    t1 = _ACTIVE_STORE.set(store)
    t2 = _ACTIVE_WORKSPACE.set(workspace_id or "default")
    return (t1, t2)


def reset_active_store(tokens):
    t1, t2 = tokens
    _ACTIVE_STORE.reset(t1)
    _ACTIVE_WORKSPACE.reset(t2)


@contextlib.contextmanager
def use_store(store: Store, workspace_id: str = "default"):
    tokens = set_active_store(store, workspace_id)
    try:
        yield store
    finally:
        reset_active_store(tokens)


def current_workspace_id() -> str:
    return _ACTIVE_WORKSPACE.get()


class WorkspaceRegistry:
    """Thread-safe cache of Store instances keyed by workspace_id."""

    def __init__(self, root_dir, app_name: str = "shared"):
        self.root_dir = Path(root_dir).expanduser().resolve()
        self.app_name = app_name
        self._stores: dict[str, Store] = {}
        self._lock = threading.Lock()

    def workspace_dir(self, workspace_id: str) -> Path:
        if not workspace_id or workspace_id == "default":
            return self.root_dir
        clean = "".join(ch for ch in workspace_id if ch.isalnum() or ch in "-_")
        if not clean:
            raise ValueError("Workspace ID không hợp lệ.")
        return self.root_dir / "workspaces" / clean

    def get_store(self, workspace_id: str = "default") -> Store:
        key = workspace_id or "default"
        with self._lock:
            store = self._stores.get(key)
            if store is None:
                store = Store(self.workspace_dir(key), app_name=self.app_name)
                self._stores[key] = store
            return store

    def delete_workspace(self, workspace_id: str):
        if not workspace_id or workspace_id == "default":
            return
        with self._lock:
            store = self._stores.pop(workspace_id, None)
            if store is not None and getattr(store, "_mongo", None) is not None:
                try:
                    store._mongo.close()
                except Exception:
                    pass
            target = self.workspace_dir(workspace_id)
            if target.exists():
                shutil.rmtree(target, ignore_errors=True)


class WorkspaceStoreProxy:
    """Delegates Store operations to the active request/thread workspace Store."""

    def __init__(self, registry: WorkspaceRegistry):
        object.__setattr__(self, "_registry", registry)

    def current(self) -> Store:
        active = _ACTIVE_STORE.get()
        if active is not None:
            return active
        return self._registry.get_store("default")

    def __getattr__(self, name):
        return getattr(self.current(), name)

    def __setattr__(self, name, value):
        setattr(self.current(), name, value)


def current_store(request: Request | None = None) -> Store:
    """Return the active workspace Store for the current request or context."""
    if request is not None:
        store = getattr(request.state, "store", None)
        if store is not None:
            return store
    active = _ACTIVE_STORE.get()
    if active is not None:
        return active
    if request is not None:
        return request.app.state.store
    raise RuntimeError("No active Store in context.")
