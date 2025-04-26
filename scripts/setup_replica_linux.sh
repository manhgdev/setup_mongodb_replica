#!/bin/bash
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

# Biến cấu hình MongoDB
MONGO_PORT="27017"
BIND_IP="0.0.0.0"
REPLICA_SET_NAME="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MONGO_VERSION="8.0"
MAX_SERVERS=7

# Bảo đảm sử dụng cấu hình chung
ADMIN_USER=$MONGODB_USER
ADMIN_PASS=$MONGODB_PASSWORD

# Đường dẫn
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_CONFIG="/etc/mongod.conf"
MONGODB_DATA_DIR="/var/lib/mongodb"
MONGODB_LOG_PATH="/var/log/mongodb/mongod.log"

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Stop MongoDB services - cả mặc định và tùy chỉnh
    sudo systemctl stop mongod 2>/dev/null || true
    sudo systemctl stop mongod_${MONGO_PORT} 2>/dev/null || true
    sudo systemctl disable mongod 2>/dev/null || true
    
    # Kill any processes using MongoDB port
    echo "Killing processes on port ${MONGO_PORT}..."
    sudo lsof -ti:${MONGO_PORT} | xargs sudo kill -9 2>/dev/null || true
    sudo fuser -k ${MONGO_PORT}/tcp 2>/dev/null || true
    
    # Wait for port to be free
    sleep 3
    
    echo -e "${GREEN}✅ MongoDB process stopped successfully${NC}"
}

# Create directories
create_dirs() {
    echo -e "${YELLOW}Tạo thư mục dữ liệu và log MongoDB...${NC}"
    
    # Tạo thư mục dữ liệu và log
    sudo mkdir -p /var/lib/mongodb
    sudo mkdir -p /var/log/mongodb
    sudo mkdir -p /var/run/mongodb
    
    # Phân quyền
    sudo chown -R mongodb:mongodb /var/lib/mongodb
    sudo chown -R mongodb:mongodb /var/log/mongodb
    sudo chown -R mongodb:mongodb /var/run/mongodb
    
    # Cấp quyền thực thi
    sudo chmod 755 /var/lib/mongodb
    sudo chmod 755 /var/log/mongodb
    sudo chmod 755 /var/run/mongodb
    
    echo -e "${GREEN}✅ Đã tạo thư mục dữ liệu và log MongoDB${NC}"
}

# Create MongoDB config
create_config() {
    local ENABLE_SECURITY=$1
    local DISABLE_REPL=$2
    
    echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
    
    # Tạo thư mục cần thiết
    sudo mkdir -p $MONGODB_DATA_DIR
    sudo mkdir -p $(dirname $MONGODB_LOG_PATH)
    
    # Xác định user MongoDB
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
        mongo_user="mongod"
    fi
    
    # Phân quyền thư mục
    sudo chown -R $mongo_user:$mongo_user $MONGODB_DATA_DIR
    sudo chown -R $mongo_user:$mongo_user $(dirname $MONGODB_LOG_PATH)
    
    # Tạo nội dung cấu hình cơ bản
    local config_content="storage:
  dbPath: $MONGODB_DATA_DIR
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0
  maxIncomingConnections: 65536
systemLog:
  destination: file
  path: $MONGODB_LOG_PATH
  logAppend: true
processManagement:
  timeZoneInfo: /usr/share/zoneinfo"

    # Thêm cấu hình replication nếu không bị tắt
    if [[ -z "$DISABLE_REPL" ]]; then
        config_content="$config_content
replication:
  replSetName: $REPLICA_SET_NAME"
    fi
    
    # Thêm cấu hình bảo mật nếu được bật
    if [[ "$ENABLE_SECURITY" == "true" ]]; then
        config_content="$config_content
security:
  keyFile: $MONGODB_KEYFILE
  authorization: enabled"
    fi

    # Ghi vào file cấu hình
    echo "$config_content" | sudo tee $MONGODB_CONFIG > /dev/null
    echo -e "${GREEN}✅ Đã tạo file cấu hình MongoDB tại $MONGODB_CONFIG${NC}"
}

