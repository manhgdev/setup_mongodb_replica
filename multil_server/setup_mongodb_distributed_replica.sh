#!/bin/bash

#=====================================================
# THIẾT LẬP MONGODB REPLICA SET PHÂN TÁN - MANHG DEV
#=====================================================

# Thiết lập màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Cấu hình mặc định
MONGO_VERSION="8.0"
MONGO_PORT="27017"
REPLICA_SET_NAME="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
DEFAULT_DATA_DIR="/var/lib/mongodb"
DEFAULT_LOG_PATH="/var/log/mongodb/mongod.log"
DEFAULT_CONFIG_FILE="/etc/mongod.conf"
DEFAULT_KEYFILE="/etc/mongodb-keyfile"

clear
echo -e "${BLUE}
============================================
  THIẾT LẬP MONGODB REPLICA SET PHÂN TÁN
============================================${NC}"

# Lấy địa chỉ IP public của server
get_public_ip() {
  # Thử nhiều dịch vụ khác nhau để lấy IP public
  PUBLIC_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org || curl -s https://icanhazip.com || curl -s https://ifconfig.me)
  
  # Nếu không thể lấy IP public, sử dụng IP local hoặc hỏi người dùng
  if [[ -z "$PUBLIC_IP" ]]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Không thể tự động lấy IP public.${NC}"
    read -p "Nhập địa chỉ IP công khai của server này [$LOCAL_IP]: " PUBLIC_IP
    PUBLIC_IP=${PUBLIC_IP:-$LOCAL_IP}
  fi
  
  echo "$PUBLIC_IP"
}

# Cài đặt MongoDB
install_mongodb() {
  if command -v mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã được cài đặt${NC}"
    mongod --version
    return 0
  fi
  
  echo -e "${YELLOW}Đang cài đặt MongoDB $MONGO_VERSION...${NC}"
  
  # Cài đặt các gói cần thiết
  sudo apt-get update
  sudo apt-get install -y gnupg curl
  
  # Thêm key MongoDB
  curl -fsSL https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc | \
    sudo gpg -o /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg \
    --dearmor
  
  # Thêm repository
  UBUNTU_VERSION=$(lsb_release -cs)
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $UBUNTU_VERSION/mongodb-org/$MONGO_VERSION multiverse" | \
    sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
  
  # Cài đặt MongoDB
  sudo apt-get update
  sudo apt-get install -y mongodb-org
  
  # Kiểm tra cài đặt
  if command -v mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã được cài đặt thành công${NC}"
    mongod --version
    return 0
  else
    echo -e "${RED}✗ Cài đặt MongoDB thất bại${NC}"
    return 1
  fi
}

# Tạo keyfile
create_keyfile() {
  echo -e "${YELLOW}Tạo keyfile xác thực...${NC}"
  
  if [ ! -f "$DEFAULT_KEYFILE" ]; then
    openssl rand -base64 756 | sudo tee $DEFAULT_KEYFILE > /dev/null
    sudo chmod 400 $DEFAULT_KEYFILE
    
    if getent passwd mongodb > /dev/null; then
      sudo chown mongodb:mongodb $DEFAULT_KEYFILE
    elif getent passwd mongod > /dev/null; then
      sudo chown mongod:mongod $DEFAULT_KEYFILE
    fi
    
    echo -e "${GREEN}✓ Đã tạo keyfile tại $DEFAULT_KEYFILE${NC}"
  else
    echo -e "${GREEN}✓ Keyfile đã tồn tại${NC}"
  fi
}

