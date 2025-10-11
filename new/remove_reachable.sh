#!/bin/bash

# Lấy đường dẫn thư mục chứa script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load các hàm utility từ lib
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/get_current_ip.sh"

MONGODB_USER="manhg"
MONGODB_PASS="manhnk"
AUTH_DB="admin"

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