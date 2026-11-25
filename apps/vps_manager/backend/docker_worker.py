"""Docker CLI operations on the selected Linux host's local daemon."""
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


def emit(message):
    print(json.dumps({"event": message}), flush=True)


def cli(args, timeout=60, logs=False):
    result = subprocess.run(["docker", "--host", "unix:///var/run/docker.sock", *args],
                            capture_output=True, text=True, errors="replace", timeout=timeout)
    if result.returncode:
        raise ValueError("Docker · " + (result.stderr.strip().splitlines() or ["exit "+str(result.returncode)])[-1][:500])
    return (result.stdout + (result.stderr if logs else "")).strip()


def compose_plan(filename):
    file = Path(filename)
    if not file.is_absolute() or file.suffix.lower() not in {".yaml", ".yml"} or not file.is_file():
        raise ValueError("Chọn đường dẫn tuyệt đối đến file Compose trên VPS.")
    base = ["compose", "-f", str(file)]
    cli([*base, "config", "--quiet"])
    config = cli([*base, "config", "--format", "json"])
    model = json.loads(config)
    return base, {"project":model["name"], "services":[{"name":name, "image":svc.get("image") or "(build)"}
                   for name,svc in model["services"].items()],
                  "revision":hashlib.sha256(config.encode()).hexdigest()}


def execute(action, p):
    if action == "docker-status":
        state = {"engine":bool(shutil.which("dockerd") or Path("/usr/sbin/dockerd").is_file()),
                 "active":False, "compose":"", "containers":[]}
        if not shutil.which("docker"):
            return state
        try:
            state["compose"] = cli(["compose","version","--short"])
        except ValueError:
            pass
        if shutil.which("systemctl"):
            unit=subprocess.run(["systemctl","show","docker.service","--property=ActiveState","--value"],capture_output=True,text=True,timeout=10)
            if unit.returncode==0 and unit.stdout.strip() in {"inactive","failed"}:
                return state
        try:
            output = cli(["ps","--all","--no-trunc","--format","{{json .}}"])
        except ValueError as exc:
            state["error"] = str(exc)
            return state
        state["active"] = True
        for line in output.splitlines():
            row = json.loads(line)
            state["containers"].append({k:row.get(k,"") for k in ("ID","Names","Image","State","Status","Ports")})
        return state
    if action in {"docker-logs","docker-container"}:
        ident = p["container"]
        if not re.fullmatch("[a-f0-9]{12,64}",ident):
            raise ValueError("ID container không hợp lệ.")
        if action == "docker-logs":
            return {"text":cli(["logs","--tail","200","--timestamps",ident],logs=True)[-65536:]}
        operation=p["operation"]
        if operation not in {"start","stop","restart"}:
            raise ValueError("Thao tác container không hợp lệ.")
        emit(operation+" · "+ident[:12])
        cli([operation,ident],120)
        return {"state":cli(["inspect","--format","{{.State.Status}}",ident])}
    if action in {"docker-plan","docker-deploy"}:
        base,plan = compose_plan(p["filename"])
        if action=="docker-plan":
            return plan
        if p["revision"]!=plan["revision"]:
            raise ValueError("Cấu hình Compose đã đổi. Kiểm tra lại kế hoạch.")
        if p["pull"]:
            emit("docker compose pull · "+plan["project"])
            cli([*base,"pull","--ignore-buildable"],1200)
        emit("docker compose up -d · "+plan["project"])
        cli([*base,"up","-d"],1200)
        return {"project":plan["project"],"services":plan["services"]}
    raise ValueError("Thao tác Docker không hợp lệ.")


def serve(request):
    try:
        print(json.dumps({"result":execute(request["action"],request["params"])}),flush=True)
    except Exception as exc:
        print(json.dumps({"error":str(exc)}),flush=True)
        sys.exit(1)


if __name__=="__main__":
    serve(json.load(sys.stdin))
