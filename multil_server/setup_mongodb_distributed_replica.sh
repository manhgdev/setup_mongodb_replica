#!/bin/bash

#============================================================
# THIẾT LẬP MONGODB REPLICA SET PHÂN TÁN GIỮA NHIỀU VPS
# Script này thiết lập một MongoDB Replica Set hoạt động 
# trên nhiều server vật lý khác nhau, đảm bảo sẵn sàng cao
# và tự động chuyển đổi khi một server gặp sự cố
#============================================================

# Thiết lập màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Biến cấu hình mặc định
MONGO_PORT="27017"
REPLICA_SET_NAME="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MONGO_VERSION="8.0"
MAX_SERVERS=7 # Giới hạn tối đa số lượng server trong replica set

# Hiển thị banner
echo -e "${BLUE}
============================================================
  THIẾT LẬP MONGODB REPLICA SET PHÂN TÁN GIỮA NHIỀU VPS
============================================================${NC}"

# Kiểm tra và cài đặt MongoDB
install_mongodb() {
  local version=$1
  echo -e "${YELLOW}Kiểm tra cài đặt MongoDB...${NC}"
  
  if command -v mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã được cài đặt${NC}"
    mongod --version
  else
    echo -e "${YELLOW}MongoDB chưa được cài đặt. Đang cài đặt MongoDB $version...${NC}"
    
    # Cài đặt các công cụ cần thiết
    sudo apt-get update
    sudo apt-get install -y gnupg curl netcat-openbsd
    
    # Xóa key cũ nếu có
    sudo rm -f /usr/share/keyrings/mongodb-server-$version.gpg
    
    # Thêm repo MongoDB
    curl -fsSL https://www.mongodb.org/static/pgp/server-$version.asc | \
      sudo gpg -o /usr/share/keyrings/mongodb-server-$version.gpg \
      --dearmor
    
    # Xác định phiên bản Ubuntu
    UBUNTU_VERSION=$(lsb_release -cs)
    echo -e "${YELLOW}Phiên bản Ubuntu: $UBUNTU_VERSION${NC}"
    
    # Sử dụng jammy cho Ubuntu 22.04, focal cho 20.04
    if [ "$UBUNTU_VERSION" = "jammy" ] || [ "$UBUNTU_VERSION" = "focal" ]; then
      # Tạo file list cho apt
      echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$version.gpg ] https://repo.mongodb.org/apt/ubuntu $UBUNTU_VERSION/mongodb-org/$version multiverse" | \
        sudo tee /etc/apt/sources.list.d/mongodb-org-$version.list
    else
      # Fallback sang jammy nếu không phải Ubuntu 22.04 hoặc 20.04
      echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$version.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/$version multiverse" | \
        sudo tee /etc/apt/sources.list.d/mongodb-org-$version.list
    fi
    
    # Cài đặt MongoDB
    sudo apt-get update
    sudo apt-get install -y mongodb-org
    
    # Kiểm tra lại cài đặt
    if command -v mongod &> /dev/null; then
      echo -e "${GREEN}✓ MongoDB đã được cài đặt thành công${NC}"
      mongod --version
    else
      echo -e "${RED}✗ Cài đặt MongoDB thất bại${NC}"
      exit 1
    fi
  fi
}

# Tạo keyfile để xác thực giữa các thành viên replica set
create_keyfile() {
  local keyfile_path=$1
  echo -e "${YELLOW}Tạo keyfile xác thực...${NC}"
  
  if [ ! -f "$keyfile_path" ]; then
    # Tạo keyfile mới với nội dung ngẫu nhiên
    openssl rand -base64 756 | sudo tee $keyfile_path > /dev/null
    sudo chmod 400 $keyfile_path
    
    # Kiểm tra và tạo user mongodb nếu không tồn tại
    if ! getent passwd mongodb > /dev/null; then
      echo -e "${YELLOW}User mongodb không tồn tại. Sử dụng user mongod...${NC}"
      if getent passwd mongod > /dev/null; then
        sudo chown mongod:mongod $keyfile_path
      else
        echo -e "${YELLOW}User mongod cũng không tồn tại. Tạo user mongodb...${NC}"
        sudo useradd -r -s /bin/false mongodb
        sudo chown mongodb:mongodb $keyfile_path
      fi
    else
      sudo chown mongodb:mongodb $keyfile_path
    fi
    
    echo -e "${GREEN}✓ Đã tạo keyfile tại $keyfile_path${NC}"
  else
    echo -e "${GREEN}✓ Keyfile đã tồn tại tại $keyfile_path${NC}"
  fi
}

