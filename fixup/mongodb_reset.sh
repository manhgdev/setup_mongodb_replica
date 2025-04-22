#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Biến cấu hình
MONGO_VERSION="8.0"
DEFAULT_DATA_DIR="/var/lib/mongodb"
DEFAULT_LOG_DIR="/var/log/mongodb"
DEFAULT_CONFIG_FILE="/etc/mongod.conf"
DEFAULT_KEYFILE="/etc/mongodb-keyfile"

clear
echo -e "${BLUE}
============================================================
     RESET HOÀN TOÀN MONGODB - MANHG DEV
============================================================${NC}"

# Kiểm tra quyền root
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}Script này cần chạy với quyền root hoặc sudo${NC}"
   echo "Vui lòng chạy lại với sudo: sudo $0"
   exit 1
fi

echo -e "${RED}CẢNH BÁO: Script này sẽ xóa hoàn toàn MongoDB, bao gồm:${NC}"
echo -e "${RED}- Tất cả dữ liệu MongoDB${NC}"
echo -e "${RED}- Tất cả cài đặt và cấu hình MongoDB${NC}"
echo -e "${RED}- Tất cả các file keyfile và xác thực${NC}"
echo
echo -e "${RED}SAU KHI CHẠY SCRIPT NÀY, TẤT CẢ DỮ LIỆU SẼ BỊ MẤT VĨNH VIỄN!${NC}"
echo

read -p "Bạn có chắc chắn muốn tiếp tục? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
   echo -e "${YELLOW}Hủy quá trình reset.${NC}"
   exit 0
fi

echo -e "${YELLOW}Bắt đầu quá trình reset MongoDB...${NC}"

# 1. Dừng dịch vụ MongoDB nếu đang chạy
echo -e "${YELLOW}1. Dừng dịch vụ MongoDB...${NC}"
systemctl stop mongod || true
sleep 2

# Kiểm tra xem có quá trình MongoDB nào còn chạy không và kill
ps aux | grep mongo[d] > /dev/null
if [ $? -eq 0 ]; then
   echo -e "${YELLOW}Vẫn còn quá trình MongoDB đang chạy, đang dừng...${NC}"
   pkill -f mongod || true
   sleep 2
fi

# 2. Gỡ cài đặt tất cả các gói MongoDB
echo -e "${YELLOW}2. Gỡ cài đặt các gói MongoDB...${NC}"
apt-get purge -y mongodb-org* || true
apt-get purge -y mongodb* || true

