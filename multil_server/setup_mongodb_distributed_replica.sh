#!/bin/bash

# Thiết lập MongoDB Replica Set phân tán với tự động failover
# Màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Biến cấu hình
MONGO_PORT="27017"
REPLICA_SET_NAME="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MONGO_VERSION="8.0"
MAX_SERVERS=7

# Thông tin node
declare -A NODES=(
    ["node1"]="$MONGO_PORT"
    ["node2"]="$((MONGO_PORT + 1))"
    ["node3"]="$((MONGO_PORT + 2))"
)

echo -e "${BLUE}=== THIẾT LẬP MONGODB REPLICA SET (3 NODE) ===${NC}"

# Cài đặt MongoDB
install_mongodb() {
  echo -e "${YELLOW}Kiểm tra cài đặt MongoDB...${NC}"
  if command -v mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã được cài đặt${NC}"
    mongod --version
    return 0
  fi
  
  echo -e "${YELLOW}Đang cài đặt MongoDB $1...${NC}"
  sudo apt-get update
  sudo apt-get install -y gnupg curl netcat-openbsd
  sudo rm -f /usr/share/keyrings/mongodb-server-$1.gpg
  
  curl -fsSL https://www.mongodb.org/static/pgp/server-$1.asc | \
    sudo gpg -o /usr/share/keyrings/mongodb-server-$1.gpg --dearmor
  
  UBUNTU_VERSION=$(lsb_release -cs)
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$1.gpg ] https://repo.mongodb.org/apt/ubuntu $UBUNTU_VERSION/mongodb-org/$1 multiverse" | \
    sudo tee /etc/apt/sources.list.d/mongodb-org-$1.list
  
  sudo apt-get update
  sudo apt-get install -y mongodb-org
  
  if command -v mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã được cài đặt thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Cài đặt MongoDB thất bại${NC}"
    exit 1
  fi
}

# Tạo keyfile đơn giản (tùy chọn)
create_keyfile() {
  echo -e "${YELLOW}Tạo keyfile xác thực...${NC}"
  local keyfile=$1
  
  if [ ! -f "$keyfile" ]; then
    openssl rand -base64 756 | sudo tee $keyfile > /dev/null
    sudo chmod 400 $keyfile
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $keyfile
    echo -e "${GREEN}✓ Đã tạo keyfile tại $keyfile${NC}"
  else
    echo -e "${GREEN}✓ Keyfile đã tồn tại${NC}"
  fi
}

# Cấu hình MongoDB
create_mongodb_config() {
  echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
  local config_file=$1
  local dbpath=$2
  local logpath=$3
  local port=$4
  local replica_set=$5
  local use_keyfile=$6
  local keyfile=$7
  
  sudo mkdir -p $dbpath
  sudo mkdir -p $(dirname $logpath)
  
  local mongo_user="mongodb"
  if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
    mongo_user="mongod"
  fi
  
  sudo chown -R $mongo_user:$mongo_user $dbpath
  sudo chown -R $mongo_user:$mongo_user $(dirname $logpath)

  # Tạo cấu hình cơ bản
  local config_content="storage:
  dbPath: $dbpath
net:
  port: $port
  bindIp: 0.0.0.0
  maxIncomingConnections: 65536
replication:
  replSetName: $replica_set
systemLog:
  destination: file
  path: $logpath
  logAppend: true
processManagement:
  timeZoneInfo: /usr/share/zoneinfo"

  # Thêm cấu hình xác thực nếu sử dụng keyfile
  if [ "$use_keyfile" = true ]; then
    config_content="$config_content
security:
  keyFile: $keyfile
  authorization: enabled"
  fi

  echo "$config_content" | sudo tee $config_file > /dev/null
  echo -e "${GREEN}✓ Đã tạo file cấu hình tại $config_file${NC}"
}

