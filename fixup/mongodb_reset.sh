#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Biến cấu hình
MONGO_VERSION="8.0"
MONGO_PORT="27017"
REPLICA_SET="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
MONGODB_DATA_DIR="/var/lib/mongodb"
MONGODB_LOG_DIR="/var/log/mongodb/mongod.log"
MONGODB_CONFIG_FILE="/etc/mongod.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"

echo -e "${BLUE}====== KHẮC PHỤC VÀ CÀI ĐẶT LẠI MONGODB 8.0 ======${NC}"
echo -e "${YELLOW}CẢNH BÁO: Script này sẽ xóa hoàn toàn dữ liệu MongoDB.${NC}"
echo -e "${YELLOW}          Đảm bảo bạn đã sao lưu dữ liệu quan trọng trước khi tiếp tục.${NC}"
read -p "Bạn chắc chắn muốn tiếp tục? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Đã hủy thao tác.${NC}"
  exit 0
fi

# 1. Dừng tất cả các tiến trình MongoDB
echo -e "${BLUE}1. Dừng tất cả các tiến trình MongoDB...${NC}"
sudo systemctl stop mongod 2>/dev/null || true
sudo killall mongod 2>/dev/null || true
sudo pkill -f mongod 2>/dev/null || true
sudo pkill -9 -f mongod 2>/dev/null || true
sleep 3
echo -e "${GREEN}✓ Đã dừng tất cả các tiến trình MongoDB${NC}"

# 2. Gỡ cài đặt MongoDB
echo -e "${BLUE}2. Gỡ cài đặt MongoDB hoàn toàn...${NC}"
sudo apt-get purge -y mongodb-org* mongodb*
sudo apt-get autoremove -y
sudo apt-get autoclean