# Create keyfile
create_keyfile() {
  echo -e "${YELLOW}Bước 1: Tạo/sao chép keyfile xác thực...${NC}"
  local keyfile=${1:-"$MONGODB_KEYFILE"}
  local primary_ip=${2}
  
  # Kiểm tra nếu không có địa chỉ IP
  if [ -z "$primary_ip" ]; then
    echo -e "${YELLOW}❌ Không có địa chỉ PRIMARY IP. Vui lòng nhập:${NC}"
    read -p "Nhập IP của PRIMARY node: " primary_ip
    if [ -z "$primary_ip" ]; then
      echo -e "${RED}❌ Không có IP, không thể tiếp tục.${NC}"
      return 1
    fi
  fi
  
  # Kiểm tra nếu đang ở PRIMARY thì tạo keyfile mới
  if [ "$(hostname -I | awk '{print $1}')" = "$primary_ip" ]; then
    if [ ! -f "$keyfile" ]; then
      echo -e "${YELLOW}PRIMARY node: Đang tạo keyfile mới...${NC}"
      openssl rand -base64 756 | sudo tee $keyfile > /dev/null
      sudo chmod 400 $keyfile
      sudo chown mongodb:mongodb $keyfile
      echo -e "${GREEN}✅ Đã tạo keyfile mới tại $keyfile${NC}"
    else
      echo -e "${YELLOW}PRIMARY node: Keyfile đã tồn tại, đang thiết lập lại quyền...${NC}"
      sudo chown mongodb:mongodb $keyfile
      sudo chmod 400 $keyfile
      echo -e "${GREEN}✅ Keyfile đã tồn tại tại $keyfile${NC}"
    fi
  else
    # Nếu không phải PRIMARY thì copy keyfile từ PRIMARY
    echo -e "${YELLOW}SECONDARY node: Đang sao chép keyfile từ PRIMARY ($primary_ip)...${NC}"
    
    # Kiểm tra nếu keyfile tồn tại trên PRIMARY
    ssh -o StrictHostKeyChecking=accept-new root@$primary_ip "test -f $keyfile" 2>/dev/null
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Keyfile không tồn tại trên PRIMARY. Đang tạo keyfile mới trên PRIMARY...${NC}"
      
      # Tạo keyfile trên PRIMARY
      ssh -o StrictHostKeyChecking=accept-new root@$primary_ip "openssl rand -base64 756 | sudo tee $keyfile > /dev/null && sudo chmod 400 $keyfile && sudo chown mongodb:mongodb $keyfile" 2>/dev/null
      if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Không thể tạo keyfile trên PRIMARY. Đang tạo keyfile cục bộ...${NC}"
        # Tạo keyfile cục bộ
        openssl rand -base64 756 | sudo tee $keyfile > /dev/null
        sudo chmod 400 $keyfile
        sudo chown mongodb:mongodb $keyfile
        echo -e "${YELLOW}⚠️ Keyfile được tạo cục bộ. Cần sao chép thủ công sang PRIMARY${NC}"
        return 1
      fi
    fi
    
    # Xóa keyfile cũ nếu tồn tại
    if [ -f "$keyfile" ]; then
      echo -e "${YELLOW}Xóa keyfile cũ...${NC}"
      sudo rm -f $keyfile
    fi
    
    # Tiến hành sao chép keyfile
    echo -e "${YELLOW}Sao chép keyfile từ PRIMARY...${NC}"
    scp -o StrictHostKeyChecking=accept-new root@$primary_ip:$keyfile $keyfile 2>/dev/null
    if [ $? -ne 0 ]; then
      echo -e "${RED}❌ Không thể sao chép keyfile từ PRIMARY. Đang tạo keyfile cục bộ...${NC}"
      # Tạo keyfile cục bộ
      openssl rand -base64 756 | sudo tee $keyfile > /dev/null
      sudo chmod 400 $keyfile
      sudo chown mongodb:mongodb $keyfile
      echo -e "${YELLOW}⚠️ Đã tạo keyfile cục bộ. Cần sao chép thủ công sang PRIMARY${NC}"
      return 1
    else
      echo -e "${YELLOW}Bước 2: Thiết lập quyền cho keyfile...${NC}"
      sudo chmod 400 $keyfile
      sudo chown mongodb:mongodb $keyfile
      echo -e "${GREEN}✅ Đã sao chép và thiết lập quyền keyfile từ PRIMARY${NC}"
      ls -la $keyfile
    fi
  fi
  
  return 0
}

