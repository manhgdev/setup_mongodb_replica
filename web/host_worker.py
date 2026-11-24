"""Fixed, allowlisted worker sent to a local host or over SSH; JSON on stdin/stdout.

Never execute the legacy interactive scripts from a web request.
"""
import base64
import datetime
import gzip
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


def event(message):
    print(json.dumps({"event": message}, ensure_ascii=False), flush=True)


def run(args, timeout=60, check=True):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout,
                            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
    if check and result.returncode:
        if args[0] in {"mongodump", "mongorestore"}:
            message = result.stderr.lower()
            for marker, explanation in [
                ("duplicate key", "Document trùng khóa ở đích. Chọn đích trống hoặc xác nhận thay thế collection."),
                ("authentication failed", "Xác thực thất bại. Kiểm tra tài khoản, mật khẩu và auth database."),
                ("unauthorized", "Tài khoản thiếu quyền hoặc phiên xác thực đã thay đổi. Kiểm tra quyền backup/restore và replay oplog."),
                ("no space left", "Máy thực thi hoặc cụm đích hết dung lượng."),
                ("server selection", "Máy thực thi không kết nối được cụm. Kiểm tra seed, DNS, TLS và firewall."),
            ]:
                if marker in message:
                    raise RuntimeError(f"{args[0]}: {explanation}")
        # Commands may contain secrets. Never print argv or tool stderr blindly.
        raise RuntimeError(f"{Path(args[0]).name} thất bại (exit {result.returncode}). Kiểm tra journal/log trên máy đích.")
    return result.stdout.strip()


def linux_info():
    info = {}
    if Path("/etc/os-release").exists():
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                info[k] = v.strip('"')
    return info


def preflight(p):
    info = linux_info()
    disk = shutil.disk_usage("/")
    tools = {name: bool(shutil.which(name)) for name in ["mongod", "mongosh", "mongodump", "mongorestore", "systemctl"]}
    version = run(["mongod", "--version"], check=False) if tools["mongod"] else "Chưa cài"
    service = p.get("service", "mongod")
    active = run(["systemctl", "is-active", service], check=False) if tools["systemctl"] else "Không có systemd"
    mem = ""
    if Path("/proc/meminfo").exists():
        mem = Path("/proc/meminfo").read_text().splitlines()[0]
    services = []
    if tools["systemctl"]:
        services = [line.split()[0] for line in run(["systemctl", "list-unit-files", "--type=service", "--no-legend", "--no-pager"], check=False).splitlines()
                    if line.startswith("mongod") and line.split()[0].endswith(".service")]
    installed = tools["mongod"] or bool(services)
    next_step = "adopt" if installed else "provision"
    return {"os": info.get("PRETTY_NAME", platform.platform()), "codename": info.get("VERSION_CODENAME", ""),
            "architecture": platform.machine(), "kernel": platform.release(), "hostname": socket.gethostname(),
            "disk_free_gb": round(disk.free / 1024**3, 1), "disk_total_gb": round(disk.total / 1024**3, 1),
            "memory": mem, "tools": tools, "version": version, "service": service, "service_state": active,
            "services": services, "mongodb_detected": installed, "next_step": next_step,
            "recommendation": "Đã phát hiện MongoDB. Tiếp nhận cụm hiện có bằng endpoint và tài khoản MongoDB; không chạy khởi tạo lại." if installed else "Chưa phát hiện package/service MongoDB trên máy. Có thể cài cụm mới hoặc chuẩn bị node cho cụm đang có. Docker/container cần kiểm tra riêng."}


if __package__:
    from .releases import _catalog
    LTS, SUPPORTED = _catalog["lts"], _catalog["supported"]
else:
    LTS, SUPPORTED = {}, {}
MONGO_PACKAGES = ["mongodb-org", "mongodb-org-database", "mongodb-org-server", "mongodb-org-shell", "mongodb-org-mongos", "mongodb-org-tools", "mongodb-org-database-tools-extra"]


def package_version(series, codename, arch, exact=""):
    if codename not in SUPPORTED.get(series, ()):
        raise ValueError("Tổ hợp Ubuntu/MongoDB chưa được hỗ trợ.")
    if arch not in {"amd64", "arm64"}:
        raise ValueError("Kiến trúc cần có package amd64 hoặc arm64.")
    url = f"https://repo.mongodb.org/apt/ubuntu/dists/{codename}/mongodb-org/{series}/multiverse/binary-{arch}/Packages.gz"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            packages = gzip.decompress(response.read()).decode()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ValueError("Kho chưa có gói cho Ubuntu và kiến trúc này.") from exc
        raise RuntimeError("Tạm thời không đọc được kho MongoDB.") from exc
    except (OSError, EOFError) as exc:
        raise RuntimeError("Tạm thời không đọc được kho MongoDB.") from exc
    version = install_version(packages, MONGO_PACKAGES, series, codename)
    if exact and (not all(exact in package_versions(packages, n) for n in MONGO_PACKAGES)
                  or (codename == "resolute" and series == "9.0" and int(exact.split(".")[-1]) < 4)):
        raise ValueError("Kho đích thiếu bản MongoDB đang chạy: " + exact)
    return exact or version


def install(p):
    info = linux_info()
    codename = info.get("VERSION_CODENAME")
    series = p["series"]
    if info.get("ID") != "ubuntu":
        raise RuntimeError("Cần chọn máy Ubuntu.")
    if shutil.which("mongod"):
        raise RuntimeError("MongoDB đã được cài. Tác vụ cài mới không thay hoặc nâng phiên bản hiện có.")
    arch = ubuntu_architecture()
    names = MONGO_PACKAGES
    version = package_version(series, codename, arch)
    event(f"Cài MongoDB {version} cho Ubuntu {codename} / {arch}.")
    event("Cập nhật danh mục gói Ubuntu.")
    package_run(["apt-get", "update"], timeout=600)
    package_run(["apt-get", "-o", "DPkg::Lock::Timeout=120", "install", "-y", "gnupg", "ca-certificates"], timeout=600)
    event("Cấu hình kho MongoDB chính thức.")
    configure_mongo_repo(series, codename, arch)
    package_run(["apt-get", "update"], timeout=600)
    event("Tải và cài các gói MongoDB.")
    package_run(["apt-get", "-o", "DPkg::Lock::Timeout=120", "install", "-y", *[f"{n}={version}" for n in names], "mongodb-mongosh", "mongodb-database-tools"], timeout=1200)
    return {"version": version, "message": "Đã cài package. Tiếp tục wizard tạo replica set."}


def configure_mongo_repo(series, codename, arch):
    keypath = "/usr/share/keyrings/mongodb-server-" + series + ".gpg"
    repo = Path("/etc/apt/sources.list.d/mongodb-org-" + series + ".list")
    write_mongo_repo(series, codename, arch, repo, Path(keypath), keypath)


def write_mongo_repo(series, codename, arch, repo, keyfile, keypath):
    major = series.split(".")[0]
    for key_version in dict.fromkeys((series, major, major + ".0")):
        try:
            with urllib.request.urlopen(f"https://pgp.mongodb.com/server-{key_version}.asc", timeout=30) as response:
                key_data = response.read()
            break
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
    else:
        raise ValueError("Chưa tìm thấy khóa ký chính thức cho MongoDB " + series)
    with tempfile.TemporaryDirectory() as tmp:
        asc = Path(tmp) / "key.asc"
        asc.write_bytes(key_data)
        run(["gpg", "--batch", "--yes", "--dearmor", "--output", str(keyfile), str(asc)])
    keyfile.chmod(0o644)
    repo.write_text(f"deb [arch={arch} signed-by={keypath}] https://repo.mongodb.org/apt/ubuntu {codename}/mongodb-org/{series} multiverse\n")


def install_version(packages, names, series, codename):
    common = set.intersection(*(set(package_versions(packages, name)) for name in names))
    stable = [v for v in common if re.fullmatch(re.escape(series) + r"\.\d+", v)]
    if codename == "resolute" and series == "9.0":
        stable = [v for v in stable if int(v.split(".")[-1]) >= 4]
    if not stable:
        raise ValueError(f"Repository chưa có đủ bộ package MongoDB {series} tương thích với Ubuntu {codename}.")
    return max(stable, key=lambda v: int(v.split(".")[-1]))


def package_versions(packages, name):
    versions = []
    for block in packages.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line and not line.startswith(" "))
        if fields.get("Package") == name and "Version" in fields:
            versions.append(fields["Version"])
    return versions


def release_path(current, series, arch, exact, requested, lookup):
    order = list(LTS)
    if current not in order:
        raise ValueError("Cần Ubuntu LTS có đường nâng đã biết. Bản hỗ trợ: " + ", ".join(LTS[c] for c in SUPPORTED[series]))
    if current == "resolute" and series == "8.0" and requested in ("auto", current):
        raise ValueError("Máy đã dùng Ubuntu 26.04. Không cần đường nâng Ubuntu. "
                         "MongoDB Community trên bản này dùng nhánh 9.0 từ 9.0.4.")
    failures = []
    for target in order[order.index(current):]:
        if target not in SUPPORTED[series] or requested not in ("auto", target):
            continue
        path = order[order.index(current) + 1:order.index(target) + 1]
        try:
            for stage in (path if exact and path else [target]):
                lookup(series, stage, arch, exact)
        except ValueError as exc:
            failures.append(str(exc))
            continue
        return target, path
    raise ValueError("; ".join(failures) or "Không có đường nâng tới bản đã chọn. Ubuntu hỗ trợ: " + ", ".join(LTS[c] for c in SUPPORTED[series]))


def ubuntu_architecture():
    arch = run(["dpkg", "--print-architecture"])
    flags = Path("/proc/cpuinfo").read_text().split()
    if arch == "arm64" and "atomics" not in flags:
        raise ValueError("CPU ARM thiếu tập lệnh atomics cần cho ARMv8.2-A.")
    if arch == "amd64" and "avx" not in flags:
        raise ValueError("CPU thiếu AVX để chạy MongoDB.")
    return arch


def host_resources():
    disk = shutil.disk_usage("/")
    resources = dict(cpu_count=os.cpu_count(), disk_total=disk.total, disk_used=disk.used, disk_free=disk.free)
    try:
        memory = dict(re.findall(r"^(MemTotal|MemAvailable):\s+(\d+) kB", Path("/proc/meminfo").read_text(), re.M))
        resources.update(ram_total=int(memory["MemTotal"]) * 1024, ram_available=int(memory["MemAvailable"]) * 1024)
    except (KeyError, OSError, ValueError):
        pass

    def cpu_sample():
        counters = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:9]))
        return sum(counters), counters[3] + counters[4]

    try:
        total, idle = cpu_sample()
        time.sleep(0.3)
        end, idle_end = cpu_sample()
        if end > total:
            resources["cpu_percent"] = round(100 * (1 - (idle_end - idle) / (end - total)), 1)
    except (IndexError, ValueError, OSError):
        pass
    try:
        device = os.stat("/").st_dev
        block = (Path("/sys/dev/block") / f"{os.major(device)}:{os.minor(device)}").resolve(strict=True)
        if (block / "partition").exists():
            block = block.parent
        if "virtual" not in block.parts:
            resources["disk_medium"] = {"0": "SSD", "1": "HDD"}.get((block / "queue/rotational").read_text().strip())
    except OSError:
        pass
    return resources


