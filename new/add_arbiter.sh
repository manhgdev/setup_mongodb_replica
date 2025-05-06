#!/bin/bash
# setup_arbiter.sh
# Script cài đặt MongoDB ARBITER Node

# Định nghĩa các biến môi trường
REPLICA_SET_NAME="rs0"
MONGODB_DATA_DIR="/data/rs0-arbiter"
MONGODB_LOG_PATH="/var/log/mongodb/mongod-arbiter.log"
MONGODB_CONFIG="/etc/mongod-arbiter.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_USER="manhg"
MONGODB_PASS="manhnk"
MONGODB_PORT="27018"

# Định nghĩa màu sắc cho terminal
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Hàm lấy IP của node hiện tại
get_current_ip() {
    local ip=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' 2>/dev/null | grep -v '^127\.' | head -n 1 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' 2>/dev/null)
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' 2>/dev/null | grep -Eo '([0-9]*\.){3}[0-9]*' 2>/dev/null | grep -v '127.0.0.1' 2>/dev/null | head -n 1 2>/dev/null)
    fi
    echo "$ip"
}

# Yêu cầu người dùng nhập IP của PRIMARY node
echo -e "${YELLOW}Vui lòng nhập IP của node:${NC}"
read -p "PRIMARY node IP: " PRIMARY_IP

if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP=$(get_current_ip)
fi

# Tự động lấy IP của ARBITER node (node hiện tại)
ARBITER_IP=$(get_current_ip)
echo "ARBITER_IP IP: $ARBITER_IP"