# 3. Xóa dữ liệu và cấu hình MongoDB
echo -e "${BLUE}3. Xóa dữ liệu và cấu hình MongoDB...${NC}"
sudo rm -rf /var/lib/mongodb/*
sudo rm -rf /var/log/mongodb/*
sudo rm -f /etc/mongod.conf
sudo rm -f /etc/mongodb-keyfile
sudo rm -f /tmp/mongodb-*.sock
sudo rm -f /tmp/*.pid
sudo rm -rf /data/rs*/mongod.lock /data/rs*/WiredTiger.lock 2>/dev/null || true
sudo rm -rf /data/rs*/* 2>/dev/null || true
sudo rm -rf /data/* 2>/dev/null || true
echo -e "${GREEN}✓ Đã xóa sạch dữ liệu và cấu hình MongoDB${NC}"

# 4. Xóa systemd service
echo -e "${BLUE}4. Xóa và làm mới systemd service...${NC}"
sudo rm -f /lib/systemd/system/mongod.service
sudo rm -f /etc/systemd/system/mongod.service
sudo rm -f /etc/systemd/system/multi-user.target.wants/mongod.service
sudo systemctl daemon-reload
echo -e "${GREEN}✓ Đã làm mới systemd service${NC}"

# 5. Tạo lại các thư mục cần thiết
echo -e "${BLUE}5. Tạo lại các thư mục cần thiết...${NC}"
sudo mkdir -p /var/lib/mongodb
sudo mkdir -p $(dirname $MONGODB_LOG_DIR)
sudo mkdir -p /data/rs0 /data/rs1 /data/rs2 /data/rs 2>/dev/null || true
sudo chown -R mongodb:mongodb /var/lib/mongodb 2>/dev/null || true
sudo chown -R mongodb:mongodb $(dirname $MONGODB_LOG_DIR) 2>/dev/null || true
sudo chown -R mongodb:mongodb /data/rs* 2>/dev/null || true
echo -e "${GREEN}✓ Đã tạo lại các thư mục cần thiết${NC}"

# 6. Cài đặt MongoDB 8.0
echo -e "${BLUE}6. Cài đặt MongoDB phiên bản $MONGO_VERSION...${NC}"
sudo apt-get update
sudo apt-get install -y curl gnupg netcat-openbsd
sudo rm -f /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg
curl -fsSL https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/$MONGO_VERSION multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
sudo apt-get update
sudo apt-get install -y mongodb-org
echo -e "${GREEN}✓ Đã cài đặt MongoDB $MONGO_VERSION${NC}"

# 7. Tạo keyfile mới
echo -e "${BLUE}7. Tạo keyfile mới...${NC}"
sudo openssl rand -base64 756 > /tmp/mongodb-keyfile
sudo mv /tmp/mongodb-keyfile $MONGODB_KEYFILE
sudo chmod 400 $MONGODB_KEYFILE
sudo chown mongodb:mongodb $MONGODB_KEYFILE 2>/dev/null || true
echo -e "${GREEN}✓ Đã tạo keyfile mới tại $MONGODB_KEYFILE${NC}"

# 8. Tạo file cấu hình mới
echo -e "${BLUE}8. Tạo file cấu hình mới...${NC}"
cat << EOF | sudo tee $MONGODB_CONFIG_FILE > /dev/null
# MongoDB configuration file
storage:
  dbPath: /var/lib/mongodb
  
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true

security:
  authorization: disabled

processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF
echo -e "${GREEN}✓ Đã tạo file cấu hình mới tại $MONGODB_CONFIG_FILE${NC}"

# 9. Cấp quyền và thiết lập service
echo -e "${BLUE}9. Đặt quyền thích hợp...${NC}"
sudo chown -R mongodb:mongodb /var/lib/mongodb
sudo chown -R mongodb:mongodb $(dirname $MONGODB_LOG_DIR)
sudo chown mongodb:mongodb $MONGODB_CONFIG_FILE
sudo chmod 600 $MONGODB_CONFIG_FILE

# 10. Khởi động MongoDB
echo -e "${BLUE}10. Khởi động MongoDB...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl start mongod
sleep 5

# 11. Kiểm tra trạng thái
echo -e "${BLUE}11. Kiểm tra trạng thái MongoDB...${NC}"
sudo systemctl status mongod --no-pager
if sudo systemctl is-active mongod >/dev/null 2>&1; then
  echo -e "${GREEN}✓ MongoDB đã khởi động thành công!${NC}"
  mongod --version
  
  # 12. Khởi tạo replica set đơn giản
  echo -e "${BLUE}12. Khởi tạo replica set đơn giản...${NC}"
  sleep 5
  mongosh --quiet --eval "rs.initiate({_id: '$REPLICA_SET', members: [{_id: 0, host: 'localhost:27017'}]})"
  echo -e "${GREEN}✓ Đã khởi tạo replica set${NC}"
  
  # 13. Kiểm tra trạng thái replica set
  echo -e "${BLUE}13. Kiểm tra trạng thái replica set...${NC}"
  mongosh --quiet --eval "rs.status()" | grep -E "name|stateStr|health|state"
  
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${GREEN}✅ MONGODB ĐÃ ĐƯỢC KHÔI PHỤC THÀNH CÔNG!${NC}"
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${YELLOW}Thông tin kết nối:${NC}"
  echo -e "  - Port: $MONGO_PORT"
  echo -e "  - Replica Set: $REPLICA_SET"
  echo -e "${YELLOW}Bạn có thể tiếp tục thiết lập bằng script setup_mongodb_replica.sh${NC}"
else
  echo -e "${RED}✗ MongoDB không thể khởi động. Kiểm tra lỗi...${NC}"
  
  # Kiểm tra journal
  echo -e "${YELLOW}Xem journal để tìm nguyên nhân:${NC}"
  sudo journalctl -u mongod --no-pager | tail -n 20
  
  # Kiểm tra log
  echo -e "${YELLOW}Xem log MongoDB:${NC}"
  sudo cat /var/log/mongodb/mongod.log | tail -n 20
  
  # Kiểm tra port
  echo -e "${YELLOW}Kiểm tra port $MONGO_PORT:${NC}"
  sudo netstat -tulpn | grep $MONGO_PORT
  
  echo -e "${RED}==================================================${NC}"
  echo -e "${RED}❌ MONGODB KHÔI PHỤC THẤT BẠI!${NC}"
  echo -e "${RED}==================================================${NC}"
  echo -e "${YELLOW}Các lỗi thường gặp:${NC}"
  echo -e "  1. Port $MONGO_PORT đã được sử dụng bởi ứng dụng khác"
  echo -e "  2. Thư mục dữ liệu không có quyền truy cập đúng"
  echo -e "  3. File cấu hình không hợp lệ"
  echo -e "${YELLOW}Vui lòng khắc phục lỗi và chạy lại script.${NC}"
fi

exit 0 