def ubuntu_inventory(p):
    host = preflight(p)
    pid = run(["systemctl", "show", "-p", "MainPID", "--value", p["service"]], check=False) if host["tools"]["systemctl"] else ""
    processes = run(["pgrep", "-x", "mongod"], check=False).split() if shutil.which("pgrep") else []
    binary = re.search(r"db version v(\d+\.\d+\.\d+)\b", host["version"])
    return dict(resources=host_resources(), os=host["os"], arch=host["architecture"], hostname=host["hostname"],
                current=host["codename"], version=binary[1] if binary else "", service=host["service"],
                service_state=host["service_state"], services=host["services"], processes=len(processes),
                pid=pid, mongodb_detected=host.get("mongodb_detected", bool(binary or host["services"])))


def ubuntu_compatibility(p):
    result = dict(p.get("inventory") or ubuntu_inventory(p))
    version = p.get("live_version") or result["version"]
    series = version.rsplit(".", 1)[0] if version else p["series"]
    result.update(version=version, series=series, path=[], target="", package="")
    try:
        if linux_info().get("ID") != "ubuntu":
            raise ValueError("Máy đã chọn cần chạy Ubuntu.")
        result["arch"] = ubuntu_architecture()
        if series not in SUPPORTED:
            raise ValueError("Bộ cài chưa hỗ trợ nhánh MongoDB " + series)
        if not version and (result["mongodb_detected"] or result["processes"]):
            raise ValueError("Đã phát hiện MongoDB nhưng chưa xác minh được phiên bản.")
        if result["current"] == "resolute" and series == "8.0":
            package = package_version("9.0", "resolute", result["arch"])
            result.update(status="mongo_upgrade" if version else "change_series",
                          package=package, target=LTS["resolute"],
                          reason=f"Giữ Ubuntu 26.04. Kho MongoDB có gói Community {package} cho {result['arch']}.")
            return result
        def lookup(branch, codename, arch, exact):
            result["package"] = package_version(branch, codename, arch, exact)
        target, path = release_path(result["current"], series, result["arch"], version, "auto", lookup)
        result.update(status="upgrade" if path else "compatible", target=LTS[target], target_codename=target, path=[LTS[c] for c in path])
    except ValueError as exc:
        result.update(status="unsupported", package="", reason=str(exc))
    except RuntimeError as exc:
        result.update(status="unknown", package="", reason=str(exc))
    return result


def ubuntu_inspect(p, preview=False):
    info = linux_info()
    if info.get("ID") != "ubuntu":
        raise ValueError("Máy đã chọn cần chạy Ubuntu.")
    current = info.get("VERSION_CODENAME", "")
    arch = run(["dpkg", "--print-architecture"])
    exact = ""
    pid = 0
    blocked = ""
    state = ""
    offline = False
    if shutil.which("mongod"):
        pid = int(run(["systemctl", "show", "-p", "MainPID", "--value", p["service"]]) or 0)
        state = run(["systemctl", "is-active", p["service"]], check=False)
        processes = run(["pgrep", "-x", "mongod"], check=False).split()
        offline = state == "inactive" and pid == 0 and not processes
        if offline:
            exact = run(["dpkg-query", "-W", "-f=${Version}", "mongodb-org-server"])
        else:
            match = re.search(r"db version v(\d+\.\d+\.\d+)\b", run(["mongod", "--version"]))
            if not match:
                raise ValueError("Không xác định được phiên bản mongod.")
            exact = match[1]
        if not offline and (not pid or processes != [str(pid)]):
            blocked = (f"Dịch vụ {p['service']} đang ở trạng thái {state or 'unknown'}. "
                       "Chưa thể xác minh instance MongoDB trước khi nâng Ubuntu.")
            if not preview:
                raise ValueError(blocked)
    elif shutil.which("pgrep") and run(["pgrep", "-x", "mongod"], check=False):
        raise ValueError("Phát hiện mongod ngoài bộ cài trên host. Kiểm tra instance trước.")
    series = exact.rsplit(".", 1)[0] if exact else p.get("series", "")
    target = p["target"]
    if not p.get("series"):
        releases = list(LTS)
        if current not in releases or (target != "auto" and target not in releases):
            raise ValueError("Cần chọn bản Ubuntu LTS có đường nâng chính thức.")
        index = releases.index(current)
        if target == "auto":
            target = releases[min(index + 1, len(releases) - 1)]
        if releases.index(target) < index:
            raise ValueError("Ubuntu đích cũ hơn bản đang chạy.")
        path = releases[index + 1:releases.index(target) + 1]
    if series and (not offline or p.get("series")):
        arch = ubuntu_architecture()
        if series not in SUPPORTED:
            raise ValueError("Chưa xác minh được gói cho MongoDB " + series)
        target, path = release_path(current, series, arch, exact, target, package_version)
    return dict(current=current, arch=arch, version=exact, series=series, target=target, path=path,
                service_state=state, offline=offline, blocked=blocked,
                pid=pid, machine_token=hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest(), hostname=socket.gethostname(), os=info["PRETTY_NAME"])


def package_activity():
    active = set()
    for proc in Path("/proc").glob("[0-9]*/comm"):
        try:
            name = proc.read_text().strip()
        except OSError:
            continue
        if name == "unattended-upgr":
            try:
                if b"unattended-upgrade-shutdown" in proc.with_name("cmdline").read_bytes():
                    continue
            except OSError:
                continue
        if name in {"apt", "apt-get", "dpkg", "unattended-upgr", "do-release-upgr"}:
            active.add(name)
    audit = run(["dpkg", "--audit"])
    log = Path("/var/log/dpkg.log")
    detail = ""
    if log.is_file():
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 4096))
            for line in reversed(stream.read().decode(errors="replace").splitlines()):
                if re.search(r" (status|install|upgrade|configure|trigproc) ", line):
                    detail = line[:220]
                    break
    download = None
    if "apt-get" in active:
        for archive in Path("/var/cache/apt/archives/partial").glob("*.deb"):
            match = re.fullmatch(r"([a-z0-9][a-z0-9+.-]*)_([^/]+)_([a-z0-9]+)\.deb", archive.name)
            if not match:
                continue
            try:
                done = archive.stat().st_size
            except FileNotFoundError:
                continue
            size = re.search(r"^Size: (\d+)$", run(["apt-cache", "show", match[1] + ":" + match[3] + "=" + match[2].replace("%3a", ":")], check=False), re.M)
            download = {"package": match[1], "bytes_done": done, "bytes_total": int(size[1]) if size else 0}
            break
    return {"processes": sorted(active), "pending": bool(audit), "detail": detail, "download": download}


def package_run(args, timeout):
    # Stream only package names and operations, never raw hook output or repository credentials.
    import threading
    if args[0] == "apt-get":
        args = [args[0], "-o", "APT::Status-Fd=1", "-o", "Dpkg::Use-Pty=0", *args[1:]]
    def read_output(stream):
        previous = 0
        phase = None
        last_update = 0
        baseline = 0
        started = 0
        for line in stream:
            sample = re.match(r"^(dlstatus|pmstatus):.*?:([0-9]+(?:[.][0-9]+)?):", line)
            if sample:
                kind, percent = sample[1], min(100, float(sample[2]))
                now = time.monotonic()
                if phase != kind or percent < baseline:
                    phase, baseline, started, last_update = kind, percent, now, 0
                if now - last_update >= 3:
                    delta = percent - baseline
                    eta = round((100-percent)*(now-started)/delta) if delta > 0 and now-started >= 3 else -1
                    event(f"APT_PROGRESS {kind} {percent:.1f} {eta}")
                    last_update = now
                continue
            match = re.search(r"(Unpacking|Setting up|Processing triggers for) ([a-z0-9][a-z0-9.+:-]*)", line)
            download = re.match(r"Get:(\d+)\s+\S+\s+.*?\s+(\S+)\s+(?:amd64|arm64|all)\s+\S+\s+\[([^\]]+)\]", line)
            if (match or download) and time.monotonic() - previous >= 2:
                event(" ".join(match.groups()) if match else f"APT tải gói {download[1]} · {download[2]} ({download[3]})")
                previous = time.monotonic()
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          errors="replace", env=dict(os.environ, LC_ALL="C", DEBIAN_FRONTEND="noninteractive")) as proc:
        reader = threading.Thread(target=read_output, args=(proc.stdout,), daemon=True)
        reader.start()
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            event("Quá thời gian dự kiến. Tiếp tục chờ thao tác gói đang chạy.")
            code = proc.wait()
        reader.join()
        if code:
            raise RuntimeError(f"{args[0]} thất bại (exit {code}). Kiểm tra nhật ký APT/dpkg.")


def recover_packages():
    status = package_activity()
    while status["processes"]:
        event("Chờ " + ", ".join(status["processes"]) + " · " + status["detail"])
        time.sleep(10)
        status = package_activity()
    if status["pending"]:
        event("Đang hoàn tất cấu hình dpkg bị gián đoạn.")
        package_run(["dpkg", "--force-confold", "--configure", "-a"], 900)
        if run(["dpkg", "--audit"]):
            raise ValueError("dpkg vẫn còn gói cấu hình dở sau khi khôi phục.")
    return {}


