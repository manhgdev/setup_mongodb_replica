#!/bin/bash

MONGODB_USER="manhg"
MONGODB_PASS="manhnk"
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
read -p "PRIMARY node IP: " PRIMARY_IP
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP=$(get_current_ip)
  echo "PRIMARY IP: $PRIMARY_IP"
fi

# Kiểm tra IP PRIMARY hợp lệ
if [[ ! $PRIMARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP PRIMARY không hợp lệ. Vui lòng nhập lại.${NC}"
    exit 1
fi

if [ -z "$PRIMARY_IP" ] || [ -z "$MONGODB_USER" ] || [ -z "$MONGODB_PASS" ]; then
  echo "Usage: $0 <PRIMARY_IP> <MONGODB_USER> <MONGODB_PASS>"
  exit 1
fi

UNREACHABLE_NODES=$(mongosh --host "$PRIMARY_IP" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --quiet --eval '
rs.status().members.filter(m => m.health === 0 || m.stateStr.includes("not reachable")).map(m => m.name).join(" ")
')

if [ -z "$UNREACHABLE_NODES" ]; then
  echo "Tất cả các node đều healthy."
  exit 0
fi

for NODE in $UNREACHABLE_NODES; do
  echo "Đang remove node không reachable: $NODE"
  mongosh --host "$PRIMARY_IP" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --eval "rs.remove(\"$NODE\")"
done

echo "Đã remove xong các node không reachable."