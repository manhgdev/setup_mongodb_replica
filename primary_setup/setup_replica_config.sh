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
  THIẾT LẬP CẤU HÌNH MONGODB REPLICA SET - MANHG DEV
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

# Thử nhiều cách để lấy IP
CURRENT_IP=""

# Phương pháp 1: hostname -I
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Phương pháp 2: ip addr
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Phương pháp 3: ifconfig
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Thông báo nếu phát hiện được IP
if [ -n "$CURRENT_IP" ]; then
  echo -e "${GREEN}✓ Đã phát hiện IP: $CURRENT_IP${NC}"
else
  echo -e "${YELLOW}⚠️ Không thể tự động phát hiện IP${NC}"
  CURRENT_IP="127.0.0.1"
fi

read -p "Địa chỉ IP/hostname của server hiện tại [$CURRENT_IP]: " USER_CURRENT_HOST
CURRENT_HOST=${USER_CURRENT_HOST:-$CURRENT_IP}

read -p "Port của server hiện tại [27017]: " CURRENT_PORT
CURRENT_PORT=${CURRENT_PORT:-27017}

# Kiểm tra trạng thái hiện tại
echo -e "${YELLOW}Kiểm tra trạng thái hiện tại...${NC}"
CURRENT_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  print('EXISTS:true');
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('EXISTS:false');
  print('ERROR:' + e.message);
}
")

# Kiểm tra xem replica set đã tồn tại chưa
if [[ "$CURRENT_STATUS" == *"EXISTS:true"* ]]; then
  echo -e "${YELLOW}Replica set đã tồn tại. Bạn muốn:${NC}"
  echo -e "${YELLOW}1. Thêm server mới vào replica set${NC}"
  echo -e "${YELLOW}2. Khởi tạo lại replica set (xóa cấu hình cũ)${NC}"
  read -p "Chọn thao tác [1-2]: " EXISTING_CHOICE
  
  if [ "$EXISTING_CHOICE" = "2" ]; then
    echo -e "${YELLOW}Đang xóa cấu hình replica set cũ...${NC}"
    # Xóa cấu hình cũ
    mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      rs.remove('$CURRENT_HOST:$CURRENT_PORT');
      print('SUCCESS:true');
    } catch(e) {
      print('ERROR:' + e.message);
    }
    "
  fi
fi

# Thu thập thông tin replica set
echo -e "${YELLOW}Nhập thông tin replica set:${NC}"
read -p "Tên replica set [rs0]: " RS_NAME
RS_NAME=${RS_NAME:-rs0}

# Tạo keyfile cho authentication
echo -e "${YELLOW}Tạo keyfile cho authentication...${NC}"
KEYFILE_PATH="/etc/mongodb-keyfile"
if [ ! -f "$KEYFILE_PATH" ]; then
  openssl rand -base64 756 > $KEYFILE_PATH
  chmod 600 $KEYFILE_PATH
  chown mongodb:mongodb $KEYFILE_PATH
  echo -e "${GREEN}✓ Đã tạo keyfile mới${NC}"
else
  echo -e "${YELLOW}✓ Keyfile đã tồn tại${NC}"
fi

# Cập nhật cấu hình MongoDB
echo -e "${YELLOW}Cập nhật cấu hình MongoDB...${NC}"
cat > /etc/mongod.conf << EOF
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: $CURRENT_PORT
  bindIp: 0.0.0.0

security:
  authorization: enabled
  keyFile: $KEYFILE_PATH

replication:
  replSetName: $RS_NAME
EOF

# Khởi động lại MongoDB
echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
systemctl restart mongod
sleep 5

# Kiểm tra trạng thái MongoDB
if ! systemctl is-active --quiet mongod; then
  echo -e "${RED}Lỗi: MongoDB không khởi động được${NC}"
  exit 1
fi

echo -e "${GREEN}✓ MongoDB đã khởi động lại thành công${NC}"

# Khởi tạo replica set
echo -e "${YELLOW}Khởi tạo replica set...${NC}"
INIT_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
try {
  config = {
    _id: '$RS_NAME',
    members: [
      { _id: 0, host: '$CURRENT_HOST:$CURRENT_PORT', priority: 10 }
    ]
  };
  result = rs.initiate(config);
  print(JSON.stringify(result));
} catch(e) {
  print('ERROR:' + e.message);
}
")

if [[ "$INIT_RESULT" == *"ERROR"* ]]; then
  echo -e "${RED}Lỗi khi khởi tạo replica set:${NC}"
  echo "$INIT_RESULT"
  exit 1
fi

echo -e "${GREEN}✓ Đã khởi tạo replica set thành công${NC}"

# Chờ replica set ổn định
echo -e "${YELLOW}Đang chờ replica set ổn định...${NC}"
sleep 10

# Kiểm tra trạng thái cuối cùng
echo -e "${YELLOW}Kiểm tra trạng thái cuối cùng...${NC}"
FINAL_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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

echo -e "${GREEN}Hoàn thành thiết lập cấu hình replica set!${NC}"
echo -e "${YELLOW}Để thêm server mới vào replica set, hãy chạy script add_to_replica_simple.sh${NC}" 