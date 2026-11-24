#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/mongo_auth.sh" || exit 1

# set_write_concern_majority.sh
# Kiểm tra và thiết lập Default Write Concern = "majority" cho Replica Set (chạy trên PRIMARY)

set -euo pipefail

# Định vị thư mục script và thư viện
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/colors.sh"
source "$LIB_DIR/check_mongodb_connection.sh"

echo -e "${YELLOW}Thiết lập Default Write Concern = 'majority' cho Replica Set${NC}"
echo -e "${YELLOW}================================================================${NC}"

# Nhập thông tin kết nối
read -p "Nhập host (mặc định: localhost): " HOST
HOST=${HOST:-localhost}

read -p "Nhập port (mặc định: 27017): " PORT
PORT=${PORT:-27017}

read -p "Nhập username (bỏ trống nếu không auth): " USERNAME || true
if [ -n "${USERNAME:-}" ]; then
  read -s -p "Nhập password: " PASSWORD; echo
  read -p "Nhập authentication database (mặc định: admin): " AUTH_DB
  AUTH_DB=${AUTH_DB:-admin}
else
  PASSWORD=""
  AUTH_DB="admin"
fi

HOSTPORT="$HOST:$PORT"

echo -e "\n${BLUE}1) Kiểm tra kết nối tới $HOSTPORT...${NC}"
if ! check_mongodb_connection "$HOSTPORT" "${USERNAME:-}" "${PASSWORD:-}" "$AUTH_DB"; then
  echo -e "${RED}Không thể kết nối tới MongoDB ở $HOSTPORT. Dừng lại.${NC}"
  exit 1
fi

# Lấy PRIMARY của replica set từ node đã nhập
echo -e "\n${BLUE}2) Xác định PRIMARY của Replica Set...${NC}"
if [ -z "${USERNAME:-}" ]; then
  PRIMARY=$(mongosh --host "$HOSTPORT" --quiet --eval 'let p=""; try { const h=db.hello(); p=h.primary||""; if(h.isWritablePrimary && !p) p=h.me||""; } catch(e) { const m=rs.isMaster(); p=m.primary||""; if(m.ismaster && !p) p=m.me||""; } print(p)')
else
  PRIMARY=$(mongo_eval "$USERNAME" "$PASSWORD" "$AUTH_DB" --host "$HOSTPORT" --quiet --eval 'let p=""; try { const h=db.hello(); p=h.primary||""; if(h.isWritablePrimary && !p) p=h.me||""; } catch(e) { const m=rs.isMaster(); p=m.primary||""; if(m.ismaster && !p) p=m.me||""; } print(p)')
fi

PRIMARY=$(echo "$PRIMARY" | tr -d ' \n\r\t')

if [ -z "$PRIMARY" ]; then
  echo -e "${RED}Không xác định được PRIMARY. Hãy chắc rằng node đã tham gia Replica Set và bạn có quyền truy cập.${NC}"
  exit 1
fi

echo -e "PRIMARY hiện tại: ${GREEN}$PRIMARY${NC}"

# Nếu host nhập vào không phải primary, chuyển sang primary
if [ "$HOSTPORT" != "$PRIMARY" ]; then
  echo -e "${YELLOW}Chuyển sang kết nối PRIMARY: $PRIMARY${NC}"
  HOSTPORT="$PRIMARY"
fi

# Hàm lấy w hiện tại của default write concern
get_current_w() {
  if [ -z "${USERNAME:-}" ]; then
    mongosh --host "$HOSTPORT" --quiet --eval 'const r=db.adminCommand({getDefaultRWConcern:1}); print((r.defaultWriteConcern&&r.defaultWriteConcern.w)||"")'
  else
    mongo_eval "$USERNAME" "$PASSWORD" "$AUTH_DB" --host "$HOSTPORT" --quiet --eval 'const r=db.adminCommand({getDefaultRWConcern:1}); print((r.defaultWriteConcern&&r.defaultWriteConcern.w)||"")'
  fi
}

echo -e "\n${BLUE}3) Kiểm tra Default Write Concern hiện tại...${NC}"
CURRENT_W=$(get_current_w | tr -d ' \n\r\t')

if [ -z "$CURRENT_W" ]; then
  echo -e "Default Write Concern hiện tại: ${YELLOW}<chưa thiết lập>${NC}"
else
  echo -e "Default Write Concern hiện tại: ${GREEN}$CURRENT_W${NC}"
fi

if [ "$CURRENT_W" = "majority" ]; then
  echo -e "${GREEN}Đã ở trạng thái mong muốn (majority). Không cần thay đổi.${NC}"
  exit 0
fi

echo -e "\n${BLUE}4) Thiết lập Default Write Concern = 'majority'...${NC}"
if [ -z "${USERNAME:-}" ]; then
  SET_RES=$(mongosh --host "$HOSTPORT" --quiet --eval "printjson(db.adminCommand({ setDefaultRWConcern: 1, defaultWriteConcern: { w: 'majority' } }))")
else
  SET_RES=$(mongo_eval "$USERNAME" "$PASSWORD" "$AUTH_DB" --host "$HOSTPORT" --quiet --eval "printjson(db.adminCommand({ setDefaultRWConcern: 1, defaultWriteConcern: { w: 'majority' } }))")
fi

echo "$SET_RES" | sed -e 's/^/  /'

# Kiểm tra lại
NEW_W=$(get_current_w | tr -d ' \n\r\t')

if [ "$NEW_W" = "majority" ]; then
  echo -e "\n${GREEN}Thiết lập thành công. Default Write Concern hiện tại: majority${NC}"
  echo -e "${BLUE}Ghi chú:${NC} Lệnh này sử dụng adminCommand setDefaultRWConcern (yêu cầu quyền clusterAdmin)."
  exit 0
else
  echo -e "\n${RED}Thiết lập thất bại hoặc không thay đổi. Giá trị hiện tại: '$NEW_W'${NC}"
  echo -e "${YELLOW}Vui lòng kiểm tra quyền user, kết nối tới PRIMARY, hoặc version MongoDB (yêu cầu 4.4+).${NC}"
  exit 2
fi