# 3. Xóa các thư mục và tệp dữ liệu MongoDB
echo -e "${YELLOW}3. Xóa tất cả dữ liệu và cấu hình MongoDB...${NC}"
rm -rf $DEFAULT_DATA_DIR/*
rm -rf $DEFAULT_LOG_DIR/*
rm -f $DEFAULT_CONFIG_FILE
rm -f $DEFAULT_KEYFILE
rm -f /etc/apt/sources.list.d/mongodb*.list
rm -f /usr/share/keyrings/mongodb*.gpg
rm -rf /var/run/mongodb
rm -rf /tmp/mongodb*

# 4. Xóa thư mục cấu hình
echo -e "${YELLOW}4. Xóa thư mục cấu hình MongoDB...${NC}"
rm -rf /etc/mongodb*

# 5. Làm sạch apt
echo -e "${YELLOW}5. Làm sạch apt cache...${NC}"
apt-get autoremove -y
apt-get clean
apt-get update

# 6. Cài đặt MongoDB lại
echo -e "${YELLOW}6. Cài đặt lại MongoDB phiên bản $MONGO_VERSION...${NC}"

# Cài đặt các công cụ cần thiết
apt-get update
apt-get install -y gnupg curl netcat-openbsd

# Thêm repo MongoDB
curl -fsSL https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc | \
  gpg -o /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg \
  --dearmor

# Xác định phiên bản Ubuntu
UBUNTU_VERSION=$(lsb_release -cs)
echo -e "${YELLOW}Phiên bản Ubuntu: $UBUNTU_VERSION${NC}"

# Sử dụng jammy cho Ubuntu 22.04, focal cho 20.04
if [ "$UBUNTU_VERSION" = "jammy" ] || [ "$UBUNTU_VERSION" = "focal" ]; then
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $UBUNTU_VERSION/mongodb-org/$MONGO_VERSION multiverse" | \
    tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
else
  # Fallback sang jammy nếu không phải Ubuntu 22.04 hoặc 20.04
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/$MONGO_VERSION multiverse" | \
    tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
fi

# Cài đặt MongoDB
apt-get update
apt-get install -y mongodb-org

# 7. Tạo thư mục dữ liệu và đặt quyền
echo -e "${YELLOW}7. Tạo thư mục dữ liệu và cấu hình quyền...${NC}"
mkdir -p $DEFAULT_DATA_DIR
mkdir -p $(dirname $DEFAULT_LOG_DIR)
mkdir -p /var/run/mongodb

# Xác định user mongodb hoặc mongod
if getent passwd mongodb > /dev/null; then
  chown -R mongodb:mongodb $DEFAULT_DATA_DIR
  chown -R mongodb:mongodb $(dirname $DEFAULT_LOG_DIR)
  chown -R mongodb:mongodb /var/run/mongodb
elif getent passwd mongod > /dev/null; then
  chown -R mongod:mongod $DEFAULT_DATA_DIR
  chown -R mongod:mongod $(dirname $DEFAULT_LOG_DIR)
  chown -R mongod:mongod /var/run/mongodb
else
  # Tạo user mongodb nếu không tồn tại
  useradd -r -s /bin/false mongodb
  chown -R mongodb:mongodb $DEFAULT_DATA_DIR
  chown -R mongodb:mongodb $(dirname $DEFAULT_LOG_DIR)
  chown -R mongodb:mongodb /var/run/mongodb
fi

# 8. Tạo cấu hình mặc định
echo -e "${YELLOW}8. Tạo cấu hình MongoDB mặc định...${NC}"
cat > $DEFAULT_CONFIG_FILE << EOF
# MongoDB configuration file
storage:
  dbPath: $DEFAULT_DATA_DIR
  journal:
    enabled: true

net:
  port: 27017
  bindIp: 0.0.0.0

systemLog:
  destination: file
  path: $DEFAULT_LOG_DIR
  logAppend: true

processManagement:
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo
EOF

# Xác định user mongodb hoặc mongod
if getent passwd mongodb > /dev/null; then
  chown mongodb:mongodb $DEFAULT_CONFIG_FILE
elif getent passwd mongod > /dev/null; then
  chown mongod:mongod $DEFAULT_CONFIG_FILE
fi

chmod 644 $DEFAULT_CONFIG_FILE

# 9. Tạo service file
echo -e "${YELLOW}9. Cấu hình systemd service...${NC}"
cat > /lib/systemd/system/mongod.service << EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
EnvironmentFile=-/etc/default/mongod
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
PIDFile=/var/run/mongodb/mongod.pid
# file size
LimitFSIZE=infinity
# cpu time
LimitCPU=infinity
# virtual memory size
LimitAS=infinity
# open files
LimitNOFILE=64000
# processes/threads
LimitNPROC=64000
# locked memory
LimitMEMLOCK=infinity
# total threads (user+kernel)
TasksMax=infinity
TasksAccounting=false
# Recommended limits for mongod as specified in
# https://docs.mongodb.com/manual/reference/ulimit/#recommended-ulimit-settings

[Install]
WantedBy=multi-user.target
EOF

# Xác định user mongodb hoặc mongod trong service file
if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
  sed -i 's/User=mongodb/User=mongod/g' /lib/systemd/system/mongod.service
  sed -i 's/Group=mongodb/Group=mongod/g' /lib/systemd/system/mongod.service
fi

chmod 644 /lib/systemd/system/mongod.service

# 10. Reload systemd, enable và start MongoDB
echo -e "${YELLOW}10. Khởi động MongoDB...${NC}"
systemctl daemon-reload
systemctl enable mongod
systemctl start mongod

# 11. Kiểm tra trạng thái MongoDB
echo -e "${YELLOW}11. Kiểm tra trạng thái MongoDB...${NC}"
sleep 5

if systemctl is-active --quiet mongod; then
  echo -e "${GREEN}MongoDB đã được cài đặt lại và khởi động thành công!${NC}"
  mongod --version
  echo -e "${GREEN}MongoDB đang chạy và lắng nghe trên cổng 27017${NC}"
else
  echo -e "${RED}MongoDB khởi động thất bại. Kiểm tra log để biết thêm chi tiết:${NC}"
  systemctl status mongod
  echo -e "${RED}Xem logs: sudo tail -n 50 $DEFAULT_LOG_DIR${NC}"
fi

echo -e "${BLUE}
============================================================
     MONGODB ĐÃ ĐƯỢC RESET VÀ CÀI ĐẶT LẠI
============================================================${NC}"

echo -e "${YELLOW}Tiếp theo, bạn có thể:${NC}"
echo "1. Cấu hình replica set bằng script 'setup_mongodb_distributed_replica.sh'"
echo "2. Tạo keyfile để xác thực các thành viên replica set"
echo "3. Tạo user admin và thiết lập xác thực"
echo 
echo -e "${YELLOW}Cấu hình MongoDB của bạn hiện là cấu hình mặc định (không replica set, không xác thực)${NC}"

exit 0
