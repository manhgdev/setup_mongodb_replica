#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}
============================================================
  KHẮC PHỤC LỖI ARBITER MONGODB - MANHG DEV
============================================================${NC}"

# Biến môi trường
MONGODB_PORT="27017"
ARBITER_PORT="27018"
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
REPLICA_SET_NAME="rs0"
MONGODB_KEYFILE="/etc/mongodb-keyfile"

echo -e "${YELLOW}Kiểm tra các thành phần cần thiết...${NC}"

# 1. Kiểm tra và tạo thư mục log
echo -e "${YELLOW}1. Kiểm tra thư mục log...${NC}"
if [ ! -d "/var/log/mongodb" ]; then
    echo -e "${RED}Thư mục log không tồn tại. Tạo mới...${NC}"
    sudo mkdir -p /var/log/mongodb
fi
sudo touch /var/log/mongodb/mongod-arbiter.log
sudo chown -R mongodb:mongodb /var/log/mongodb
sudo chmod 755 /var/log/mongodb
sudo chmod 644 /var/log/mongodb/mongod-arbiter.log
echo -e "${GREEN}✓ Đã tạo thư mục log và file log${NC}"

# 2. Kiểm tra thư mục data
echo -e "${YELLOW}2. Kiểm tra thư mục data...${NC}"
if [ ! -d "/var/lib/mongodb-arbiter" ]; then
    echo -e "${RED}Thư mục data không tồn tại. Tạo mới...${NC}"
    sudo mkdir -p /var/lib/mongodb-arbiter
fi
sudo chown -R mongodb:mongodb /var/lib/mongodb-arbiter
sudo chmod 755 /var/lib/mongodb-arbiter
echo -e "${GREEN}✓ Đã tạo thư mục data${NC}"

# 3. Kiểm tra keyfile
echo -e "${YELLOW}3. Kiểm tra keyfile...${NC}"
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại. Tạo mới...${NC}"
    sudo bash -c "openssl rand -base64 756 > $MONGODB_KEYFILE"
fi
sudo chmod 400 "$MONGODB_KEYFILE"
sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
echo -e "${GREEN}✓ Đã thiết lập keyfile${NC}"

# 4. Kiểm tra mongod command
echo -e "${YELLOW}4. Kiểm tra lệnh mongod...${NC}"
if ! command -v mongod &> /dev/null; then
    echo -e "${RED}mongod không được tìm thấy. Kiểm tra cài đặt MongoDB.${NC}"
    MONGOD_PATH=$(find / -name mongod -type f -executable 2>/dev/null | head -n 1)
    if [ -n "$MONGOD_PATH" ]; then
        echo -e "${GREEN}Tìm thấy mongod tại: $MONGOD_PATH${NC}"
    else
        echo -e "${RED}Không tìm thấy mongod. Vui lòng cài đặt MongoDB trước.${NC}"
        exit 1
    fi
else
    MONGOD_PATH=$(which mongod)
    echo -e "${GREEN}✓ mongod được tìm thấy tại: $MONGOD_PATH${NC}"
fi

# 5. Tạo file cấu hình đơn giản hơn
echo -e "${YELLOW}5. Tạo file cấu hình đơn giản...${NC}"
sudo bash -c "cat > /etc/mongod-arbiter.conf << EOF
# Cấu hình MongoDB Arbiter đơn giản
storage:
  dbPath: /var/lib/mongodb-arbiter

systemLog:
  destination: file
  path: /var/log/mongodb/mongod-arbiter.log
  logAppend: true

net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET_NAME

security:
  keyFile: $MONGODB_KEYFILE
EOF"
echo -e "${GREEN}✓ Đã tạo file cấu hình đơn giản${NC}"

# 6. Tạo và cấu hình service
echo -e "${YELLOW}6. Cấu hình service...${NC}"
sudo bash -c "cat > /etc/systemd/system/mongod-arbiter.service << EOF
[Unit]
Description=MongoDB Arbiter
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=$MONGOD_PATH --config /etc/mongod-arbiter.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF"
echo -e "${GREEN}✓ Đã cấu hình service${NC}"

# 7. Kiểm tra user mongodb
echo -e "${YELLOW}7. Kiểm tra user mongodb...${NC}"
if ! id -u mongodb &>/dev/null; then
    echo -e "${RED}User mongodb không tồn tại. Dùng mongod...${NC}"
    if ! id -u mongod &>/dev/null; then
        echo -e "${RED}User mongod cũng không tồn tại. Tạo user mongodb...${NC}"
        sudo useradd -r -d /var/lib/mongodb -s /bin/false mongodb
    else
        echo -e "${YELLOW}Sử dụng user mongod...${NC}"
        # Cập nhật service để sử dụng user mongod
        sudo sed -i 's/User=mongodb/User=mongod/g' /etc/systemd/system/mongod-arbiter.service
        sudo sed -i 's/Group=mongodb/Group=mongod/g' /etc/systemd/system/mongod-arbiter.service
        
        # Cập nhật quyền sở hữu
        sudo chown -R mongod:mongod /var/lib/mongodb-arbiter
        sudo chown -R mongod:mongod /var/log/mongodb
        sudo chown mongod:mongod "$MONGODB_KEYFILE"
    fi
