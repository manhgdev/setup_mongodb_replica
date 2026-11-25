#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p dist
archive="dist/mongodb-manager-web.tar.gz"
tar --exclude='__pycache__' --exclude='*.pyc' -czf "$archive" \
    gateway apps shared web deploy requirements-web.txt start-web.sh pm2.start.json README.md README_JOIN_REPLICA.md BACKUP.MD previews README_WEB.md WEB_VALIDATION.md
echo "Đã tạo $archive"
echo 'Gói chỉ chứa ứng dụng và hướng dẫn; không chứa mật khẩu, .web-data hoặc .venv.'