def check_upgrade(stage):
    if os.geteuid() or not Path("/run/systemd/system").is_dir():
        raise ValueError("Nâng Ubuntu cần quyền root và systemd.")
    if shutil.disk_usage("/").free < 5 * 1024**3:
        raise ValueError("Cần ít nhất 5 GiB trống trên phân vùng gốc.")
    if run(["dpkg", "--audit"]):
        raise ValueError("dpkg đang có gói cấu hình dở.")
    run(["apt-get", "check"])
    tool = shutil.which("do-release-upgrade")
    if not tool:
        raise ValueError("Máy thiếu update-manager-core (do-release-upgrade).")
    policy = Path("/etc/update-manager/release-upgrades").read_text()
    if not re.search(r"^\s*Prompt\s*=\s*lts\s*$", policy, re.M | re.I):
        raise ValueError("Đặt Prompt=lts trong /etc/update-manager/release-upgrades.")
    probe = subprocess.run([tool, "-c"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=120, env=dict(os.environ, LC_ALL="C"))
    if not re.search(r"New release ['\"]?" + re.escape(LTS[stage]) + r"(?:\.|\s|')", probe.stdout):
        raise ValueError("Ubuntu chưa cung cấp chặng lên " + LTS[stage] + ". Kiểm tra cập nhật gói và nguồn Ubuntu.")


UPGRADE_SCRIPT = """#!/bin/bash
set -eu
cd "$1"
exec >>upgrade.log 2>&1
exec 9>/run/mongodb-manager-ubuntu.lock
flock -n 9 || { echo busy >failed; exit 1; }
trap 'echo "Lỗi ở dòng $LINENO" > failed' ERR
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
release_holds() {
  if [ -s package-holds ]; then xargs -r apt-mark unhold <package-holds; fi
  if [ -s original-holds ]; then xargs -r apt-mark hold <original-holds; fi
}
if [ -f package-holds ]; then
  trap release_holds EXIT
  xargs -r apt-mark hold <package-holds
fi
if [ ! -f release-complete ]; then
  echo apt >phase
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
  if [ -e /run/reboot-required ] && [ ! -e prepared ]; then
    touch prepared
    release_holds
    trap - EXIT
    echo prepare-reboot >phase
    systemctl reboot
    exit
  fi
  echo release >phase
  do-release-upgrade -f DistUpgradeViewNonInteractive
  . /etc/os-release
  test "$VERSION_CODENAME" = "$2"
  touch release-complete
fi
if [ -s mongo-packages ]; then
  echo packages >phase
  install -m 644 mongo-key.gpg "/usr/share/keyrings/mongodb-server-$3.gpg"
  install -m 644 mongo-target.list "/etc/apt/sources.list.d/mongodb-org-$3.list"
  apt-get update
  cut -d= -f1 mongo-packages | xargs -r apt-mark unhold
  xargs -r apt-get -y --no-remove --reinstall -o Dpkg::Options::=--force-confold install <mongo-packages
fi
release_holds
trap - EXIT
echo reboot >phase
systemctl reboot
"""


def ubuntu_action(action, p):
    if action == "ubuntu_inventory":
        return ubuntu_inventory(p)
    if action == "ubuntu_compatibility":
        return ubuntu_compatibility(p)
    if action == "ubuntu_restore_service":
        token = hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest()
        if token != p["machine_token"] or linux_info().get("VERSION_CODENAME") != p["current"]:
            raise ValueError("Máy hoặc bản Ubuntu khác kế hoạch đã xác nhận.")
        if run(["systemctl", "is-active", p["service"]], check=False) == "inactive":
            run(["systemctl", "start", p["service"]], timeout=120)
        return {}
    if action == "ubuntu_assess":
        try:
            return ubuntu_inspect(p, preview=True)
        except (ValueError, OSError, RuntimeError) as exc:
            info = linux_info()
            version = ""
            if shutil.which("dpkg-query"):
                package = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Version}", "mongodb-org-server"], check=False).split()
                if len(package) == 2 and package[0] in {"ii", "hi"}:
                    version = package[1]
            return dict(os=info.get("PRETTY_NAME", platform.system()), arch=platform.machine(),
                        series=p.get("series", ""), version=version, path=[], blocked=str(exc))
    if action == "ubuntu_precheck":
        check_upgrade(p["stage"])
        return {}
    if action == "ubuntu_inspect":
        return ubuntu_inspect(p)
    stage = p["stage"]
    if stage not in LTS or not re.fullmatch("[a-f0-9]{32}", p["job_id"]):
        raise ValueError("Chặng nâng không hợp lệ.")
    directory = Path("/var/lib/mongodb-manager/ubuntu") / p["job_id"] / stage
    phase = directory / "phase"
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    if action == "ubuntu_status":
        if not phase.exists():
            return {"phase": "new"}
        last_phase = status = phase.read_text().strip()
        if (directory / "failed").exists():
            status = "failed"
        if status in {"starting", "apt", "release", "packages"} and boot != (directory / "boot").read_text():
            status = "failed"
        detail = ""
        logfile = Path("/var/log/dpkg.log") if last_phase == "release" else directory / "upgrade.log"
        if logfile.is_file() and logfile.stat().st_mtime >= phase.stat().st_mtime:
            with logfile.open("rb") as stream:
                stream.seek(max(0, logfile.stat().st_size - 4096))
                lines = stream.read(4096).decode(errors="replace").splitlines()
            for line in reversed(lines):
                download = re.match(r"Get:(\d+)\s+\S+\s+.*?\s+(\S+)\s+(?:amd64|arm64|all)\s+\S+\s+\[([^\]]+)\]", line)
                if download:
                    detail = f"APT tải gói {download[1]} · {download[2]} ({download[3]})"
                    break
                match = re.search(r"(Setting up|Unpacking|Processing triggers for|Removing|Purging|remove|purge|trigproc|status installed|status unpacked|status half-configured|status config-files|status not-installed) ([a-z0-9][a-z0-9.+:-]{0,100})(?: |$)", line)
                if match:
                    detail = " ".join(match.groups())
                    break
        unit = "mongo-upgrade-" + p["job_id"] + "-" + stage
        if (directory / "prepared").exists() and status not in {"prepare-reboot", "reboot"}:
            unit += "-resume"
        if (directory / "unit").is_file():
            unit = (directory / "unit").read_text()
        if status in {"apt", "release", "starting", "packages"}:
            active = run(["systemctl", "is-active", unit], check=False)
            if active == "failed" or (active in {"inactive", "unknown"} and time.time() - phase.stat().st_mtime > 60):
                status = "failed"
        progress = {}
        if status == "apt" and detail.startswith("APT tải"):
            unit_size = re.fullmatch(r"([\d.]+) (B|kB|MB|GB)", download[3])
            if unit_size:
                scale = {"B": 1, "kB": 1000, "MB": 1000000, "GB": 1000000000}
                size = int(float(unit_size[1]) * scale[unit_size[2]])
                for item in Path("/var/cache/apt/archives/partial").glob("*.deb"):
                    if item.name.split("_", 1)[0] == download[2]:
                        try:
                            progress = dict(bytes_done=min(item.stat().st_size, size), bytes_total=size, package=download[2])
                        except FileNotFoundError:
                            pass
                        break
        if status == "apt" and detail.startswith("Setting up") and logfile.stat().st_size < 4 * 1024**2:
            content = logfile.read_text(errors="replace")
            counts = re.findall(r"(\d+) upgraded, (\d+) newly installed", content)
            if counts:
                total = sum(map(int, counts[-1]))
                done = len(set(re.findall(r"^Setting up ([^ ]+)", content, re.M)))
                if 0 < done <= total:
                    progress = dict(packages_done=done, packages_total=total)
        if status == "release":
            mainlog = Path("/var/log/dist-upgrade/main.log")
            if mainlog.is_file() and mainlog.stat().st_mtime >= phase.stat().st_mtime:
                with mainlog.open("rb") as stream:
                    stream.seek(max(0, mainlog.stat().st_size - 256000))
                    text = stream.read().decode(errors="replace")
                lists = re.findall(r"DEBUG (toinstall|toupgrade): '(\[[^\n]*\])'", text)
                planned = {pkg for _, group in lists for pkg in re.findall(r"'([a-z0-9+.-]+)'", group)}
                if planned:
                    if detail:
                        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(phase.stat().st_mtime))
                        finished = set()
                        with logfile.open(errors="replace") as stream:
                            for row in stream:
                                if row[:19] < stamp:
                                    continue
                                fields = row.split()
                                if len(fields) >= 6 and fields[2] == "status" and fields[3] in {"unpacked", "installed"}:
                                    pkg = fields[4].split(":")[0]
                                    if pkg in planned:
                                        finished.add((pkg, fields[3]))
                        progress = dict(packages_done=len(finished), packages_total=2 * len(planned), configuring=True)
                    elif not detail:
                        files = set()
                        started = phase.stat().st_mtime
                        for item in Path("/var/cache/apt/archives").glob("*.deb"):
                            try:
                                if item.stat().st_ctime >= started:
                                    files.add(item.name.split("_", 1)[0])
                            except FileNotFoundError:
                                continue
                        detail = "APT tải bộ gói Ubuntu mới"
                        progress = dict(packages_done=len(planned & files), packages_total=len(planned), downloading=True)
        missing_key = False
        if status == "failed" and last_phase == "apt" and logfile.is_file():
            with logfile.open("rb") as stream:
                stream.seek(max(0, logfile.stat().st_size - 8192))
                tail = stream.read().decode(errors="replace")
            missing_key = ("NO_PUBKEY 41DE058A4E7DCA05" in tail and
                           "repo.mongodb.org/apt/ubuntu" in tail and "/mongodb-org/8.0" in tail)
            if missing_key:
                detail = "APT thiếu khóa ký chính thức của kho MongoDB 8.0."
        return dict(phase=status, last_phase=last_phase, detail=detail, progress=progress, repair_key=missing_key, can_finalize=(directory / "release-complete").exists(), rebooted=boot != (directory / "boot").read_text(),
                    current=linux_info().get("VERSION_CODENAME"), log=str(directory / "upgrade.log"))
    if action == "ubuntu_tools":
        if (linux_info().get("VERSION_CODENAME") != stage
                or hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest() != p["machine_token"]):
            raise ValueError("Máy hoặc bản Ubuntu khác chặng cần xác minh.")
        packages = [name for name in ("zip", "unzip") if not shutil.which(name)]
        baseline = directory / "manual-packages.before"
        unavailable = []
        if baseline.is_file():
            installed = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${binary:Package}\\n"])
            present = {line.split()[1].split(":")[0] for line in installed.splitlines()
                       if len(line.split()) == 2 and line.split()[0] in ("ii", "hi")}
            for name in baseline.read_text().splitlines():
                if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?", name) or name.split(":")[0] in present:
                    continue
                policy = run(["apt-cache", "policy", name], check=False)
                if re.search(r"Candidate: (?!\(none\))\S+", policy):
                    packages.append(name)
                else:
                    unavailable.append(name)
        node = shutil.which("node")
        pm2 = shutil.which("pm2")
        home = Path.home()
        if not node:
            candidates = sorted((home / ".nvm/versions/node").glob("*/bin/node"), key=lambda path: path.stat().st_mtime)
            if candidates:
                node = str(candidates[-1])
                os.environ["PATH"] = str(candidates[-1].parent) + ":" + os.environ["PATH"]
        if not pm2:
            pm2 = shutil.which("pm2") or next((str(path) for path in [home / ".bun/bin/pm2"] if path.is_file()), None)
        if not node:
            packages.append("nodejs")
        if not pm2 and not shutil.which("npm"):
            packages.append("npm")
        if packages:
            run(["apt-get", "-o", "DPkg::Lock::Timeout=120", "--no-remove", "install", "-y", *packages], timeout=900)
        if not pm2:
            run(["npm", "install", "--global", "pm2"], timeout=600)
            pm2 = shutil.which("pm2")
        if not pm2 or not all(shutil.which(name) for name in ("zip", "unzip", "node")):
            raise ValueError("Chưa xác minh được zip, unzip, Node.js và PM2.")
        # Read the CLI package version without starting a new PM2 daemon.
        manifest = Path(pm2).resolve().parent.parent / "package.json"
        meta = json.loads(manifest.read_text())
        if meta.get("name") != "pm2":
            raise ValueError("Không xác minh được gói PM2 tại " + pm2)
        result = {"node": run(["node", "--version"]), "pm2": meta["version"], "zip": run(["zip", "-v"]).splitlines()[1]}
        if unavailable:
            result["Gói cũ thiếu ứng viên trong kho Ubuntu mới"] = ", ".join(unavailable)
        return result
    if action == "ubuntu_repair_key":
        state = ubuntu_action("ubuntu_status", p)
        if (not state.get("repair_key") or state["current"] != p["source"] or state["rebooted"]
                or hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest() != p["machine_token"]):
            raise ValueError("Máy hoặc chặng APT đã thay đổi. Kiểm tra lại tác vụ.")
        key = Path("/usr/share/keyrings/mongodb-server-8.0.gpg")
        sources = Path("/etc/apt/sources.list.d").glob("*.list")
        if not any("signed-by=" + str(key) in line and "https://repo.mongodb.org/apt/ubuntu " in line
                   and "/mongodb-org/8.0 " in line for src in sources for line in src.read_text().splitlines()
                   if line.strip().startswith("deb ")):
            raise ValueError("Kho MongoDB chưa trỏ tới keyring chính thức.")
        with tempfile.TemporaryDirectory(dir=key.parent) as tmp:
            signed = Path(tmp) / "server.asc"
            with urllib.request.urlopen("https://pgp.mongodb.com/server-8.0.asc", timeout=30) as response:
                signed.write_bytes(response.read())
            fields = run(["gpg", "--batch", "--show-keys", "--with-colons", str(signed)]).splitlines()
            keys = [line for line in fields if line.startswith("pub:")]
            fingerprints = [line.split(":")[9] for line in fields if line.startswith("fpr:")]
            if len(keys) != 1 or fingerprints[:1] != ["4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05"]:
                raise ValueError("Fingerprint của khóa MongoDB 8.0 không khớp.")
            binary = Path(tmp) / "server.gpg"
            run(["gpg", "--batch", "--dearmor", "--output", str(binary), str(signed)])
            binary.chmod(0o644)
            os.replace(binary, key)
        (directory / "failed").unlink()
        return launch_ubuntu(directory, p, boot, "-key-" + secrets.token_hex(4))
    if action == "ubuntu_finalize":
        if (not (directory / "release-complete").is_file() or linux_info().get("VERSION_CODENAME") != stage
                or hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest() != p["machine_token"]):
            raise ValueError("Chưa xác minh được máy và chặng nâng đã hoàn tất trên VPS.")
        if ubuntu_action("ubuntu_status", p)["phase"] != "failed":
            raise ValueError("Kiểm tra lại tác vụ đang chạy trước khi tiếp tục.")
        run(["apt-get", "check"])
        if run(["dpkg", "--audit"]):
            raise ValueError("dpkg còn gói cấu hình dở. Kiểm tra log trên VPS.")
        if (directory / "failed").exists():
            (directory / "failed").unlink()
        return launch_ubuntu(directory, p, boot, "-finish-" + secrets.token_hex(4))
    if action != "ubuntu_start":
        raise ValueError("Tác vụ Ubuntu không hợp lệ.")
    current = linux_info().get("VERSION_CODENAME")
    if current not in LTS or list(LTS).index(stage) != list(LTS).index(current) + 1:
        raise ValueError("Ubuntu nguồn đã đổi. Kiểm tra lại lộ trình.")
    resumed = phase.exists()
    if resumed and (phase.read_text().strip() != "prepare-reboot" or boot == (directory / "boot").read_text()):
        return {"started": True}
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    manual = directory / "manual-packages.before"
    if not manual.exists():
        manual.write_text(run(["apt-mark", "showmanual"]) + "\n")
    script = directory / "upgrade.sh"
    script.write_text(UPGRADE_SCRIPT)
    if p["version"]:
        # The Ubuntu package has the same MongoDB version but different distro dependencies.
        # Only manage packages installed on this host (server-only installations are valid).
        installed = []
        for name in MONGO_PACKAGES:
            value = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Version}", name], check=False).split()
            if not value or value[0] not in {"ii", "hi"}:
                continue
            if value[-1] != p["version"]:
                raise ValueError("Bộ package MongoDB đang cài không đồng nhất.")
            installed.append(name)
        if "mongodb-org-server" not in installed:
            raise ValueError("Cần mongod được quản lý bởi gói mongodb-org-server.")
        if not p.get("offline"):
            arch = run(["dpkg", "--print-architecture"])
            repo = directory / "mongo-target.list"
            keyring = directory / "mongo-key.gpg"
            write_mongo_repo(p["series"], stage, arch, repo, keyring, "/usr/share/keyrings/mongodb-server-" + p["series"] + ".gpg")
            (directory / "mongo-packages").write_text("\n".join(n + "=" + p["version"] for n in installed))
        held = set(run(["apt-mark", "showhold"]).split())
        newly_held = directory / "package-holds"
        if not newly_held.exists():
            newly_held.write_text("\n".join(n for n in installed if n not in held))
        original = set(installed) - set(newly_held.read_text().split())
        (directory / "original-holds").write_text("\n".join(sorted(original)))
    return launch_ubuntu(directory, p, boot, "-resume" if resumed else "")