# Tạo file cấu hình MongoDB
create_mongodb_config() {
  local config_file=$1
  local dbpath=$2
  local logpath=$3
  local port=$4
  local replica_set=$5
  local keyfile=$6
  local bind_ip=$7
  
  echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
  
  sudo mkdir -p $dbpath
  sudo mkdir -p $(dirname $logpath)
  
  # Xác định user mongodb hoặc mongod
  local mongo_user="mongodb"
  if ! getent passwd mongodb > /dev/null; then
    if getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
  fi
  
  sudo chown -R $mongo_user:$mongo_user $dbpath
  sudo chown -R $mongo_user:$mongo_user $(dirname $logpath)
  
  # Sao lưu file cấu hình cũ nếu tồn tại
  if [ -f "$config_file" ]; then
    backup_file="${config_file}.$(date +%Y%m%d%H%M%S).bak"
    sudo cp $config_file $backup_file
    echo -e "${YELLOW}Đã sao lưu file cấu hình cũ tại $backup_file${NC}"
  fi
  
  # Tạo file cấu hình
  sudo tee $config_file > /dev/null << EOF
# MongoDB configuration file
storage:
  dbPath: $dbpath
  journal:
    enabled: true

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
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo
EOF

  echo -e "${GREEN}✓ Đã tạo file cấu hình tại $config_file${NC}"
}

# Đảm bảo quyền truy cập đúng cho các thư mục cấu hình
ensure_directory_permissions() {
  echo -e "${YELLOW}Đảm bảo quyền truy cập cho các thư mục MongoDB...${NC}"
  
  # Xác định user mongodb hoặc mongod
  local mongo_user="mongodb"
  if ! getent passwd mongodb > /dev/null; then
    if getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
  fi
  
  # Thư mục dữ liệu
  sudo mkdir -p $MONGODB_DATA_DIR
  sudo chown -R $mongo_user:$mongo_user $MONGODB_DATA_DIR
  sudo chmod -R 750 $MONGODB_DATA_DIR
  
  # Thư mục log
  sudo mkdir -p $(dirname $MONGODB_LOG_DIR)
  sudo chown -R $mongo_user:$mongo_user $(dirname $MONGODB_LOG_DIR)
  sudo chmod -R 755 $(dirname $MONGODB_LOG_DIR)
  
  # Thư mục pid
  sudo mkdir -p /var/run/mongodb
  sudo chown -R $mongo_user:$mongo_user /var/run/mongodb
  
  # KeyFile
  sudo chown $mongo_user:$mongo_user $MONGODB_KEYFILE
  sudo chmod 400 $MONGODB_KEYFILE
  
  # Config file
  sudo chown $mongo_user:$mongo_user $MONGODB_CONFIG_FILE
  
  echo -e "${GREEN}✓ Đã thiết lập quyền truy cập chính xác${NC}"
}

