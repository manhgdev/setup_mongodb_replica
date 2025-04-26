#!/bin/bash
# setup_secondary.sh
# Script cài đặt MongoDB Secondary Node

# Định nghĩa các biến môi trường
REPLICA_SET_NAME="rs0"
MONGODB_DATA_DIR="/data/rs0"
MONGODB_LOG_PATH="/var/log/mongodb/mongod.log"
MONGODB_CONFIG="/etc/mongod.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_USER="manhg"
MONGODB_PASS="manhnk"

# Định nghĩa màu sắc cho terminal
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Hàm tạo keyfile
create_keyfile() {
    local primary_host=$1
    
    echo -e "${YELLOW}Tạo keyfile cho xác thực...${NC}"
    
    # Yêu cầu thông tin đăng nhập SSH
    read -p "Nhập username SSH cho máy chủ primary: " ssh_user
    
    # Thử copy keyfile từ primary
    echo -e "${YELLOW}Copy keyfile từ máy chủ primary $primary_host...${NC}"
    if scp -o StrictHostKeyChecking=no ${ssh_user}@${primary_host}:${MONGODB_KEYFILE} ${MONGODB_KEYFILE}; then
        echo -e "${GREEN}Đã copy keyfile từ primary thành công${NC}"
    else
        echo -e "${RED}Không thể copy keyfile từ primary. Tạo keyfile mới...${NC}"
        openssl rand -base64 756 > "$MONGODB_KEYFILE"
        echo -e "${YELLOW}Cảnh báo: Sử dụng keyfile mới có thể gây ra vấn đề với xác thực replica set${NC}"
        echo -e "${YELLOW}Nên copy keyfile từ primary node thủ công để đảm bảo tính nhất quán${NC}"
    fi
    
    # Thiết lập quyền
    chmod 400 "$MONGODB_KEYFILE"
    if [ "$(id -u)" -eq 0 ] || [ -n "$sudo_cmd" ]; then
        if getent passwd mongodb >/dev/null; then
            $sudo_cmd chown mongodb:mongodb "$MONGODB_KEYFILE"
        fi
    fi
    
    echo -e "${GREEN}Keyfile đã được thiết lập${NC}"
}

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
echo -e "${YELLOW}Vui lòng nhập IP của PRIMARY node:${NC}"
read -p "PRIMARY node IP: " PRIMARY_IP

# Kiểm tra IP PRIMARY hợp lệ
if [[ ! $PRIMARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP PRIMARY không hợp lệ. Vui lòng nhập lại.${NC}"
    exit 1
fi

# Tự động lấy IP của SECONDARY node (node hiện tại)
SECONDARY_IP=$(get_current_ip)
echo "SECONDARY_IP IP: $SECONDARY_IP"

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

# Tạo keyfile từ PRIMARY node
create_keyfile "$PRIMARY_IP"

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
AUTH_STATUS=$(mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "try { db.runCommand({ping: 1}).ok } catch(e) { 0 }" 2>/dev/null)

if [ "$AUTH_STATUS" == "1" ]; then
    # Trường hợp 2: Đã cài đặt authentication thành công
    echo -e "${GREEN}Đã cài đặt authentication thành công. Sử dụng tài khoản hiện có.${NC}"
    
    # Kiểm tra replica set
    RS_STATUS=$(mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "try { rs.status().ok } catch(e) { 0 }" 2>/dev/null)
    
    if [ "$RS_STATUS" == "1" ]; then
        echo -e "${GREEN}Replica Set đã được cấu hình đúng.${NC}"
    else
        echo -e "${YELLOW}Replica Set chưa được cấu hình đúng. Đang cập nhật...${NC}"
        
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
        mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.add(\"$SECONDARY_HOST\")"
        sleep 2
        mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "
            var cfg = rs.conf();
            for (var i = 0; i < cfg.members.length; i++) {
                if (cfg.members[i].host === '$SECONDARY_HOST') {
                    cfg.members[i].priority = 5;
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
    
    # Join vào Replica Set từ PRIMARY
    echo -e "${YELLOW}Đang join vào Replica Set từ PRIMARY...${NC}"
    mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.add(\"$SECONDARY_HOST\")"
    
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
        mongosh --port 27017 admin --eval "
        if (!db.getUser('$MONGODB_USER')) {
          db.createUser({ user: '$MONGODB_USER', pwd: '$MONGODB_PASS', roles: [{ role: 'root', db: 'admin' }] });
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
    mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.status()"
fi

# Hoàn thành
echo -e "${GREEN}MongoDB Secondary Node đã được thiết lập thành công!${NC}"
echo -e "${GREEN}Bạn có thể đăng nhập với lệnh sau:${NC}"
echo -e "${GREEN}mongosh -u $MONGODB_USER -p $MONGODB_PASS --authenticationDatabase admin${NC}"
