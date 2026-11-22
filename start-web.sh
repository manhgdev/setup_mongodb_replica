#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo 'Cần Python 3.10 trở lên để chạy MongoDB Manager.' >&2
    exit 1
fi
if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
fi
if ! .venv/bin/python -c 'import fastapi, uvicorn, pymongo, cryptography, paramiko' >/dev/null 2>&1; then
    .venv/bin/python -m ensurepip --upgrade
    .venv/bin/python -m pip install -r requirements-web.txt
fi
echo 'MongoDB Manager: http://127.0.0.1:8765'
echo 'Chỉ lắng nghe trên máy này. Ctrl+C để dừng.'
exec .venv/bin/python -m uvicorn web.app:app --host 127.0.0.1 --port 8765 --workers 1 --proxy-headers --forwarded-allow-ips=127.0.0.1,::1