# Create admin user
create_admin_user() {
    local USERNAME=$1
    local PASSWORD=$2
    
    echo -e "${YELLOW}Tạo người dùng admin...${NC}"
    local result=$(mongosh --port $MONGO_PORT --eval "
    db.getSiblingDB('admin').createUser({
        user: '$USERNAME',
        pwd: '$PASSWORD',
        roles: [
            { role: 'root', db: 'admin' },
            { role: 'clusterAdmin', db: 'admin' }
        ]
    })")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Không thể tạo người dùng admin${NC}"
        echo "Lỗi: $result"
        return 1
    fi
    echo -e "${GREEN}✅ Đã tạo người dùng admin thành công${NC}"
}

# Create systemd service
create_systemd_service() {
    local WITH_SECURITY=$1
    local DISABLE_REPL=$2
    local SERVICE_NAME="mongod"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    
    echo -e "${YELLOW}Tạo dịch vụ systemd...${NC}"
    
    # Dừng dịch vụ MongoDB nếu đang chạy
    sudo systemctl stop mongod &>/dev/null || true
    
    # Unmask dịch vụ mongod nếu đang bị masked
    if sudo systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${YELLOW}Dịch vụ mongod đang bị masked, đang unmask...${NC}"
        sudo systemctl unmask mongod &>/dev/null
        sudo systemctl daemon-reload
    fi
    
    # Cập nhật cấu hình
    create_config $WITH_SECURITY $DISABLE_REPL
    
    # Tạo file dịch vụ
    sudo cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server
After=network.target
Documentation=https://docs.mongodb.org/manual

[Service]
User=mongodb
Group=mongodb
Type=simple
ExecStart=/usr/bin/mongod --config ${MONGODB_CONFIG}
ExecStop=/usr/bin/mongod --config ${MONGODB_CONFIG} --shutdown
Restart=on-failure
RestartSec=5
SyslogIdentifier=mongodb

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    
    echo -e "${GREEN}✅ Dịch vụ ${SERVICE_NAME} đã được tạo${NC}"
}

# Start MongoDB and check status
start_mongodb() {
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Dừng MongoDB nếu đang chạy
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${YELLOW}MongoDB đang chạy, đang dừng...${NC}"
        sudo systemctl stop mongod
        sleep 2
    fi
    
    # Xóa pid file cũ nếu tồn tại
    if [ -f "/var/run/mongodb/mongod.pid" ]; then
        echo -e "${YELLOW}Xóa pid file cũ...${NC}"
        sudo rm -f /var/run/mongodb/mongod.pid
    fi
    
    # Kiểm tra và tạo thư mục run nếu chưa tồn tại
    if [ ! -d "/var/run/mongodb" ]; then
        echo -e "${YELLOW}Tạo thư mục run...${NC}"
        sudo mkdir -p /var/run/mongodb
        sudo chown -R mongodb:mongodb /var/run/mongodb
        sudo chmod 755 /var/run/mongodb
    fi
    
    # Reload systemd và khởi động MongoDB
    echo -e "${YELLOW}Reload systemd và khởi động MongoDB...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl start mongod
    
    # Đợi và kiểm tra trạng thái
    echo -e "${YELLOW}Đợi MongoDB khởi động...${NC}"
    sleep 5
    
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${GREEN}✅ MongoDB đã khởi động thành công${NC}"
        sudo systemctl status mongod --no-pager
        return 0
    else
        echo -e "${RED}❌ Không thể khởi động MongoDB${NC}"
        echo -e "${YELLOW}Kiểm tra log để tìm lỗi:${NC}"
        sudo tail -n 30 /var/log/mongodb/mongod.log
        
        # Thử khởi động lại với tùy chọn --bind_ip_all
        echo -e "${YELLOW}Thử khởi động lại với tùy chọn --bind_ip_all...${NC}"
        sudo systemctl stop mongod
        sudo mongod --config /etc/mongod.conf --bind_ip_all &
        sleep 5
        
        if ps aux | grep -v grep | grep -q mongod; then
            echo -e "${GREEN}✅ MongoDB đã khởi động thành công với --bind_ip_all${NC}"
            return 0
        else
            echo -e "${RED}❌ Vẫn không thể khởi động MongoDB${NC}"
            return 1
        fi
    fi
}

# Configure firewall
configure_firewall() {
    echo -e "${YELLOW}Cấu hình tường lửa...${NC}"
    if command -v ufw &> /dev/null; then
        echo "UFW đã được cài đặt, cấu hình port ${MONGO_PORT}..."
        sudo ufw allow ${MONGO_PORT}/tcp
        echo -e "${GREEN}✅ Tường lửa đã được cấu hình${NC}"
    else
        echo "UFW chưa được cài đặt, bỏ qua cấu hình tường lửa"
    fi
}

# Verify MongoDB connection
verify_mongodb_connection() {
    local AUTH=$1
    local USERNAME=$2
    local PASSWORD=$3
    local HOST=${4:-"localhost"}
    
    echo -e "${YELLOW}Kiểm tra kết nối MongoDB...${NC}"
    
    local cmd="db.version()"
    local auth_params=""
    
    if [ "$AUTH" = "true" ]; then
        auth_params="--authenticationDatabase ${AUTH_DATABASE} -u $USERNAME -p $PASSWORD"
        cmd="rs.status()"
    fi
    
    # Thử kết nối với IP và localhost
    echo "Thử kết nối với $HOST:${MONGO_PORT}..."
    local result=$(mongosh --host $HOST --port ${MONGO_PORT} $auth_params --eval "$cmd" --quiet 2>&1)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Đã kết nối thành công tới MongoDB tại $HOST:${MONGO_PORT}${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Không thể kết nối tới MongoDB tại $HOST:${MONGO_PORT}${NC}"
        echo "Lỗi: $result"
        
        # Nếu thất bại với IP, thử với localhost
        if [ "$HOST" != "localhost" ] && [ "$HOST" != "127.0.0.1" ]; then
            echo "Thử kết nối với localhost:${MONGO_PORT}..."
            local result_local=$(mongosh --host localhost --port ${MONGO_PORT} $auth_params --eval "$cmd" --quiet 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Đã kết nối thành công tới MongoDB tại localhost:${MONGO_PORT}${NC}"
                echo -e "${YELLOW}⚠️ Chỉ có thể kết nối tới localhost, không phải IP. Đang tiếp tục với localhost.${NC}"
                HOST="localhost"
                return 0
            fi
        fi
    
        return 1
    fi
}

# Kiểm tra MongoDB đã được cài đặt chưa
check_mongodb() {
    echo -e "${YELLOW}Kiểm tra cài đặt MongoDB...${NC}"
    if command -v mongod &> /dev/null; then
        echo -e "${GREEN}✅ MongoDB đã được cài đặt${NC}"
        mongod --version
        return 0
    fi
    
    echo -e "${YELLOW}MongoDB chưa được cài đặt. Đang cài đặt MongoDB $MONGO_VERSION...${NC}"
    
    # Cài đặt MongoDB
    sudo apt-get update
    sudo apt-get install -y gnupg curl
    sudo rm -f /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg
    
    curl -fsSL https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc | \
    sudo gpg -o /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg --dearmor
    
    UBUNTU_VERSION=$(lsb_release -cs)
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $UBUNTU_VERSION/mongodb-org/$MONGO_VERSION multiverse" | \
    sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
    
    sudo apt-get update
    sudo apt-get install -y mongodb-org
    
    if command -v mongod &> /dev/null; then
        echo -e "${GREEN}✅ MongoDB đã được cài đặt thành công${NC}"
        return 0
    else
        echo -e "${RED}❌ Cài đặt MongoDB thất bại${NC}"
        exit 1
    fi
}

# Lấy IP của server
get_server_ip() {
    # Thử nhiều cách để lấy IP
    local CURRENT_IP=""
    
    # Phương pháp 1: hostname -I
    if [ -z "$CURRENT_IP" ]; then
        local IP_RESULT=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$IP_RESULT" ]; then
            CURRENT_IP=$IP_RESULT
        fi
    fi
    
    # Phương pháp 2: ip addr
    if [ -z "$CURRENT_IP" ]; then
        local IP_RESULT=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
        if [ -n "$IP_RESULT" ]; then
            CURRENT_IP=$IP_RESULT
        fi
    fi
    
    # Phương pháp 3: ifconfig
    if [ -z "$CURRENT_IP" ]; then
        local IP_RESULT=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
        if [ -n "$IP_RESULT" ]; then
            CURRENT_IP=$IP_RESULT
        fi
    fi
    
    # Nếu không tìm thấy IP, sử dụng localhost
    if [ -z "$CURRENT_IP" ]; then
        CURRENT_IP="127.0.0.1"
    fi
    
    echo "$CURRENT_IP"
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1

    echo -e "${GREEN}=== THIẾT LẬP MONGODB PRIMARY NODE ===${NC}"
    
    # Thu thập thông tin cần thiết
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(get_server_ip)
        echo "Detected server IP: $SERVER_IP"
        read -p "Sử dụng IP này? Nhập IP khác hoặc Enter để xác nhận: " INPUT_IP
        if [ ! -z "$INPUT_IP" ]; then
            SERVER_IP=$INPUT_IP
        fi
    fi
    
    # Thông tin đăng nhập cho admin
    echo "Nhập thông tin đăng nhập admin cho PRIMARY:"
    read -p "Tên người dùng [$MONGODB_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$MONGODB_USER}
    read -sp "Mật khẩu [$MONGODB_PASSWORD]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$MONGODB_PASSWORD}
    echo ""
    
    # Tạo keyfile
    echo -e "${YELLOW}Tạo keyfile xác thực cho PRIMARY node...${NC}"
    create_keyfile "$MONGODB_KEYFILE" $SERVER_IP
    
    # Xác nhận thông tin
    echo -e "${YELLOW}=== THÔNG TIN ĐÃ NHẬP ===${NC}"
    echo "Server IP: $SERVER_IP"
    echo "Admin User: $PRIMARY_USER"
    echo "Keyfile: $MONGODB_KEYFILE"
    echo "Config file: $MONGODB_CONFIG"
    echo "Replica Set: $REPLICA_SET_NAME"
    echo -e "${YELLOW}=========================${NC}"
    read -p "Xác nhận thông tin trên? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Hủy thiết lập.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Khởi tạo MongoDB PRIMARY trên port $MONGO_PORT...${NC}"

    # Dừng và xóa dữ liệu cũ
    stop_mongodb
    
    # Tạo thư mục dữ liệu và log
    create_dirs
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Kiểm tra kết nối mạng
    echo -e "${YELLOW}Kiểm tra kết nối mạng...${NC}"
    echo "Địa chỉ IP Server: $SERVER_IP"
    ping -c 1 -W 1 $SERVER_IP || echo "Không thể ping tới IP của server, nhưng tiếp tục thử"
    
    # Tạo cấu hình không có bảo mật và không có replSetName ban đầu
    create_config false "no_repl"
    
    # Tạo và khởi động dịch vụ
    create_systemd_service false "no_repl"
    if ! start_mongodb; then
        return 1
    fi
    
    # Kiểm tra kết nối - thử cả localhost và IP
    local CONNECT_HOST="localhost"
    if ! verify_mongodb_connection false "" "" "localhost"; then
        if ! verify_mongodb_connection false "" "" "127.0.0.1"; then
            if ! verify_mongodb_connection false "" "" $SERVER_IP; then
                echo -e "${RED}❌ Không thể kết nối tới MongoDB từ bất kỳ host nào${NC}"
                return 1
            else
                CONNECT_HOST=$SERVER_IP
            fi
        else
            CONNECT_HOST="127.0.0.1"
        fi
    fi
    
    # Dừng MongoDB
    echo -e "${YELLOW}Dừng MongoDB để thêm cấu hình replica set...${NC}"
    stop_mongodb
    
    # Tạo cấu hình với replication
    create_config false
    
    # Khởi động lại với cấu hình replica set
    create_systemd_service false
    if ! start_mongodb; then
        return 1
    fi
    
    # Kiểm tra lại kết nối
    if ! verify_mongodb_connection false "" "" $CONNECT_HOST; then
        echo -e "${YELLOW}Thử kết nối lại với các host khác...${NC}"
        if ! verify_mongodb_connection false "" "" "localhost"; then
            if ! verify_mongodb_connection false "" "" "127.0.0.1"; then
                if ! verify_mongodb_connection false "" "" $SERVER_IP; then
                    echo -e "${RED}❌ Không thể kết nối lại sau khi thêm cấu hình replication${NC}"
                    return 1
                else
                    CONNECT_HOST=$SERVER_IP
                fi
            else
                CONNECT_HOST="127.0.0.1"
            fi
        else
            CONNECT_HOST="localhost"
        fi
    fi
    
    # Khởi tạo replica set - sử dụng host đã kết nối thành công
    echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$MONGO_PORT${NC}"
    
    # Thử vài cách khởi tạo khác nhau
    local success=false
    
    # Cách 1: Khởi tạo với IP server trực tiếp
    echo "Phương pháp 1: Khởi tạo với IP server trực tiếp"
    local init_result=$(mongosh --host $CONNECT_HOST --port $MONGO_PORT --eval "
    rs.initiate({
        _id: '$REPLICA_SET_NAME',
        members: [
            { _id: 0, host: '$SERVER_IP:$MONGO_PORT', priority: 10 }
        ]
    })" --quiet)
    
    if echo "$init_result" | grep -q "ok" && ! echo "$init_result" | grep -q "NotYetInitialized"; then
        echo -e "${GREEN}✅ Khởi tạo replica set với IP server thành công${NC}"
        success=true
    else
        echo -e "${YELLOW}⚠️ Phương pháp 1 thất bại, đang thử phương pháp 2...${NC}"
        echo "Lỗi: $init_result"
        
        # Cách 2: Khởi tạo đơn giản với rs.initiate() và sau đó cập nhật cấu hình
        echo "Phương pháp 2: Khởi tạo đơn giản"
        local init_result2=$(mongosh --host $CONNECT_HOST --port $MONGO_PORT --eval "rs.initiate()" --quiet)
        
        if echo "$init_result2" | grep -q "ok" && ! echo "$init_result2" | grep -q "NotYetInitialized"; then
            echo -e "${GREEN}✅ Khởi tạo replica set thành công (phương pháp 2)${NC}"
            success=true
            
            # Chờ một chút cho MongoDB ổn định
            echo "Đợi 5 giây cho MongoDB ổn định..."
            sleep 5
            
            # Cập nhật cấu hình với IP thực tế
            echo "Cập nhật cấu hình với IP thực tế..."
            local update_result=$(mongosh --host $CONNECT_HOST --port $MONGO_PORT --eval "
            var config = rs.conf();
            config.members[0].host = '$SERVER_IP:$MONGO_PORT';
            rs.reconfig(config, {force: true});" --quiet)
            
            if echo "$update_result" | grep -q "ok"; then
                echo -e "${GREEN}✅ Cập nhật cấu hình với IP thực tế thành công${NC}"
            else
                echo -e "${YELLOW}⚠️ Không thể cập nhật cấu hình, replica set có thể không hoạt động đúng${NC}"
                echo "Lỗi: $update_result"
            fi
        else
            echo -e "${YELLOW}⚠️ Phương pháp 2 thất bại, đang thử phương pháp 3...${NC}"
            echo "Lỗi: $init_result2"
            
            # Cách 3: Force khởi tạo
            echo "Phương pháp 3: Khởi tạo với localhost và force, sau đó cập nhật IP"
            local init_result3=$(mongosh --host localhost --port $MONGO_PORT --eval "
            rs.initiate({
                _id: '$REPLICA_SET_NAME',
                members: [
                    { _id: 0, host: 'localhost:$MONGO_PORT', priority: 10 }
                ]
            }, {force: true})" --quiet)
            
            if echo "$init_result3" | grep -q "ok" && ! echo "$init_result3" | grep -q "NotYetInitialized"; then
                echo -e "${GREEN}✅ Khởi tạo replica set với localhost và force thành công${NC}"
                success=true
                
                # Chờ một chút cho MongoDB ổn định
                echo "Đợi 15 giây cho MongoDB ổn định..."
                sleep 15
                
                # Cập nhật cấu hình với IP thực tế
                echo "Cập nhật cấu hình với IP thực tế..."
                local update_result=$(mongosh --host localhost --port $MONGO_PORT --eval "
                var config = rs.conf();
                config.members[0].host = '$SERVER_IP:$MONGO_PORT';
                rs.reconfig(config, {force: true});" --quiet)
                
                if echo "$update_result" | grep -q "ok"; then
                    echo -e "${GREEN}✅ Cập nhật cấu hình với IP thực tế thành công${NC}"
                else
                    echo -e "${YELLOW}⚠️ Không thể cập nhật cấu hình, replica set có thể không hoạt động đúng${NC}"
                    echo "Lỗi: $update_result"
                fi
            else
                echo -e "${RED}❌ Tất cả các phương pháp khởi tạo đều thất bại${NC}"
                echo "Lỗi cuối cùng: $init_result3"
            fi
        fi
    fi
    
    if [ "$success" = "false" ]; then
        return 1
    fi
    
    echo -e "${YELLOW}Đợi MongoDB khởi tạo và bầu chọn PRIMARY...${NC}"
    sleep 15
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    local status=$(mongosh --host $CONNECT_HOST --port $MONGO_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "${GREEN}✅ Replica Set đã được khởi tạo thành công${NC}"
        echo "Config hiện tại:"
        mongosh --host $CONNECT_HOST --port $MONGO_PORT --eval "rs.conf()" --quiet
        
        # Tạo người dùng admin
        create_admin_user $PRIMARY_USER $PRIMARY_PASS || return 1
        
        # Bật bảo mật và khởi động lại
        echo -e "${YELLOW}Khởi động lại với bảo mật...${NC}"
        create_systemd_service true
        if ! start_mongodb; then
            return 1
        fi
        
        # Xác minh kết nối với xác thực
        echo -e "${YELLOW}Xác minh kết nối với xác thực...${NC}"
        if verify_mongodb_connection true $PRIMARY_USER $PRIMARY_PASS $CONNECT_HOST; then
            echo -e "\n${GREEN}=== THIẾT LẬP MONGODB PRIMARY HOÀN TẤT ===${NC}"
            echo -e "${GREEN}Lệnh kết nối:${NC}"
            echo "mongosh --host $SERVER_IP --port $MONGO_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE"
            echo ""
            echo -e "${YELLOW}Lưu ý:${NC} Nếu không thể kết nối qua IP, sử dụng lệnh:"
            echo "mongosh --host localhost --port $MONGO_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE"
            
            echo -e "\n${GREEN}=== THÔNG TIN REPLICA SET ===${NC}"
            local rs_info=$(mongosh --host $CONNECT_HOST --port $MONGO_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr + (m.stateStr === 'PRIMARY' ? ' ⭐' : '')); })" --quiet)
            echo -e "${GREEN}$rs_info${NC}"
        else
            return 1
        fi
    else
        echo -e "${RED}❌ Khởi tạo Replica Set thất bại - Node không được bầu làm PRIMARY${NC}"
        echo "Trạng thái hiện tại:"
        echo "$status"
        return 1
    fi
}

# Setup SECONDARY server
setup_secondary() {
    echo -e "${BLUE}=== THIẾT LẬP SECONDARY NODE CHO MONGODB REPLICA SET ===${NC}"
    
    # Kiểm tra đã cài đặt MongoDB chưa
    check_mongodb
    
    # 1. Thu thập thông tin về PRIMARY node
    echo -e "${YELLOW}1. Nhập thông tin PRIMARY node:${NC}"
    
    # Sử dụng PRIMARY_IP đã được nhập trước đó từ menu chính
    if [ -z "$PRIMARY_IP" ]; then
        read -p "IP của PRIMARY node: " PRIMARY_IP
    else
        echo -e "IP của PRIMARY node: ${GREEN}$PRIMARY_IP${NC}"
    fi
    
    read -p "Port của PRIMARY node [$MONGO_PORT]: " PRIMARY_PORT
    PRIMARY_PORT=${PRIMARY_PORT:-$MONGO_PORT}
    read -p "Username [$MONGODB_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$MONGODB_USER}
    read -p "Password [$MONGODB_PASSWORD]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$MONGODB_PASSWORD}
    read -p "Tên Replica Set [$REPLICA_SET_NAME]: " REPLICA_SET
    REPLICA_SET=${REPLICA_SET:-$REPLICA_SET_NAME}
    
    # 2. Lấy IP của server hiện tại
    echo -e "${YELLOW}2. Lấy thông tin server hiện tại...${NC}"
    SERVER_IP=$(get_server_ip)
    echo -e "Địa chỉ IP: ${GREEN}$SERVER_IP${NC}"
    
    # 3. Xác nhận với người dùng
    echo -e "${YELLOW}3. Xác nhận thông tin setup:${NC}"
    echo -e "- PRIMARY node: ${GREEN}$PRIMARY_IP:$PRIMARY_PORT${NC}"
    echo -e "- SECONDARY node: ${GREEN}$SERVER_IP:$MONGO_PORT${NC}"
    echo -e "- Replica Set: ${GREEN}$REPLICA_SET${NC}"
    echo -e "- Xác thực: ${GREEN}$PRIMARY_USER/$PRIMARY_PASS${NC}"
    read -p "Thông tin đã chính xác? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Hủy thiết lập.${NC}"
        return 1
    fi
    
    # 4. Chuẩn bị thư mục dữ liệu và log
    echo -e "${YELLOW}4. Chuẩn bị thư mục dữ liệu và log...${NC}"
    sudo mkdir -p $MONGODB_DATA_DIR
    sudo mkdir -p $(dirname $MONGODB_LOG_PATH)
    sudo chown -R mongodb:mongodb $MONGODB_DATA_DIR
    sudo chown -R mongodb:mongodb $(dirname $MONGODB_LOG_PATH)
    
    # 5. Kiểm tra kết nối với PRIMARY
    echo -e "${YELLOW}5. Kiểm tra kết nối với PRIMARY...${NC}"
    if ! ping -c 1 $PRIMARY_IP &>/dev/null; then
        echo -e "${RED}❌ Không thể ping tới PRIMARY${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Ping tới PRIMARY thành công${NC}"
    
    if ! nc -z -w5 $PRIMARY_IP $PRIMARY_PORT &>/dev/null; then
        echo -e "${RED}❌ Không thể kết nối tới $PRIMARY_IP:$PRIMARY_PORT${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Kết nối tới $PRIMARY_IP:$PRIMARY_PORT thành công${NC}"
    
    # 6. Lấy keyfile từ PRIMARY
    echo -e "${YELLOW}6. Lấy keyfile từ PRIMARY...${NC}"
    # Lấy keyfile từ PRIMARY nếu có thể, nếu không thì tự tạo
    create_keyfile "$MONGODB_KEYFILE" "$PRIMARY_IP"
    
    # 7. Cấu hình MongoDB
    echo -e "${YELLOW}7. Tạo cấu hình MongoDB...${NC}"
    sudo bash -c "cat > $MONGODB_CONFIG << EOF
storage:
  dbPath: $MONGODB_DATA_DIR
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0
  maxIncomingConnections: 65536
replication:
  replSetName: $REPLICA_SET
systemLog:
  destination: file
  path: $MONGODB_LOG_PATH
  logAppend: true
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
security:
  keyFile: $MONGODB_KEYFILE
  authorization: enabled
EOF"
    
    # 8. Mở port firewall
    echo -e "${YELLOW}8. Mở port firewall...${NC}"
    if command -v ufw &>/dev/null; then
        sudo ufw allow $MONGO_PORT/tcp
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --add-port=$MONGO_PORT/tcp
        sudo firewall-cmd --reload
    fi
    echo -e "${GREEN}✅ Đã mở port $MONGO_PORT${NC}"
    
    # 9. Dừng MongoDB nếu đang chạy
    echo -e "${YELLOW}9. Dừng MongoDB nếu đang chạy...${NC}"
    sudo systemctl stop mongod &>/dev/null
    
    # 10. Xóa dữ liệu cũ (nếu cần)
    echo -e "${YELLOW}10. Xóa dữ liệu cũ (nếu có)...${NC}"
    sudo rm -rf $MONGODB_DATA_DIR/*
    
    # 11. Đảm bảo keyfile có quyền đúng
    echo -e "${YELLOW}10. Đảm bảo keyfile có quyền đúng...${NC}"
    sudo chmod 400 $MONGODB_KEYFILE
    sudo chown mongodb:mongodb $MONGODB_KEYFILE
    ls -la $MONGODB_KEYFILE
    
    # 12. Khởi động MongoDB với cấu hình replica set
    echo -e "${YELLOW}11. Khởi động MongoDB với cấu hình replica set...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl start mongod
    
    # Đợi MongoDB khởi động
    echo -e "Đợi MongoDB khởi động..."
    sleep 10
    
    if ! sudo systemctl is-active --quiet mongod; then
        echo -e "${RED}❌ MongoDB không thể khởi động với cấu hình replica set. Kiểm tra lỗi:${NC}"
        sudo systemctl status mongod --no-pager
        sudo tail -n 30 $MONGODB_LOG_PATH
        
        # Thử khởi động lại với tùy chọn --bind_ip_all
        echo -e "${YELLOW}Thử khởi động MongoDB với tùy chọn --bind_ip_all...${NC}"
        sudo systemctl stop mongod
        sudo systemctl start mongod
        sleep 5
        
        if ! sudo systemctl is-active --quiet mongod; then
            echo -e "${RED}❌ MongoDB vẫn không thể khởi động. Kiểm tra lại cấu hình.${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✅ MongoDB với cấu hình replica set đã khởi động thành công${NC}"
    fi
    
    # 13. Kiểm tra kết nối MongoDB tại local
    echo -e "${YELLOW}12. Kiểm tra kết nối MongoDB tại local...${NC}"
    attempts=0
    while [ $attempts -lt 5 ]; do
        if mongosh --eval "db.version()" &>/dev/null; then
            echo -e "${GREEN}✅ Kết nối tới MongoDB local thành công${NC}"
            break
        fi
        
        echo -e "${YELLOW}Đang đợi MongoDB khởi động (${attempts}/5)...${NC}"
        sleep 2
        attempts=$((attempts+1))
        
        if [ $attempts -eq 5 ]; then
            echo -e "${RED}❌ Không thể kết nối tới MongoDB local sau nhiều lần thử${NC}"
            return 1
        fi
    done
    
    # 14. Kiểm tra kết nối với PRIMARY
    echo -e "${YELLOW}13. Kiểm tra kết nối với PRIMARY...${NC}"
    if ! ping -c 1 $PRIMARY_IP &>/dev/null; then
        echo -e "${RED}❌ Không thể ping tới PRIMARY${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Ping tới PRIMARY thành công${NC}"
    
    if ! nc -z -w5 $PRIMARY_IP $PRIMARY_PORT &>/dev/null; then
        echo -e "${RED}❌ Không thể kết nối tới $PRIMARY_IP:$PRIMARY_PORT${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Kết nối tới $PRIMARY_IP:$PRIMARY_PORT thành công${NC}"
    
    # 15. Kiểm tra PRIMARY có đang hoạt động không
    echo -e "${YELLOW}14. Kiểm tra PRIMARY có đang hoạt động không...${NC}"
    local rs_status=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "rs.status()" --quiet 2>&1)
    
    if echo "$rs_status" | grep -q "MongoNetworkError\|failed\|error"; then
        echo -e "${RED}❌ Không thể kết nối tới PRIMARY. Lỗi:${NC}"
        echo "$rs_status"
        return 1
    fi
    
    echo -e "${GREEN}✅ Kết nối tới PRIMARY thành công${NC}"
    
    # Kiểm tra trạng thái của PRIMARY
    local primary_found=false
    
    # Tìm PRIMARY node trong output rs.status()
    if echo "$rs_status" | grep -q "\"stateStr\" : \"PRIMARY\""; then
        echo -e "${GREEN}✅ Node $PRIMARY_IP đã là PRIMARY node${NC}"
        primary_found=true
    else
        # Kiểm tra bằng isMaster
        local is_master=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "db.isMaster()" --quiet)
        if echo "$is_master" | grep -q "\"ismaster\" : true\|\"isWritablePrimary\" : true"; then
            echo -e "${GREEN}✅ Node $PRIMARY_IP đã là PRIMARY node${NC}"
            primary_found=true
        fi
    fi
    
    if [ "$primary_found" = false ]; then
        echo -e "${RED}❌ Node $PRIMARY_IP không phải là PRIMARY!${NC}"
        echo -e "${YELLOW}Vui lòng chạy tùy chọn 'Thiết lập PRIMARY Node' trên node $PRIMARY_IP trước.${NC}"
        return 1
    fi
    
    # 16. Kiểm tra node có đã trong replica set không
    echo -e "${YELLOW}15. Kiểm tra node trong replica set...${NC}"
    if echo "$rs_status" | grep -q "$SERVER_IP:$MONGO_PORT"; then
        echo -e "${YELLOW}Node đã tồn tại trong replica set, xóa và thêm lại...${NC}"
        local remove_result=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "
            rs.remove('$SERVER_IP:$MONGO_PORT');
        " --quiet)
        sleep 5
    fi
    
    # 17. Thêm node vào replica set
    echo -e "${YELLOW}16. Thêm node vào replica set...${NC}"
    local add_result=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "
        rs.add('$SERVER_IP:$MONGO_PORT');
    " --quiet)
    
    if echo "$add_result" | grep -q "\"ok\" : 1\|ok: 1"; then
        echo -e "${GREEN}✅ Đã thêm node vào replica set thành công${NC}"
    else
        echo -e "${RED}❌ Không thể thêm node vào replica set:${NC}"
        echo "$add_result"
        return 1
    fi
    
    # 18. Kiểm tra trạng thái cuối cùng
    echo -e "${YELLOW}17. Kiểm tra trạng thái cuối cùng...${NC}"
    sleep 10 # Đợi đồng bộ
    
    local final_status=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase $AUTH_DATABASE --eval "
        var status = rs.status();
        print('=== TRẠNG THÁI REPLICA SET ===');
        status.members.forEach(function(member) {
            print(member.name + ' - ' + member.stateStr + ' (health: ' + member.health + ')' + (member.stateStr === 'PRIMARY' ? ' ⭐' : member.stateStr === 'SECONDARY' ? ' ⚡' : ''));
        });
    " --quiet)
    
    echo -e "${GREEN}$final_status${NC}"
    echo -e "${GREEN}✅ Thiết lập SECONDARY node hoàn tất!${NC}"
    echo -e "${YELLOW}Lưu ý: Có thể mất một vài phút để SECONDARY đồng bộ hoàn toàn với PRIMARY.${NC}"
    
    # Đợi người dùng xác nhận
    read -p "Nhấn Enter để tiếp tục..."
    return 0
}

# Main function for replica set setup
setup_replica_linux() {
    local option
    local SERVER_IP=$(get_server_ip)
    local PRIMARY_IP=""
    
    while true; do
        echo -e "${GREEN}=================================================${NC}"
        echo -e "${GREEN}=== THIẾT LẬP MONGODB REPLICA SET - LINUX ===${NC}"
        echo -e "${GREEN}=================================================${NC}"
        echo -e "Server IP hiện tại: ${YELLOW}$SERVER_IP${NC}"
        echo -e "MongoDB version: ${YELLOW}$MONGO_VERSION${NC}"
        echo -e "Port: ${YELLOW}$MONGO_PORT${NC}"
        echo -e "Replica Set: ${YELLOW}$REPLICA_SET_NAME${NC}"
        echo -e "User/Pass: ${YELLOW}$MONGODB_USER/$MONGODB_PASSWORD${NC}"
        echo
        echo "1. Thiết lập PRIMARY Node"
        echo "2. Thiết lập SECONDARY Node"
        echo "0. Quay lại menu chính"
        
        read -p "Chọn tùy chọn (0-2): " option
        
        case $option in
            1)
                setup_primary "$SERVER_IP"
                ;;
            2)
                if [ -z "$PRIMARY_IP" ]; then
                    read -p "Nhập địa chỉ IP của PRIMARY: " PRIMARY_IP
                fi
                setup_secondary
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ!${NC}"
                ;;
        esac
        
        read -p "Nhấn Enter để tiếp tục..."
    done
}