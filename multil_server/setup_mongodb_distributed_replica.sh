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

# Sửa chữa replica set khi có vấn đề
repair_replica_set() {
  local port=$1
  local username=$2
  local password=$3
  local primary_server=$4
  local this_server=$5
  
  echo -e "${YELLOW}Đang sửa chữa replica set...${NC}"
  
  # Kiểm tra kết nối tới primary
  if ! nc -z -w5 $primary_server $port; then
    echo -e "${RED}Không thể kết nối tới primary server $primary_server:$port${NC}"
    return 1
  fi
  
  # Xóa dữ liệu replica set hiện tại trên server này
  echo -e "${YELLOW}Xóa dữ liệu replica set cũ trên server này...${NC}"
  sudo systemctl stop mongod
  echo -e "${YELLOW}Xóa dữ liệu MongoDB cũ...${NC}"
  sudo rm -rf $MONGODB_DATA_DIR/*
  
  # Khởi động lại MongoDB
  echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
  sudo systemctl start mongod
  sleep 5
  
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
    echo -e "${RED}MongoDB không sẵn sàng sau khi khởi động lại${NC}"
    return 1
  fi
  
  # Thử thêm vào replica set
  echo -e "${YELLOW}Thêm server này vào replica set từ primary...${NC}"
  add_result=$(mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.add('$this_server:$port')")
  
  if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
    echo -e "${GREEN}✓ Đã thêm server này vào replica set${NC}"
    return 0
  else
    echo -e "${RED}✗ Vẫn không thể thêm server: $add_result${NC}"
    return 1
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
  
  # Kiểm tra kết nối tới primary
  echo -e "${YELLOW}Kiểm tra kết nối tới primary server...${NC}"
  if ! nc -z -w5 $primary_server_ip $port; then
    echo -e "${RED}Không thể kết nối tới primary server $primary_server_ip:$port${NC}"
    echo -e "${YELLOW}Đảm bảo primary server đang chạy và port $port đã được mở.${NC}"
    return 1
  fi
  
  # Kiểm tra xem primary có thực sự là primary không
  echo -e "${YELLOW}Kiểm tra trạng thái primary...${NC}"
  primary_check=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
  try {
    const isMaster = db.adminCommand({ isMaster: 1 });
    if (isMaster.ismaster) {
      print('PRIMARY');
    } else {
      print('NOT_PRIMARY');
    }
  } catch(e) {
    if (e.message.includes('Authentication failed')) {
      print('AUTH_FAILED');
    } else {
      print('ERROR: ' + e.message);
    }
  }
  ")
  
  if [[ "$primary_check" == "AUTH_FAILED" ]]; then
    echo -e "${RED}Xác thực thất bại với primary server. Kiểm tra lại username/password.${NC}"
    echo -e "${YELLOW}Thử thao tác không xác thực...${NC}"
    
    # Thử kết nối không xác thực
    primary_check=$(mongosh --host "$primary_server_ip:$port" --quiet --eval "
    try {
      const isMaster = db.adminCommand({ isMaster: 1 });
      if (isMaster.ismaster) {
        print('PRIMARY_NO_AUTH');
      } else {
        print('NOT_PRIMARY_NO_AUTH');
      }
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
  fi
  
  if [[ "$primary_check" == "NOT_PRIMARY"* ]]; then
    echo -e "${RED}Server được chỉ định không phải là PRIMARY!${NC}"
    
    # Tìm primary thực sự
    echo -e "${YELLOW}Tìm PRIMARY thực sự...${NC}"
    real_primary=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
    try {
      const status = rs.status();
      for (let member of status.members) {
        if (member.stateStr === 'PRIMARY') {
          print(member.name);
          break;
        }
      }
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    " 2>/dev/null)
    
    if [[ "$real_primary" != "ERROR:"* && "$real_primary" != "" ]]; then
      echo -e "${GREEN}Tìm thấy PRIMARY thực sự: $real_primary${NC}"
      primary_server_ip=${real_primary%:*}
      echo -e "${YELLOW}Sử dụng $primary_server_ip làm PRIMARY server${NC}"
    else
      echo -e "${RED}Không tìm thấy PRIMARY trong replica set. Có thể đang trong quá trình bầu chọn.${NC}"
      echo -e "${YELLOW}Thử thêm server này như một server mới...${NC}"
      repair_replica_set $port $username $password $primary_server_ip $this_server_ip
      return $?
    fi
  fi
  
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
    if [[ "$rs_config" == *"not authorized"* ]]; then
      echo -e "${YELLOW}Lỗi xác thực. Kiểm tra lại username/password...${NC}"
    fi
    echo -e "${YELLOW}Thử sửa chữa replica set...${NC}"
    repair_replica_set $port $username $password $primary_server_ip $this_server_ip
    return $?
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
      echo -e "${YELLOW}Thử sửa chữa replica set...${NC}"
      repair_replica_set $port $username $password $primary_server_ip $this_server_ip
      return $?
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
      echo -e "${YELLOW}Thử sửa chữa replica set...${NC}"
      repair_replica_set $port $username $password $primary_server_ip $this_server_ip
      return $?
    fi
  else
    echo -e "${RED}✗ Lỗi khi kiểm tra cấu hình: $duplicate_check${NC}"
    echo -e "${YELLOW}Thử sửa chữa replica set...${NC}"
    repair_replica_set $port $username $password $primary_server_ip $this_server_ip
    return $?
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

# Tham gia vào replica set đã tồn tại 
join_existing_replica() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local primary_server_ip=$4
  local username=$5
  local password=$6
  
  echo -e "${BLUE}=== THÊM MÁY SECONDARY VÀO REPLICA SET ĐÃ TỒN TẠI ===${NC}"
  
  # 1. Dừng MongoDB hiện tại
  echo -e "${YELLOW}1. Dừng MongoDB hiện tại nếu đang chạy...${NC}"
  if systemctl is-active --quiet mongod; then
    sudo systemctl stop mongod
  fi
  
  # 2. Lấy keyfile từ primary nếu cần
  echo -e "${YELLOW}2. Lấy keyfile từ primary nếu có thể...${NC}"
  
  # Tạo thư mục tạm để lưu keyfile
  TMP_KEYFILE="/tmp/mongodb-keyfile-tmp"
  if [[ -n "$username" && -n "$password" ]]; then
    echo -e "${YELLOW}Thử lấy keyfile từ primary thông qua SSH...${NC}"
    read -p "Nhập SSH username cho primary server [$USER]: " SSH_USER
    SSH_USER=${SSH_USER:-$USER}
    
    # Kiểm tra nếu có thể SSH tới primary
    if ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_USER@$primary_server_ip echo "SSH OK" &>/dev/null; then
      echo -e "${GREEN}Kết nối SSH thành công, đang sao chép keyfile...${NC}"
      
      # Sao chép keyfile từ primary server
      scp $SSH_USER@$primary_server_ip:/etc/mongodb-keyfile $TMP_KEYFILE
      
      if [ -f "$TMP_KEYFILE" ]; then
        echo -e "${GREEN}Đã sao chép keyfile từ primary.${NC}"
        sudo cp $TMP_KEYFILE $MONGODB_KEYFILE
        
        # Xác định user mongodb hoặc mongod
        local mongo_user="mongodb"
        if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
          mongo_user="mongod"
        fi
        
        sudo chown $mongo_user:$mongo_user $MONGODB_KEYFILE
        sudo chmod 400 $MONGODB_KEYFILE
        rm -f $TMP_KEYFILE
      else
        echo -e "${YELLOW}Không thể sao chép keyfile, sẽ tạo keyfile mới...${NC}"
        create_keyfile $MONGODB_KEYFILE
      fi
    else
      echo -e "${YELLOW}Không thể kết nối SSH tới primary, sẽ tạo keyfile mới...${NC}"
      create_keyfile $MONGODB_KEYFILE
      echo -e "${YELLOW}LƯU Ý: Có thể cần thủ công đồng bộ keyfile giữa các node.${NC}"
    fi
  else
    echo -e "${YELLOW}Không có thông tin xác thực, sẽ tạo keyfile mới...${NC}"
    create_keyfile $MONGODB_KEYFILE
  fi
  
  # 3. Tạo lại cấu hình MongoDB cho secondary
  echo -e "${YELLOW}3. Tạo cấu hình MongoDB cho secondary...${NC}"
  create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $port $replica_set $MONGODB_KEYFILE
  
  # 4. Xóa dữ liệu local để tránh xung đột
  echo -e "${YELLOW}4. Xóa dữ liệu local để tránh xung đột...${NC}"
  read -p "Xóa dữ liệu MongoDB hiện tại? (y/n): " CLEAN_DATA
  if [[ "$CLEAN_DATA" =~ ^[Yy]$ ]]; then
    sudo rm -rf $MONGODB_DATA_DIR/*
    echo -e "${GREEN}Đã xóa dữ liệu cũ.${NC}"
  else
    echo -e "${YELLOW}Giữ lại dữ liệu hiện tại.${NC}"
  fi
  
  # 5. Đảm bảo quyền truy cập
  ensure_directory_permissions
  
  # 6. Khởi động MongoDB
  echo -e "${YELLOW}6. Khởi động MongoDB...${NC}"
  sudo systemctl start mongod
  sleep 5
  
  # 7. Kiểm tra kết nối tới primary server
  echo -e "${YELLOW}7. Kiểm tra kết nối tới primary server...${NC}"
  if ! nc -z -w5 $primary_server_ip $port; then
    echo -e "${RED}Không thể kết nối tới primary server $primary_server_ip:$port${NC}"
    echo -e "${YELLOW}Đảm bảo primary server đang chạy và port $port đã được mở.${NC}"
    return 1
  fi
  
  # 8. Chờ MongoDB khởi động và kiểm tra trạng thái
  echo -e "${YELLOW}8. Chờ MongoDB khởi động...${NC}"
  local mongo_ready=false
  for i in {1..15}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
      mongo_ready=true
      break
    fi
    echo -e "${YELLOW}Đang đợi MongoDB khởi động (${i}/15)...${NC}"
    sleep 2
  done
  
  if [ "$mongo_ready" = false ]; then
    echo -e "${RED}MongoDB không sẵn sàng sau khi khởi động lại${NC}"
    sudo systemctl status mongod
    echo -e "${YELLOW}Kiểm tra log: sudo tail -f $MONGODB_LOG_DIR${NC}"
    return 1
  fi
  
  # 9. Kiểm tra và sửa cấu hình replica set trên primary nếu cần
  echo -e "${YELLOW}9. Kiểm tra cấu hình replica set trên primary...${NC}"
  
  # Thử kiểm tra status của primary (không xác thực)
  echo -e "${YELLOW}Kiểm tra status của primary (không xác thực)...${NC}"
  local status_check=$(mongosh --host "$primary_server_ip:$port" --eval "try { rs.status(); print('OK') } catch(e) { print(e.message) }")
  
  # Kiểm tra xem có cần xác thực không
  local auth_needed=false
  if [[ "$status_check" == *"not authorized"* || "$status_check" == *"Authentication failed"* ]]; then
    auth_needed=true
    echo -e "${YELLOW}Cần xác thực để kết nối tới primary.${NC}"
    
    # Kiểm tra lại thông tin xác thực
    if [[ -z "$username" || -z "$password" ]]; then
      read -p "Nhập username MongoDB [manhg]: " username
      username=${username:-manhg}
      read -p "Nhập password MongoDB [manhnk]: " password
      password=${password:-manhnk}
    fi
    
    # Kiểm tra xác thực với primary
    local auth_check=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.status(); print('AUTH_OK') } catch(e) { print(e.message) }")
    
    if [[ "$auth_check" == *"AUTH_OK"* ]]; then
      echo -e "${GREEN}Xác thực với primary thành công.${NC}"
    else
      echo -e "${RED}Xác thực với primary thất bại: $auth_check${NC}"
      echo -e "${YELLOW}Đang thử tạo user admin trên máy local...${NC}"
      
      # Tạo user admin trên local node
      local create_user_result=$(mongosh --port $port --eval "
      try {
        use admin;
        db.createUser({
          user: '$username',
          pwd: '$password',
          roles: [ { role: 'root', db: 'admin' } ]
        });
        print('USER_CREATED');
      } catch(e) {
        print(e.message);
      }
      ")
      
      echo -e "${YELLOW}Kết quả tạo user: $create_user_result${NC}"
    fi
  else
    echo -e "${GREEN}Kết nối tới primary không cần xác thực.${NC}"
  fi
  
  # 10. Thêm server này vào replica set từ primary
  echo -e "${YELLOW}10. Thêm server này vào replica set từ primary...${NC}"
  
  # Kiểm tra xem server này đã là thành viên của replica set chưa
  local local_rs_check=$(mongosh --port $port --eval "try { rs.status().members.map(m => m.name).indexOf('$this_server_ip:$port') >= 0 ? 'MEMBER' : 'NOT_MEMBER' } catch(e) { print(e.message) }")
  
  if [[ "$local_rs_check" == "MEMBER" ]]; then
    echo -e "${GREEN}Server này đã là thành viên của replica set.${NC}"
  else
    # Thêm server này vào replica set
    local add_cmd="rs.add('$this_server_ip:$port')"
    local add_result=""
    
    if [ "$auth_needed" = true ]; then
      echo -e "${YELLOW}Thêm server với xác thực...${NC}"
      add_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "$add_cmd")
    else
      echo -e "${YELLOW}Thêm server không cần xác thực...${NC}"
      add_result=$(mongosh --host "$primary_server_ip:$port" --eval "$add_cmd")
    fi
    
    if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
      echo -e "${GREEN}✓ Đã thêm server này vào replica set thành công${NC}"
    else
      echo -e "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
      
      # 11. Xử lý lỗi hostnames trùng nhau
      if [[ "$add_result" == *"same host field"* || "$add_result" == *"duplicate"* ]]; then
        echo -e "${YELLOW}Phát hiện host trùng lặp. Sửa cấu hình...${NC}"
        
        local reconfig_cmd=$(cat << EOF
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
EOF
        )
        
        local fix_result=""
        if [ "$auth_needed" = true ]; then
          fix_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "$reconfig_cmd")
        else
          fix_result=$(mongosh --host "$primary_server_ip:$port" --eval "$reconfig_cmd")
        fi
        
        if [[ "$fix_result" == *"SUCCESS"* ]]; then
          echo -e "${GREEN}✓ Đã sửa cấu hình và thêm server này vào replica set${NC}"
        else
          echo -e "${RED}✗ Không thể sửa cấu hình: $fix_result${NC}"
          return 1
        fi
      fi
    fi
  fi
  
  # 12. Kiểm tra trạng thái replica set
  echo -e "${YELLOW}12. Kiểm tra trạng thái replica set...${NC}"
  sleep 10 # Đợi để replica set đồng bộ
  
  if [ "$auth_needed" = true ]; then
    local check_cmd="rs.status()"
    local check_result=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --eval "$check_cmd")
    echo "$check_result" | grep -E "name|stateStr|health" | grep -A 1 "$this_server_ip"
  else
    local check_cmd="rs.status()"
    local check_result=$(mongosh --port $port --eval "$check_cmd")
    echo "$check_result" | grep -E "name|stateStr|health" | grep -A 1 "$this_server_ip"
  fi
  
  echo -e "${GREEN}✓ Server đã tham gia thành công vào replica set hiện có!${NC}"
  return 0
}

# CHƯƠNG TRÌNH CHÍNH
main() {
  echo -e "${BLUE}THÔNG TIN CẤU HÌNH${NC}"
  
  # Lấy IP của server
  THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Địa chỉ IP của server: $THIS_SERVER_IP${NC}"
  
  read -p "Server này là primary? (y/n): " IS_PRIMARY
  
  # Nếu server này là secondary, hỏi có muốn cách đơn giản không
  if [[ "$IS_PRIMARY" =~ ^[Nn]$ ]]; then
    read -p "Sử dụng chức năng thêm secondary đơn giản? (y/n): " USE_SIMPLE_JOIN
  fi
  
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
  
  # Phân nhánh xử lý dựa vào loại server và chế độ join
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    # Thiết lập PRIMARY
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
    
    # Khởi tạo replica set
    init_replica_set_multi $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD
  else
    # Thiết lập SECONDARY
    if [[ "$USE_SIMPLE_JOIN" =~ ^[Yy]$ ]]; then
      # Sử dụng phương pháp join đơn giản
      join_existing_replica $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD
    else
      # Sử dụng phương pháp join truyền thống
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
      
      echo -e "${YELLOW}Server này sẽ được thêm vào replica set đã tồn tại.${NC}"
      read -p "Tiếp tục? (y/n): " CONTINUE
      
      if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
        add_to_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD
      fi
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