fi

# 8. Kiểm tra port
echo -e "${YELLOW}8. Kiểm tra port $ARBITER_PORT...${NC}"
if sudo lsof -i :$ARBITER_PORT | grep LISTEN; then
    echo -e "${RED}Port $ARBITER_PORT đang được sử dụng. Chọn port khác...${NC}"
    NEW_PORT=$((ARBITER_PORT + 1))
    echo -e "${YELLOW}Thay đổi port arbiter thành $NEW_PORT${NC}"
    sudo sed -i "s/port: $ARBITER_PORT/port: $NEW_PORT/g" /etc/mongod-arbiter.conf
    ARBITER_PORT=$NEW_PORT
else
    echo -e "${GREEN}✓ Port $ARBITER_PORT khả dụng${NC}"
fi

# 9. Khởi động và kiểm tra arbiter
echo -e "${YELLOW}9. Khởi động arbiter...${NC}"
sudo systemctl daemon-reload
sudo systemctl stop mongod-arbiter 2>/dev/null
sudo systemctl start mongod-arbiter

echo -e "${YELLOW}Đợi khởi động (5 giây)...${NC}"
sleep 5

# 10. Kiểm tra trạng thái
echo -e "${YELLOW}10. Kiểm tra trạng thái arbiter...${NC}"
if sudo systemctl is-active --quiet mongod-arbiter; then
    echo -e "${GREEN}✓ Arbiter đã khởi động thành công!${NC}"
    sudo systemctl enable mongod-arbiter
else
    echo -e "${RED}Arbiter không thể khởi động.${NC}"
    echo -e "${YELLOW}Kiểm tra log systemd:${NC}"
    sudo journalctl -u mongod-arbiter -n 20 --no-pager
    
    # Thử chạy mongod trực tiếp để xem lỗi chi tiết
    echo -e "${YELLOW}Thử chạy mongod trực tiếp để xem lỗi:${NC}"
    sudo -u mongodb $MONGOD_PATH --config /etc/mongod-arbiter.conf --fork
    
    exit 1
fi

# 11. Thêm arbiter vào replica set
echo -e "${YELLOW}11. Thêm arbiter vào replica set...${NC}"

# Lấy địa chỉ IP của server
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}Địa chỉ IP của server này: $SERVER_IP${NC}"

# Tìm PRIMARY trong replica set
echo -e "${YELLOW}Tìm PRIMARY trong replica set...${NC}"
RS_STATUS=$(mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    if (status.members[i].stateStr === 'PRIMARY') {
      print('PRIMARY:' + status.members[i].name);
      quit();
    }
  }
  print('PRIMARY_NOT_FOUND');
} catch (e) {
  print('ERROR:' + e.message);
}
")

if [[ "$RS_STATUS" == PRIMARY:* ]]; then
  PRIMARY_HOST=$(echo "$RS_STATUS" | cut -d':' -f2-)
  echo -e "${GREEN}✓ Tìm thấy PRIMARY tại: $PRIMARY_HOST${NC}"
else
  echo -e "${RED}Không tìm thấy PRIMARY trong replica set${NC}"
  echo -e "${YELLOW}Vui lòng cung cấp địa chỉ của PRIMARY:${NC}"
  read -p "IP:Port của PRIMARY (ví dụ: 157.66.46.252:27017): " PRIMARY_HOST
  
  if [ -z "$PRIMARY_HOST" ]; then
    echo -e "${RED}Không có thông tin PRIMARY, không thể thêm arbiter${NC}"
    exit 1
  fi
fi

# Thêm arbiter vào replica set từ PRIMARY
echo -e "${YELLOW}Thêm arbiter từ PRIMARY ($PRIMARY_HOST)...${NC}"
ADD_ARBITER_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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

# Kiểm tra kết quả
if [[ "$ADD_ARBITER_RESULT" == *"SUCCESS"* ]]; then
    echo -e "${GREEN}✓ Arbiter đã được thêm vào replica set!${NC}"
elif [[ "$ADD_ARBITER_RESULT" == *"already exists"* ]]; then
    echo -e "${YELLOW}⚠️ Arbiter đã tồn tại trong replica set.${NC}"
else
    echo -e "${RED}⚠️ Có vấn đề khi thêm arbiter.${NC}"
fi

# 12. Hiển thị trạng thái replica set
echo -e "${YELLOW}12. Kiểm tra trạng thái replica set...${NC}"
mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "rs.status()" | grep -E "name|stateStr"

echo -e "${BLUE}
============================================================
  HOÀN THÀNH KHẮC PHỤC ARBITER
============================================================${NC}"

echo -e "${GREEN}Arbiter đã được cấu hình tại: $SERVER_IP:$ARBITER_PORT${NC}"
echo -e "${YELLOW}Lệnh để kiểm tra trạng thái replica set:${NC}"
echo -e "  mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval \"rs.status()\"" 