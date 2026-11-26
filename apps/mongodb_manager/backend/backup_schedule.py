"""Persistent cron schedules for the manager's job runner."""
import logging
import threading
from datetime import datetime, timedelta, timezone

from croniter import croniter
from pydantic import BaseModel, ConfigDict, Field

from shared.manager_core.job_slots import Busy
from shared.manager_core.workspaces import use_store
from .operations import validate_params

KIND = "backup-schedules"
VIETNAM = timezone(timedelta(hours=7))


class ScheduleInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    machine_id: str = Field(min_length=1)
    cron: str = Field(min_length=1, max_length=100)
    params: dict


def next_run(expression, current):
    if len(expression.split()) != 5:
        raise ValueError("Cron cần đúng 5 trường: phút, giờ, ngày, tháng, thứ.")
    try:
        local = croniter(expression, current.astimezone(VIETNAM)).get_next(datetime)
    except (ValueError, KeyError, OverflowError) as exc:
        raise ValueError("Biểu thức cron không hợp lệ hoặc không có lần chạy kế tiếp.") from exc
    return local.astimezone(timezone.utc).isoformat()


class BackupScheduler:
    def __init__(self, store, dispatch, workspaces=None, auth=None):
        self.store = store
        self.dispatch = dispatch
        self.workspaces = workspaces
        self.auth = auth
        self.settings_lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, name="backup-scheduler", daemon=True)

    def save(self, profile_id, body):
        with self.settings_lock:
            self.store.get("profiles", profile_id)
            machine = self.store.get("machines", body.machine_id)
            if machine.get("profile_id") != profile_id:
                raise ValueError("Máy lưu backup phải thuộc workspace đang mở.")
            expression = body.cron.strip()
            schedule = {"machine_id": machine["id"], "cron": expression, "enabled": True,
                        "params": validate_params("backup", body.params, machine),
                        "next_run": next_run(expression, datetime.now(timezone.utc))}
            return self.store.save(KIND, schedule, profile_id)

    def pause(self, profile_id):
        with self.settings_lock:
            return self.store.update_fields(KIND, profile_id, {"enabled": False, "next_run": None})

    def run(self):
        while not self.stop.wait(5):
            try:
                self.tick(datetime.now(timezone.utc))
            except Exception:
                logging.getLogger(__name__).exception("Backup scheduler tick failed")

    def tick(self, current):
        with self.settings_lock:
            if self.workspaces and self.auth:
                ws_ids = ["default"]
                seen = {"default"}
                for user in self.auth.users():
                    ws_id = user.get("workspace_id") or "default"
                    if ws_id not in seen:
                        seen.add(ws_id)
                        ws_ids.append(ws_id)
                for ws_id in ws_ids:
                    ws_store = self.workspaces.get_store(ws_id)
                    with use_store(ws_store, ws_id):
                        self._tick_store(ws_store, current, ws_id)
            else:
                self._tick_store(self.store, current, "default")

    def _tick_store(self, store, current, ws_id):
        due = sorted((s for s in store.all(KIND) if s["enabled"] and
                      datetime.fromisoformat(s["next_run"]) <= current), key=lambda s: s["next_run"])
        for schedule in due:
            try:
                profile = store.get("profiles", schedule["id"])
                machine = store.get("machines", schedule["machine_id"])
            except KeyError:
                machine = None
            if not machine or machine.get("profile_id") != schedule["id"]:
                store.update_fields(KIND, schedule["id"], {"enabled": False, "next_run": None})
                continue
            schedule["next_run"] = next_run(schedule["cron"], current)
            try:
                self.dispatch(schedule, profile, machine, store, ws_id)
            except TypeError:
                self.dispatch(schedule, profile, machine)
            except Busy:
                continue  # Stored due time stays unchanged until this host is available.