# Tạo file cấu hình MongoDB
create_mongodb_config() {
  echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
  
  # Tạo thư mục cần thiết
  sudo mkdir -p $DEFAULT_DATA_DIR
  sudo mkdir -p $(dirname $DEFAULT_LOG_PATH)
  sudo mkdir -p /var/run/mongodb
  
  # Thiết lập quyền
  if getent passwd mongodb > /dev/null; then
    MONGO_USER="mongodb"
  elif getent passwd mongod > /dev/null; then
    MONGO_USER="mongod"
  else
    sudo useradd -r -s /bin/false mongodb
    MONGO_USER="mongodb"
  fi
  
  sudo chown -R $MONGO_USER:$MONGO_USER $DEFAULT_DATA_DIR
  sudo chown -R $MONGO_USER:$MONGO_USER $(dirname $DEFAULT_LOG_PATH)
  sudo chown -R $MONGO_USER:$MONGO_USER /var/run/mongodb
  
  # Tạo file cấu hình
  sudo tee $DEFAULT_CONFIG_FILE > /dev/null << EOF
# MongoDB configuration file
storage:
  dbPath: $DEFAULT_DATA_DIR

net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET_NAME

systemLog:
  destination: file
  path: $DEFAULT_LOG_PATH
  logAppend: true

security:
  keyFile: $DEFAULT_KEYFILE
  authorization: enabled

processManagement:
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo
EOF

  sudo chown $MONGO_USER:$MONGO_USER $DEFAULT_CONFIG_FILE
  sudo chmod 644 $DEFAULT_CONFIG_FILE
  
  echo -e "${GREEN}✓ Đã tạo file cấu hình tại $DEFAULT_CONFIG_FILE${NC}"
}

# Khởi động MongoDB
start_mongodb() {
  echo -e "${YELLOW}Khởi động MongoDB...${NC}"
  
  sudo systemctl daemon-reload
  sudo systemctl enable mongod
  sudo systemctl restart mongod
  
  sleep 5
  if sudo systemctl is-active mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    sudo systemctl status mongod
    echo -e "${YELLOW}Xem log để kiểm tra lỗi: sudo tail -n 50 $DEFAULT_LOG_PATH${NC}"
    return 1
  fi
}

# Khởi tạo Replica Set
init_replica_set() {
  local SERVER_IP=$1
  
  echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
  
  # Kiểm tra replica set đã được khởi tạo chưa
  if mongosh --quiet --port $MONGO_PORT --eval "try { rs.status(); print('EXISTS'); } catch(e) { print('NOT_INIT'); }" 2>/dev/null | grep -q "EXISTS"; then
    echo -e "${GREEN}✓ Replica Set đã tồn tại${NC}"
    return 0
  fi
  
  # Khởi tạo replica set
  echo -e "${YELLOW}Khởi tạo Replica Set mới với server: $SERVER_IP:$MONGO_PORT${NC}"
  
  INIT_CMD="rs.initiate({_id: '$REPLICA_SET_NAME', members: [{_id: 0, host: '$SERVER_IP:$MONGO_PORT', priority: 10}]});"
  INIT_RESULT=$(mongosh --port $MONGO_PORT --eval "$INIT_CMD")
  
  if [[ "$INIT_RESULT" == *"\"ok\" : 1"* || "$INIT_RESULT" == *"ok : 1"* || "$INIT_RESULT" == *"already initialized"* ]]; then
    echo -e "${GREEN}✓ Khởi tạo Replica Set thành công${NC}"
    
    # Tạo admin user sau khi khởi tạo replica set
    sleep 10  # Đợi replica set ổn định
    
    echo -e "${YELLOW}Đang tạo user admin...${NC}"
    CREATE_USER="admin = db.getSiblingDB('admin'); admin.createUser({user: '$MONGODB_USER', pwd: '$MONGODB_PASSWORD', roles: ['root']});"
    
    if mongosh --port $MONGO_PORT --eval "$CREATE_USER" | grep -q "Successfully added user"; then
      echo -e "${GREEN}✓ Đã tạo user admin thành công${NC}"
    else
      echo -e "${YELLOW}Có thể user admin đã tồn tại hoặc có lỗi khi tạo user${NC}"
    fi
    
    return 0
  else
    echo -e "${RED}✗ Khởi tạo Replica Set thất bại: $INIT_RESULT${NC}"
    return 1
  fi
}

