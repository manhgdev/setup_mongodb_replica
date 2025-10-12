#!/bin/bash

# diagnose_server_selection.sh
# Chẩn đoán lỗi MongoServerSelectionError (kết nối/không chọn được server phù hợp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/colors.sh"
source "$LIB_DIR/check_mongodb_connection.sh"

echo -e "${YELLOW}Chẩn đoán MongoDB Server Selection${NC}"
echo -e "${YELLOW}=================================${NC}"

read -p "Nhập PRIMARY host (ví dụ 10.0.0.1:27017): " PRIMARY_HOST
read -p "Nhập username (để trống nếu không auth): " USERNAME || true
if [ -n "${USERNAME:-}" ]; then
  read -s -p "Nhập password: " PASSWORD; echo
  read -p "Nhập authentication database (mặc định: admin): " AUTH_DB
  AUTH_DB=${AUTH_DB:-admin}
else
  PASSWORD=""
  AUTH_DB="admin"
fi

echo -e "\n${BLUE}1) Kiểm tra kết nối tới PRIMARY: $PRIMARY_HOST${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "${USERNAME:-}" "${PASSWORD:-}" "$AUTH_DB"; then
  echo -e "${RED}Không thể ping MongoDB PRIMARY. Kiểm tra firewall, bindIp và thông tin xác thực.${NC}"
  exit 1
fi

echo -e "\n${BLUE}2) Đọc cấu hình Replica Set và liệt kê members${NC}"
if [ -z "${USERNAME:-}" ]; then
  CFG_JSON=$(mongosh --host "$PRIMARY_HOST" --quiet --eval 'printjson(rs.conf())')
  RS_NAME=$(mongosh --host "$PRIMARY_HOST" --quiet --eval 'print(rs.conf()._id)')
else
  CFG_JSON=$(mongosh --host "$PRIMARY_HOST" -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase "$AUTH_DB" --quiet --eval 'printjson(rs.conf())')
  RS_NAME=$(mongosh --host "$PRIMARY_HOST" -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase "$AUTH_DB" --quiet --eval 'print(rs.conf()._id)')
fi

echo "$CFG_JSON" | sed -e 's/^/  /'

# Trích xuất danh sách host và phân loại arbiter/data-bearing
HOSTS=()
DATA_HOSTS=()
ARBITERS=()
while IFS= read -r line; do
  host=$(echo "$line" | sed -n 's/.*host"\s*:\s*"\([^"']*\)".*/\1/p')
  arb=$(echo "$line" | sed -n 's/.*arbiterOnly"\s*:\s*\(true\|false\).*/\1/p')
  if [ -n "$host" ]; then
    HOSTS+=("$host")
    if echo "$arb" | grep -qi true; then
      ARBITERS+=("$host")
    else
      DATA_HOSTS+=("$host")
    fi
  fi
done < <(echo "$CFG_JSON")

echo -e "\n${BLUE}Members phát hiện:${NC}"
for h in "${HOSTS[@]}"; do echo "  - $h"; done

echo -e "\n${BLUE}3) Kiểm tra network tới từng member (TCP 27017)${NC}"
for h in "${HOSTS[@]}"; do
  host_only=$(echo "$h" | cut -d: -f1)
  port_only=$(echo "$h" | cut -d: -f2)
  port_only=${port_only:-27017}
  if nc -z -w 2 "$host_only" "$port_only" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} TCP OK: $host_only:$port_only"
  else
    echo -e "${RED}✗${NC} TCP FAIL: $host_only:$port_only (Firewall/bindIp/DNS?)"
  fi
done

echo -e "\n${BLUE}4) Kiểm tra mongosh ping tới từng member${NC}"
for h in "${HOSTS[@]}"; do
  if [ -z "${USERNAME:-}" ]; then
    res=$(timeout 5 mongosh --host "$h" --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | tr -d ' \n\r\t')
  else
    res=$(timeout 5 mongosh --host "$h" -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase "$AUTH_DB" --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | tr -d ' \n\r\t')
  fi
  if [ "$res" = "1" ]; then
    echo -e "${GREEN}✓${NC} mongosh OK: $h"
  else
    echo -e "${RED}✗${NC} mongosh FAIL: $h (không thể ping)"
  fi
done

echo -e "\n${BLUE}5) Gợi ý connection string cho ứng dụng (không nên include arbiter)${NC}"
JOINED_DATA=$(IFS=,; echo "${DATA_HOSTS[*]}")
if [ -n "$JOINED_DATA" ]; then
  if [ -n "${USERNAME:-}" ]; then
    echo "mongodb://${USERNAME}:${PASSWORD}@${JOINED_DATA}/?replicaSet=${RS_NAME}&authSource=${AUTH_DB}&directConnection=false"
  else
    echo "mongodb://${JOINED_DATA}/?replicaSet=${RS_NAME}&directConnection=false"
  fi
else
  echo -e "${YELLOW}Không phát hiện member dữ liệu. Kiểm tra lại cấu hình replica set.${NC}"
fi

echo -e "\n${BLUE}6) Kiểm tra các vấn đề phổ biến${NC}"
issues=0
for h in "${HOSTS[@]}"; do
  if echo "$h" | grep -qE '(^127\.0\.0\.1|localhost)'; then
    echo -e "${YELLOW}- Cảnh báo: member dùng localhost/127.0.0.1 ($h). Ứng dụng bên ngoài sẽ không kết nối được.${NC}"
    issues=$((issues+1))
  fi
done

if [ $issues -gt 0 ]; then
  cat << 'TIP'

Gợi ý sửa rs.conf() nếu đang dùng localhost/127.0.0.1:
  var cfg = rs.conf();
  // Cập nhật từng member có host sai
  cfg.members.forEach(m => { if (m.host.startsWith('localhost') || m.host.startsWith('127.0.0.1')) m.host = '<IP_THUCTE>:27017' });
  cfg.version += 1;
  rs.reconfig(cfg);

Đồng thời, trong /etc/mongod.conf đảm bảo:
  net:
    bindIp: 0.0.0.0

Mở firewall (tùy hệ điều hành):
  sudo ufw allow 27017/tcp
  sudo firewall-cmd --permanent --add-port=27017/tcp && sudo firewall-cmd --reload
TIP
fi

echo -e "\n${GREEN}Hoàn tất chẩn đoán.${NC}"