# Khởi động MongoDB
start_mongodb() {
  echo -e "${YELLOW}Khởi động MongoDB...${NC}"
  
  # Dừng MongoDB hiện tại nếu đang chạy
  if systemctl is-active --quiet mongod; then
    echo -e "${YELLOW}Dừng MongoDB hiện tại...${NC}"
    sudo systemctl stop mongod
    sleep 3
  fi
  
  # Tạo service file nếu cần
  sudo bash -c 'cat > /lib/systemd/system/mongod.service << EOF
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
EOF'
  
  # Đặt quyền service file
  sudo chmod 644 /lib/systemd/system/mongod.service
  
  # Xác định user mongodb hoặc mongod trong service file
  if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
    sudo sed -i 's/User=mongodb/User=mongod/g' /lib/systemd/system/mongod.service
    sudo sed -i 's/Group=mongodb/Group=mongod/g' /lib/systemd/system/mongod.service
  fi
  
  # Reload systemd để áp dụng thay đổi
  sudo systemctl daemon-reload
  
  # Khởi động MongoDB với cấu hình mới
  sudo systemctl enable mongod
  sudo systemctl start mongod
  
  # Kiểm tra trạng thái
  sleep 5
  if sudo systemctl is-active mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
  else
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    sudo systemctl status mongod
    
    # Kiểm tra thêm xem có lỗi gì không
    echo -e "${YELLOW}Kiểm tra log MongoDB...${NC}"
    sudo tail -n 20 $MONGODB_LOG_DIR/mongod.log
    
    echo -e "${YELLOW}Thử dùng mongod trực tiếp để xem lỗi...${NC}"
    sudo mongod --config $MONGODB_CONFIG_FILE --fork
    
    echo -e "${RED}Nếu vẫn không khởi động được, hãy thử:${NC}"
    echo "1. Kiểm tra quyền: ls -la $MONGODB_DATA_DIR"
    echo "2. Kiểm tra disk space: df -h"
    echo "3. Kiểm tra log: sudo tail -f $MONGODB_LOG_DIR/mongod.log"
    
    return 1
  fi
}

