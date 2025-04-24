#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}
============================================================
  SỬA LỖI SERVER KHÔNG REACHABLE - MANHG DEV
============================================================${NC}"

# Kiểm tra cài đặt MongoDB
if ! command -v mongosh &> /dev/null; then
    echo -e "${RED}Lỗi: MongoDB Shell (mongosh) chưa được cài đặt${NC}"
    exit 1
fi

# Thu thập thông tin kết nối
echo -e "${YELLOW}Nhập thông tin kết nối:${NC}"
read -p "Tên người dùng MongoDB [manhg]: " USERNAME
USERNAME=${USERNAME:-manhg}

read -p "Mật khẩu MongoDB [manhnk]: " PASSWORD
PASSWORD=${PASSWORD:-manhnk}

read -p "Database xác thực [admin]: " AUTH_DB
AUTH_DB=${AUTH_DB:-admin}

# Thông tin server không reachable
echo -e "${YELLOW}Nhập thông tin server không reachable:${NC}"
read -p "Địa chỉ IP/hostname của server không reachable: " UNREACHABLE_HOST
read -p "Port của server không reachable [27017]: " UNREACHABLE_PORT
UNREACHABLE_PORT=${UNREACHABLE_PORT:-27017}

# Thông tin PRIMARY server
echo -e "${YELLOW}Nhập thông tin PRIMARY server:${NC}"
read -p "Địa chỉ IP/hostname của PRIMARY server: " PRIMARY_HOST
read -p "Port của PRIMARY server [27017]: " PRIMARY_PORT
PRIMARY_PORT=${PRIMARY_PORT:-27017}

# 1. Kiểm tra kết nối đến PRIMARY
echo -e "${YELLOW}Kiểm tra kết nối đến PRIMARY...${NC}"
PRIMARY_STATUS=$(mongosh --host $PRIMARY_HOST --port $PRIMARY_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== TRẠNG THÁI PRIMARY =====${NC}"
echo "$PRIMARY_STATUS"

# 2. Xóa server không reachable khỏi replica set
echo -e "${YELLOW}Xóa server không reachable khỏi replica set...${NC}"
REMOVE_RESULT=$(mongosh --host $PRIMARY_HOST --port $PRIMARY_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
try {
  result = rs.remove('$UNREACHABLE_HOST:$UNREACHABLE_PORT');
  print(JSON.stringify(result));
} catch(e) {
  print('ERROR:' + e.message);
}
")

if [[ "$REMOVE_RESULT" == *"ERROR"* ]]; then
  echo -e "${RED}Lỗi khi xóa server:${NC}"
  echo "$REMOVE_RESULT"
  exit 1
fi

echo -e "${GREEN}✓ Đã xóa server không reachable${NC}"

# 3. Kiểm tra và sửa lỗi trên server không reachable
echo -e "${YELLOW}Kiểm tra và sửa lỗi trên server không reachable...${NC}"

# SSH vào server và thực hiện các bước sửa lỗi
echo -e "${YELLOW}Thực hiện các bước sau trên server $UNREACHABLE_HOST:${NC}"
echo -e "${YELLOW}1. Kiểm tra trạng thái MongoDB:${NC}"
echo "systemctl status mongod"

echo -e "${YELLOW}2. Kiểm tra log MongoDB:${NC}"
echo "tail -n 50 /var/log/mongodb/mongod.log"

echo -e "${YELLOW}3. Kiểm tra cấu hình MongoDB:${NC}"
echo "cat /etc/mongod.conf"

echo -e "${YELLOW}4. Kiểm tra keyfile:${NC}"
echo "ls -l /etc/mongodb-keyfile"

echo -e "${YELLOW}5. Kiểm tra quyền truy cập:${NC}"
echo "ls -l /var/lib/mongodb"
echo "ls -l /var/log/mongodb"

echo -e "${YELLOW}6. Khởi động lại MongoDB:${NC}"
echo "systemctl restart mongod"

# 4. Thêm lại server vào replica set
echo -e "${YELLOW}Thêm lại server vào replica set...${NC}"
ADD_RESULT=$(mongosh --host $PRIMARY_HOST --port $PRIMARY_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
try {
  result = rs.add('$UNREACHABLE_HOST:$UNREACHABLE_PORT');
  print(JSON.stringify(result));
} catch(e) {
  print('ERROR:' + e.message);
}
")

if [[ "$ADD_RESULT" == *"ERROR"* ]]; then
  echo -e "${RED}Lỗi khi thêm server:${NC}"
  echo "$ADD_RESULT"
  exit 1
fi

echo -e "${GREEN}✓ Đã thêm lại server vào replica set${NC}"

# 5. Chờ và kiểm tra trạng thái
echo -e "${YELLOW}Đang chờ server ổn định...${NC}"
sleep 30

FINAL_STATUS=$(mongosh --host $PRIMARY_HOST --port $PRIMARY_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== TRẠNG THÁI CUỐI CÙNG =====${NC}"
echo "$FINAL_STATUS"

echo -e "${GREEN}Hoàn thành quá trình sửa lỗi!${NC}"
echo -e "${YELLOW}Nếu server vẫn không reachable, hãy kiểm tra:${NC}"
echo "1. Firewall và network connectivity"
echo "2. MongoDB configuration"
echo "3. Keyfile permissions"
echo "4. MongoDB service status"
echo "5. MongoDB logs" 