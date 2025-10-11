#!/bin/bash
# add_arbiter.sh
# Script thêm MongoDB Arbiter Node vào Replica Set

# Thiết lập error handling
# set -e  # Tạm thời disable để tránh script bị terminate
# Disable trap để tránh script bị ngắt khi kill process
# trap 'echo -e "${RED}Script bị ngắt! Đang dọn dẹp...${NC}"; exit 1' INT TERM

# Lấy đường dẫn thư mục chứa script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load các hàm utility từ lib
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/get_current_ip.sh"
source "$LIB_DIR/check_mongodb_connection.sh"
source "$LIB_DIR/check_replica_set_status.sh"
source "$LIB_DIR/remove_duplicate_members.sh"
source "$LIB_DIR/create_keyfile.sh"

# Định nghĩa các biến môi trường
REPLICA_SET_NAME="rs0"
MONGODB_DATA_DIR="/data/rs0-arbiter"
MONGODB_LOG_PATH="/var/log/mongodb/mongod-arbiter.log"
MONGODB_CONFIG="/etc/mongod-arbiter.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_USER="manhg"
MONGODB_PASS="manhnk"
ARBITER_PORT="27017"  # Sử dụng port mặc định MongoDB

# Hàm tạo cấu hình MongoDB cho Arbiter
create_arbiter_config() {
    local arbiter_ip=$1
    
    echo -e "${YELLOW}Tạo cấu hình MongoDB cho Arbiter...${NC}"
    
    # Tạo cấu hình đặc biệt cho Arbiter
    cat > "/tmp/mongod-arbiter.conf" << EOF
storage:
  dbPath: $MONGODB_DATA_DIR
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH
net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0
security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE
replication:
  replSetName: $REPLICA_SET_NAME
EOF
    
    # Copy cấu hình và set quyền
    sudo cp "/tmp/mongod-arbiter.conf" "$MONGODB_CONFIG"
    sudo mkdir -p "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")"
    sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")" 2>/dev/null || true
    
    echo -e "${GREEN}Đã tạo cấu hình MongoDB cho Arbiter${NC}"
}

# ==================== MAIN SCRIPT ====================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}     THIẾT LẬP MONGODB ARBITER NODE     ${NC}"
echo -e "${BLUE}========================================${NC}"

# Yêu cầu người dùng nhập IP của PRIMARY node
echo -e "${YELLOW}Vui lòng nhập IP của PRIMARY node:${NC}"
read -p "PRIMARY node IP: " PRIMARY_IP

# Kiểm tra IP PRIMARY hợp lệ
if [[ ! $PRIMARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP PRIMARY không hợp lệ. Vui lòng nhập lại.${NC}"
    exit 1
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
ARBITER_HOST="${ARBITER_IP}:${ARBITER_PORT}"

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB Arbiter Node...${NC}"
echo -e "${YELLOW}PRIMARY node: $PRIMARY_HOST${NC}"
echo -e "${YELLOW}ARBITER node: $ARBITER_HOST${NC}"

# Kiểm tra kết nối tới PRIMARY node
echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin"; then
    echo -e "${RED}Không thể kết nối tới PRIMARY node. Vui lòng kiểm tra lại.${NC}"
    echo -e "${YELLOW}Đảm bảo rằng:${NC}"
    echo -e "${YELLOW}1. PRIMARY node đang chạy${NC}"
    echo -e "${YELLOW}2. Thông tin xác thực ($MONGODB_USER/$MONGODB_PASS) chính xác${NC}"
    echo -e "${YELLOW}3. Firewall cho phép kết nối MongoDB${NC}"
    exit 1
fi

# Kiểm tra trạng thái replica set trên PRIMARY
echo -e "${YELLOW}Kiểm tra trạng thái replica set trên PRIMARY...${NC}"
RS_STATUS=$(check_replica_set_status "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin")
if [ "$RS_STATUS" != "1" ]; then
    echo -e "${RED}Replica Set chưa được cấu hình đúng trên PRIMARY node.${NC}"
    echo -e "${YELLOW}Vui lòng chạy setup_primary.sh trước khi thêm arbiter.${NC}"
    exit 1
fi

# Tạo keyfile từ PRIMARY node
create_keyfile "$PRIMARY_IP" "$MONGODB_KEYFILE"

# Kiểm tra keyfile
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại tại $MONGODB_KEYFILE${NC}"
    echo -e "${YELLOW}Vui lòng đảm bảo keyfile đã được tạo thành công.${NC}"
    exit 1
fi
    # Tạo thư mục dữ liệu MongoDB cho Arbiter
echo -e "${YELLOW}Tạo thư mục dữ liệu MongoDB cho Arbiter...${NC}"
sudo mkdir -p "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")"
sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")" 2>/dev/null || true

# Tạo cấu hình MongoDB cho Arbiter
create_arbiter_config "$ARBITER_IP"

# Khởi động MongoDB Arbiter trên port 27017
echo -e "${YELLOW}Khởi động MongoDB Arbiter trên port 27017...${NC}"

# Chỉ cần khởi động đơn giản
if sudo systemctl restart mongod; then
    echo -e "${GREEN}MongoDB đã khởi động trên port 27017${NC}"
else
    sudo mongod --config "$MONGODB_CONFIG" --fork
    echo -e "${GREEN}MongoDB đã khởi động trực tiếp trên port 27017${NC}"
fi

sleep 3

# Kiểm tra MongoDB đã khởi động thành công
if ! pgrep -f mongod >/dev/null; then
    echo -e "${RED}MongoDB không khởi động được${NC}"
    exit 1
fi

echo -e "${GREEN}MongoDB Arbiter đã khởi động thành công!${NC}"

# Kiểm tra kết nối local tới Arbiter
echo -e "${YELLOW}Kiểm tra kết nối local tới Arbiter...${NC}"
sleep 5

# Thử kết nối nhiều lần nếu cần
for i in {1..5}; do
    echo -e "${YELLOW}Thử kết nối lần $i...${NC}"
    if mongosh --port "$ARBITER_PORT" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null; then
        echo -e "${GREEN}Kết nối thành công tới MongoDB Arbiter trên port $ARBITER_PORT${NC}"
        break
    else
        if [ $i -eq 5 ]; then
            echo -e "${RED}Không thể kết nối tới MongoDB Arbiter trên port $ARBITER_PORT${NC}"
            exit 1
        else
            echo -e "${YELLOW}Kết nối thất bại, đợi 3 giây và thử lại...${NC}"
            sleep 3
        fi
    fi
done

# Xóa các member trùng lặp trước khi thêm arbiter
remove_duplicate_members "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin" "$ARBITER_HOST"
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