# Khởi tạo replica set trên server đầu tiên với nhiều server
init_replica_set_multi() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local server_list=$4 # Danh sách các server, phân tách bằng dấu phẩy
  local username=$5
  local password=$6
  
  echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
  echo -e "${YELLOW}Server này: $this_server_ip${NC}"
  echo -e "${YELLOW}Danh sách server: $server_list${NC}"
  
  # Kiểm tra đảm bảo IP server không bị lỗi
  if [[ -z "$this_server_ip" || "$this_server_ip" == "địa" ]]; then
    echo -e "${RED}Lỗi: Địa chỉ IP server không hợp lệ ($this_server_ip)${NC}"
    this_server_ip=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Sử dụng IP local: $this_server_ip${NC}"
  fi
  
  # Đảm bảo MongoDB đang chạy
  if ! systemctl is-active --quiet mongod; then
    echo -e "${YELLOW}MongoDB không chạy. Đang khởi động lại...${NC}"
    sudo systemctl start mongod
    sleep 5
  fi
  
  # Kiểm tra MongoDB đã sẵn sàng chưa
  echo -e "${YELLOW}Kiểm tra MongoDB đã sẵn sàng chưa...${NC}"
  # Đợi tối đa 60 giây cho MongoDB sẵn sàng
  mongo_ready=false
  for i in {1..30}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
      mongo_ready=true
      break
    fi
    echo -e "${YELLOW}Đang đợi MongoDB khởi động (${i}/30)...${NC}"
    sleep 2
  done
  
  if [ "$mongo_ready" = false ]; then
    echo -e "${RED}MongoDB không sẵn sàng sau thời gian chờ. Kiểm tra lại cài đặt.${NC}"
    sudo systemctl status mongod
    return 1
  fi
  
  # Biến kiểm tra khởi tạo thành công
  local init_success=false
  
  # Kiểm tra xem replica set đã được khởi tạo chưa
  rs_status=$(mongosh --quiet --port $port --eval "try { rs.status(); print('EXISTS'); } catch(e) { print('NOT_INIT'); }")
  
  if [[ "$rs_status" == *"NOT_INIT"* ]]; then
    echo "Khởi tạo replica set mới với server: $this_server_ip"
    
    # Sửa đổi - Sử dụng cách khởi tạo đơn giản nhất trước
    echo "Sử dụng phương pháp khởi tạo đơn giản..."
    init_command="rs.initiate({_id: '$replica_set', members: [{_id: 0, host: '$this_server_ip:$port', priority: 10}]});"
    echo "Thực thi lệnh: $init_command"
    
    init_result=$(mongosh --port $port --eval "$init_command")
    
    # Thay đổi: kiểm tra cả hai định dạng ok: 1 (không có dấu ngoặc kép) và "ok" : 1 (có dấu ngoặc kép)
    if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* ]]; then
      echo -e "${GREEN}✓ Khởi tạo replica set thành công${NC}"
      init_success=true
    else
      echo -e "${RED}✗ Khởi tạo replica set thất bại: $init_result${NC}"
      
      # Kiểm tra xem có phải đã khởi tạo trước đó không
      if [[ "$init_result" == *"already initialized"* ]]; then
        echo -e "${GREEN}✓ Replica set đã được khởi tạo trước đó${NC}"
        init_success=true
      else
        # Thử lại lần 2 với localhost
        echo -e "${YELLOW}Thử lại với localhost...${NC}"
        retry_command="rs.initiate({_id: '$replica_set', members: [{_id: 0, host: 'localhost:$port', priority: 10}]});"
        echo "Thực thi lệnh: $retry_command"
        
        init_result=$(mongosh --port $port --eval "$retry_command")
        
        if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* || "$init_result" == *"already initialized"* ]]; then
          echo -e "${GREEN}✓ Khởi tạo replica set thành công với localhost${NC}"
          init_success=true
          
          # Cập nhật lại cấu hình với IP thật
          echo -e "${YELLOW}Cập nhật lại cấu hình replica set với IP thật...${NC}"
          update_cmd="cfg = rs.conf(); cfg.members[0].host='$this_server_ip:$port'; rs.reconfig(cfg);"
          update_result=$(mongosh --port $port --eval "$update_cmd")
          echo "Kết quả cập nhật: $update_result"
        else
          echo -e "${RED}✗ Khởi tạo replica set thất bại: $init_result${NC}"
          
          # Thử lại lần 3 với 127.0.0.1
          echo -e "${YELLOW}Thử lại với 127.0.0.1...${NC}"
          retry_command="rs.initiate({_id: '$replica_set', members: [{_id: 0, host: '127.0.0.1:$port', priority: 10}]});"
          echo "Thực thi lệnh: $retry_command"
          
          init_result=$(mongosh --port $port --eval "$retry_command")
          
          if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* || "$init_result" == *"already initialized"* ]]; then
            echo -e "${GREEN}✓ Khởi tạo replica set thành công với 127.0.0.1${NC}"
            init_success=true
            
            # Cập nhật lại cấu hình với IP thật
            echo -e "${YELLOW}Cập nhật lại cấu hình replica set với IP thật...${NC}"
            update_cmd="cfg = rs.conf(); cfg.members[0].host='$this_server_ip:$port'; rs.reconfig(cfg);"
            update_result=$(mongosh --port $port --eval "$update_cmd")
            echo "Kết quả cập nhật: $update_result"
          else
            echo -e "${RED}✗ Khởi tạo tất cả các phương pháp đều thất bại${NC}"
            return 1
          fi
        fi
      fi
    fi
    
    # Nếu khởi tạo thành công, tiếp tục các bước còn lại
    if [ "$init_success" = true ]; then
      # Đợi replica set khởi tạo
      echo "Đợi replica set khởi tạo..."
      sleep 15
      
      # Tạo user admin
      echo "Tạo user quản trị..."
      create_user_result=$(mongosh --port $port --eval "
      db = db.getSiblingDB('admin');
      try {
        db.createUser({
          user: '$username',
          pwd: '$password',
          roles: [ { role: 'root', db: 'admin' } ]
        });
        print('✓ Tạo user thành công');
      } catch(e) {
        if(e.codeName === 'DuplicateKey') {
          print('✓ User đã tồn tại');
        } else {
          print('⚠ Lỗi: ' + e.message);
        }
      }
      ")
      
      echo "$create_user_result"
      
      # Nếu đã khởi tạo replica set thành công với 1 node, thêm các node còn lại vào
      if [ "$server_list" != "$this_server_ip" ]; then
        echo -e "${YELLOW}Thêm các server khác vào replica set...${NC}"
        
        # Phân tách chuỗi server_list thành mảng
        IFS=',' read -ra server_array <<< "$server_list"
        
        for server in "${server_array[@]}"; do
          # Bỏ qua server hiện tại và các alias của nó
          if [[ "$server" != "$this_server_ip" && "$server" != "localhost" && "$server" != "127.0.0.1" ]]; then
            echo -e "${YELLOW}Thêm server: $server${NC}"
            
            # Kiểm tra kết nối đến server
            if nc -z -w5 $server $port; then
              echo -e "${GREEN}Server $server:$port đang lắng nghe${NC}"
            else
              echo -e "${RED}Không thể kết nối đến $server:$port. Đảm bảo MongoDB đang chạy và port đã mở.${NC}"
              continue
            fi
            
            # Thêm server vào replica set
            add_cmd="rs.add('$server:$port')"
            add_result=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase "admin" --eval "$add_cmd")
            
            if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
              echo -e "${GREEN}✓ Đã thêm server $server vào replica set${NC}"
            else
              echo -e "${RED}✗ Không thể thêm server $server: $add_result${NC}"
            fi
          fi
        done
      fi
    fi
  else
    echo -e "${GREEN}✓ Replica set đã được khởi tạo trước đó${NC}"
    
    # Kiểm tra user admin đã tồn tại chưa
    admin_exists=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase "admin" --eval "db.version()" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}User admin chưa tồn tại hoặc mật khẩu không đúng. Đang tạo...${NC}"
      create_user_result=$(mongosh --port $port --eval "
      db = db.getSiblingDB('admin');
      try {
        db.createUser({
          user: '$username',
          pwd: '$password',
          roles: [ { role: 'root', db: 'admin' } ]
        });
        print('✓ Tạo user thành công');
      } catch(e) {
        print('⚠ Lỗi: ' + e.message);
      }
      ")
      echo "$create_user_result"
    else
      echo -e "${GREEN}✓ User admin đã tồn tại${NC}"
    fi
  fi
}