def launch_ubuntu(directory, p, boot, suffix):
    unit = "mongo-upgrade-" + p["job_id"] + "-" + p["stage"] + suffix
    (directory / "unit").write_text(unit)
    (directory / "boot").write_text(boot)
    (directory / "phase").write_text("starting")
    try:
        run(["systemd-run", "--unit=" + unit, "/bin/bash", str(directory / "upgrade.sh"),
             str(directory), p["stage"], p["series"]])
    except Exception:
        (directory / "failed").write_text("systemd-run")
        raise
    return {"started": True}


def shell_js(source, values, timeout=120):
    # Script contains secrets; only the random file path appears in the process list.
    with tempfile.TemporaryDirectory(prefix="mongo-manager-") as directory:
        script = Path(directory) / "task.js"
        script.write_text("const input = " + json.dumps(values) + ";\n" + source)
        script.chmod(0o600)
        result = run(["mongosh", "--quiet", "--nodb", "--file", str(script)], timeout=timeout)
        return json.loads(result.splitlines()[-1])


def port_conflict(port):
    details = []
    if shutil.which("ss"):
        listeners = run(["ss", "-Hlntp", f"sport = :{port}"], check=False)
        for line in listeners.splitlines():
            owner = re.search(r'\("([^"]+)",pid=(\d+)', line)
            fields = line.split()
            if owner and len(fields) >= 4:
                details.append(f"{owner[1]} (PID {owner[2]}) tại {fields[3]}")
    owner_info = ", ".join(details) or "chưa xác định được tiến trình"
    return f"Cổng {port} đang được sử dụng: {owner_info}. Dùng node đã chuẩn bị đúng replica set và keyfile, giải phóng cổng hoặc chọn port khác cho instance mới."


def check_instance_target(p):
    instance = p["instance"]
    for base in ("/etc/mongodb-manager", "/var/lib/mongodb-manager", "/var/log/mongodb-manager"):
        if (Path(base) / instance).exists():
            raise RuntimeError("Instance hoặc dữ liệu đã tồn tại. Kiểm tra máy và tiếp nhận cấu hình, không chạy lại khởi tạo.")
    with socket.socket() as listener:
        try:
            listener.bind(("0.0.0.0", p["port"]))
        except OSError as exc:
            if exc.errno == 98:
                raise RuntimeError(port_conflict(p["port"])) from None
            raise


def provision(p):
    check_instance_target(p)
    if not shutil.which("mongod"):
        install(p)
    if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", run(["mongod", "--version"])):
        raise RuntimeError("Binary MongoDB đích không cùng nhánh đã chọn. Không tự thay phiên bản đang có.")
    return setup(p)


def setup(p, bootstrap=True):
    if linux_info().get("ID") != "ubuntu" or not shutil.which("systemctl"):
        raise RuntimeError("Setup service chỉ hỗ trợ Ubuntu dùng systemd.")
    if not shutil.which("mongod") or not shutil.which("mongosh"):
        raise RuntimeError("Cần cài MongoDB Server và mongosh trước.")
    instance = p["instance"]
    port = p["port"]
    service = f"mongod-manager-{instance}"
    root = Path("/etc/mongodb-manager") / instance
    data = Path("/var/lib/mongodb-manager") / instance
    check_instance_target(p)
    import pwd
    account = pwd.getpwnam("mongodb")
    logdir = Path("/var/log/mongodb-manager") / instance
    for directory in (root, data, logdir):
        try:
            directory.parent.mkdir(mode=0o711)
        except FileExistsError:
            pass
        else:
            directory.parent.chmod(0o711)
        directory.mkdir(mode=0o750)

        os.chown(directory, account.pw_uid, account.pw_gid)
    keyfile = root / "keyfile"
    keyfile.touch(mode=0o600, exist_ok=False)
    keyfile.write_text(base64.b64decode(p["keyfile_b64"]).decode() if not bootstrap else base64.b64encode(secrets.token_bytes(512)).decode())
    keyfile.chmod(0o400)
    os.chown(keyfile, account.pw_uid, account.pw_gid)
    config = {"storage": {"dbPath": str(data)}, "systemLog": {"destination": "file", "path": str(logdir / "mongod.log"), "logAppend": True},
              "net": {"port": port, "bindIp": p["bind_ip"]}, "replication": {"replSetName": p["replica_set"]},
              "security": {"authorization": "enabled", "keyFile": str(keyfile)}}
    # Direct IP endpoints are supported by this manager, without split-horizon DNS.
    config["setParameter"] = {"disableSplitHorizonIPCheck": True}
    configpath = root / "mongod.conf"
    configpath.write_text(json.dumps(config, indent=2))
    os.chown(configpath, account.pw_uid, account.pw_gid)
    configpath.chmod(0o600)
    unit = Path(f"/etc/systemd/system/{service}.service")
    unit.write_text(f"[Unit]\nDescription=MongoDB Manager {instance}\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nUser=mongodb\nGroup=mongodb\nExecStart=/usr/bin/mongod --config {configpath}\nRestart=on-failure\nLimitNOFILE=64000\nTimeoutStopSec=120\n\n[Install]\nWantedBy=multi-user.target\n")
    event("Đã tạo cấu hình và service riêng. Khởi động với keyfile và auth…")
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "--now", service])
    if not bootstrap:
        event("Node mới dùng keyfile của cụm nguồn. Không chạy replSetInitiate hoặc tạo user trên node này.")
        return {"prepared": True, "service": service, "config": str(configpath), "data": str(data)}
    try:
        result = shell_js('''
let conn;
for(let i=0;i<60;i++) { try { conn=new Mongo("mongodb://127.0.0.1:"+input.port+"/?directConnection=true&serverSelectionTimeoutMS=1000"); conn.getDB("admin").runCommand({ping:1}); break; } catch(e) { sleep(1000); } }
if(!conn) throw new Error("MongoDB chưa sẵn sàng");
const admin=conn.getDB("admin");
let r=admin.runCommand({replSetInitiate:{_id:input.replica_set,members:[{_id:0,host:input.advertise}]}});
if(!r.ok) throw new Error("Không khởi tạo được replica set");
let ready=false;
for(let i=0;i<60;i++){if(admin.runCommand({hello:1}).isWritablePrimary){ready=true;break;} sleep(1000);}
if(!ready) throw new Error("Chưa bầu được primary");
r=admin.runCommand({createUser:input.username,pwd:input.password,roles:[{role:"root",db:"admin"}]});
if(!r.ok) throw new Error("Không tạo được user");
if(!admin.auth(input.username,input.password)) throw new Error("Xác thực thất bại");
print(JSON.stringify({ready:true,primary:input.advertise}));
''', p, timeout=180)
    except Exception:
        event(f"Bootstrap chưa hoàn tất. Đã giữ lại cấu hình tại {root}; xem journal của {service}.")
        raise
    return {**result, "service": service, "config": str(configpath), "data": str(data), "keyfile": str(keyfile)}


