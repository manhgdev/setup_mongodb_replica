#!/bin/bash

# Thiết lập MongoDB Replica Set phân tán giữa nhiều server
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

echo -e "${BLUE}=== THIẾT LẬP MONGODB REPLICA SET PHÂN TÁN ===${NC}"

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

# Tạo keyfile 
create_keyfile() {
  echo -e "${YELLOW}Tạo keyfile xác thực...${NC}"
  if [ ! -f "$1" ]; then
    openssl rand -base64 756 | sudo tee $1 > /dev/null
    sudo chmod 400 $1
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $1
    echo -e "${GREEN}✓ Đã tạo keyfile tại $1${NC}"
  else
    echo -e "${GREEN}✓ Keyfile đã tồn tại${NC}"
  fi
}

# Tạo file cấu hình
create_mongodb_config() {
  echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
  local config_file=$1
  local dbpath=$2
  local logpath=$3
  local port=$4
  local replica_set=$5
  local keyfile=$6
  
  sudo mkdir -p $dbpath
  sudo mkdir -p $(dirname $logpath)
  
  local mongo_user="mongodb"
  if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
    mongo_user="mongod"
  fi
  
  sudo chown -R $mongo_user:$mongo_user $dbpath
  sudo chown -R $mongo_user:$mongo_user $(dirname $logpath)
  
  sudo tee $config_file > /dev/null << EOF
storage:
  dbPath: $dbpath
net:
  port: $port
  bindIp: 0.0.0.0
replication:
  replSetName: $replica_set
systemLog:
  destination: file
  path: $logpath
  logAppend: true
security:
  keyFile: $keyfile
  authorization: enabled
processManagement:
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo
EOF

  echo -e "${GREEN}✓ Đã tạo file cấu hình tại $config_file${NC}"
}

# Đảm bảo quyền truy cập
ensure_directory_permissions() {
  echo -e "${YELLOW}Đảm bảo quyền truy cập...${NC}"
  
  local mongo_user="mongodb"
  if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
    mongo_user="mongod"
  fi
  
  sudo mkdir -p $MONGODB_DATA_DIR
  sudo chown -R $mongo_user:$mongo_user $MONGODB_DATA_DIR
  sudo chmod -R 750 $MONGODB_DATA_DIR
  
  sudo mkdir -p $(dirname $MONGODB_LOG_DIR)
  sudo chown -R $mongo_user:$mongo_user $(dirname $MONGODB_LOG_DIR)
  
  sudo mkdir -p /var/run/mongodb
  sudo chown -R $mongo_user:$mongo_user /var/run/mongodb
  
  sudo chown $mongo_user:$mongo_user $MONGODB_KEYFILE
  sudo chmod 400 $MONGODB_KEYFILE
  
  sudo chown $mongo_user:$mongo_user $MONGODB_CONFIG_FILE
  
  echo -e "${GREEN}✓ Đã thiết lập quyền truy cập${NC}"
}

# Khởi động MongoDB
start_mongodb() {
  echo -e "${YELLOW}Khởi động MongoDB...${NC}"
  
  if systemctl is-active --quiet mongod; then
    sudo systemctl stop mongod
    sleep 2
  fi
  
  sudo tee /lib/systemd/system/mongod.service > /dev/null << EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
PIDFile=/var/run/mongodb/mongod.pid
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitNOFILE=64000
LimitNPROC=64000
LimitMEMLOCK=infinity
TasksMax=infinity
TasksAccounting=false

[Install]
WantedBy=multi-user.target
EOF
  
  if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
    sudo sed -i 's/User=mongodb/User=mongod/g' /lib/systemd/system/mongod.service
    sudo sed -i 's/Group=mongodb/Group=mongod/g' /lib/systemd/system/mongod.service
  fi
  
  sudo systemctl daemon-reload
  sudo systemctl enable mongod
  sudo systemctl start mongod
  
  sleep 5
  if sudo systemctl is-active mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    sudo systemctl status mongod
    return 1
  fi
}