# Kết nối server thứ hai vào replica set (nếu chưa)
add_to_replica_set() {
  local port=$1
  local replica_set=$2
  local this_server_ip=$3
  local primary_server_ip=$4
  local username=$5
  local password=$6
  
  echo -e "${YELLOW}Kiểm tra và kết nối với replica set...${NC}"
  
  # Kiểm tra xem server này đã trong replica set chưa
  rs_status=$(mongosh --port $port --quiet --eval "rs.status().members.map(m => m.name)")
  
  if [[ "$rs_status" == *"$this_server_ip:$port"* ]]; then
    echo -e "${GREEN}✓ Server này đã là thành viên của replica set${NC}"
    return 0
  fi
  
  # Kết nối đến primary để thêm server này
  echo "Kết nối đến primary server để thêm server này..."
  
  # Thêm server này vào replica set
  add_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "
  rs.add('$this_server_ip:$port')
  ")
  
  if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* ]]; then
    echo -e "${GREEN}✓ Đã thêm server này vào replica set${NC}"
  else
    echo -e "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
    return 1
  fi
}

# Kiểm tra trạng thái replica set
check_replica_status() {
  local port=$1
  local username=$2
  local password=$3
  
  echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
  
  # Kiểm tra xem cần xác thực hay không
  local auth_status=$(mongosh --port $port --quiet --eval "db.serverCmdLineOpts().parsed.security && db.serverCmdLineOpts().parsed.security.authorization" 2>/dev/null)
  
  if [[ "$auth_status" == "enabled" && -n "$username" && -n "$password" ]]; then
    # Sử dụng xác thực
    rs_status=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.status(); } catch(e) { print('Lỗi: ' + e.message); }")
  else
    # Không sử dụng xác thực
    rs_status=$(mongosh --port $port --eval "try { rs.status(); } catch(e) { print('Lỗi: ' + e.message); }")
  fi
  
  echo -e "${BLUE}=== Trạng thái Replica Set ===${NC}"
  echo "$rs_status" | grep -E "name|stateStr|health|state"
  
  # Kiểm tra primary
  if [[ "$auth_status" == "enabled" && -n "$username" && -n "$password" ]]; then
    primary_info=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
    try {
      primary = rs.isMaster().primary;
      if (primary) { print('Primary: ' + primary); } else { print('No primary found'); }
    } catch(e) {
      print('Lỗi: ' + e.message);
    }
    ")
  else
    primary_info=$(mongosh --port $port --quiet --eval "
    try {
      primary = rs.isMaster().primary;
      if (primary) { print('Primary: ' + primary); } else { print('No primary found'); }
    } catch(e) {
      print('Lỗi: ' + e.message);
    }
    ")
  fi
  
  echo -e "${BLUE}$primary_info${NC}"
}

