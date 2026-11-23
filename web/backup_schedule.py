"""Persistent cron schedules for the manager's single-worker job runner."""
import logging
import threading
from datetime import datetime, timedelta, timezone

from croniter import croniter
from pydantic import BaseModel, ConfigDict, Field

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
    def __init__(self, store, job_lock, dispatch):
        self.store = store
        self.job_lock = job_lock
        self.dispatch = dispatch
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
            due = sorted((s for s in self.store.all(KIND) if s["enabled"] and
                          datetime.fromisoformat(s["next_run"]) <= current), key=lambda s: s["next_run"])
            for schedule in due:
                try:
                    profile = self.store.get("profiles", schedule["id"])
                    machine = self.store.get("machines", schedule["machine_id"])
                except KeyError:
                    machine = None
                if not machine or machine.get("profile_id") != schedule["id"]:
                    self.store.update_fields(KIND, schedule["id"], {"enabled": False, "next_run": None})
                    continue
                if not self.job_lock.acquire(blocking=False):
                    return
                try:
                    schedule["next_run"] = next_run(schedule["cron"], current)
                    self.dispatch(schedule, profile, machine)
                except Exception:
                    self.job_lock.release()
                    raise
                return  # The worker now owns the job lock.
