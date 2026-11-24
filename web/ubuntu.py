"""Orchestration checkpoints live in the encrypted Manager store; each release runs on the host."""
import time

from pymongo import ReadPreference
from pymongo.errors import AutoReconnect, PyMongoError

from .releases import catalog
from .operations import check_quorum, client, healthy_config, host_run


PHASE_LABELS = {
    "new": "Kiểm tra trước khi nâng", "starting": "Khởi động tác vụ trên VPS",
    "apt": "Cập nhật gói Ubuntu", "prepare-reboot": "Khởi động lại sau khi cập nhật gói",
    "release": "Đang nâng bản phát hành Ubuntu", "packages": "Cài gói MongoDB cho Ubuntu đích",
    "reboot": "Khởi động lại để xác minh phiên bản", "failed": "Chặng nâng bị lỗi",
}


def inspect(machine, params):
    return host_run(machine, "ubuntu_inspect", params, lambda _: None)


def mongo_state(machine, profile, info, handoff=False, verify=False):
    if info.get("offline"):
        return "MongoDB đang dừng. Manager giữ phiên bản gói và không khởi động dịch vụ.", {}
    if not info["version"]:
        return "Máy chưa cài MongoDB", {}
    if not profile or not machine.get("mongo_endpoint"):
        raise ValueError("Gắn máy với hồ sơ và endpoint của mongod đang chạy.")
    with client(profile, direct=machine["mongo_endpoint"]) as db:
        hello = db.admin.command("hello")
        status = db.admin.command("serverStatus")
        if (status["pid"] != info["pid"] or status["host"].split(":")[0] != info["hostname"]
                or status["version"] != info["version"]):
            raise ValueError("Endpoint và tiến trình mongod trên VPS không khớp.")
        config = db.admin.command("getCmdLineOpts")["parsed"]
        if not hello.get("arbiterOnly"):
            db.get_database("local", read_preference=ReadPreference.SECONDARY_PREFERRED).get_collection("startup_log").find_one({}, {"_id": 1})
        if not hello.get("setName"):
            if not hello.get("isWritablePrimary") or hello.get("msg") == "isdbgrid":
                raise ValueError("Chưa xác định được vai trò mongod.")
            return "Standalone sẽ ngừng phục vụ trong lúc cập nhật và reboot.", config
        cfg, states = healthy_config(db)
        me = next((m for m in states.values() if m.get("self")), {})
        if me.get("state") not in (1, 2, 7) or hello["setName"] != profile.get("replica_set"):
            raise ValueError("Node chưa sẵn sàng hoặc khác replica set của hồ sơ.")
        if not any(m.get("state") == 1 and m.get("health") == 1 for m in states.values()):
            raise ValueError("Replica set chưa bầu được primary khỏe.")
        if len(cfg["members"]) == 1:
            return "Replica một node sẽ ngừng phục vụ trong lúc cập nhật và reboot.", config
        if verify:
            return me["stateStr"], config
        if any(m.get("newlyAdded") for m in cfg["members"]):
            raise ValueError("Chờ member mới hoàn tất đồng bộ và có quyền bỏ phiếu.")
        peers = {k: v for k, v in states.items() if k != me["_id"] and v.get("state") in (1, 2, 7)}
        check_quorum(cfg, peers)
        if handoff and me["state"] == 1:
            try:
                db.admin.command({"replSetStepDown": 3600, "secondaryCatchUpPeriodSecs": 30})
            except AutoReconnect:
                pass
            with client(profile) as cluster:
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    try:
                        elected = cluster.admin.command("hello")
                        after = db.admin.command("hello")
                        if after.get("secondary") and elected.get("isWritablePrimary") and elected.get("me") != hello.get("me"):
                            break
                    except AutoReconnect:
                        pass
                    time.sleep(2)
                else:
                    raise ValueError("Chưa xác minh được primary mới.")
        return "Nâng từng member. Primary sẽ bàn giao trước khi máy tạm dừng.", config