# Thêm server vào Replica Set
add_server_to_replica_set() {
  local PRIMARY_SERVER=$1
  local SECONDARY_SERVER=$2
  local SECONDARY_ID=$3
  
  echo -e "${YELLOW}Thêm server $SECONDARY_SERVER vào Replica Set...${NC}"
  
  # Kiểm tra kết nối đến primary
  if ! mongosh --host $PRIMARY_SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "db.serverStatus()" &>/dev/null; then
    echo -e "${RED}✗ Không thể kết nối đến PRIMARY server $PRIMARY_SERVER${NC}"
    return 1
  fi
  
  # Kiểm tra xem server đã thuộc replica set chưa
  MEMBER_CHECK=$(mongosh --host $PRIMARY_SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "rs.conf().members.map(m => m.host).includes('$SECONDARY_SERVER:$MONGO_PORT')")
  
  if [[ "$MEMBER_CHECK" == *"true"* ]]; then
    echo -e "${GREEN}✓ Server $SECONDARY_SERVER đã thuộc Replica Set${NC}"
    return 0
  fi
  
  # Thêm server mới vào replica set
  ADD_CMD="rs.add({host: '$SECONDARY_SERVER:$MONGO_PORT', priority: 2, votes: 1, _id: $SECONDARY_ID})"
  ADD_RESULT=$(mongosh --host $PRIMARY_SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "$ADD_CMD")
  
  if [[ "$ADD_RESULT" == *"\"ok\" : 1"* || "$ADD_RESULT" == *"ok : 1"* ]]; then
    echo -e "${GREEN}✓ Đã thêm server $SECONDARY_SERVER vào Replica Set thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Thêm server thất bại: $ADD_RESULT${NC}"
    return 1
  fi
}

# Kiểm tra trạng thái Replica Set
check_replica_status() {
  local SERVER=$1
  
  echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
  
  # Kiểm tra xem đã tạo user chưa
  if mongosh --host $SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "db.serverStatus()" &>/dev/null; then
    # Hiển thị thông tin về replica set
    echo -e "\n${YELLOW}Thông tin Replica Set:${NC}"
    mongosh --host $SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "rs.status()"
    
    echo -e "\n${YELLOW}Cấu hình Replica Set:${NC}"
    mongosh --host $SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "rs.conf()"
    
    echo -e "\n${YELLOW}Thông tin isMaster:${NC}"
    mongosh --host $SERVER --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "rs.isMaster()"
  else
    echo -e "${RED}Không thể kết nối đến MongoDB với thông tin xác thực cung cấp${NC}"
    echo -e "${YELLOW}Thử kiểm tra trạng thái không xác thực...${NC}"
    mongosh --host $SERVER --port $MONGO_PORT --eval "rs.status()"
  fi
}

# Tạo chuỗi kết nối cho ứng dụng
create_connection_string() {
  local SERVERS=("$@")
  local CONN_STRING="mongodb://$MONGODB_USER:$MONGODB_PASSWORD@"
  
  for i in "${!SERVERS[@]}"; do
    if [ $i -gt 0 ]; then
      CONN_STRING+=","
    fi
    CONN_STRING+="${SERVERS[$i]}:$MONGO_PORT"
  done
  
  CONN_STRING+="/$AUTH_DATABASE?replicaSet=$REPLICA_SET_NAME"
  
  echo -e "${GREEN}Chuỗi kết nối MongoDB:${NC}"
  echo -e "${BLUE}$CONN_STRING${NC}"
}

# Mở cổng MongoDB trong firewall
configure_firewall() {
  echo -e "${YELLOW}Cấu hình Firewall...${NC}"
  
  # Kiểm tra UFW
  if command -v ufw &> /dev/null; then
    echo -e "${YELLOW}Cấu hình UFW...${NC}"
    sudo ufw allow $MONGO_PORT/tcp
    sudo ufw status | grep $MONGO_PORT
  fi
  
  # Kiểm tra Firewalld
  if command -v firewall-cmd &> /dev/null; then
    echo -e "${YELLOW}Cấu hình Firewalld...${NC}"
    sudo firewall-cmd --permanent --add-port=$MONGO_PORT/tcp
    sudo firewall-cmd --reload
    sudo firewall-cmd --list-ports | grep $MONGO_PORT
  fi
  
  echo -e "${GREEN}✓ Đã cấu hình Firewall${NC}"
}

#===================== MAIN PROGRAM ======================

# 1. Cài đặt MongoDB
install_mongodb || exit 1

# 2. Lấy địa chỉ IP public
THIS_SERVER_IP=$(get_public_ip)
echo -e "${GREEN}Địa chỉ IP của server này: $THIS_SERVER_IP${NC}"