# Tạo chuỗi kết nối MongoDB cho ứng dụng với nhiều server
create_connection_string_multi() {
  local replica_set=$1
  local server_list=$2 # Danh sách các server, phân tách bằng dấu phẩy
  local port=$3
  local username=$4
  local password=$5
  
  # Tạo chuỗi kết nối với tất cả các server
  local conn_servers=""
  local server_array=()
  
  # Phân tách chuỗi server_list thành mảng
  IFS=',' read -ra server_array <<< "$server_list"
  
  # Lặp qua từng server để thêm vào chuỗi kết nối
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
  echo -e "${YELLOW}Sử dụng chuỗi kết nối này trong ứng dụng của bạn để tự động chuyển đổi khi một server gặp sự cố${NC}"
}

# Lấy địa chỉ IP public
get_public_ip() {
  echo -e "${YELLOW}Lấy địa chỉ IP public...${NC}"
  
  # Thử nhiều cách để lấy IP
  local public_ip=""
  
  # Cách 1: Lấy từ dịch vụ bên ngoài
  public_ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || curl -s ipecho.net/plain 2>/dev/null)
  
  # Cách 2: Nếu cách 1 thất bại, thử lấy IP local
  if [ -z "$public_ip" ]; then
    public_ip=$(hostname -I | awk '{print $1}')
  fi
  
  # Cách 3: Nếu cả hai cách trên đều thất bại, yêu cầu nhập thủ công
  if [ -z "$public_ip" ]; then
    echo -e "${RED}Không thể xác định địa chỉ IP.${NC}"
    read -p "Nhập địa chỉ IP của server này: " public_ip
    
    if [ -z "$public_ip" ]; then
      echo -e "${RED}Không có địa chỉ IP, không thể tiếp tục.${NC}"
      exit 1
    fi
  fi
  
  echo -e "${GREEN}Địa chỉ IP: $public_ip${NC}"
  echo "$public_ip"
}

# Mở port firewall
configure_firewall() {
  local port=$1
  
  echo -e "${YELLOW}Cấu hình tường lửa...${NC}"
  
  # Kiểm tra nếu ufw được cài đặt
  if command -v ufw &> /dev/null; then
    echo "Mở port MongoDB ($port) trên UFW..."
    sudo ufw allow $port/tcp
    sudo ufw status | grep $port
  fi
  
  # Kiểm tra nếu firewalld được cài đặt
  if command -v firewall-cmd &> /dev/null; then
    echo "Mở port MongoDB ($port) trên FirewallD..."
    sudo firewall-cmd --permanent --add-port=$port/tcp
    sudo firewall-cmd --reload
    sudo firewall-cmd --list-ports | grep $port
  fi
  
  echo -e "${GREEN}✓ Đã cấu hình tường lửa${NC}"
}