# Khởi động MongoDB
start_mongodb() {
  echo -e "${YELLOW}Khởi động MongoDB...${NC}"
  
  if systemctl is-active --quiet mongod; then
    sudo systemctl stop mongod
    sleep 2
  fi
  
  sudo systemctl daemon-reload
  sudo systemctl enable mongod
  sudo systemctl start mongod
  
  # Kiểm tra log sau khi khởi động
  sleep 5
  if sudo systemctl is-active mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    sudo systemctl status mongod
    echo -e "${YELLOW}Kiểm tra log để tìm lỗi:${NC}"
    sudo tail -n 20 /var/log/mongodb/mongod.log
    return 1
  fi
}

# Mở port firewall
configure_firewall() {
  local port=$1
  echo -e "${YELLOW}Cấu hình tường lửa...${NC}"
  
  if command -v ufw &> /dev/null; then
    sudo ufw allow $port/tcp
  fi
  
  if command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port=$port/tcp
    sudo firewall-cmd --reload
  fi
  
  echo -e "${GREEN}✓ Đã cấu hình tường lửa${NC}"
}

# Khởi tạo replica set
init_replica_set() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local server_list=$4
  local username=$5
  local password=$6
  local use_auth=$7
  
  echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
  
  # Kiểm tra MongoDB đã sẵn sàng
  echo -e "${YELLOW}Đang đợi MongoDB khởi động...${NC}"
  for i in {1..15}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
      echo -e "${GREEN}✓ MongoDB đã sẵn sàng${NC}"
      break
    fi
    echo "Thử lần ${i}/15..."
    sleep 2
    
    if [ $i -eq 15 ]; then
      echo -e "${RED}MongoDB không sẵn sàng sau thời gian chờ${NC}"
      return 1
    fi
  done
  
  # Kiểm tra replica set đã được khởi tạo chưa
  rs_status=$(mongosh --quiet --port $port --eval "try { rs.status(); print('EXISTS'); } catch(e) { print('NOT_INIT'); }")
  
  if [[ "$rs_status" == *"NOT_INIT"* ]]; then
    # Xây dựng cấu hình replica set
    echo -e "${YELLOW}Khởi tạo replica set mới...${NC}"
    local rs_config="{ _id: '$replica_set', members: ["
    
    IFS=',' read -ra server_array <<< "$server_list"
    local member_id=0
    
    for server in "${server_array[@]}"; do
      local priority=1
      # Server đầu tiên có priority cao hơn để được ưu tiên làm primary
      if [ $member_id -eq 0 ]; then
        priority=10
      fi
      
      if [ $member_id -gt 0 ]; then
        rs_config+=", "
      fi
      
      rs_config+="{_id: $member_id, host: '$server:$port', priority: $priority}"
      ((member_id++))
    done
    
    rs_config+="] }"
    
    # Khởi tạo replica set
    init_result=$(mongosh --port $port --eval "rs.initiate($rs_config)")
    
    if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* ]]; then
      echo -e "${GREEN}✓ Khởi tạo replica set thành công${NC}"
      sleep 10
      
      # Tạo user admin nếu cần xác thực
      if [ "$use_auth" = true ]; then
        echo -e "${YELLOW}Tạo user quản trị...${NC}"
        create_user_result=$(mongosh --port $port --eval "
        db = db.getSiblingDB('admin');
        db.createUser({
          user: '$username',
          pwd: '$password',
          roles: [ { role: 'root', db: 'admin' } ]
        });
        ")
        
        if [[ "$create_user_result" == *"Successfully added user"* ]]; then
          echo -e "${GREEN}✓ Tạo user thành công${NC}"
        else
          echo -e "${YELLOW}User có thể đã tồn tại hoặc có lỗi: $create_user_result${NC}"
        fi
      fi
    else
      echo -e "${RED}✗ Khởi tạo replica set thất bại: $init_result${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}✓ Replica set đã được khởi tạo trước đó${NC}"
  fi
}