def verify_other_loopback_listeners(service, listeners):
    unit = service if service.endswith(".service") else service + ".service"
    for row in listeners:
        address = row.split()[3].rsplit(":", 1)[0].strip("[]")
        pids = re.findall(r"pid=(\d+)", row)
        if address not in {"127.0.0.1", "::1"} or not pids:
            raise ValueError("Cổng MongoDB vẫn đang lắng nghe. Kiểm tra tiến trình trước khi xóa.")
        for pid in pids:
            groups = (Path("/proc") / pid / "cgroup").read_text().splitlines()
            units = {part for group in groups for part in group.split("/") if part.endswith(".service")}
            if unit in units or not units:
                raise ValueError("Chưa xác minh được tiến trình lắng nghe thuộc dịch vụ khác.")


def wiredtiger_directory(descriptors):
    paths = set()
    for descriptor in descriptors:
        try:
            target = descriptor.resolve(strict=True)
        except (FileNotFoundError, OSError):
            continue
        if target.name == "mongod.lock":
            paths.add(target.parent)
    if len(paths) != 1:
        raise ValueError("Không xác định được duy nhất một dbPath từ các file khóa của mongod đang chạy.")
    path = paths.pop()
    if not (path / "WiredTiger.wt").is_file():
        raise ValueError("dbPath của tiến trình không chứa WiredTiger.wt.")
    return path


def role_storage(p):
    pid = run(["systemctl", "show", "-p", "MainPID", "--value", p["service"]])
    proc = Path("/proc") / pid
    if not pid.isdigit() or pid == "0" or (proc / "exe").resolve().name != "mongod":
        raise ValueError("Không xác minh được mongod của service.")
    path = wiredtiger_directory((proc / "fd").iterdir())
    if path.is_mount() or not (path / "mongod.lock").is_file():
        raise ValueError("Thư mục dữ liệu không hỗ trợ lưu trữ bằng đổi tên.")
    if shutil.disk_usage(path).free < p["required_bytes"]:
        raise ValueError("VPS chưa đủ dung lượng trống cho bản đồng bộ mới.")
    version = re.search(r"db version v([0-9.]+)", run([str(proc / "exe"), "--version"]))
    if not version:
        raise ValueError("Chưa đọc được phiên bản mongod.")
    return {"path": str(path), "pid": int(pid), "inode": path.stat().st_ino, "device": path.stat().st_dev, "version": version[1]}


def role_restart(p):
    check_service_stopped(p)
    path = Path(p["path"])
    stat = path.stat()
    if path.resolve() != path or (stat.st_dev, stat.st_ino) != (p["device"], p["inode"]) or not (path / "WiredTiger.wt").is_file():
        raise ValueError("Thư mục dữ liệu đã thay đổi sau khi dừng dịch vụ.")
    archive = path.with_name(path.name + "-before-role-" + secrets.token_hex(8))
    path.rename(archive)
    event("Đã lưu thư mục cũ tại " + str(archive))
    path.mkdir(mode=0o700)
    os.chown(path, stat.st_uid, stat.st_gid)
    run(["systemctl", "enable", "--now", p["service"]], timeout=180)
    return {"archive": str(archive)}


def retire_member(p):
    service = p["service"]
    port = str(int(p["port"]))
    pid = run(["systemctl", "show", "-p", "MainPID", "--value", service])
    listeners = run(["ss", "-Hlnpt", f"sport = :{port}"]).splitlines()
    state = run(["systemctl", "is-active", service], check=False)
    if p.get("storage_pid") and pid != str(p["storage_pid"]):
        raise ValueError("Tiến trình mongod đã đổi sau khi kiểm tra thư mục dữ liệu.")
    if pid == "0" and state == "inactive":
        verify_other_loopback_listeners(service, listeners)
        load = run(["systemctl", "show", "-p", "LoadState", "--value", service])
        if load == "not-found":
            return {"service": service, "state": "inactive", "autostart": "not-found"}
    else:
        if not pid.isdigit() or int(pid) < 1 or not p.get("process_id") or not listeners:
            raise ValueError("Chưa xác minh được tiến trình MongoDB thuộc service đã chọn.")
        own = [row for row in listeners if f'"mongod",pid={pid},' in row]
        if not own:
            raise ValueError(f"Cổng MongoDB {port} không có tiến trình thuộc {service}. Kiểm tra tên service trong hồ sơ.")
        verify_other_loopback_listeners(service, [row for row in listeners if row not in own])
        if p.get("expected_pid"):
            if int(pid) != p["expected_pid"] or socket.gethostname() != p["expected_hostname"]:
                raise ValueError("PID hoặc hostname qua SSH không khớp endpoint MongoDB.")
        else:
            address = own[0].split()[3].rsplit(":", 1)[0].strip("[]")
            if address in {"0.0.0.0", "*", "::"}:
                address = "::1" if address == "::" else "127.0.0.1"
            try:
                host = '[' + address + ']' if ':' in address else address
                uri = f"mongodb://{host}:{port}/admin?directConnection=true&serverSelectionTimeoutMS=2000"
                output = run(["mongosh", "--quiet", uri, "--eval",
                              "const h=db.runCommand({hello:1});print(JSON.stringify({primary:h.isWritablePrimary,"
                              "process_id:h.topologyVersion.processId.toHexString()}))"], timeout=10)
                local = json.loads(output.splitlines()[-1])
            except (RuntimeError, OSError, ValueError) as exc:
                raise ValueError("Không đọc được hello tại địa chỉ bind " + address + ":" + port +
                                 ". Cần tài khoản có quyền serverStatus hoặc mongosh kết nối được đúng instance.") from exc
            if local.get("primary") or local.get("process_id") != p["process_id"]:
                raise ValueError("Tiến trình trên VPS không khớp endpoint hoặc vừa lên primary.")
        if not p["member_present"] and run(["ss", "-Hnt", "state", "established", f"sport = :{port}"]):
            raise ValueError("Node đã rời cụm nhưng cổng MongoDB còn kết nối vào.")
    run(["systemctl", "disable", "--now", service], timeout=150)
    if (run(["systemctl", "is-active", service], check=False) != "inactive"
            or run(["systemctl", "is-enabled", service], check=False) != "disabled"):
        raise RuntimeError("Chưa xác minh được service đã dừng và tắt tự khởi động.")
    verify_other_loopback_listeners(service, run(["ss", "-Hlnpt", f"sport = :{port}"]).splitlines())
    return {"service": service, "state": "inactive", "autostart": "disabled"}


def check_service_stopped(p):
    service = p["service"]
    if run(["systemctl", "is-active", service], check=False) != "inactive":
        raise ValueError("Dịch vụ MongoDB chưa dừng.")
    if p.get("port"):
        listeners = run(["ss", "-Hlnpt", f"sport = :{int(p['port'])}"]).splitlines()
        verify_other_loopback_listeners(service, listeners)
    if p.get("precheck"):
        return {"state": "inactive"}
    autostart = run(["systemctl", "is-enabled", service], check=False)
    if autostart in {"enabled", "enabled-runtime"}:
        run(["systemctl", "disable", service])
        autostart = run(["systemctl", "is-enabled", service], check=False)
    if autostart not in {"disabled", "not-found", "masked", "masked-runtime"}:
        raise ValueError("Chưa xác minh được tự khởi động của dịch vụ đã tắt.")
    if run(["systemctl", "is-active", service], check=False) != "inactive":
        raise ValueError("Dịch vụ MongoDB vừa đổi trạng thái. Kiểm tra lại trước khi xóa.")
    return {"state": "inactive"}


def prepare_member(p):
    if not p.get("replace_empty"):
        return prepare_instance(p)
    if p.get("service") != "mongod":
        raise ValueError("Chọn đúng service mongod của standalone.")
    port = int(p["port"])
    pid = run(["systemctl", "show", "mongod", "-p", "MainPID", "--value"])
    listeners = run(["ss", "-Hlntp", f"sport = :{port}"]).splitlines()
    if not listeners:
        return prepare_instance(p)
    if not pid.isdigit() or not all(len(row.split()) >= 4 and row.split()[3] == f"127.0.0.1:{port}"
                                    and f'("mongod",pid={pid},' in row for row in listeners):
        raise ValueError(port_conflict(port))
    if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", run(["mongod", "--version"])):
        raise ValueError("Standalone đang dùng cổng và khác nhánh MongoDB của primary. Kiểm tra phiên bản trước khi dừng.")
    if any(Path("/etc/mongodb-manager").glob("*/mongod.conf")):
        raise ValueError("Đã có instance Manager. Kiểm tra cấu hình trước khi thay standalone.")
    check = shell_js("""
const a=new Mongo("mongodb://127.0.0.1:"+input.port+"/?directConnection=true").getDB("admin");
const h=a.runCommand({hello:1}), d=a.runCommand({listDatabases:1,nameOnly:true});
print(JSON.stringify({empty:!!(h.ok && h.isWritablePrimary && !h.setName && !h.isreplicaset && !h.msg && d.ok &&
  d.databases.every(x=>["local","config","admin"].includes(x.name)))}));
""", {"port": port})
    if not check["empty"]:
        raise ValueError("Chưa xác minh được standalone trống. Giữ nguyên service.")
    enabled = run(["systemctl", "is-enabled", "mongod"], check=False) == "enabled"
    run(["systemctl", "disable", "--now", "mongod"])
    try:
        return prepare_instance(p)
    except Exception:
        if not run(["ss", "-Hlnt", f"sport = :{port}"]):
            run(["systemctl", "start", "mongod"])
            if enabled:
                run(["systemctl", "enable", "mongod"])
        raise