# CHƯƠNG TRÌNH CHÍNH
main() {
  # 1. Xác định thông tin cấu hình
  echo -e "${BLUE}THÔNG TIN CẤU HÌNH${NC}"
  
  # Lấy IP public của server hiện tại
  THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Địa chỉ IP của server này (local): $THIS_SERVER_IP${NC}"
  
  # Thử lấy IP public (nhưng ưu tiên IP local để đảm bảo kết nối được)
  PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || curl -s ipecho.net/plain 2>/dev/null)
  if [ -n "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}Địa chỉ IP public: $PUBLIC_IP${NC}"
    read -p "Sử dụng IP public thay vì IP local? (y/n) [n]: " USE_PUBLIC_IP
    if [[ "$USE_PUBLIC_IP" =~ ^[Yy]$ ]]; then
      THIS_SERVER_IP="$PUBLIC_IP"
      echo -e "${GREEN}Sử dụng IP public: $THIS_SERVER_IP${NC}"
    else
      echo -e "${GREEN}Sử dụng IP local: $THIS_SERVER_IP${NC}" 
    fi
  fi
  
  read -p "Server này là primary? (y/n): " IS_PRIMARY
  
  # Xác định số lượng server trong replica set
  echo -e "${YELLOW}Số lượng server tối đa trong MongoDB Replica Set là $MAX_SERVERS${NC}"
  read -p "Nhập số lượng server trong replica set [2-$MAX_SERVERS]: " SERVER_COUNT
  
  # Validate số lượng server
  if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -lt 2 ] || [ "$SERVER_COUNT" -gt $MAX_SERVERS ]; then
    echo -e "${RED}Số lượng server không hợp lệ. Sử dụng giá trị mặc định: 2${NC}"
    SERVER_COUNT=2
  fi
  
  # Khởi tạo danh sách server
  SERVER_LIST="$THIS_SERVER_IP"
  
  # Nếu số lượng server > 1, yêu cầu nhập các server còn lại
  if [ "$SERVER_COUNT" -gt 1 ]; then
    if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
      # Nhập IP của các server khác
      for ((i=1; i<SERVER_COUNT; i++)); do
        read -p "Nhập địa chỉ IP của server thứ $((i+1)): " OTHER_SERVER_IP
        if [ -n "$OTHER_SERVER_IP" ]; then
          SERVER_LIST+=",$OTHER_SERVER_IP"
        fi
      done
    else
      # Nếu là secondary, chỉ cần nhập IP của server primary
      read -p "Địa chỉ IP của server primary: " PRIMARY_SERVER_IP
      
      # Lấy danh sách server từ primary
      echo -e "${YELLOW}Kết nối với primary server ($PRIMARY_SERVER_IP) để lấy thông tin replica set...${NC}"
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
  
  # Nếu người dùng không chọn port, luôn mặc định là 27017
  if [ -z "$USER_MONGO_PORT" ]; then
    MONGO_PORT="27017"
    echo -e "${YELLOW}Sử dụng port mặc định 27017 để đảm bảo luôn là PRIMARY${NC}"
  fi
  
  # 2. Cài đặt MongoDB nếu chưa có
  install_mongodb $MONGO_VERSION
  
  # 3. Tạo keyfile để xác thực giữa các server
  create_keyfile $MONGODB_KEYFILE
  
  # 4. Tạo file cấu hình MongoDB
  create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE "0.0.0.0"
  
  # 4.5 Đảm bảo quyền truy cập đúng
  ensure_directory_permissions
  
  # 5. Cấu hình tường lửa
  configure_firewall $MONGO_PORT
  
  # 6. Khởi động MongoDB
  if ! start_mongodb; then
    echo -e "${RED}MongoDB không khởi động được. Đang kiểm tra các lỗi phổ biến...${NC}"
    
    # Kiểm tra SELinux
    if command -v getenforce &> /dev/null && [ "$(getenforce)" = "Enforcing" ]; then
      echo -e "${YELLOW}SELinux đang bật. Tạm thời tắt để kiểm tra...${NC}"
      sudo setenforce 0
      if start_mongodb; then
        echo -e "${GREEN}MongoDB đã khởi động thành công sau khi tắt SELinux${NC}"
        echo -e "${YELLOW}Đang cấu hình SELinux cho MongoDB...${NC}"
        sudo setsebool -P mongod_bind_all_unreserved_ports 1
      else
        echo -e "${RED}Tắt SELinux không giải quyết được vấn đề${NC}"
      fi
    fi
    
    # Kiểm tra xem port đã được sử dụng chưa
    if netstat -tuln | grep ":$MONGO_PORT " > /dev/null; then
      echo -e "${RED}Port $MONGO_PORT đã được sử dụng bởi tiến trình khác${NC}"
      netstat -tuln | grep ":$MONGO_PORT "
      read -p "Bạn có muốn thử port khác không? (y/n): " TRY_OTHER_PORT
      if [[ "$TRY_OTHER_PORT" =~ ^[Yy]$ ]]; then
        read -p "Nhập port mới: " NEW_PORT
        MONGO_PORT=$NEW_PORT
        create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE "0.0.0.0"
        ensure_directory_permissions
        configure_firewall $MONGO_PORT
        start_mongodb
      fi
    fi
  fi
  
  # 7. Thiết lập replica set
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    # Nếu là primary server, khởi tạo replica set mới với nhiều server
    init_replica_set_multi $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD
  else
    # Nếu là secondary server, thêm vào replica set đã tồn tại
    echo -e "${YELLOW}Server này sẽ được thêm vào replica set đã tồn tại.${NC}"
    echo -e "${YELLOW}Đảm bảo rằng server primary đã được thiết lập và đang hoạt động.${NC}"
    read -p "Tiếp tục? (y/n): " CONTINUE
    
    if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
      add_to_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD
    else
      echo -e "${YELLOW}Bỏ qua thiết lập kết nối với replica set.${NC}"
    fi
  fi
  
  # 8. Kiểm tra trạng thái replica set
  sleep 5 # Đợi replica set ổn định
  check_replica_status $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
  
  # 9. Tạo chuỗi kết nối MongoDB cho ứng dụng với nhiều server
  create_connection_string_multi $REPLICA_SET_NAME "$SERVER_LIST" $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
  
  # 10. Hướng dẫn tiếp theo
  echo -e "${BLUE}
