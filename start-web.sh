#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Check before importing the app: starting a second worker also runs job recovery.
probe_python=.venv/bin/python
[[ -x "$probe_python" ]] || probe_python=python3
if "$probe_python" - <<'PYTHON'
import http.client
import json
import socket
import sys

try:
    sock = socket.create_connection(("127.0.0.1", 8765), timeout=2)
except ConnectionRefusedError:
    sys.exit(1)
with sock:
    conn = http.client.HTTPConnection("127.0.0.1", 8765, timeout=3)
    conn.sock = sock
    try:
        conn.request("GET", "/api/auth/status", headers={"X-MongoDB-Manager": "1"})
        response = conn.getresponse()
        status = json.loads(response.read(8192))
        if response.status == 200 and isinstance(status, dict) and {"enabled", "authenticated", "csrf", "public_url"} <= status.keys():
            conn.request("GET", "/vps/")
            vps = conn.getresponse()
            if vps.status != 200 or b"ZM VPS Manager" not in vps.read(16384):
                print("Cổng 8765 đang chạy bản Manager cũ. Chờ tác vụ hoàn tất rồi khởi động lại service.", file=sys.stderr)
                sys.exit(3)
            print("Manager đang chạy: http://127.0.0.1:8765/ và http://127.0.0.1:8765/vps/")
            sys.exit(0)
    except (OSError, ValueError, http.client.HTTPException):
        pass
    sys.exit(2)
PYTHON
then
    exit 0
else
    probe_status=$?
    if [[ $probe_status == 3 ]]; then exit 3; fi
    if [[ $probe_status != 1 ]]; then
        echo 'Cổng 8765 đang được sử dụng nhưng chưa xác nhận được MongoDB Manager.' >&2
        exit 1
    fi
fi
if [[ ! -x .venv/bin/python ]]; then
    if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        echo 'Cần Python 3.10 trở lên để tạo môi trường MongoDB Manager.' >&2
        exit 1
    fi
    python3 -m venv .venv || {
        echo 'Trên Ubuntu, cài python3-venv trước khi chạy lại.' >&2
        exit 1
    }
fi
if ! .venv/bin/python -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo 'Python trong .venv cần phiên bản 3.10 trở lên. Hãy tạo lại môi trường Python.' >&2
    exit 1
fi
if ! .venv/bin/python - <<'PYTHON'
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
try:
    from packaging.requirements import Requirement
    manifests = [Path("apps/mongodb_manager/requirements.txt"), Path("apps/vps_manager/requirements.txt")]
    for line in {line for manifest in manifests for line in manifest.read_text().splitlines()}:
        if line.strip() and not line.startswith("#"):
            req = Requirement(line)
            if version(req.name) not in req.specifier:
                raise SystemExit(1)
    import fastapi, uvicorn, pymongo, cryptography, paramiko
except (ImportError, PackageNotFoundError):
    raise SystemExit(1)
PYTHON
then
    if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
        .venv/bin/python -m ensurepip --upgrade
    fi
    .venv/bin/python -m pip install -r requirements-web.txt
fi
echo 'MongoDB Manager: http://127.0.0.1:8765'
echo 'Chỉ lắng nghe trên máy này. Ctrl+C để dừng.'
exec .venv/bin/python -m uvicorn gateway.app:app --host 127.0.0.1 --port 8765 --workers 1 --proxy-headers --forwarded-allow-ips=127.0.0.1,::1