def prepare_instance(p):
    # A removed node can still own the port under its original service name.
    service = p.get('service', '')
    match = re.fullmatch(r'mongod-manager-([a-z][a-z0-9-]{0,30})', service)
    if match and run(['systemctl', 'is-active', service], check=False) == 'active':
        live_root = Path('/etc/mongodb-manager') / match.group(1)
        live_path = live_root / 'mongod.conf'
        pid = run(['systemctl', 'show', service, '-p', 'MainPID', '--value'])
        argv = (Path('/proc') / str(int(pid)) / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0')
        if argv == [b'/usr/bin/mongod', b'--config', os.fsencode(live_path)]:
            live = json.loads(live_path.read_text())
            if live.get('net', {}).get('port') == p['port']:
                security = live.get('security', {})
                keyfile = live_root / 'keyfile'
                if (live.get('replication', {}).get('replSetName') != p['replica_set']
                        or security.get('authorization') != 'enabled' or security.get('keyFile') != str(keyfile)
                        or ''.join(keyfile.read_text().split()) != ''.join(base64.b64decode(p['keyfile_b64']).decode().split())):
                    raise RuntimeError(f"Service {service} đang dùng cổng {p['port']} nhưng cấu hình replica set hoặc keyfile khác cụm nguồn.")
                version = run([f'/proc/{pid}/exe', '--version'])
                if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", version):
                    raise RuntimeError("Phiên bản service đang chạy khác nhánh nguồn.")
                event(f"Tái sử dụng service {service} đang chạy trên cổng {p['port']}.")
                return dict(prepared=True, reused=True, service=service, config=str(live_path), data=live['storage']['dbPath'])
    config_root = Path('/etc/mongodb-manager')
    if not (config_root / p['instance'] / 'mongod.conf').exists():
        matches = []
        for path in config_root.glob('*/mongod.conf'):
            instance = path.parent.name
            if not re.fullmatch(r'[a-z][a-z0-9-]{0,30}', instance):
                continue
            try:
                config = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if (config.get('replication', {}).get('replSetName') == p['replica_set']
                    and config.get('net', {}).get('port') == p['port']):
                matches.append(instance)
        if len(matches) > 1:
            raise ValueError('Có nhiều instance cũ cùng cụm và cổng. Nhập đúng tên instance cần bật lại.')
        if matches:
            p = dict(p, instance=matches[0])
    root = Path('/etc/mongodb-manager') / p['instance']
    data_root = Path('/var/lib/mongodb-manager')
    configpath = root / 'mongod.conf'
    existing = configpath.is_file()
    if not existing:
        check_instance_target(p)
    if not shutil.which("mongod"):
        if existing:
            raise RuntimeError("Đã có cấu hình instance nhưng thiếu binary mongod.")
        install(p)
    version = run(["mongod", "--version"])
    if not re.search(r"\bv" + re.escape(p["series"]) + r"\.", version):
        raise RuntimeError("Binary MongoDB đích không cùng nhánh với cụm nguồn. Không tự thay phiên bản đang có.")
    if existing:
        config = json.loads(configpath.read_text())
        keypath = root / 'keyfile'
        expected_key = base64.b64decode(p['keyfile_b64']).decode()
        raw_data = config.get('storage', {}).get('dbPath', '')
        data = data_root / os.path.basename(raw_data)
        checks = {
            'replSetName': config.get('replication', {}).get('replSetName') == p['replica_set'],
            'net.port': config.get('net', {}).get('port') == p['port'],
            'storage.dbPath': raw_data == str(data) and data != data_root and data.is_dir()
                              and data.resolve().parent == data_root.resolve(),
            'security.keyFile': config.get('security', {}).get('keyFile') == str(keypath) and keypath.is_file(),
            'security.authorization': config.get('security', {}).get('authorization') == 'enabled',
        }
        if checks['security.keyFile']:
            checks['nội dung keyfile'] = ''.join(keypath.read_text().split()) == ''.join(expected_key.split())
        mismatches = [name for name, valid in checks.items() if not valid]
        if mismatches:
            raise RuntimeError('Instance có sẵn không khớp: ' + ', '.join(mismatches) + '. Không ghi đè cấu hình.')
        service = 'mongod-manager-' + p['instance']
        if run(['systemctl', 'is-active', service], check=False) != 'active':
            unit = run(['systemctl', 'show', '-p', 'FragmentPath', '--value', service])
            if unit != f'/etc/systemd/system/{service}.service':
                raise ValueError('Không tìm thấy unit systemd do Manager tạo cho instance cũ.')
            exec_start = run(['systemctl', 'show', '-p', 'ExecStart', '--value', service])
            if f'argv[]=/usr/bin/mongod --config /etc/mongodb-manager/{p["instance"]}/mongod.conf ;' not in exec_start:
                raise ValueError('Unit systemd không dùng đúng cấu hình instance cũ.')
            event('Đã xác minh instance cũ. Bật lại dịch vụ và tự khởi động…')
            run(['systemctl', 'enable', '--now', service])
        else:
            event('Instance do manager tạo đã chạy và khớp cấu hình. Tái sử dụng, không cài lại hoặc xóa dữ liệu.')
        return {'prepared': True, 'reused': True, 'service': service, 'config': str(configpath), 'data': str(data)}
    return setup(p, bootstrap=False)


def read_keyfile(p):
    path = Path(p["path"])
    if not path.is_absolute() or not path.is_file() or path.stat().st_size > 16384:
        raise RuntimeError("Keyfile nguồn không hợp lệ hoặc quá lớn.")
    return {"keyfile_b64": base64.b64encode(path.read_bytes()).decode()}


def member_network(p):
    # A node must reach its own advertised endpoint as well as existing members.
    failures = []
    for endpoint in p['endpoints']:
        host, port = endpoint.rsplit(':', 1)
        try:
            with socket.create_connection((host.strip('[]'), int(port)), timeout=5):
                pass
        except OSError:
            failures.append(endpoint)
    if failures:
        raise RuntimeError('VPS đích không kết nối được tới ' + ', '.join(failures) + '. Kiểm tra firewall, NAT và đường mạng; bao gồm kết nối tới chính endpoint quảng bá. Chưa thêm membership.')
    return {'reachable': True, 'checked': len(p['endpoints'])}


def backups_root(create=True):
    root = Path("/var/backups/mongodb-manager")
    if root.is_symlink():
        raise RuntimeError("Thư mục backup không được là symlink.")
    if create:
        root.mkdir(parents=True, mode=0o700, exist_ok=True)
    return root


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def backup(p):
    root = backups_root()
    key = secrets.token_hex(16)
    directory = root / key
    directory.mkdir(mode=0o700)
    databases = p.get("databases") or ([p["database"]] if p.get("database") else [])
    oplog = not databases and p.get("replica", True)
    archives = []
    try:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "tools.json"
            cfg.write_text(json.dumps(p["connection"]))
            cfg.chmod(0o600)
            collections = p.get("collections") or ([p["collection"]] if p.get("collection") else [None])
            scopes = [(db, col) for db in databases or [None] for col in collections]
            for index, (database, collection) in enumerate(scopes):
                name = f"part-{index}.archive.gz"
                archive = directory / name
                output = "--out=" + str(directory / "dump") if oplog else "--archive=" + str(archive)
                cmd = ["mongodump", output, "--gzip", "--config=" + str(cfg)]
                if database:
                    cmd += ["--db", database]
                    if collection:
                        cmd.append("--collection=" + collection)
                elif oplog:
                    cmd.append("--oplog")
                event("Đang backup: " + (database or "toàn cụm") + ("." + collection if collection else ""))
                run(cmd, timeout=7200)
                if oplog:
                    file = directory / "dump" / "oplog.bson"
                    if not file.exists():
                        file = file.with_suffix(".bson.gz")
                    oplog_file = directory / "oplog.bson"
                    with file.open("rb") as stream:
                        compressed = stream.read(2) == b"\x1f\x8b"
                    if compressed:
                        with gzip.open(file, "rb") as src, oplog_file.open("wb") as dest:
                            shutil.copyfileobj(src, dest)
                        file.unlink()
                    else:
                        file.rename(oplog_file)
                    continue
                archives.append({"file": name, "database": database, "collection": collection, "sha256": checksum(archive), "size": archive.stat().st_size})
        meta = {"id": key, "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "application_only": p.get("application_only", False), "databases": databases, "database": ", ".join(databases) or "Tất cả", "archives": archives,
                "collections": p.get("collections", []), "collection": p.get("collection", ""), "oplog": oplog, "size": sum(a["size"] for a in archives),
                "source": p["source"], "source_id": p.get("source_id"), "verified_restore": False, "compatibility": p["compatibility"],
                "tools_version": run(["mongodump", "--version"])}
        if oplog:
            files = [f for f in (directory / "dump").rglob("*") if f.is_file()] + [oplog_file]
            meta["files"] = {str(f.relative_to(directory)): checksum(f) for f in files}
            meta["size"] = sum(f.stat().st_size for f in files)
        pending = directory / "manifest.tmp"
        pending.write_text(json.dumps(meta, indent=2))
        pending.replace(directory / "manifest.json")
        return meta
    except Exception:
        shutil.rmtree(directory)
        raise


def delete_backup(p):
    key = p["backup_id"]
    if not re.fullmatch(r"[0-9a-f]{32}", key):
        raise ValueError("ID backup không hợp lệ.")
    folder = backups_root(create=False) / key
    manifest = folder / "manifest.json"
    if (folder.is_symlink() or manifest.is_symlink() or not manifest.is_file()
            or json.loads(manifest.read_text()).get("id") != key):
        raise ValueError("Không tìm thấy đúng bản backup trên máy đã chọn.")
    shutil.rmtree(folder)
    return {"deleted": key}


def list_backups(p):
    return sorted([json.loads(f.read_text()) for f in backups_root(create=False).glob("*/manifest.json") if not f.is_symlink()], key=lambda b: b["time"], reverse=True)


def bson_frames(stream, archive=False):
    while True:
        prefix = stream.read(4)
        if not prefix:
            return
        if archive and prefix == b"\xff" * 4:
            yield None
            continue
        size = int.from_bytes(prefix, "little")
        if len(prefix) != 4 or not 5 <= size <= 32 * 1024 * 1024:
            raise ValueError("Kích thước BSON trong backup không hợp lệ.")
        body = stream.read(size - 4)
        if len(body) != size - 4 or body[-1:] != b"\x00":
            raise ValueError("Dữ liệu BSON trong backup bị thiếu.")
        yield prefix + body


def archive_namespace(frame):
    # Both MongoDB archive metadata and block headers begin with these BSON strings.
    pos = 4
    names = []
    for field in (b"db", b"collection"):
        tag = b"\x02" + field + b"\x00"
        if not frame.startswith(tag, pos):
            raise ValueError("Định dạng header archive chưa được hỗ trợ.")
        pos += len(tag)
        size = int.from_bytes(frame[pos:pos+4], "little")
        pos += 4
        if not size or pos + size > len(frame) or frame[pos+size-1] != 0:
            raise ValueError("Tên namespace trong archive không hợp lệ.")
        names.append(frame[pos:pos+size-1].decode())
        pos += size
    return tuple(names)


def preview_backup(p):
    key = p["backup_id"]
    if not re.fullmatch(r"[a-f0-9]{32}", key):
        raise ValueError("ID backup không hợp lệ.")
    directory = backups_root(create=False) / key

    def checked(name):
        path = directory / name
        if (Path(name).is_absolute() or ".." in Path(name).parts or directory.is_symlink()
                or path.resolve() != directory.resolve() / name or not path.is_file()):
            raise ValueError("File backup không hợp lệ.")
        return path

    meta = json.loads(checked("manifest.json").read_text())
    selected = (p.get("database"), p.get("collection"))
    listing = not any(selected)
    namespaces = set()
    records = []
    skip = p.get("offset", 0)
    total = 0

    def visible(ns):
        return ns[0] not in {"local", "config"} and not ns[1].startswith("system.") and all(ns)

    def accept(frame):
        nonlocal skip, total
        if skip:
            skip -= 1
        elif len(records) >= 25 or (records and total + len(frame) > 2_000_000):
            return False
        else:
            records.append(base64.b64encode(frame).decode())
            total += len(frame)
        return True

    more = False
    if "files" in meta:
        for name in meta["files"]:
            rel = Path(name)
            if len(rel.parts) != 3 or rel.parts[0] != "dump" or not name.endswith(".bson.gz"):
                continue
            coll = rel.name[:-len(".bson.gz")]
            metadata = str(rel.with_name(coll + ".metadata.json.gz"))
            if metadata in meta["files"]:
                with gzip.open(checked(metadata), "rt") as stream:
                    coll = json.load(stream).get("collectionName", coll)
            ns = (rel.parts[1], coll)
            if not visible(ns):
                continue
            namespaces.add(ns)
            if ns == selected:
                with gzip.open(checked(name), "rb") as stream:
                    more = not all(accept(frame) for frame in bson_frames(stream))
                break
    else:
        for part in meta.get("archives") or [{"file":"backup.archive.gz"}]:
            if not re.fullmatch(r"(backup|part-[0-9]+)\.archive\.gz", part["file"]):
                raise ValueError("Tên archive không hợp lệ.")
            with gzip.open(checked(part["file"]), "rb") as stream:
                if stream.read(4) != bytes.fromhex("6de29981"):
                    raise ValueError("File không phải MongoDB archive.")
                frames = bson_frames(stream, archive=True)
                next(frames)  # archive version header
                members = set()
                for frame in frames:
                    if frame is None:
                        break
                    ns = archive_namespace(frame)
                    if visible(ns):
                        members.add(ns)
                namespaces.update(members)
                if listing or selected not in members:
                    continue
                for header in frames:
                    if header is None:
                        raise ValueError("Thiếu header của khối BSON.")
                    ns = archive_namespace(header)
                    for frame in frames:
                        if frame is None:
                            break
                        if ns == selected and not accept(frame):
                            more = True
                            break
                    if more:
                        break
                break
    if not listing and selected not in namespaces:
        raise ValueError("Collection không có trong bản backup.")
    return {"namespaces": sorted(namespaces) if listing else [], "records": records, "more": more}


def check_restore_compatibility(source, target):
    if not source or source.get("fcv") != target.get("fcv") or source.get("version", "").split(".")[:2] != target.get("version", "").split(".")[:2]:
        raise RuntimeError("Restore yêu cầu cùng nhánh MongoDB và FCV với nguồn. Backup cũ thiếu metadata cần kiểm tra và restore thủ công.")


def collection_signature(archive, namespace):
    """Compare a single collection across dump order and archive block boundaries."""
    count = total = 0
    with gzip.open(archive, "rb") as stream:
        if stream.read(4) != bytes.fromhex("6de29981"):
            raise ValueError("Archive không hợp lệ.")
        frames = bson_frames(stream, archive=True)
        next(frames)
        header = next(frames)
        if not header or archive_namespace(header) != namespace or next(frames) is not None:
            return None
        # The archive collection header starts with db, collection, metadata (BSON strings).
        pos = 4
        for key in (b"db", b"collection", b"metadata"):
            tag = b"\x02" + key + b"\x00"
            if not header.startswith(tag, pos):
                return None
            pos += len(tag)
            size = int.from_bytes(header[pos:pos+4], "little")
            value = header[pos+4:pos+3+size]
            pos += 4 + size
        meta = json.loads(value)
        meta.pop("uuid", None)  # Ordinary restores allocate a new collection UUID.
        if "indexes" in meta:
            meta["indexes"].sort(key=lambda idx: idx["name"])
        for block in frames:
            if block is None or archive_namespace(block) != namespace:
                return None
            for frame in frames:
                if frame is None:
                    break
                count += 1
                total = (total + int.from_bytes(hashlib.sha256(frame).digest(), "big")) % (1 << 256)
    # Preserve key order in compound index definitions.
    return count, total, json.dumps(meta, ensure_ascii=False)


def restore(p):
    directory = backups_root(create=False) / p["backup_id"]
    if directory.is_symlink():
        raise RuntimeError("Đường dẫn backup không hợp lệ.")
    manifest = directory / "manifest.json"
    if not manifest.is_file():
        raise ValueError("Không tìm thấy manifest của bản backup trên máy lưu đã chọn. Làm mới danh sách trên máy đã tạo backup rồi nhấn Restore ở đúng dòng.")
    meta = json.loads(manifest.read_text())
    check_restore_compatibility(meta.get("compatibility"), p["compatibility"])
    if "files" in meta:
        dump = directory / "dump"
        oplog = directory / "oplog.bson"
        files = list(dump.rglob("*")) + [oplog]
        if dump.is_symlink() or any(f.is_symlink() for f in files):
            raise RuntimeError("Đường dẫn bản backup không hợp lệ.")
        actual = {str(f.relative_to(directory)): checksum(f) for f in files if f.is_file()}
        if not oplog.is_file() or actual != meta["files"]:
            raise RuntimeError("Checksum backup không khớp.")
        parts = []
    else:
        parts = meta.get("archives") or [{"file": "backup.archive.gz", "sha256": meta["sha256"]}]
    archives = []
    for part in parts:
        name = part["file"]
        if not re.fullmatch(r"(?:backup|part-[0-9]+)\.archive\.gz", name):
            raise RuntimeError("Tên archive không hợp lệ.")
        archive = directory / name
        if archive.is_symlink() or checksum(archive) != part["sha256"]:
            raise RuntimeError("Checksum backup không khớp.")
        archives.append(archive)
    with tempfile.TemporaryDirectory() as tmp:
        cfg = Path(tmp) / "tools.json"
        cfg.write_text(json.dumps(p["connection"]))
        cfg.chmod(0o600)
        if "files" in meta:
            base = ["mongorestore", "--gzip", "--stopOnError", "--config=" + str(cfg)]
            event("Đang restore dữ liệu và tài khoản từ bản toàn cụm.")
            run(base + (["--drop", "--preserveUUID"] if p.get("drop") else []) + [str(dump)], timeout=7200)
            # Restoring admin can invalidate the authenticated session; replay with a new connection.
            empty = Path(tmp) / "replay"
            empty.mkdir()
            event("Đang kết nối lại để replay oplog trên cụm đích.")
            replay = ["mongorestore", "--stopOnError", "--config=" + str(cfg), "--oplogReplay", "--oplogFile=" + str(oplog)]
            run(replay + [str(empty)], timeout=7200)
        for part, archive in zip(parts, archives):
            command = ["mongorestore", "--archive=" + str(archive), "--gzip", "--stopOnError", "--config=" + str(cfg)]
            if meta["oplog"]:
                command.append("--oplogReplay")
            if p.get("drop"):
                command.append("--drop")
            event("Đang restore: " + (part.get("database") or meta["database"]))
            try:
                run(command, timeout=7200)
            except RuntimeError as exc:
                namespace = (part.get("database"), part.get("collection"))
                if p.get("drop") or meta.get("oplog") or not all(namespace) or "Document trùng khóa" not in str(exc):
                    raise
                event("Đang đối chiếu document, cấu hình và index tại đích: " + ".".join(namespace))
                check = Path(tmp) / "check.archive.gz"
                run(["mongodump", "--config=" + str(cfg), "--gzip", "--archive=" + str(check),
                     "--db=" + namespace[0], "--collection=" + namespace[1]], timeout=7200)
                expected = collection_signature(archive, namespace)
                if expected is None or expected != collection_signature(check, namespace):
                    raise RuntimeError("Collection đích khác bản backup và có khóa trùng. Chỉ chọn thay thế collection nếu muốn ghi đè dữ liệu đích.") from exc
                event(f"Đã đối chiếu khớp {expected[0]} document và metadata. Collection đã có đủ dữ liệu.")
    return {"restored": True, "backup_id": p["backup_id"], "message": "mongorestore hoàn tất. Kiểm tra dữ liệu ứng dụng trên cụm đích."}


def stopped_mongo_package(p):
    service = p["service"]
    state = run(["systemctl", "is-active", service], check=False)
    if state != "inactive":
        return {}
    if run(["systemctl", "show", "-p", "LoadState", "--value", service]) != "loaded":
        package = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev}", "mongodb-org-server"], check=False)
        if (not shutil.which("mongod") and package.strip() not in {"ii", "hi"}
                and not run(["pgrep", "-x", "mongod"], check=False)):
            return {"role": "NOT_INSTALLED"}
        raise ValueError("Không tìm thấy dịch vụ MongoDB đã cấu hình trên VPS.")
    status = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Version}", "mongodb-org-server"], check=False).split()
    if len(status) != 2 or status[0] not in {"ii", "hi"}:
        raise ValueError("Không tìm thấy gói mongodb-org-server đã cài.")
    return dict(current=status[1], role="INACTIVE", port=p["port"],
                machine_token=hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest())