============================================================
  HƯỚNG DẪN TIẾP THEO
============================================================${NC}"
  
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}✅ Server primary đã được thiết lập thành công!${NC}"
    echo -e "${YELLOW}Tiếp theo, hãy thiết lập các server secondary:${NC}"
    echo "1. Sao chép script này sang các server còn lại"
    echo "2. Chạy script và chọn 'n' khi được hỏi 'Server này là primary?'"
    echo "3. Cung cấp địa chỉ IP của server này ($THIS_SERVER_IP) khi được hỏi về server primary"
  else
    echo -e "${GREEN}✅ Server secondary đã được kết nối thành công!${NC}"
    echo -e "${YELLOW}Toàn bộ replica set đã được thiết lập và đang hoạt động.${NC}"
  fi
  
  echo -e "${BLUE}
============================================================
  KIỂM TRA SỰ CỐ
============================================================${NC}"
  
  echo "Để kiểm tra khả năng chịu lỗi, bạn có thể thử dừng MongoDB trên một server:"
  echo "  sudo systemctl stop mongod"
  echo
  echo "Sau đó kiểm tra trạng thái replica set trên server còn lại:"
  echo "  mongosh --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval \"rs.status()\""
  echo
  echo "Ứng dụng của bạn sẽ tự động chuyển đổi kết nối sang server còn hoạt động nếu sử dụng chuỗi kết nối được cung cấp ở trên."
}

# Chạy chương trình chính
main

exit 0 