# Khởi tạo replica set
init_replica_set_multi() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local server_list=$4
  local username=$5
  local password=$6
  
  echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
  
  # Kiểm tra MongoDB đã sẵn sàng
  mongo_ready=false
  for i in {1..15}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
      mongo_ready=true
      break
    fi
    echo -e "${YELLOW}Đang đợi MongoDB khởi động (${i}/15)...${NC}"
    sleep 2
  done
  
  if [ "$mongo_ready" = false ]; then
    echo -e "${RED}MongoDB không sẵn sàng sau thời gian chờ${NC}"
    return 1
  fi
  
  # Kiểm tra replica set đã được khởi tạo chưa
  rs_status=$(mongosh --quiet --port $port --eval "try { rs.status(); print('EXISTS'); } catch(e) { print('NOT_INIT'); }")
  
  if [[ "$rs_status" == *"NOT_INIT"* ]]; then
    # Khởi tạo replica set mới
    init_command="rs.initiate({_id: '$replica_set', members: [{_id: 0, host: '$this_server_ip:$port', priority: 10}]});"
    init_result=$(mongosh --port $port --eval "$init_command")
    
    if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* || "$init_result" == *"already initialized"* ]]; then
      echo -e "${GREEN}✓ Khởi tạo replica set thành công${NC}"
      sleep 10
      
      # Tạo user admin
      echo "Tạo user quản trị..."
      mongosh --port $port --eval "
      db = db.getSiblingDB('admin');
      try {
        db.createUser({
          user: '$username',
          pwd: '$password',
          roles: [ { role: 'root', db: 'admin' } ]
        });
      } catch(e) {}
      "
      
      # Thêm các server khác vào replica set
      if [ "$server_list" != "$this_server_ip" ]; then
        IFS=',' read -ra server_array <<< "$server_list"
        
        for server in "${server_array[@]}"; do
          if [[ "$server" != "$this_server_ip" ]]; then
            echo -e "${YELLOW}Thêm server: $server${NC}"
            
            if nc -z -w5 $server $port; then
              add_cmd="rs.add('$server:$port')"
              add_result=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase "admin" --eval "$add_cmd")
              
              if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
                echo -e "${GREEN}✓ Đã thêm server $server vào replica set${NC}"
              else
                echo -e "${RED}✗ Không thể thêm server $server: $add_result${NC}"
              fi
            else
              echo -e "${RED}Không thể kết nối đến $server:$port${NC}"
            fi
          fi
        done
      fi
    else
      echo -e "${RED}✗ Khởi tạo replica set thất bại: $init_result${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}✓ Replica set đã được khởi tạo trước đó${NC}"
  fi
}