# Nếu không lấy được IP tự động, yêu cầu nhập
if [ -z "$ARBITER_IP" ] || [[ ! $ARBITER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}Không thể tự động lấy IP của node hiện tại.${NC}"
    echo -e "${YELLOW}Vui lòng nhập IP của ARBITER node (node hiện tại):${NC}"
    read -p "ARBITER node IP: " ARBITER_IP
    
    # Kiểm tra IP ARBITER hợp lệ
    if [[ ! $ARBITER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}IP ARBITER không hợp lệ. Vui lòng nhập lại.${NC}"
        exit 1
    fi
fi

PRIMARY_HOST="${PRIMARY_IP}:27017"
ARBITER_HOST="${ARBITER_IP}:${MONGODB_PORT}"

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB ARBITER Node...${NC}"
echo -e "${YELLOW}PRIMARY node: $PRIMARY_HOST${NC}"
echo -e "${YELLOW}ARBITER node: $ARBITER_HOST${NC}"

# 1. Kiểm tra keyfile từ PRIMARY
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại tại $MONGODB_KEYFILE${NC}"
    echo -e "${YELLOW}Vui lòng copy keyfile từ PRIMARY node về trước khi chạy script này.${NC}"
    exit 1
fi

# Kiểm tra quyền keyfile
KEYFILE_PERMS=$(stat -c "%a" "$MONGODB_KEYFILE" 2>/dev/null)
if [ "$KEYFILE_PERMS" != "400" ]; then
    echo -e "${YELLOW}Đang cập nhật quyền keyfile...${NC}"
    sudo chmod 400 "$MONGODB_KEYFILE"
    sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
fi

# 2. Tạo thư mục dữ liệu MongoDB nếu chưa tồn tại
if [ ! -d "$MONGODB_DATA_DIR" ]; then
    echo -e "${YELLOW}Tạo thư mục dữ liệu MongoDB...${NC}"
    sudo mkdir -p "$MONGODB_DATA_DIR"
    sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR"
else
    echo -e "${GREEN}Thư mục dữ liệu MongoDB đã tồn tại.${NC}"
fi

# Tạo backup cấu hình hiện tại
echo -e "${YELLOW}Tạo backup cấu hình hiện tại...${NC}"
sudo cp "$MONGODB_CONFIG" "${MONGODB_CONFIG}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

# Dừng MongoDB để làm sạch
echo -e "${YELLOW}Dừng MongoDB...${NC}"
sudo systemctl stop mongod-arbiter 2>/dev/null || true
sleep 5

# Xoá lock file nếu có
if [ -f "/var/lib/mongodb/mongod-arbiter.lock" ]; then
    echo -e "${YELLOW}Xoá lock file...${NC}"
    sudo rm -f /var/lib/mongodb/mongod-arbiter.lock
fi

# Cập nhật cấu hình MongoDB mới
echo -e "${YELLOW}Cập nhật cấu hình MongoDB...${NC}"

# Tạo cấu hình hoàn chỉnh
cat > "/tmp/mongod-arbiter.conf" << EOF
# mongod-arbiter.conf

# Where and how to store data.
storage:
  dbPath: $MONGODB_DATA_DIR

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH

# network interfaces
net:
  port: $MONGODB_PORT
  bindIp: 0.0.0.0

# security
security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE

# replication
replication:
  replSetName: "${REPLICA_SET_NAME}"
EOF

# Copy cấu hình hoàn chỉnh
sudo cp "/tmp/mongod-arbiter.conf" "$MONGODB_CONFIG"
sudo chmod 644 "$MONGODB_CONFIG"

# Tạo systemd service cho ARBITER
cat > "/tmp/mongod-arbiter.service" << EOF
[Unit]
Description=MongoDB Database Server (ARBITER)
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config $MONGODB_CONFIG
PIDFile=/var/run/mongodb/mongod-arbiter.pid
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitNOFILE=64000
LimitNPROC=64000

[Install]
WantedBy=multi-user.target
EOF

# Copy service file
sudo cp "/tmp/mongod-arbiter.service" "/etc/systemd/system/mongod-arbiter.service"
sudo systemctl daemon-reload

# Khởi động MongoDB ARBITER
echo -e "${YELLOW}Khởi động MongoDB ARBITER...${NC}"
sudo systemctl start mongod-arbiter
sleep 5

# Kiểm tra MongoDB đã chạy
if ! systemctl is-active --quiet mongod-arbiter; then
    echo -e "${RED}MongoDB ARBITER không khởi động được. Kiểm tra logs tại $MONGODB_LOG_PATH${NC}"
    exit 1
fi

# Đợi PRIMARY node sẵn sàng
echo -e "${YELLOW}Đang đợi PRIMARY node sẵn sàng...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
PRIMARY_READY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    PRIMARY_STATE=$(mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "try { rs.status().members.find(m => m.stateStr === 'PRIMARY').stateStr } catch(e) { '' }" 2>/dev/null)
    
    if [ "$PRIMARY_STATE" == "PRIMARY" ]; then
        PRIMARY_READY=true
        break
    fi
    
    echo -e "${YELLOW}PRIMARY node chưa sẵn sàng, đợi 5 giây...${NC}"
    sleep 5
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ "$PRIMARY_READY" = false ]; then
    echo -e "${RED}Không thể kết nối với PRIMARY node sau $MAX_RETRIES lần thử. Vui lòng kiểm tra lại.${NC}"
    exit 1
fi

# Thiết lập write concern trước khi thêm ARBITER
echo -e "${YELLOW}Thiết lập write concern...${NC}"
mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "db.adminCommand({setDefaultRWConcern: 1, defaultWriteConcern: {w: 'majority'}})"

# Join vào Replica Set từ PRIMARY
echo -e "${YELLOW}Đang join vào Replica Set từ PRIMARY...${NC}"
mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.addArb(\"$ARBITER_HOST\")" || {
    echo -e "${YELLOW}Thử cách khác để thêm ARBITER...${NC}"
    mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.reconfig(rs.conf())"
    sleep 5
    mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.addArb(\"$ARBITER_HOST\")"
}

# Đợi một chút để Replica Set cập nhật
sleep 5

# Kiểm tra trạng thái Replica Set
echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
mongosh --port $MONGODB_PORT -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.status()"

# Hoàn thành
echo -e "${GREEN}MongoDB ARBITER Node đã được thiết lập thành công!${NC}"
echo -e "${GREEN}Bạn có thể đăng nhập với lệnh sau:${NC}"
echo -e "${GREEN}mongosh --port $MONGODB_PORT -u $MONGODB_USER -p $MONGODB_PASS --authenticationDatabase admin${NC}"