def arbiter_packages(action, p):
    service = p["service"]
    codename = linux_info().get("VERSION_CODENAME", "")
    series = p["version"].rsplit(".", 1)[0]
    if codename not in SUPPORTED.get(series, ()) or not re.fullmatch(r"\d+\.\d+\.\d+", p["version"]):
        raise ValueError("Không có gói MongoDB cho Ubuntu và nhánh đã chọn.")
    offline = p.get("role") == "INACTIVE"
    if offline:
        state = stopped_mongo_package(p)
        if (state.get("current") != p["current"] or state.get("machine_token") != p["machine_token"]
                or run(["pgrep", "-x", "mongod"], check=False)):
            raise ValueError("Phiên bản gói, máy hoặc tiến trình mongod đã đổi. Kiểm tra lại VPS.")
    else:
        pid = run(["systemctl", "show", "-p", "MainPID", "--value", service])
        listeners = run(["ss", "-Hlnpt", f"sport = :{int(p['port'])}"])
        if not pid.isdigit() or run(["pgrep", "-x", "mongod"]).split() != [pid] or f'"mongod",pid={pid},' not in listeners:
            raise ValueError("Cổng endpoint và service phải thuộc cùng một instance mongod duy nhất.")
        process_id = run(["mongosh", "--quiet", "--host", "127.0.0.1", "--port", str(p["port"]), "--eval",
                          "db.hello().topologyVersion.processId.toHexString()"])
        if process_id != p["process_id"]:
            raise ValueError("Instance trên kết nối SSH khác arbiter của endpoint.")
    packages = []
    for name in MONGO_PACKAGES:
        status = run(["dpkg-query", "-W", "-f=${db:Status-Abbrev} ${Version}", name], check=False).split()
        if status and status[0] == "hi":
            raise ValueError("Gói MongoDB đang được hold: " + name)
        if status and status[0] == "ii":
            if status[-1] != p["current"]:
                raise ValueError("Phiên bản gói đã cài khác phiên bản mongod đang chạy.")
            packages.append(name)
    if "mongodb-org-server" not in packages or run(["dpkg", "--audit"]):
        raise ValueError("Cần mongodb-org-server do apt quản lý và trạng thái dpkg hoàn chỉnh.")
    args = ["apt-get", "-y", "--no-remove", "-o", "Dpkg::Options::=--force-confold"]
    pinned = [name + "=" + p["version"] for name in packages]
    if action in {"arbiter_check", "arbiter_packages"}:
        arch = ubuntu_architecture()
        package_version(series, codename, arch, p["version"])
        if action == "arbiter_check":
            return {"service": service, "packages": packages}
        configure_mongo_repo(series, codename, arch)
        package_run(["apt-get", "-o", "Acquire::Retries=3", "update"], timeout=600)
        package_run([*args, "--download-only", "install", *pinned], timeout=1200)
    elif offline:
        masked = run(["systemctl", "is-enabled", "mongod.service"], check=False) in {"masked", "masked-runtime"}
        if not masked:
            run(["systemctl", "mask", "--runtime", "mongod.service"])
        try:
            if run(["systemctl", "show", "-p", "LoadState", "--value", "mongod.service"]) != "masked":
                raise ValueError("Chưa khóa được dịch vụ mặc định trong khi cập nhật gói.")
            package_run([*args, "--no-download", "install", *pinned], timeout=1200)
        finally:
            if not masked:
                run(["systemctl", "unmask", "--runtime", "mongod.service"])
    else:
        run(["systemctl", "stop", service])
        try:
            package_run([*args, "--no-download", "install", *pinned], timeout=1200)
        finally:
            run(["systemctl", "start", service])
    return {"service": service}


