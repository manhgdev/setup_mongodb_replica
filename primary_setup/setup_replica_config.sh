#!/bin/bash

# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import required configuration files
if [ -f "$SCRIPT_DIR/../config/mongodb_settings.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_settings.sh"
else
    # Màu sắc
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
fi

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
read -p "Tên người dùng MongoDB [$MONGODB_USER]: " USERNAME
USERNAME=${USERNAME:-$MONGODB_USER}

read -p "Mật khẩu MongoDB [$MONGODB_PASSWORD]: " PASSWORD
PASSWORD=${PASSWORD:-$MONGODB_PASSWORD}

read -p "Database xác thực [$AUTH_DATABASE]: " AUTH_DB
AUTH_DB=${AUTH_DB:-$AUTH_DATABASE}

# Thử nhiều cách để lấy IP
CURRENT_IP=$(get_server_ip)

# Thông báo nếu phát hiện được IP
if [ -n "$CURRENT_IP" ]; then
  echo -e "${GREEN}✓ Đã phát hiện IP: $CURRENT_IP${NC}"
else
  echo -e "${YELLOW}⚠️ Không thể tự động phát hiện IP${NC}"
  CURRENT_IP="127.0.0.1"
fi

read -p "Địa chỉ IP/hostname của server hiện tại [$CURRENT_IP]: " USER_CURRENT_HOST
CURRENT_HOST=${USER_CURRENT_HOST:-$CURRENT_IP}

read -p "Port của server hiện tại [$MONGO_PORT]: " CURRENT_PORT
CURRENT_PORT=${CURRENT_PORT:-$MONGODB_PORT}

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
read -p "Tên replica set [$REPLICA_SET_NAME]: " RS_NAME
RS_NAME=${RS_NAME:-$REPLICA_SET_NAME}

# Tạo keyfile cho authentication
echo -e "${YELLOW}Tạo keyfile cho authentication...${NC}"
if [ ! -f "$MONGODB_KEYFILE" ]; then
  openssl rand -base64 756 > $MONGODB_KEYFILE
  chmod 600 $MONGODB_KEYFILE
  chown mongodb:mongodb $MONGODB_KEYFILE
  echo -e "${GREEN}✓ Đã tạo keyfile mới${NC}"
else
  chmod 600 $MONGODB_KEYFILE
  chown mongodb:mongodb $MONGODB_KEYFILE
  echo -e "${YELLOW}✓ Keyfile đã tồn tại${NC}"
fi

# Cập nhật cấu hình MongoDB
echo -e "${YELLOW}Cập nhật cấu hình MongoDB...${NC}"
cat > $MONGODB_CONFIG << EOF
storage:
  dbPath: $MONGODB_DATA_DIR

systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH

net:
  port: $CURRENT_PORT
  bindIp: $BIND_IP

security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE

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