# Kết nối server thứ hai vào replica set
add_to_replica_set() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local primary_server_ip=$4
  local username=$5
  local password=$6
  
  echo -e "${YELLOW}Kiểm tra và kết nối với replica set...${NC}"
  
  # Kiểm tra xem server này đã trong replica set chưa
  rs_status=$(mongosh --port $port --quiet --eval "try { rs.status().members.map(m => m.name) } catch(e) { print('NOT_FOUND') }")
  
  if [[ "$rs_status" == *"$this_server_ip:$port"* ]]; then
    echo -e "${GREEN}✓ Server này đã là thành viên của replica set${NC}"
    return 0
  fi
  
  # Kiểm tra cấu hình replica set trên primary
  echo "Kiểm tra cấu hình replica set hiện tại trên primary..."
  rs_config=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "try { rs.conf() } catch(e) { print('ERROR: ' + e.message) }")
  
  # Kiểm tra lỗi trong cấu hình
  if [[ "$rs_config" == ERROR* ]]; then
    echo -e "${RED}Không thể lấy cấu hình replica set: $rs_config${NC}"
    return 1
  fi
  
  # Kiểm tra xem có host trùng lặp không
  duplicate_check=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
  try {
    const config = rs.conf();
    const hosts = config.members.map(m => m.host);
    const duplicates = hosts.filter((item, index) => hosts.indexOf(item) !== index);
    if (duplicates.length > 0) {
      print('DUPLICATE: ' + duplicates.join(','));
    } else if (hosts.includes('$this_server_ip:$port')) {
      print('EXISTS');
    } else {
      print('OK');
    }
  } catch(e) {
    print('ERROR: ' + e.message);
  }
  ")
  
  # Xử lý các tình huống khác nhau
  if [[ "$duplicate_check" == DUPLICATE* ]]; then
    echo -e "${RED}Phát hiện host trùng lặp trong cấu hình: $duplicate_check${NC}"
    echo -e "${YELLOW}Đang xóa các bản ghi trùng lặp...${NC}"
    
    # Xóa cấu hình trùng lặp và tạo cấu hình mới
    fix_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
    try {
      const config = rs.conf();
      const uniqueHosts = {};
      const uniqueMembers = [];
      let id = 0;
      
      for (const member of config.members) {
        if (!uniqueHosts[member.host]) {
          uniqueHosts[member.host] = true;
          member._id = id++;
          uniqueMembers.push(member);
        }
      }
      
      config.members = uniqueMembers;
      
      if (!uniqueHosts['$this_server_ip:$port']) {
        config.members.push({
          _id: id,
          host: '$this_server_ip:$port',
          priority: 1
        });
      }
      
      rs.reconfig(config, {force: true});
      print('SUCCESS');
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    if [[ "$fix_result" == "SUCCESS" ]]; then
      echo -e "${GREEN}✓ Đã sửa cấu hình và thêm server này vào replica set${NC}"
    else
      echo -e "${RED}✗ Không thể sửa cấu hình: $fix_result${NC}"
      return 1
    fi
  elif [[ "$duplicate_check" == "EXISTS" ]]; then
    echo -e "${GREEN}✓ Server này đã được cấu hình trong replica set${NC}"
    return 0
  elif [[ "$duplicate_check" == "OK" ]]; then
    # Thêm server này vào replica set
    echo "Thêm server vào replica set..."
    add_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.add('$this_server_ip:$port')")
    
    if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* ]]; then
      echo -e "${GREEN}✓ Đã thêm server này vào replica set${NC}"
    else
      echo -e "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
      return 1
    fi
  else
    echo -e "${RED}✗ Lỗi khi kiểm tra cấu hình: $duplicate_check${NC}"
    return 1
  fi
}

# Kiểm tra trạng thái replica set
check_replica_status() {
  local port=$1
  local username=$2
  local password=$3
  
  echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
  
  # Kiểm tra primary
  primary_info=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
  try {
    primary = rs.isMaster().primary;
    if (primary) { print('Primary: ' + primary); } else { print('No primary found'); }
  } catch(e) {
    print('Lỗi: ' + e.message);
  }
  ")
  
  echo -e "${BLUE}$primary_info${NC}"
  
  # Nếu không tìm thấy primary, thử khởi tạo lại replica set
  if [[ "$primary_info" == *"No primary found"* ]]; then
    echo -e "${YELLOW}Không tìm thấy primary. Thử khởi tạo lại replica set...${NC}"
    mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --eval "
    try {
      rs.status();
    } catch(e) {
      if (e.codeName === 'NotYetInitialized') {
        rs.initiate();
        print('Đã khởi tạo replica set mới');
      }
    }
    "
    sleep 5
  fi
}

