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

# Lấy danh sách các node không reachable
echo "Đang kiểm tra các node không reachable..."
UNREACHABLE_INFO=$(mongosh --host "$PRIMARY_IP" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --quiet --eval '
const status = rs.status();
const unreachable = status.members.filter(m => m.health === 0 || m.stateStr.includes("not reachable"));
if (unreachable.length === 0) {
  print("NONE");
} else {
  unreachable.forEach(m => print(m._id + ":" + m.name));
}
')

if [ "$UNREACHABLE_INFO" = "NONE" ]; then
  echo -e "${GREEN}Tất cả các node đều healthy.${NC}"
  exit 0
fi

echo -e "${YELLOW}Các node không reachable:${NC}"
echo "$UNREACHABLE_INFO"

# Sử dụng rs.reconfig() với force để remove các node
echo -e "\n${YELLOW}Đang remove các node bằng rs.reconfig() force...${NC}"
mongosh --host "$PRIMARY_IP" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --quiet --eval "
const cfg = rs.conf();
const unreachable = rs.status().members.filter(m => m.health === 0 || m.stateStr.includes('not reachable')).map(m => m._id);
cfg.members = cfg.members.filter(m => !unreachable.includes(m._id));
cfg.version++;
try {
  rs.reconfig(cfg, {force: true});
  print('SUCCESS: Đã remove các node không reachable');
} catch(e) {
  print('ERROR: ' + e);
}
"

echo -e "\n${GREEN}Hoàn tất! Kiểm tra lại trạng thái replica set:${NC}"
mongosh --host "$PRIMARY_IP" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "$AUTH_DB" --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr + ' (health: ' + m.health + ')'))"