# 3. Tạo keyfile
create_keyfile

# 4. Tạo file cấu hình MongoDB
create_mongodb_config

# 5. Khởi động MongoDB
start_mongodb || exit 1

# 6. Cấu hình firewall
configure_firewall

# Lựa chọn chế độ thiết lập
echo -e "\n${YELLOW}Chọn chế độ thiết lập:${NC}"
echo "1. Thiết lập server đầu tiên (PRIMARY)"
echo "2. Thêm server này vào Replica Set hiện có (SECONDARY)"
read -p "Lựa chọn của bạn (1/2): " SETUP_MODE

if [ "$SETUP_MODE" == "1" ]; then
  # Thiết lập server đầu tiên
  echo -e "${YELLOW}Thiết lập server đầu tiên (PRIMARY)...${NC}"
  
  # Khởi tạo Replica Set
  init_replica_set $THIS_SERVER_IP
  
  # Kiểm tra trạng thái
  sleep 5
  check_replica_status $THIS_SERVER_IP
  
  # Tạo chuỗi kết nối
  create_connection_string $THIS_SERVER_IP
  
  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}Thiết lập PRIMARY hoàn tất. Thông tin quan trọng:${NC}"
  echo -e "${YELLOW}Server: $THIS_SERVER_IP:$MONGO_PORT${NC}"
  echo -e "${YELLOW}Replica Set: $REPLICA_SET_NAME${NC}"
  echo -e "${YELLOW}User: $MONGODB_USER${NC}"
  echo -e "${YELLOW}Password: $MONGODB_PASSWORD${NC}"
  echo -e "${GREEN}===================================================${NC}"
  
elif [ "$SETUP_MODE" == "2" ]; then
  # Thêm server này vào Replica Set
  echo -e "${YELLOW}Thêm server này vào Replica Set hiện có...${NC}"
  
  read -p "Nhập địa chỉ IP của server PRIMARY: " PRIMARY_SERVER
  read -p "Nhập ID cho server này [2]: " SECONDARY_ID
  SECONDARY_ID=${SECONDARY_ID:-2}
  
  # Kiểm tra server PRIMARY
  if ! ping -c 1 $PRIMARY_SERVER &> /dev/null; then
    echo -e "${RED}✗ Không thể ping đến server PRIMARY $PRIMARY_SERVER${NC}"
    echo -e "${YELLOW}Tiếp tục với giả định rằng server này có thể kết nối được qua port MongoDB...${NC}"
  fi
  
  # Thêm server vào Replica Set
  add_server_to_replica_set $PRIMARY_SERVER $THIS_SERVER_IP $SECONDARY_ID
  
  # Kiểm tra trạng thái
  sleep 5
  check_replica_status $PRIMARY_SERVER
  
  # Tạo chuỗi kết nối
  create_connection_string $PRIMARY_SERVER $THIS_SERVER_IP
  
  echo -e "\n${GREEN}===================================================${NC}"
  echo -e "${GREEN}Thiết lập SECONDARY hoàn tất. Thông tin quan trọng:${NC}"
  echo -e "${YELLOW}Server PRIMARY: $PRIMARY_SERVER:$MONGO_PORT${NC}"
  echo -e "${YELLOW}Server này (SECONDARY): $THIS_SERVER_IP:$MONGO_PORT${NC}"
  echo -e "${YELLOW}Replica Set: $REPLICA_SET_NAME${NC}"
  echo -e "${GREEN}===================================================${NC}"
  
else
  echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
  exit 1
fi

echo -e "\n${GREEN}Thiết lập MongoDB Replica Set hoàn tất!${NC}"
echo -e "${YELLOW}Kiểm tra để đảm bảo tất cả hoạt động chính xác:${NC}"
echo "1. Sử dụng mongosh để kết nối và kiểm tra:"
echo "   mongosh --host $THIS_SERVER_IP --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin"
echo "2. Trong shell MongoDB, chạy lệnh: rs.status()"
echo -e "${YELLOW}Nếu cần thêm server, chạy script này trên server mới và chọn chế độ 2.${NC}" 