#!/bin/bash
# setup_primary.sh
# Script cài đặt MongoDB Primary Node

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

PRIMARY_IP=$(get_current_ip)
echo "PRIMARY IP: $PRIMARY_IP"

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB Primary Node...${NC}"

# 1. Tạo thư mục dữ liệu MongoDB nếu chưa tồn tại
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
        
        # Khởi tạo Replica Set
        echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
        mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.initiate({ _id: \"$REPLICA_SET_NAME\", members: [{ _id: 0, host: \"$PRIMARY_IP:27017\" }] })"
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
    sleep 15
    
    # Kiểm tra MongoDB đã chạy
    if ! systemctl is-active --quiet mongod; then
        echo -e "${RED}MongoDB không khởi động được. Kiểm tra logs tại /var/log/mongodb/mongod.log${NC}"
        exit 1
    fi
    
    # Kiểm tra xem Replica Set đã được khởi tạo chưa
    RS_CHECK=$(mongosh --port 27017 --quiet --eval "try { rs.status().ok } catch(e) { 0 }" 2>/dev/null)
    
    if [ "$RS_CHECK" == "1" ]; then
        echo -e "${BLUE}Replica Set đã được khởi tạo trước đó.${NC}"
    else
        # Khởi tạo Replica Set
        echo -e "${YELLOW}Khởi tạo Replica Set với tên $REPLICA_SET_NAME...${NC}"
        mongosh --port 27017 --eval "rs.initiate({ _id: '$REPLICA_SET_NAME', members: [{ _id: 0, host: '$PRIMARY_IP:27017', priority: 10 }] })"
        sleep 10
    fi
    
    # Kiểm tra lại Replica Set đã khởi tạo thành công
    RS_CHECK=$(mongosh --port 27017 --quiet --eval "try { rs.status().ok } catch(e) { 0 }" 2>/dev/null)
    if [ "$RS_CHECK" != "1" ]; then
        echo -e "${RED}Khởi tạo Replica Set thất bại. Vui lòng kiểm tra logs.${NC}"
        exit 1
    fi
    
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
    
    # Tạo KeyFile cho Replica Set
    echo -e "${YELLOW}Tạo KeyFile cho Replica Set...${NC}"
    if [ -f "$MONGODB_KEYFILE" ]; then
        echo -e "${BLUE}KeyFile đã tồn tại.${NC}"
    else
        sudo openssl rand -base64 756 | sudo tee $MONGODB_KEYFILE > /dev/null
        sudo chmod 400 $MONGODB_KEYFILE
        sudo chown mongodb:mongodb $MONGODB_KEYFILE
    fi
    
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
fi

# Kiểm tra đăng nhập cuối cùng
echo -e "${YELLOW}Kiểm tra đăng nhập...${NC}"
AUTH_CHECK=$(mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "try { db.runCommand({ping: 1}).ok } catch(e) { 0 }" 2>/dev/null)

if [ "$AUTH_CHECK" == "1" ]; then
    echo -e "${GREEN}Đăng nhập thành công!${NC}"
    
    # Hiển thị trạng thái Replica Set
    echo -e "${YELLOW}Trạng thái Replica Set:${NC}"
    mongosh --port 27017 -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.status()"
    
    # Hoàn thành
    echo -e "${GREEN}MongoDB Primary Node đã được thiết lập thành công!${NC}"
    echo -e "${GREEN}Bạn có thể đăng nhập với lệnh sau:${NC}"
    echo -e "${GREEN}mongosh -u $MONGODB_USER -p $MONGODB_PASS --authenticationDatabase admin${NC}"
else
    echo -e "${RED}Đăng nhập thất bại. Vui lòng thử lại script hoặc khởi động lại MongoDB.${NC}"
    echo -e "${YELLOW}Kiểm tra xem MongoDB đã khởi động lại hoàn toàn chưa. Đôi khi cần đợi lâu hơn.${NC}"
    echo -e "${YELLOW}Nếu vẫn lỗi, hãy chạy lệnh sau để xem logs:${NC}"
    echo -e "${BLUE}sudo tail -n 50 /var/log/mongodb/mongod.log${NC}"
fi