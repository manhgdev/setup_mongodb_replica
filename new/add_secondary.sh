#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/mongo_auth.sh" || exit 1
# add_secondary.sh
# Script cài đặt và thêm MongoDB Secondary Node vào Replica Set

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
MONGODB_DATA_DIR="/data/rs0"
MONGODB_LOG_PATH="/var/log/mongodb/mongod.log"
MONGODB_CONFIG="/etc/mongod.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_USER="manhg"
IFS= read -rs -p "Mật khẩu MongoDB: " MONGODB_PASS || exit 1
echo >&2
[[ -n "$MONGODB_PASS" ]] || exit 1

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}     THIẾT LẬP MONGODB SECONDARY NODE   ${NC}"
echo -e "${BLUE}========================================${NC}"

# Yêu cầu người dùng nhập IP của PRIMARY node
echo -e "${YELLOW}Vui lòng nhập IP của PRIMARY node:${NC}"
read -p "PRIMARY node IP: " PRIMARY_IP

# Kiểm tra IP PRIMARY hợp lệ
if [[ ! $PRIMARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP PRIMARY không hợp lệ. Vui lòng nhập lại.${NC}"
    exit 1
fi

# Tự động lấy IP của SECONDARY node (node hiện tại)
SECONDARY_IP=$(get_current_ip)
echo "SECONDARY IP: $SECONDARY_IP"

# Nếu không lấy được IP tự động, yêu cầu nhập
if [ -z "$SECONDARY_IP" ] || [[ ! $SECONDARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}Không thể tự động lấy IP của node hiện tại.${NC}"
    echo -e "${YELLOW}Vui lòng nhập IP của SECONDARY node (node hiện tại):${NC}"
    read -p "SECONDARY node IP: " SECONDARY_IP
    
    # Kiểm tra IP SECONDARY hợp lệ
    if [[ ! $SECONDARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}IP SECONDARY không hợp lệ. Vui lòng nhập lại.${NC}"
        exit 1
    fi
fi

PRIMARY_HOST="${PRIMARY_IP}:27017"
SECONDARY_HOST="${SECONDARY_IP}:27017"

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB Secondary Node...${NC}"
echo -e "${YELLOW}PRIMARY node: $PRIMARY_HOST${NC}"
echo -e "${YELLOW}SECONDARY node: $SECONDARY_HOST${NC}"

# Kiểm tra kết nối tới PRIMARY node
echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin"; then
    echo -e "${RED}Không thể kết nối tới PRIMARY node. Vui lòng kiểm tra lại.${NC}"
    exit 1
fi

# Tạo keyfile từ PRIMARY node
create_keyfile "$PRIMARY_IP" "$MONGODB_KEYFILE"

# 1. Kiểm tra keyfile từ PRIMARY
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại tại $MONGODB_KEYFILE${NC}"
    echo -e "${YELLOW}Vui lòng copy keyfile từ PRIMARY node về trước khi chạy script này.${NC}"
    exit 1
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
sudo cp "$MONGODB_CONFIG" "${MONGODB_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

# Kiểm tra xem đã có thể đăng nhập với tài khoản admin chưa
echo -e "${YELLOW}Kiểm tra xem đã cài đặt authentication chưa...${NC}"
AUTH_STATUS=$(check_mongodb_connection "localhost:27017" "$MONGODB_USER" "$MONGODB_PASS" "admin")

if [ "$AUTH_STATUS" == "1" ]; then
    # Trường hợp 2: Đã cài đặt authentication thành công
    echo -e "${GREEN}Đã cài đặt authentication thành công. Sử dụng tài khoản hiện có.${NC}"
    
    # Kiểm tra replica set
    RS_STATUS=$(check_replica_set_status "localhost:27017" "$MONGODB_USER" "$MONGODB_PASS" "admin")
    
    if [ "$RS_STATUS" == "1" ]; then
        echo -e "${GREEN}Replica Set đã được cấu hình đúng.${NC}"
    else
        echo -e "${YELLOW}Replica Set chưa được cấu hình đúng. Đang cập nhật...${NC}"
        
        # Xóa member trùng lặp trước khi thêm mới
        remove_duplicate_members "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin" "$SECONDARY_HOST"
        
        # Cập nhật cấu hình replication
        if ! grep -q "^replication:" "$MONGODB_CONFIG"; then
            echo -e "\nreplication:\n  replSetName: \"$REPLICA_SET_NAME\"" | sudo tee -a "$MONGODB_CONFIG" > /dev/null
        else
            sudo sed -i "/^replication:/,/^[a-z]/s|replSetName:.*|replSetName: \"$REPLICA_SET_NAME\"|" "$MONGODB_CONFIG"
        fi
        
        # Khởi động lại MongoDB
        echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
        sudo systemctl restart mongod
        sleep 15
        
        # Join vào Replica Set từ PRIMARY
        echo -e "${YELLOW}Đang join vào Replica Set từ PRIMARY...${NC}"
        mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --eval "rs.add(\"$SECONDARY_HOST\")"
        sleep 2
        mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --eval "
            var cfg = rs.conf();
            for (var i = 0; i < cfg.members.length; i++) {
                if (cfg.members[i].host === '$SECONDARY_HOST') {
                    cfg.members[i].priority = 1;
                }
            }
            cfg.version += 1;
            rs.reconfig(cfg);
        "
    fi
    
else
    # Trường hợp 1: Chưa cài đặt authentication hoặc authentication thất bại
    echo -e "${YELLOW}Chưa cài đặt authentication hoặc cài đặt thất bại. Thiết lập lại từ đầu...${NC}"
    
    # Dừng MongoDB để làm sạch
    echo -e "${YELLOW}Dừng MongoDB để làm sạch cài đặt...${NC}"
    sudo systemctl stop mongod
    sleep 5
    
    # Xoá lock file nếu có
    if [ -f "/var/lib/mongodb/mongod.lock" ]; then
        echo -e "${YELLOW}Xoá lock file...${NC}"
        sudo rm -f /var/lib/mongodb/mongod.lock
    fi
    
    # Cập nhật cấu hình MongoDB mới (không bao gồm security và authentication ban đầu)
    echo -e "${YELLOW}Cập nhật cấu hình MongoDB...${NC}"
    
    # Tạo cấu hình tạm thời chỉ với replication, không có authentication
    cat > "/tmp/mongod.conf.tmp" << EOF
# mongod.conf

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      # Đặt giới hạn Cache rõ ràng (ví dụ: 2 GB)
      cacheSizeGB: 4

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

# replication
replication:
  replSetName: "${REPLICA_SET_NAME}"
EOF
    
    # Copy cấu hình tạm thời
    sudo cp "/tmp/mongod.conf.tmp" "$MONGODB_CONFIG"
    sudo chmod 644 "$MONGODB_CONFIG"
    
    # Khởi động MongoDB với cấu hình mới
    echo -e "${YELLOW}Khởi động MongoDB với cấu hình chỉ replication (không authentication)...${NC}"
    sudo systemctl start mongod
    sleep 5
    
    # Kiểm tra MongoDB đã chạy
    if ! systemctl is-active --quiet mongod; then
        echo -e "${RED}MongoDB không khởi động được. Kiểm tra logs tại /var/log/mongodb/mongod.log${NC}"
        exit 1
    fi
    
    # Xóa member trùng lặp trước khi thêm mới
    remove_duplicate_members "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin" "$SECONDARY_HOST"
    
    # Join vào Replica Set từ PRIMARY
    echo -e "${YELLOW}Đang join vào Replica Set từ PRIMARY...${NC}"
    mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --eval "rs.add(\"$SECONDARY_HOST\")"
    
    # Đợi một chút để Replica Set cập nhật
    sleep 5
    
    # Kiểm tra trạng thái Replica Set
    echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
    mongosh --port 27017 --eval "rs.status()"
    
    # Tạo User Root (kiểm tra trước nếu đã tồn tại)
    echo -e "${YELLOW}Kiểm tra và tạo user root cho MongoDB...${NC}"
    USER_EXISTS=$(mongosh --port 27017 --quiet --eval "try { db.getSiblingDB('admin').getUser('$MONGODB_USER') ? 1 : 0 } catch(e) { 0 }" 2>/dev/null)
    
    if [ "$USER_EXISTS" == "1" ]; then
        echo -e "${BLUE}User $MONGODB_USER đã tồn tại.${NC}"
    else
        echo -e "${YELLOW}Tạo user mới $MONGODB_USER...${NC}"
        mongosh 3<<<"$MONGODB_PASS" --port 27017 admin --eval "
        if (!db.getUser('$MONGODB_USER')) {
          db.createUser({ user: '$MONGODB_USER', pwd: require('fs').readFileSync(3,'utf8').slice(0,-1), roles: [{ role: 'root', db: 'admin' }] });
        } else {
          print('User đã tồn tại');
        }
        "
    fi
    sleep 5
    
    # Cập nhật cấu hình hoàn chỉnh bao gồm security
    cat > "/tmp/mongod.conf.complete" << EOF
# mongod.conf

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb
  wiredTiger:
    engineConfig:
      # Đặt giới hạn Cache rõ ràng (ví dụ: 2 GB)
      cacheSizeGB: 4

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# network interfaces
net:
  port: 27017
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
    sudo cp "/tmp/mongod.conf.complete" "$MONGODB_CONFIG"
    sudo chmod 644 "$MONGODB_CONFIG"
    
    # Khởi động lại MongoDB với cấu hình đầy đủ
    echo -e "${YELLOW}Khởi động lại MongoDB với cấu hình đầy đủ...${NC}"
    sudo systemctl restart mongod
    sleep 5
    
    # Kiểm tra MongoDB đã chạy
    if ! systemctl is-active --quiet mongod; then
        echo -e "${RED}MongoDB không khởi động được. Kiểm tra logs tại /var/log/mongodb/mongod.log${NC}"
        exit 1
    fi
    
    # Kiểm tra trạng thái Replica Set
    echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
    mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --port 27017 --eval "rs.status()"
fi

# Hoàn thành
echo -e "${GREEN}MongoDB Secondary Node đã được thiết lập thành công!${NC}"
echo -e "${GREEN}Bạn có thể đăng nhập với lệnh sau:${NC}"
echo -e "${GREEN}mongosh -u $MONGODB_USER --authenticationDatabase admin${NC}"