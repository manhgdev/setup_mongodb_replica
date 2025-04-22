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

# Tạo keyfile đơn giản
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

# Cấu hình MongoDB đơn giản hơn
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
  
  sudo tee $config_file > /dev/null << EOFn cho kết nối replica set
storage:ee $config_file > /dev/null << EOF
  dbPath: $dbpath
net:Path: $dbpath
  port: $port
  bindIp: 0.0.0.0
replication:0.0.0
  replSetName: $replica_set5536
systemLog:ue
  destination: filetrue
  path: $logpath
  logAppend: trueeplica_set
security::
  keyFile: $keyfile
  authorization: enabled
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOFurity:
  keyFile: $keyfile
  echo -e "${GREEN}✓ Đã tạo file cấu hình tại $config_file${NC}"
}rocessManagement:
  timeZoneInfo: /usr/share/zoneinfo
# Khởi động MongoDB
start_mongodb() {g:
  echo -e "${YELLOW}Khởi động MongoDB...${NC}"
  mode: off
  if systemctl is-active --quiet mongod; then
    sudo systemctl stop mongod
    sleep 2${GREEN}✓ Đã tạo file cấu hình tại $config_file${NC}"
  fi
  
  sudo systemctl daemon-reload
  sudo systemctl enable mongod
  sudo systemctl start mongod MongoDB...${NC}"
  
  # Kiểm tra log sau khi khởi động để phát hiện lỗi
  sleep 5systemctl stop mongod
  if sudo systemctl is-active mongod &> /dev/null; then
    echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
  else systemctl daemon-reload
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    sudo systemctl status mongod
    echo -e "${YELLOW}Kiểm tra log để tìm lỗi:${NC}"
    sudo tail -n 20 /var/log/mongodb/mongod.log lỗi
    return 1
  fi sudo systemctl is-active mongod &> /dev/null; then
}   echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    return 0
# Sửa lỗi "not reachable/healthy"
fix_unreachable_node() {ng thể khởi động MongoDB${NC}"
  local problem_node=$1iểm tra log để tìm nguyên nhân:${NC}"
  local port=$2n 30 /var/log/mongodb/mongod.log
  local primary_server=$3
  local username=$4
  local password=$5
  local this_server=$6
  Hàm chuyên biệt để khắc phục lỗi "not reachable/healthy"
  echo -e "${BLUE}=== SỬA LỖI NODE KHÔNG KHẢ DỤNG (not reachable/healthy) ===${NC}"
  local problem_node=$1
  # Kiểm tra xem node lỗi có phải là server hiện tại không
  if [[ "$problem_node" == "$this_server:$port" ]]; then
    echo -e "${YELLOW}Node gặp vấn đề là server hiện tại. Tiến hành sửa lỗi nội bộ...${NC}"
    cal password=$5
    # 1. Kiểm tra MongoDB có đang chạy không
    echo -e "${YELLOW}1. Kiểm tra trạng thái MongoDB...${NC}"
    if ! systemctl is-active --quiet mongod; theneachable/healthy)\" ===${NC}"
      echo -e "${RED}MongoDB không chạy. Khởi động lại...${NC}"
      sudo systemctl start mongod
      sleep 5blem_node" == "$this_server:$port" || "$problem_node" == *"$this_server"* ]]; then
    else -e "${YELLOW}Đang sửa lỗi tại node có vấn đề ($this_server)...${NC}"
      echo -e "${GREEN}✓ MongoDB đang chạy${NC}"
    fi1. Kiểm tra MongoDB có đang chạy
    echo -e "${YELLOW}1. Kiểm tra trạng thái MongoDB...${NC}"
    # 2. Kiểm tra log để tìm lỗiuiet mongod; then
    echo -e "${YELLOW}2. Kiểm tra log MongoDB...${NC}"...${NC}"
    sudo tail -n 30 /var/log/mongodb/mongod.log
      sleep 5
    # 3. Kiểm tra kết nối mạng
    echo -e "${YELLOW}3. Kiểm tra kết nối mạng...${NC}"
    echo -e "Kiểm tra kết nối đến primary server $primary_server:$port"
    if nc -z -w5 $primary_server $port; then
      echo -e "${GREEN}✓ Kết nối đến primary server thành công${NC}"
    else -e "${YELLOW}2. Kiểm tra keyfile...${NC}"
      echo -e "${RED}✗ Không thể kết nối đến primary server${NC}"
      echo -e "Kiểm tra cấu hình mạng và tường lửa..."eyfile từ primary node.${NC}"
    firead -p "Cung cấp nội dung keyfile từ primary (base64): " KEYFILE_CONTENT
      echo "$KEYFILE_CONTENT" | sudo tee $MONGODB_KEYFILE > /dev/null
    # 4. Kiểm tra cấu hìnhODB_KEYFILE
    echo -e "${YELLOW}4. Kiểm tra cấu hình MongoDB...${NC}"
    grep -A 20 "replication:" /etc/mongod.conf& getent passwd mongod > /dev/null; then
        mongo_user="mongod"
    # 5. Khởi động lại MongoDB để áp dụng cấu hình
    echo -e "${YELLOW}5. Khởi động lại MongoDB...${NC}"LE
    sudo systemctl restart mongodfile và đặt quyền thích hợp.${NC}"
    sleep 10
      echo -e "${GREEN}Keyfile đã tồn tại.${NC}"
  else
    echo -e "${YELLOW}Node gặp vấn đề là server khác ($problem_node). Tiến hành sửa lỗi từ xa...${NC}"
      local current_permissions=$(stat -c "%a" $MONGODB_KEYFILE)
    # Thử xóa và thêm lại node vào replica set; then
    echo -e "${YELLOW}1. Xóa node khỏi replica set...${NC}". Đang sửa...${NC}"
    remove_result=$(mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.remove('$problem_node'); print('REMOVED'); } catch(e) { print(e.message); }")
    echo "$remove_result"
      
    echo -e "${YELLOW}2. Đợi cập nhật cấu hình replica set...${NC}"
    sleep 5getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
        mongo_user="mongod"
    echo -e "${YELLOW}3. Thêm lại node vào replica set...${NC}"
    add_result=$(mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.add('$problem_node')")
    echo "$add_result"ner=$(stat -c "%U:%G" $MONGODB_KEYFILE)
  fi  if [[ "$current_owner" != "$mongo_user:$mongo_user" ]]; then
        echo -e "${YELLOW}Chủ sở hữu keyfile không đúng. Đang sửa...${NC}"
  # Kiểm tra lại trạng tháiser:$mongo_user $MONGODB_KEYFILE
  echo -e "${YELLOW}Kiểm tra lại trạng thái sau khi sửa...${NC}"
  sleep 10
  status_result=$(mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.status()")
  echo "$status_result" | grep -A 3 "$problem_node"
    echo -e "${YELLOW}3. Kiểm tra kết nối mạng đến primary ($primary_server)...${NC}"
  echo -e "${YELLOW}HƯỚNG DẪN KHẮC PHỤC (not reachable/healthy):${NC}"
  echo -e "1. Đảm bảo MongoDB đang chạy trên server $problem_node"tường lửa.${NC}"
  echo -e "2. Kiểm tra tường lửa cho phép kết nối port $port (sudo ufw status)"
  echo -e "3. Đảm bảo keyfile giống nhau trên tất cả các node"
  echo -e "4. Kiểm tra cấu hình bindIp trong file /etc/mongod.conf tại node $problem_node"
  echo -e "5. Xác minh DNS và hostname có thể phân giải giữa các server"
  echo -e "6. Sử dụng IP thay vì hostname nếu có vấn đề về DNS"
  echo -e "7. Kiểm tra SELinux nếu được bật (getenforce, setenforce 0)"tường lửa.${NC}"
}   else
      echo -e "${GREEN}Kết nối TCP đến primary:$port thành công.${NC}"
# Mở port firewall
configure_firewall() {
  local port=$1ra và cập nhật cấu hình MongoDB
  echo -e "${YELLOW}Cấu hình tường lửa...${NC}"oDB...${NC}"
    sudo grep "replSetName\|bindIp\|keyFile" /etc/mongod.conf
  if command -v ufw &> /dev/null; then
    sudo ufw allow $port/tcpDB với cấu hình mới
  fiecho -e "${YELLOW}5. Khởi động lại MongoDB...${NC}"
    sudo systemctl restart mongod
  if command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port=$port/tcp
    sudo firewall-cmd --reloadham gia lại replica set nếu cần thiết
  fiecho -e "${YELLOW}6. Tham gia lại replica set từ đầu? (y/n)${NC}"
    read -p "Điều này sẽ xóa dữ liệu và tham gia lại (y/n): " REJOIN
  echo -e "${GREEN}✓ Đã cấu hình tường lửa${NC}"
}   if [[ "$REJOIN" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Dọn dẹp và chuẩn bị cho việc tham gia lại...${NC}"
# Khởi tạo replica set (đơn giản hóa)
init_replica_set() {LOW}Xóa dữ liệu MongoDB cũ...${NC}"
  local port=$1rf $MONGODB_DATA_DIR/*
  local replica_set=$2}Đã xóa dữ liệu MongoDB.${NC}"
  local this_server_ip=$3
  local server_list=$4W}Khởi động lại MongoDB...${NC}"
  local username=$5l start mongod
  local password=$6
      
  echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
      echo -e "${YELLOW}Xóa server này khỏi replica set từ primary...${NC}"
  # Kiểm tra MongoDB đã sẵn sàngerver:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.remove('$this_server:$port'); } catch(e) { print('Error: ' + e.message); }"
  echo -e "${YELLOW}Đang đợi MongoDB khởi động...${NC}"
  for i in {1..15}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
      echo -e "${GREEN}✓ MongoDB đã sẵn sàng${NC}"
      break-e "${YELLOW}Thêm lại server vào replica set...${NC}"
    fimongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.add('$this_server:$port'); } catch(e) { print('Error: ' + e.message); }"
    echo "Thử lần ${i}/15..."
    sleep 2
    # Đang ở server khác, xử lý từ xa
    if [ $i -eq 15 ]; then sửa lỗi từ xa cho node $problem_node...${NC}"
      echo -e "${RED}MongoDB không sẵn sàng sau thời gian chờ${NC}"
      return 1tra trạng thái hiện tại
    fiho -e "${YELLOW}1. Kiểm tra trạng thái hiện tại...${NC}"
  donengosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.status()" | grep -A 3 "$problem_node"
    
  # Kiểm tra replica set đã được khởi tạo chưa
  rs_status=$(mongosh --quiet --port $port --eval "try { rs.status(); print('EXISTS'); } catch(e) { print('NOT_INIT'); }")
    mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.remove('$problem_node'); print('Đã xóa thành công'); } catch(e) { print('Lỗi: ' + e.message); }"
  if [[ "$rs_status" == *"NOT_INIT"* ]]; then
    # Xây dựng cấu hình replica set
    echo -e "${YELLOW}Khởi tạo replica set mới...${NC}"
    local rs_config="{ _id: '$replica_set', members: ["..${NC}"
    mongosh --host "$primary_server:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "try { rs.add('$problem_node'); print('Đã thêm thành công'); } catch(e) { print('Lỗi: ' + e.message); }"
    IFS=',' read -ra server_array <<< "$server_list"
    local member_id=0
    Kiểm tra kết quả sau khi sửa
    for server in "${server_array[@]}"; dohi sửa...${NC}"
      local priority=1
      # Server đầu tiên có priority cao hơn để được ưu tiên làm primary--authenticationDatabase admin --eval "rs.status()" | grep -A 3 "$problem_node"
      if [ $member_id -eq 0 ]; then
        priority=10== HƯỚNG DẪN BỔ SUNG ===${NC}"
      fie "${YELLOW}1. Đảm bảo đồng bộ keyfile giữa các server:${NC}"
       "   - Sao chép keyfile từ primary sang các secondary"
      if [ $member_id -gt 0 ]; then400 /etc/mongodb-keyfile"
        rs_config+=", "hủ sở hữu: chown mongodb:mongodb /etc/mongodb-keyfile"
      fie "${YELLOW}2. Kiểm tra DNS và hosts:${NC}"
       "   - Thêm các IP và hostname vào /etc/hosts nếu cần"
      rs_config+="{_id: $member_id, host: '$server:$port', priority: $priority}"
      ((member_id++))ce (nếu là Enforcing, thử setenforce 0)"
    donee "${YELLOW}4. Kiểm tra firewall:${NC}"
    ho "   - ufw status (đảm bảo port $port được cho phép)"
    rs_config+="] }"
    
    # Khởi tạo replica set
    init_result=$(mongosh --port $port --eval "rs.initiate($rs_config)")
    cal port=$1
    if [[ "$init_result" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* ]]; then
      echo -e "${GREEN}✓ Khởi tạo replica set thành công${NC}"
      sleep 10v ufw &> /dev/null; then
      do ufw allow $port/tcp
      # Tạo user admin
      echo -e "${YELLOW}Tạo user quản trị...${NC}"
      create_user_result=$(mongosh --port $port --eval "
      db = db.getSiblingDB('admin');add-port=$port/tcp
      db.createUser({ --reload
        user: '$username',
        pwd: '$password',
        roles: [ { role: 'root', db: 'admin' } ]
      });
      ")
       tạo replica set (đơn giản hóa)
      if [[ "$create_user_result" == *"Successfully added user"* ]]; then
        echo -e "${GREEN}✓ Tạo user thành công${NC}"
      elseplica_set=$2
        echo -e "${YELLOW}User có thể đã tồn tại hoặc có lỗi: $create_user_result${NC}"
      fiserver_list=$4
    elseusername=$5
      echo -e "${RED}✗ Khởi tạo replica set thất bại: $init_result${NC}"
      return 1
    fi -e "${YELLOW}Khởi tạo Replica Set...${NC}"
  else
    echo -e "${GREEN}✓ Replica set đã được khởi tạo trước đó${NC}"
  fiho -e "${YELLOW}Đang đợi MongoDB khởi động...${NC}"
} for i in {1..15}; do
    if mongosh --port $port --eval "db.stats()" &>/dev/null; then
# Kết nối vào replica set hiện cóđã sẵn sàng${NC}"
join_replica_set() {
  local port=$1
  local this_server_ip=$2..."
  local primary_server_ip=$3
  local username=$4
  local password=$5]; then
      echo -e "${RED}MongoDB không sẵn sàng sau thời gian chờ${NC}"
  echo -e "${YELLOW}Kết nối vào replica set hiện có...${NC}"
    fi
  # Kiểm tra kết nối tới primary
  echo -e "${YELLOW}Kiểm tra kết nối tới primary server...${NC}"
  if ! nc -z -w5 $primary_server_ip $port; then
    echo -e "${RED}Không thể kết nối tới primary server $primary_server_ip:$port${NC}" } catch(e) { print('NOT_INIT'); }")
    return 1
  fi [[ "$rs_status" == *"NOT_INIT"* ]]; then
    # Xây dựng cấu hình replica set
  # Thêm server vào replica setreplica set mới...${NC}"
  echo -e "${YELLOW}Thêm server này vào replica set...${NC}"
  add_result=$(mongosh --host "$primary_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.add('$this_server_ip:$port')")
    IFS=',' read -ra server_array <<< "$server_list"
  if [[ "$add_result" == *"\"ok\" : 1"* || "$add_result" == *"ok: 1"* || "$add_result" == *"already a member"* ]]; then
    echo -e "${GREEN}✓ Đã thêm server vào replica set thành công${NC}"
  elser server in "${server_array[@]}"; do
    echo -e "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
    return 1er đầu tiên có priority cao hơn để được ưu tiên làm primary
  fi  if [ $member_id -eq 0 ]; then
}       priority=10
      fi
# Tạo chuỗi kết nối
create_connection_string() {]; then
  local replica_set=$1"
  local server_list=$2
  local port=$3
  local username=$4_id: $member_id, host: '$server:$port', priority: $priority}"
  local password=$5))
    done
  local conn_servers=""
  IFS=',' read -ra server_array <<< "$server_list"
    
  for i in "${!server_array[@]}"; do
    server=${server_array[$i]}rt $port --eval "rs.initiate($rs_config)")
    if [[ $i -gt 0 ]]; then
      conn_servers+=","" == *"\"ok\" : 1"* || "$init_result" == *"ok: 1"* ]]; then
    fiecho -e "${GREEN}✓ Khởi tạo replica set thành công${NC}"
    conn_servers+="$server:$port"
  done
      # Tạo user admin
  conn_string="mongodb://$username:$password@$conn_servers/admin?replicaSet=$replica_set"
      create_user_result=$(mongosh --port $port --eval "
  echo -e "${BLUE}=== CHUỖI KẾT NỐI CHO ỨNG DỤNG ===${NC}"
  echo -e "${GREEN}$conn_string${NC}"
}       user: '$username',
        pwd: '$password',
# Kiểm tra trạng thái replica setdb: 'admin' } ]
check_replica_status() {
  local port=$1
  local username=$2
  local password=$3e_user_result" == *"Successfully added user"* ]]; then
        echo -e "${GREEN}✓ Tạo user thành công${NC}"
  echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
        echo -e "${YELLOW}User có thể đã tồn tại hoặc có lỗi: $create_user_result${NC}"
  status_result=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
  rs.status().members.forEach(function(member) {
    print(member.name + ' - ' + member.stateStr + (member.stateStr === 'PRIMARY' ? ' ✅' : ''));
  }); return 1
  ")fi
  else
  echo -e "${BLUE}=== TRẠNG THÁI REPLICA SET ===${NC}"ước đó${NC}"
  echo -e "${GREEN}$status_result${NC}"
}

# CHƯƠNG TRÌNH CHÍNHa set hiện có
main() {lica_set() {
  # Lấy IP của server
  THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
  echo -e "${YELLOW}Địa chỉ IP của server: $THIS_SERVER_IP${NC}"
  local username=$4
  read -p "Server này là primary? (y/n): " IS_PRIMARY
  
  # Xác định số lượng và danh sách serveret hiện có...${NC}"
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    read -p "Nhập số lượng server trong replica set [2-$MAX_SERVERS]: " SERVER_COUNT
    ho -e "${YELLOW}Kiểm tra kết nối tới primary server...${NC}"
    if ! [[ "$SERVER_COUNT" =~ ^[0-9]+$ ]] || [ "$SERVER_COUNT" -lt 1 ] || [ "$SERVER_COUNT" -gt $MAX_SERVERS ]; then
      SERVER_COUNT=1hông thể kết nối tới primary server $primary_server_ip:$port${NC}"
    fiturn 1
    
    # Khởi tạo danh sách server
    SERVER_LIST="$THIS_SERVER_IP"
    ho -e "${YELLOW}Thêm server này vào replica set...${NC}"
    if [ "$SERVER_COUNT" -gt 1 ]; theny_server_ip:$port" -u "$username" -p "$password" --authenticationDatabase admin --eval "rs.add('$this_server_ip:$port')")
      for ((i=1; i<SERVER_COUNT; i++)); do
        read -p "Nhập địa chỉ IP của server thứ $((i+1)): " OTHER_SERVER_IPadd_result" == *"already a member"* ]]; then
        if [ -n "$OTHER_SERVER_IP" ]; thenreplica set thành công${NC}"
          SERVER_LIST+=",$OTHER_SERVER_IP"
        fie "${RED}✗ Không thể thêm server vào replica set: $add_result${NC}"
      done 1
    fi
  else
    read -p "Địa chỉ IP của server primary: " PRIMARY_SERVER_IP
  fio chuỗi kết nối
  eate_connection_string() {
  read -p "Port MongoDB [$MONGO_PORT]: " USER_MONGO_PORT
  if [ -n "$USER_MONGO_PORT" ]; then
    MONGO_PORT=$USER_MONGO_PORT
  fical username=$4
  local password=$5
  read -p "Tên Replica Set [$REPLICA_SET_NAME]: " USER_REPLICA_SET
  if [ -n "$USER_REPLICA_SET" ]; then
    REPLICA_SET_NAME=$USER_REPLICA_SETserver_list"
  fi
  for i in "${!server_array[@]}"; do
  read -p "Tên người dùng MongoDB [$MONGODB_USER]: " USER_MONGODB_USER
  if [ -n "$USER_MONGODB_USER" ]; then
    MONGODB_USER=$USER_MONGODB_USER
  fifi
    conn_servers+="$server:$port"
  read -p "Mật khẩu MongoDB [$MONGODB_PASSWORD]: " USER_MONGODB_PASSWORD
  if [ -n "$USER_MONGODB_PASSWORD" ]; then
    MONGODB_PASSWORD=$USER_MONGODB_PASSWORDd@$conn_servers/admin?replicaSet=$replica_set"
  fi
  echo -e "${BLUE}=== CHUỖI KẾT NỐI CHO ỨNG DỤNG ===${NC}"
  # Đặt đường dẫnN}$conn_string${NC}"
  MONGODB_DATA_DIR="/var/lib/mongodb"
  MONGODB_LOG_DIR="/var/log/mongodb/mongod.log"
  MONGODB_CONFIG_FILE="/etc/mongod.conf"
  MONGODB_KEYFILE="/etc/mongodb-keyfile"
  local port=$1
  # Cài đặt MongoDB
  install_mongodb $MONGO_VERSION
  
  # Tạo keyfileLLOW}Kiểm tra trạng thái replica set...${NC}"
  create_keyfile $MONGODB_KEYFILE
  status_result=$(mongosh --port $port -u "$username" -p "$password" --authenticationDatabase admin --quiet --eval "
  # Tạo cấu hìnhmbers.forEach(function(member) {
  create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE
  });
  # Mở port firewall
  configure_firewall $MONGO_PORT
  echo -e "${BLUE}=== TRẠNG THÁI REPLICA SET ===${NC}"
  # Khởi động MongoDBtatus_result${NC}"
  start_mongodb
  
  # Thêm tùy chọn fix node lỗi
  read -p "Sửa lỗi node 'not reachable/healthy'? (y/n): " FIX_NODE
  if [[ "$FIX_NODE" =~ ^[Yy]$ ]]; then
    read -p "Nhập địa chỉ node có vấn đề (IP:port): " PROBLEM_NODE
    read -p "Nhập địa chỉ primary server: " PRIMARY_SERVER${NC}"
    
    # Sử dụng hàm chuyên biệt để sửa lỗi not reachable
    fix_unreachable_node "$PROBLEM_NODE" "$MONGO_PORT" "$PRIMARY_SERVER" "$MONGODB_USER" "$MONGODB_PASSWORD" "$THIS_SERVER_IP"
    exit 0Xác định số lượng và danh sách server
  fiif [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
  g server trong replica set [2-$MAX_SERVERS]: " SERVER_COUNT
  # Thiết lập replica set
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; thenthen
    init_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD
    # Kiểm tra và hiển thị trạng thái
    sleep 5
    check_replica_status $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
    create_connection_string $REPLICA_SET_NAME "$SERVER_LIST" $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORDRVER_LIST="$THIS_SERVER_IP"
  else
    join_replica_set $MONGO_PORT $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORDif [ "$SERVER_COUNT" -gt 1 ]; then
  fi    for ((i=1; i<SERVER_COUNT; i++)); do
  SERVER_IP
  echo -e "${GREEN}✅ Thiết lập MongoDB Replica Set hoàn tất!${NC}"
  echo -e "${YELLOW}Chú ý: MongoDB sẽ tự động bầu chọn primary mới nếu primary hiện tại gặp sự cố.${NC}"         SERVER_LIST+=",$OTHER_SERVER_IP"
}        fi

# Chạy chương trình chínhfi
main  else
ad -p "Địa chỉ IP của server primary: " PRIMARY_SERVER_IP

exit 0  fi
  
  read -p "Port MongoDB [$MONGO_PORT]: " USER_MONGO_PORT
  if [ -n "$USER_MONGO_PORT" ]; then
    MONGO_PORT=$USER_MONGO_PORT
  fi
  
  read -p "Tên Replica Set [$REPLICA_SET_NAME]: " USER_REPLICA_SET
  if [ -n "$USER_REPLICA_SET" ]; then
    REPLICA_SET_NAME=$USER_REPLICA_SET
  fi
  
  read -p "Tên người dùng MongoDB [$MONGODB_USER]: " USER_MONGODB_USER
  if [ -n "$USER_MONGODB_USER" ]; then
    MONGODB_USER=$USER_MONGODB_USER
  fi
  
  read -p "Mật khẩu MongoDB [$MONGODB_PASSWORD]: " USER_MONGODB_PASSWORD
  if [ -n "$USER_MONGODB_PASSWORD" ]; then
    MONGODB_PASSWORD=$USER_MONGODB_PASSWORD
  fi
  
  # Đặt đường dẫn
  MONGODB_DATA_DIR="/var/lib/mongodb"
  MONGODB_LOG_DIR="/var/log/mongodb/mongod.log"
  MONGODB_CONFIG_FILE="/etc/mongod.conf"
  MONGODB_KEYFILE="/etc/mongodb-keyfile"
  
  # Cài đặt MongoDB
  install_mongodb $MONGO_VERSION
  
  # Tạo keyfile
  create_keyfile $MONGODB_KEYFILE
  
  # Tạo cấu hình
  create_mongodb_config $MONGODB_CONFIG_FILE $MONGODB_DATA_DIR $MONGODB_LOG_DIR $MONGO_PORT $REPLICA_SET_NAME $MONGODB_KEYFILE
  
  # Mở port firewall
  configure_firewall $MONGO_PORT
  
  # Khởi động MongoDB
  start_mongodb
  
  # Thêm tùy chọn fix node lỗi
  read -p "Sửa lỗi node 'not reachable/healthy'? (y/n): " FIX_NODE
  if [[ "$FIX_NODE" =~ ^[Yy]$ ]]; then
    read -p "Nhập địa chỉ node có vấn đề (IP:port): " PROBLEM_NODE
    read -p "Nhập địa chỉ primary server: " PRIMARY_SERVER
    
    fix_not_reachable "$PROBLEM_NODE" "$MONGO_PORT" "$PRIMARY_SERVER" "$MONGODB_USER" "$MONGODB_PASSWORD" "$THIS_SERVER_IP"
    exit 0
  fi
  
  # Thiết lập replica set
  if [[ "$IS_PRIMARY" =~ ^[Yy]$ ]]; then
    init_replica_set $MONGO_PORT $REPLICA_SET_NAME $THIS_SERVER_IP "$SERVER_LIST" $MONGODB_USER $MONGODB_PASSWORD
    # Kiểm tra và hiển thị trạng thái
    sleep 5
    check_replica_status $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
    create_connection_string $REPLICA_SET_NAME "$SERVER_LIST" $MONGO_PORT $MONGODB_USER $MONGODB_PASSWORD
  else
    join_replica_set $MONGO_PORT $THIS_SERVER_IP $PRIMARY_SERVER_IP $MONGODB_USER $MONGODB_PASSWORD
  fi
  
  echo -e "${GREEN}✅ Thiết lập MongoDB Replica Set hoàn tất!${NC}"
  echo -e "${YELLOW}Chú ý: MongoDB sẽ tự động bầu chọn primary mới nếu primary hiện tại gặp sự cố.${NC}"
}

# Chạy chương trình chính
main

exit 0