def advance(store, job, machine, profile, ctx, stop, emit):
    expected = ctx["info"]
    p = dict(ctx["params"], target=expected["target"])
    for index in range(ctx.get("index", 0), len(expected["path"])):
        stage = expected["path"][index]
        args = dict(job_id=job["id"], stage=stage, series=expected["series"], version=expected["version"], offline=expected.get("offline", False))
        while not stop.is_set():
            try:
                state = host_run(machine, "ubuntu_status", args, lambda _: None)
            except (OSError, RuntimeError) as exc:
                if not ctx.get("launching"):
                    raise
                if not ctx.get("disconnected"):
                    emit("Chờ kết nối lại VPS để đọc chặng đang chạy. " + str(exc))
                    ctx["disconnected"] = True
                    store.save("ubuntu-jobs", ctx, job["id"])
                if machine.get("id"):
                    try:
                        current = store.get("machines", machine["id"])
                    except KeyError:
                        current = machine
                    if all(machine.get(k) == current.get(k) for k in ("host", "port", "mode", "user", "service")):
                        machine = current
                if stop.wait(10):
                    return None
                continue
            if ctx.pop("disconnected", False):
                emit("Đã kết nối lại VPS và đọc trạng thái tác vụ.")
                store.save("ubuntu-jobs", ctx, job["id"])
            phase = state["phase"]
            progress = state.get("progress") or {}
            sampled = time.time()
            previous = ctx.get("download_sample", {})
            unit = "bytes" if progress.get("bytes_total") else "packages"
            total = progress.get(unit + "_total", 0)
            done = progress.get(unit + "_done", 0)
            sample_key = (stage, phase, unit, progress.get("package", ""), total)
            if total and previous.get("key") == list(sample_key):
                delta = done - previous["done"]
                interval = sampled - previous["time"]
                if delta > 0 and interval > 0:
                    progress["eta_seconds"] = round((total - done) * interval / delta)
            if total and (previous.get("key") != list(sample_key) or done != previous.get("done")):
                ctx["download_sample"] = dict(key=list(sample_key), done=done, time=sampled)
            job["upgrade_progress"] = dict(phase=PHASE_LABELS.get(phase, phase), detail=state.get("detail", ""), checked_at=sampled, **progress)
            store.save("jobs", job, job["id"])
            if state.get("detail") and state["detail"] != ctx.get("detail") and time.time() - ctx.get("last_log", 0) >= 10:
                emit(state["detail"])
                ctx.update(detail=state["detail"], last_log=time.time())
                store.save("ubuntu-jobs", ctx, job["id"])
            if phase != ctx.get("phase"):
                emit("Ubuntu " + catalog()["lts"][stage] + " · " + PHASE_LABELS.get(phase, phase) + (" · " + state["log"] if state.get("log") else ""))
                ctx["phase"] = phase
                store.save("ubuntu-jobs", ctx, job["id"])
            if phase in {"apt", "release", "reboot"}:
                ctx.pop("launch_error", None)
            if phase in {"prepare-reboot", "reboot"} and state["rebooted"] and expected["version"] and not expected.get("offline") and expected.get("machine_token"):
                source = expected["path"][index - 1] if index else expected["current"]
                identity = {"machine_token": expected["machine_token"], "current": stage if phase == "reboot" else source}
                host_run(machine, "ubuntu_restore_service", identity, emit)
            if phase == "failed" and ctx.pop("retry_finalize", False):
                store.save("ubuntu-jobs", ctx, job["id"])
                try:
                    host_run(machine, "ubuntu_finalize", dict(args, machine_token=expected["machine_token"]), emit)
                except (OSError, RuntimeError) as exc:
                    ctx["launch_error"] = str(exc)
                    store.save("ubuntu-jobs", ctx, job["id"])
                continue
            if phase == "failed" and ctx.get("launch_error"):
                raise ValueError(ctx["launch_error"])
            if phase == "failed":
                raise ValueError("Nâng Ubuntu bị lỗi ở bước " + PHASE_LABELS.get(state.get("last_phase"), "chạy trên VPS") + ". Xem " + state["log"])
            if phase == "reboot" and state["rebooted"]:
                if state["current"] != stage:
                    raise ValueError("Sau reboot máy chưa chạy đúng bản Ubuntu đích.")
                # SSH often returns before mongod finishes recovery and the replica elects a primary.
                try:
                    info = inspect(machine, p)
                    _, config = mongo_state(machine, profile, info, verify=True)
                except (ValueError, RuntimeError, OSError, PyMongoError):
                    if time.time() > ctx.setdefault("verify_until", time.time() + 180):
                        raise
                    store.save("ubuntu-jobs", ctx, job["id"])
                    if stop.wait(5):
                        return None
                    continue
                if expected.get("machine_token") and expected["machine_token"] != info.get("machine_token"):
                    raise ValueError("Danh tính máy sau khi khởi động lại đã thay đổi.")
                if (info["version"] != expected["version"] or info["current"] != stage
                        or bool(info.get("offline")) != bool(expected.get("offline"))):
                    raise ValueError("Ubuntu hoặc phiên bản mongod sau reboot khác kế hoạch.")
                if config != ctx.get("config", {}):
                    raise ValueError("Cấu hình mongod sau reboot khác cấu hình đã ghi nhận.")
                ctx.pop("verify_until", None)
                ctx.update(index=index + 1, phase="", launching=False)
                store.save("ubuntu-jobs", ctx, job["id"])
                break
            if phase == "new" or (phase == "prepare-reboot" and state["rebooted"]):
                if ctx.get("launch_error"):
                    raise ValueError(ctx["launch_error"])
                try:
                    info = inspect(machine, p)
                    if ctx.get("plan", {}).get("public", {}).get("package_wait"):
                        host_run(machine, "package_recover", {}, emit)
                    host_run(machine, "ubuntu_precheck", args, emit)
                    if phase == "prepare-reboot":
                        mongo_state(machine, profile, info)
                except (ValueError, RuntimeError, OSError, PyMongoError):
                    if phase != "prepare-reboot" or time.time() > ctx.setdefault("ready_until", time.time() + 180):
                        raise
                    store.save("ubuntu-jobs", ctx, job["id"])
                    if stop.wait(8):
                        return None
                    continue
                ctx.pop("ready_until", None)
                if (bool(info.get("offline")) != bool(expected.get("offline")) or info["path"] != expected["path"][index:] or info["version"] != expected["version"]
                        or (expected.get("machine_token") and info.get("machine_token") != expected["machine_token"])):
                    raise ValueError("Máy hoặc lộ trình nâng đã thay đổi. Kiểm tra lại.")
                _, config = mongo_state(machine, profile, info, handoff=True)
                ctx.update(launching=True, config=config)
                store.save("ubuntu-jobs", ctx, job["id"])
                try:
                    host_run(machine, "ubuntu_start", args, emit)
                except (OSError, RuntimeError) as exc:
                    # A dropped SSH reply may follow successful systemd-run. Reconcile this job ID first.
                    ctx["launch_error"] = str(exc)
                    store.save("ubuntu-jobs", ctx, job["id"])
            if stop.wait(8):
                return None
        if stop.is_set():
            return None
    if expected.get("machine_token") and expected["path"]:
        emit("Kiểm tra zip, unzip, Node.js và PM2 sau nâng Ubuntu.")
        tools = host_run(machine, "ubuntu_tools", dict(job_id=job["id"], stage=expected["target"],
                         machine_token=expected["machine_token"]), emit)
        emit("Đã kiểm tra " + ", ".join(f"{name} {version}" for name, version in tools.items()))
    return {"ubuntu": catalog()["lts"][expected["target"]], "series": expected["series"], "version": expected["version"]}
