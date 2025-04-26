#!/bin/bash

PRIMARY_HOST="$1"
MONGODB_USER="$2"
MONGODB_PASS="$3"
AUTH_DB="admin"

# Hàm lấy IP của node hiện tại
get_current_ip() {
    local ip=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' 2>/dev/null | grep -v '^127\.' | head -n 1 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' 2>/dev/null)
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' 2>/dev/null | grep -Eo '([0-9]*\.){3}[0-9]*' 2>/dev/null | grep -v '127.0.0.1' 2>/dev/null | head -n 1 2>/dev/null)
    fi
    echo "$ip"
}

echo -e "Vui lòng nhập IP của PRIMARY node"
read -p "PRIMARY node IP: " PRIMARY_HOST
if [ -z "$PRIMARY_HOST" ]; then
  PRIMARY_HOST=$(get_current_ip)
fi

if [ -z "$PRIMARY_HOST" ] || [ -z "$MONGODB_USER" ] || [ -z "$MONGODB_PASS" ]; then
  echo "Usage: $0 <PRIMARY_HOST> <MONGODB_USER> <MONGODB_PASS>"
  exit 1
fi

read -p "Nhập SECONDARY_HOST (ví dụ: 192.168.1.2:27017): " SECONDARY_HOST

if [ -z "$SECONDARY_HOST" ]; then
  echo "SECONDARY_HOST không được để trống!"
  exit 1
fi

mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --eval "
rs.add('$SECONDARY_HOST');
var cfg = rs.conf();
for (var i = 0; i < cfg.members.length; i++) {
  if (cfg.members[i].host === '$SECONDARY_HOST') {
    cfg.members[i].priority = 3;
  }
}
cfg.version += 1;
rs.reconfig(cfg);
"