# Tạo chuỗi kết nối
create_connection_string() {
  local replica_set=$1
  local server_list=$2
  local port=$3
  local username=$4
  local password=$5
  
  local conn_servers=""
  IFS=',' read -ra server_array <<< "$server_list"
  
  for i in "${!server_array[@]}"; do
    server=${server_array[$i]}
    if [[ $i -gt 0 ]]; then
      conn_servers+=","
    fi
    conn_servers+="$server:$port"
  done
  
  conn_string="mongodb://$username:$password@$conn_servers/admin?replicaSet=$replica_set"
  
  echo -e "${BLUE}=== CHUỖI KẾT NỐI CHO ỨNG DỤNG ===${NC}"
  echo -e "${GREEN}$conn_string${NC}"
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

# CHƯƠNG TRÌNH CHÍNH
main() {
  echo -e "${BLUE}THÔNG TIN CẤU HÌNH${NC}"
  
  # Lấy IP của server
  THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Địa chỉ IP của server: $THIS_SERVER_IP${NC}"
  
  read -p "Server này là primary? (y/n): " IS_PRIMARY
  
  # Xác định số lượng server
  read -p "Nhập số lượng server trong replica set [2-$MAX_SERVERS]: " SERVER_COUNT
  
  if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -lt 2 ] || [ "$SERVER_COUNT" -gt $MAX_SERVERS ]; then
    SERVER_COUNT=2
  fi
  
  # Khởi tạo danh sách server
  SERVER_LIST="$THIS_SERVER_IP"
  
  if [ "$SERVER_COUNT" -gt 1 ]; then
    if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
      for ((i=1; i<SERVER_COUNT; i++)); do
        read -p "Nhập địa chỉ IP của server thứ $((i+1)): " OTHER_SERVER_IP
        if [ -n "$OTHER_SERVER_IP" ]; then
          SERVER_LIST+=",$OTHER_SERVER_IP"
        fi
      done
    else
      read -p "Địa chỉ IP của server primary: " PRIMARY_SERVER_IP
      SERVER_LIST="$PRIMARY_SERVER_IP,$THIS_SERVER_IP"
    fi
  fi
  
  read -p "Port MongoDB [$MONGO_PORT]: " USER_MONGO_PORT
  MONGO_PORT=${USER_MONGO_PORT:-$MONGO_PORT}
  
  read -p "Tên Replica Set [$REPLICA_SET_NAME]: " USER_REPLICA_SET
  REPLICA_SET_NAME=${USER_REPLICA_SET:-$REPLICA_SET_NAME}
  
  read -p "Tên người dùng MongoDB [$MONGODB_USER]: " USER_MONGODB_USER
  MONGODB_USER=${USER_MONGODB_USER:-$MONGODB_USER}
  
  read -p "Mật khẩu MongoDB [$MONGODB_PASSWORD]: " USER_MONGODB_PASSWORD
  MONGODB_PASSWORD=${USER_MONGODB_PASSWORD:-$MONGODB_PASSWORD}
  
  # Đặt đường dẫn
  MONGODB_DATA_DIR="/var/lib/mongodb"
  MONGODB_LOG_DIR="/var/log/mongodb/mongod.log"
  MONGODB_CONFIG_FILE="/etc/mongod.conf"
  MONGODB_KEYFILE="/etc/mongodb-keyfile"
  
  # Cài đặt và cấu hình
  install_mongodb $MONGO_VERSION
  create_keyfile $MONGODB_KEYFILE
  create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE
  ensure_directory_permissions
  configure_firewall $MONGO_PORT
  
  # Khởi động MongoDB
  if ! start_mongodb; then
    if netstat -tuln | grep ":$MONGO_PORT " > /dev/null; then
      echo -e "${RED}Port $MONGO_PORT đã được sử dụng${NC}"
      read -p "Nhập port mới: " NEW_PORT
      MONGO_PORT=$NEW_PORT
      create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE
      ensure_directory_permissions
      configure_firewall $MONGO_PORT
      start_mongodb
    fi
  fi
  
  # Thiết lập replica set
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    init_replica_set_multi $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD
  else
    echo -e "${YELLOW}Server này sẽ được thêm vào replica set đã tồn tại.${NC}"
    read -p "Tiếp tục? (y/n): " CONTINUE
    
    if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
      add_to_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD
    fi
  fi
  
  # Kiểm tra trạng thái và tạo chuỗi kết nối
  sleep 5
  check_replica_status $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
  create_connection_string $REPLICA_SET_NAME "$SERVER_LIST" $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
  
  echo -e "${GREEN}✅ Thiết lập MongoDB Replica Set hoàn tất!${NC}"
}

# Chạy chương trình chính
main

exit 0 