STARTUP_HINTS = (
    (r"address already in use|EADDRINUSE", "Cổng bị chiếm. Đối chiếu PID đang lắng nghe với MainPID của service."),
    (r"permissions on .*too open", "Keyfile cho phép nhóm hoặc người khác truy cập. Kiểm tra quyền keyfile."),
    (r"permission denied|operation not permitted", "Truy cập bị từ chối. Kiểm tra owner và quyền của dbPath, đường dẫn log và keyfile."),
    (r"no space left|ENOSPC", "Hết dung lượng hoặc inode. Kiểm tra filesystem chứa dữ liệu và log."),
    (r"error parsing YAML|unrecognized option|error parsing command line", "Cấu hình không hợp lệ. Kiểm tra cú pháp và tên tùy chọn trong file cấu hình của service."),
    (r"WT_PANIC|WT_TRY_SALVAGE|checksum mismatch", "WiredTiger báo lỗi dữ liệu. Bảo toàn dbPath và kiểm tra bản backup trước khi phục hồi."),
)


def startup_diagnosis(service, port=None):
    state = run(["systemctl", "show", service, "-p", "ActiveState", "-p", "Result", "-p", "MainPID", "-p", "ExecMainStatus"], check=False)
    journal = run(["journalctl", "-b", "-u", service, "-n", "100", "--no-pager", "-o", "cat"], check=False)
    paths = {}
    match = re.fullmatch(r"mongod-manager-([a-z][a-z0-9-]{0,30})", service)
    if match:
        instance = match[1]
        config = Path("/etc/mongodb-manager") / instance / "mongod.conf"
        try:
            settings = json.loads(config.read_text())
            for section, option in (("storage", "dbPath"), ("systemLog", "path"), ("security", "keyFile")):
                path = Path(settings[section][option])
                try:
                    meta = path.lstat()
                    paths[option] = dict(path=str(path), uid=meta.st_uid, gid=meta.st_gid,
                                         mode=oct(meta.st_mode & 0o777), free_bytes=shutil.disk_usage(path.parent).free)
                except OSError:
                    paths[option] = dict(path=str(path), error="Không đọc được metadata.")
        except (OSError, ValueError, TypeError, KeyError):
            paths["config"] = "Không đọc được cấu hình JSON chuẩn của instance Manager."
    hints = [hint for pattern, hint in STARTUP_HINTS if re.search(pattern, journal, re.I)]
    listener = run(["ss", "-Hlntp", f"sport = :{int(port)}"], check=False) if port and shutil.which("ss") else ""
    return {"service": service, "systemd": state, "listener": listener, "paths": paths, "findings": hints or [
        "Journal chưa đủ để kết luận. Xem systemLog.path của instance và nhật ký MongoDB tại thời điểm lỗi."]}


def repair_keyfile(service):
    import pwd
    import stat
    match = re.fullmatch(r"mongod-manager-([a-z][a-z0-9-]{0,30})", service)
    if not match:
        raise ValueError("Chỉ sửa keyfile của instance do Manager tạo.")
    root = Path("/etc/mongodb-manager") / match[1]
    config = root / "mongod.conf"
    key = root / "keyfile"

    def prop(name):
        return run(["systemctl", "show", service, "-p", name, "--value"])

    if (prop("ActiveState") not in {"inactive", "failed"} or prop("User") != "mongodb"
            or prop("FragmentPath") != f"/etc/systemd/system/{service}.service"
            or f"argv[]=/usr/bin/mongod --config {config} ;" not in prop("ExecStart")):
        raise ValueError("Cần instance Manager đã dừng và dùng đúng cấu hình.")
    if config.resolve() != config or json.loads(config.read_text()).get("security", {}).get("keyFile") != str(key):
        raise ValueError("Cấu hình không trỏ đến keyfile của instance.")
    fd = os.open(key, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != pwd.getpwnam("mongodb").pw_uid:
            raise ValueError("Chưa xác minh được owner hoặc loại file của keyfile.")
        if stat.S_IMODE(info.st_mode) in {0o400, 0o600}:
            raise ValueError("Quyền keyfile đã phù hợp. Chạy chẩn đoán để tìm nguyên nhân khác.")
        event(f"{key}: {stat.S_IMODE(info.st_mode):04o} → 0400")
        os.fchmod(fd, 0o400)
    finally:
        os.close(fd)


def service_operation(p):
    service, operation = p["service"], p["operation"]
    if operation == "diagnose":
        return startup_diagnosis(service, p.get("mongo_port"))
    if operation == "repair_keyfile":
        repair_keyfile(service)
        operation = "start"
    try:
        run(["systemctl", operation, service], timeout=180)
        state = run(["systemctl", "is-active", service], check=False)
        if operation in {"start", "restart"} and state != "active":
            raise RuntimeError("Service chưa active.")
    except (RuntimeError, subprocess.TimeoutExpired):
        if operation in {"start", "restart"}:
            report = startup_diagnosis(service, p.get("mongo_port"))
            event(report["systemd"])
            if report["listener"]:
                event(report["listener"])
            raise RuntimeError(" ".join(report["findings"])) from None
        raise
    return {"state": state, "operation": operation}


def main(request):
    p = request["params"]
    action = request["action"]
    if action == "package_activity":
        return package_activity()
    if action == "package_recover":
        return recover_packages()
    if action == "mongo_stopped_package":
        return stopped_mongo_package(p)
    if action == "mongo_latest":
        return {"version": package_version(p["series"], linux_info().get("VERSION_CODENAME", ""), ubuntu_architecture())}
    if action in {"arbiter_check", "arbiter_packages", "arbiter_install"}:
        return arbiter_packages(action, p)
    if action.startswith("ubuntu_"):
        return ubuntu_action(action, p)
    if action == "public_address":
        direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with direct.open("https://api.ipify.org", timeout=8) as response:
            return {"ip": response.read(64).decode("ascii").strip()}
    if action == "check_service_stopped":
        return check_service_stopped(p)
    if action == "role_storage":
        return role_storage(p)
    if action == "role_restart":
        return role_restart(p)
    if action == "retire_member":
        return retire_member(p)
    if action == "hostname":
        return {"hostname": socket.gethostname()}
    if action == "preflight":
        return preflight(p)
    if action == "logs":
        return {"log": run(["journalctl", "-u", p["service"], "--no-pager", "-n", "100"], check=False)}
    if action == "service":
        return service_operation(p)
    handlers = {"install": install, "setup": setup, "provision": provision, "prepare_member": prepare_member,
                "read_keyfile": read_keyfile, "member_network": member_network, "backup": backup, "backups": list_backups, "delete_backup": delete_backup, "preview_backup": preview_backup, "restore": restore}
    if action not in handlers:
        raise RuntimeError("Tác vụ không được hỗ trợ.")
    return handlers[action](p)


def serve(request):
    global LTS, SUPPORTED
    if "release_catalog" in request:
        data = request["release_catalog"]
        LTS, SUPPORTED = data["lts"], data["supported"]
    try:
        result = main(request)
        print(json.dumps({"result": result}, ensure_ascii=False), flush=True)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    serve(json.load(sys.stdin))