# Kết nối vào replica set hiện có
join_replica_set() {
  local port=$1
  local this_server_ip=$2
  local primary_server_ip=$3
  local username=$4
  local password=$5
  local use_auth=$6
  
  echo -e "${YELLOW}Kết nối vào replica set hiện có...${NC}"
  
  # Kiểm tra kết nối tới primary
  echo -e "${YELLOW}Kiểm tra kết nối tới primary server...${NC}"
  if ! nc -z -w5 $primary_server_ip $port; then
    echo -e "${RED}Không thể kết nối tới primary server $primary_server_ip:$port${NC}"
    return 1
  fi
  
  # Thêm server vào replica set
  echo -e "${YELLOW}Thêm server này vào replica set...${NC}"
  local auth_params=""
  if [ "$use_auth" = true ]; then
    auth_params="-u \"$username\" -p \"$password\" --authenticationDatabase admin"
  fi
  
  add_result=$(mongosh --host "$primary_server_ip:$port" $auth_params --eval "rs.add('$this_server_ip:$port')")
  
  if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
    echo -e "${GREEN}✓ Đã thêm server vào replica set thành công${NC}"
  else
    echo -e "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
    return 1
  fi
}

# Sửa lỗi "not reachable/healthy"
fix_unreachable_node() {
  local problem_node=$1
  local port=$2
  local primary_server=$3
  local username=$4
  local password=$5
  local this_server=$6
  local use_auth=$7
  
  echo -e "${BLUE}=== SỬA LỖI NODE KHÔNG KHẢ DỤNG (not reachable/healthy) ===${NC}"
  
  # Xác định auth params
  local auth_params=""
  if [ "$use_auth" = true ]; then
    auth_params="-u \"$username\" -p \"$password\" --authenticationDatabase admin"
  fi
  
  if [[ "$problem_node" == "$this_server:$port" || "$problem_node" == *"$this_server"* ]]; then
    echo -e "${YELLOW}Node gặp vấn đề là server hiện tại. Tiến hành sửa lỗi nội bộ...${NC}"
    
    # 1. Kiểm tra MongoDB có đang chạy không
    echo -e "${YELLOW}1. Kiểm tra trạng thái MongoDB...${NC}"
    if ! systemctl is-active --quiet mongod; then
      echo -e "${RED}MongoDB không chạy. Khởi động lại...${NC}"
      sudo systemctl start mongod
      sleep 5
    else
      echo -e "${GREEN}✓ MongoDB đang chạy${NC}"
    fi
    
    # 2. Kiểm tra log để tìm lỗi
    echo -e "${YELLOW}2. Kiểm tra log MongoDB...${NC}"
    sudo tail -n 30 /var/log/mongodb/mongod.log
    
    # 3. Kiểm tra kết nối mạng
    echo -e "${YELLOW}3. Kiểm tra kết nối mạng...${NC}"
    if nc -z -w5 $primary_server $port; then
      echo -e "${GREEN}✓ Kết nối đến primary server thành công${NC}"
    else
      echo -e "${RED}✗ Không thể kết nối đến primary server${NC}"
      echo -e "Kiểm tra mạng và tường lửa..."
    fi
    
    # 4. Làm sạch và tham gia lại
    echo -e "${YELLOW}4. Tham gia lại replica set từ đầu? (y/n)${NC}"
    read -p "Điều này sẽ xóa dữ liệu MongoDB và tham gia lại (y/n): " REJOIN
    
    if [[ "$REJOIN" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Xóa server này khỏi replica set từ primary...${NC}"
      mongosh --host "$primary_server:$port" $auth_params --eval "try { rs.remove('$this_server:$port'); } catch(e) {}"
      
      echo -e "${YELLOW}Dừng MongoDB...${NC}"
      sudo systemctl stop mongod
      
      echo -e "${YELLOW}Xóa dữ liệu cũ...${NC}"
      sudo rm -rf /var/lib/mongodb/*
      
      echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
      sudo systemctl start mongod
      sleep 10
      
      echo -e "${YELLOW}Thêm lại server vào replica set...${NC}"
      mongosh --host "$primary_server:$port" $auth_params --eval "rs.add('$this_server:$port')"
    fi
  else
    echo -e "${YELLOW}Node gặp vấn đề là server khác ($problem_node). Tiến hành sửa lỗi từ xa...${NC}"
    
    # Thử xóa và thêm lại node vào replica set
    echo -e "${YELLOW}1. Xóa node khỏi replica set...${NC}"
    mongosh --host "$primary_server:$port" $auth_params --eval "try { rs.remove('$problem_node'); print('Đã xóa'); } catch(e) { print('Lỗi: ' + e.message); }"
    
    sleep 5
    
    echo -e "${YELLOW}2. Thêm lại node vào replica set...${NC}"
    mongosh --host "$primary_server:$port" $auth_params --eval "try { rs.add('$problem_node'); print('Đã thêm'); } catch(e) { print('Lỗi: ' + e.message); }"
  fi
  
  # Kiểm tra lại trạng thái
  echo -e "${YELLOW}Kiểm tra lại trạng thái sau khi sửa...${NC}"
  sleep 10
  mongosh --host "$primary_server:$port" $auth_params --eval "rs.status()" | grep -A 3 "$problem_node"
}

# Tạo chuỗi kết nối
create_connection_string() {
  local replica_set=$1
  local server_list=$2
  local port=$3
  local username=$4
  local password=$5
  local use_auth=$6
  
  local conn_servers=""
  IFS=',' read -ra server_array <<< "$server_list"
  
  for i in "${!server_array[@]}"; do
    server=${server_array[$i]}
    if [[ $i -gt 0 ]]; then
      conn_servers+=","
    fi
    conn_servers+="$server:$port"
  done
  
  local conn_string=""
  if [ "$use_auth" = true ]; then
    conn_string="mongodb://$username:$password@$conn_servers/admin?replicaSet=$replica_set"
  else
    conn_string="mongodb://$conn_servers/admin?replicaSet=$replica_set"
  fi
  
  echo -e "${BLUE}=== CHUỖI KẾT NỐI CHO ỨNG DỤNG ===${NC}"
  echo -e "${GREEN}$conn_string${NC}"
}

# Kiểm tra trạng thái replica set
check_replica_status() {
  local port=$1
  local username=$2
  local password=$3
  local use_auth=$4
  
  echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
  
  local auth_params=""
  if [ "$use_auth" = true ]; then
    auth_params="-u \"$username\" -p \"$password\" --authenticationDatabase admin"
  fi
  
  status_result=$(mongosh --port $port $auth_params --quiet --eval "
  rs.status().members.forEach(function(member) {
    print(member.name + ' - ' + member.stateStr + (member.stateStr === 'PRIMARY' ? ' ✅' : ''));
  });
  ")
  
  echo -e "${BLUE}=== TRẠNG THÁI REPLICA SET ===${NC}"
  echo -e "${GREEN}$status_result${NC}"
}

# CHƯƠNG TRÌNH CHÍNH
main() {
  # Lấy IP của server
  THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Địa chỉ IP của server: $THIS_SERVER_IP${NC}"
  
  read -p "Server này là primary? (y/n): " IS_PRIMARY
  
  # Xác định sử dụng keyfile hay không
  read -p "Sử dụng xác thực (keyfile + username/password)? (y/n): " USE_AUTH
  if [[ "$USE_AUTH" =~ ^[Yy]$ ]]; then
    USE_AUTH=true
  else
    USE_AUTH=false
    echo -e "${YELLOW}Chú ý: Không sử dụng xác thực làm giảm tính bảo mật của hệ thống${NC}"
  fi
  
  # Xác định số lượng và danh sách server
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    read -p "Nhập số lượng server trong replica set [2-$MAX_SERVERS]: " SERVER_COUNT
    
    if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -lt 1 ] || [ "$SERVER_COUNT" -gt $MAX_SERVERS ]; then
      SERVER_COUNT=1
    fi
    
    # Khởi tạo danh sách server
    SERVER_LIST="$THIS_SERVER_IP"
    
    if [ "$SERVER_COUNT" -gt 1 ]; then
      for ((i=1; i<SERVER_COUNT; i++)); do
        read -p "Nhập địa chỉ IP của server thứ $((i+1)): " OTHER_SERVER_IP
        if [ -n "$OTHER_SERVER_IP" ]; then
          SERVER_LIST+=",$OTHER_SERVER_IP"
        fi
      done
    fi
  else
    read -p "Địa chỉ IP của server primary: " PRIMARY_SERVER_IP
  fi
  
  read -p "Port MongoDB [$MONGO_PORT]: " USER_MONGO_PORT
  if [ -n "$USER_MONGO_PORT" ]; then
    MONGO_PORT=$USER_MONGO_PORT
  fi
  
  read -p "Tên Replica Set [$REPLICA_SET_NAME]: " USER_REPLICA_SET
  if [ -n "$USER_REPLICA_SET" ]; then
    REPLICA_SET_NAME=$USER_REPLICA_SET
  fi
  
  if [ "$USE_AUTH" = true ]; then
    read -p "Tên người dùng MongoDB [$MONGODB_USER]: " USER_MONGODB_USER
    if [ -n "$USER_MONGODB_USER" ]; then
      MONGODB_USER=$USER_MONGODB_USER
    fi
    
    read -p "Mật khẩu MongoDB [$MONGODB_PASSWORD]: " USER_MONGODB_PASSWORD
    if [ -n "$USER_MONGODB_PASSWORD" ]; then
      MONGODB_PASSWORD=$USER_MONGODB_PASSWORD
    fi
  else
    # Đặt giá trị mặc định ngay cả khi không sử dụng xác thực
    MONGODB_USER="admin"
    MONGODB_PASSWORD="password"
  fi
  
  # Đặt đường dẫn
  MONGODB_DATA_DIR="/var/lib/mongodb"
  MONGODB_LOG_DIR="/var/log/mongodb/mongod.log"
  MONGODB_CONFIG_FILE="/etc/mongod.conf"
  MONGODB_KEYFILE="/etc/mongodb-keyfile"
  
  # Cài đặt MongoDB
  install_mongodb $MONGO_VERSION
  
  # Tạo keyfile nếu cần
  if [ "$USE_AUTH" = true ]; then
    create_keyfile $MONGODB_KEYFILE
    create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME true $MONGODB_KEYFILE
  else
    create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME false ""
  fi
  
  # Mở port firewall
  configure_firewall $MONGO_PORT
  
  # Khởi động MongoDB
  start_mongodb
  
  # Thêm tùy chọn fix node lỗi
  read -p "Sửa lỗi node 'not reachable/healthy'? (y/n): " FIX_NODE
  if [[ "$FIX_NODE" =~ ^[Yy]$ ]]; then
    read -p "Nhập địa chỉ node có vấn đề (IP:port): " PROBLEM_NODE
    read -p "Nhập địa chỉ primary server: " PRIMARY_SERVER
    
    fix_unreachable_node "$PROBLEM_NODE" "$MONGO_PORT" "$PRIMARY_SERVER" "$MONGODB_USER" "$MONGODB_PASSWORD" "$THIS_SERVER_IP" $USE_AUTH
    exit 0
  fi
  
  # Thiết lập replica set
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    init_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD $USE_AUTH
    # Kiểm tra và hiển thị trạng thái
    sleep 5
    check_replica_status $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD $USE_AUTH
    create_connection_string $REPLICA_SET_NAME "$SERVER_LIST" $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD $USE_AUTH
  else
    join_replica_set $MONGO_PORT $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD $USE_AUTH
  fi
  
  echo -e "${GREEN}✅ Thiết lập MongoDB Replica Set hoàn tất!${NC}"
  echo -e "${YELLOW}Chú ý: MongoDB sẽ tự động bầu chọn primary mới nếu primary hiện tại gặp sự cố.${NC}"
}

# Chạy chương trình chính
main

exit 0