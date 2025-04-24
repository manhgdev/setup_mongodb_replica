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
  THÊM ARBITER VÀO MONGODB REPLICA SET - MANHG DEV
============================================================${NC}"

# Kiểm tra quyền sudo
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Script này cần quyền sudo để chạy${NC}"
    read -p "Bạn muốn tiếp tục với sudo không? (y/n): " RUN_SUDO
    if [[ "$RUN_SUDO" =~ ^[Yy]$ ]]; then
        echo "Chạy lại script với sudo..."
        sudo "$0" "$@"
        exit $?
    else
        echo -e "${RED}Thoát script.${NC}"
        exit 1
    fi
fi

# Tham số mặc định
MONGODB_PORT="27017"
ARBITER_PORT="27018"
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
REPLICA_SET_NAME="rs0"

# Thu thập thông tin
read -p "Tên người dùng MongoDB [$USERNAME]: " USER_INPUT
USERNAME=${USER_INPUT:-$USERNAME}

read -p "Mật khẩu MongoDB [$PASSWORD]: " USER_INPUT
PASSWORD=${USER_INPUT:-$PASSWORD}

read -p "Port MongoDB chính [$MONGODB_PORT]: " USER_INPUT
MONGODB_PORT=${USER_INPUT:-$MONGODB_PORT}

read -p "Port cho arbiter [$ARBITER_PORT]: " USER_INPUT
ARBITER_PORT=${USER_INPUT:-$ARBITER_PORT}

read -p "Địa chỉ IP của server (sẽ dùng cho arbiter): " SERVER_IP
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Sử dụng địa chỉ IP: $SERVER_IP${NC}"
fi

# Kiểm tra xem MongoDB có đang chạy không
echo -e "${YELLOW}Kiểm tra MongoDB...${NC}"
if ! systemctl is-active --quiet mongod; then
    echo -e "${RED}MongoDB không đang chạy. Khởi động...${NC}"
    systemctl start mongod
    sleep 5
    
    if ! systemctl is-active --quiet mongod; then
        echo -e "${RED}Không thể khởi động MongoDB. Kiểm tra trạng thái và thử lại.${NC}"
        exit 1
    fi
fi

# Kiểm tra keyfile
MONGODB_KEYFILE="/etc/mongodb-keyfile"
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${YELLOW}Keyfile không tồn tại. Tạo mới...${NC}"
    openssl rand -base64 756 > "$MONGODB_KEYFILE"
    chmod 400 "$MONGODB_KEYFILE"
    chown mongodb:mongodb "$MONGODB_KEYFILE"
    echo -e "${GREEN}Đã tạo keyfile tại $MONGODB_KEYFILE${NC}"
fi

# Tạo thư mục cho arbiter
echo -e "${YELLOW}Tạo thư mục cho arbiter...${NC}"
mkdir -p /var/lib/mongodb-arbiter
chown -R mongodb:mongodb /var/lib/mongodb-arbiter

# Tạo file cấu hình cho arbiter
echo -e "${YELLOW}Tạo file cấu hình cho arbiter...${NC}"
cat > /etc/mongod-arbiter.conf << EOF
storage:
  dbPath: /var/lib/mongodb-arbiter
  journal:
    enabled: true

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod-arbiter.log

net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0

security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE

replication:
  replSetName: $REPLICA_SET_NAME
EOF

# Tạo thư mục log nếu chưa tồn tại
mkdir -p /var/log/mongodb
chown -R mongodb:mongodb /var/log/mongodb

# Tạo service cho arbiter
echo -e "${YELLOW}Tạo service cho arbiter...${NC}"
cat > /etc/systemd/system/mongod-arbiter.service << EOF
[Unit]
Description=MongoDB Arbiter
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod-arbiter.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, khởi động và bật arbiter
echo -e "${YELLOW}Khởi động arbiter...${NC}"
systemctl daemon-reload
systemctl start mongod-arbiter
systemctl enable mongod-arbiter

# Đợi arbiter khởi động
echo -e "${YELLOW}Đợi arbiter khởi động...${NC}"
sleep 5

# Kiểm tra arbiter đã chạy chưa
if ! systemctl is-active --quiet mongod-arbiter; then
    echo -e "${RED}Arbiter không thể khởi động. Kiểm tra log tại /var/log/mongodb/mongod-arbiter.log${NC}"
    exit 1
fi

# Thêm arbiter vào replica set
echo -e "${YELLOW}Thêm arbiter vào replica set...${NC}"
ADD_ARBITER_RESULT=$(mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  result = rs.addArb('$SERVER_IP:$ARBITER_PORT');
  if (result.ok) {
    print('SUCCESS: Arbiter đã được thêm thành công');
  } else {
    print('ERROR: ' + result.errmsg);
  }
} catch (e) {
  print('ERROR: ' + e.message);
}
")

echo "$ADD_ARBITER_RESULT"

# Kiểm tra trạng thái của replica set
echo -e "${YELLOW}Kiểm tra cấu hình replica set...${NC}"
RS_CONFIG=$(mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  config = rs.conf();
  print('MEMBERS: ' + config.members.length);
  for (var i = 0; i < config.members.length; i++) {
    print(config.members[i].host + ' - arbiterOnly: ' + config.members[i].arbiterOnly);
  }
} catch (e) {
  print('ERROR: ' + e.message);
}
")

echo "$RS_CONFIG"

# Kiểm tra xem arbiter đã được thêm thành công chưa
if [[ "$RS_CONFIG" == *"$SERVER_IP:$ARBITER_PORT - arbiterOnly: true"* ]]; then
    echo -e "${GREEN}✅ Arbiter đã được thêm thành công và đang hoạt động!${NC}"
else
    echo -e "${RED}⚠️ Không thể xác nhận arbiter đã được thêm thành công.${NC}"
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    
    # Kiểm tra trạng thái replica set
    mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "rs.status()"
fi

# Hiển thị kết luận
echo -e "${BLUE}
============================================================
  HOÀN THÀNH THIẾT LẬP ARBITER
============================================================${NC}"

echo -e "${GREEN}Arbiter đã được cấu hình tại: $SERVER_IP:$ARBITER_PORT${NC}"
echo -e "${YELLOW}Bây giờ replica set của bạn có 3 thành viên (2 node dữ liệu + 1 arbiter)${NC}"
echo -e "${YELLOW}Điều này sẽ cho phép bầu PRIMARY khi một node dữ liệu bị down${NC}"

# Cung cấp lệnh để kiểm tra trạng thái
echo -e "${BLUE}Để kiểm tra trạng thái replica set:${NC}"
echo -e "  mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval \"rs.status()\"" 