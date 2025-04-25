#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'

# Default admin credentials
ADMIN_USER="manhg"
ADMIN_PASS="manhnk"

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Stop MongoDB services - cả mặc định và tùy chỉnh
    sudo systemctl stop mongod 2>/dev/null || true
    sudo systemctl stop mongod_27017 2>/dev/null || true
    sudo systemctl disable mongod 2>/dev/null || true
    
    # Kill any processes using MongoDB port
    echo "Killing processes on port 27017..."
    sudo lsof -ti:27017 | xargs sudo kill -9 2>/dev/null || true
    sudo fuser -k 27017/tcp 2>/dev/null || true
    
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
    
    # Tạo file cấu hình MongoDB
    sudo tee /etc/mongod.conf > /dev/null <<EOF
# mongod.conf

# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb

# how the process runs
processManagement:
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo

# network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

EOF

    # Thêm cấu hình replication nếu không bị tắt
    if [[ -z "$DISABLE_REPL" ]]; then
        sudo tee -a /etc/mongod.conf > /dev/null <<EOF
# replication
replication:
  replSetName: rs0
  
EOF
    fi
    
    # Thêm cấu hình bảo mật nếu được bật
    if [[ "$ENABLE_SECURITY" == "true" ]]; then
        sudo tee -a /etc/mongod.conf > /dev/null <<EOF
# security
security:
  authorization: enabled
  keyFile: /etc/mongodb.keyfile
  
EOF
    fi
    
    echo -e "${GREEN}✅ Đã tạo file cấu hình MongoDB tại /etc/mongod.conf${NC}"
}

# Create keyfile
create_keyfile() {
  echo -e "${YELLOW}Bước 1: Tạo/sao chép keyfile xác thực...${NC}"
  local keyfile=${1:-"/etc/mongodb.keyfile"}
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

# Apply keyfile to MongoDB
apply_keyfile() {
    local KEYFILE_PATH=$1
    local PRIMARY_IP=$2
    
    echo -e "${YELLOW}Áp dụng keyfile và bảo mật...${NC}"
    
    # Dừng MongoDB
    sudo systemctl stop mongod
    
    # Kiểm tra và sửa quyền keyfile
    if [ -f "$KEYFILE_PATH" ]; then
        sudo chmod 400 $KEYFILE_PATH
        sudo chown mongodb:mongodb $KEYFILE_PATH
    else
        echo -e "${RED}❌ Không tìm thấy keyfile tại $KEYFILE_PATH${NC}"
        return 1
    fi
    
    # Cập nhật cấu hình với bảo mật
    create_config true
    
    # Khởi động lại với bảo mật
    if ! start_mongodb; then
        echo -e "${RED}❌ Không thể khởi động MongoDB với bảo mật${NC}"
        return 1
    fi
    
    # Xác minh kết nối với localhost
    if verify_mongodb_connection true $SEC_USER $SEC_PASS "localhost"; then
        echo -e "${GREEN}✅ MongoDB đã khởi động với bảo mật thành công${NC}"
        return 0
    else
        echo -e "${RED}❌ Không thể kết nối đến MongoDB với bảo mật${NC}"
        return 1
    fi
}

# Create admin user
create_admin_user() {
    local PORT=27017
    local USERNAME=$1
    local PASSWORD=$2
    
    echo -e "${YELLOW}Tạo người dùng admin...${NC}"
    local result=$(mongosh --port $PORT --eval "
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
    local PORT=27017
    local WITH_SECURITY=$1
    local SERVICE_NAME="mongod_${PORT}"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    echo -e "${YELLOW}Tạo dịch vụ systemd...${NC}"
    
    # Dừng dịch vụ MongoDB mặc định
    sudo systemctl stop mongod &>/dev/null || true
    sudo systemctl disable mongod &>/dev/null || true
    
    # Unmask dịch vụ mongod nếu đang bị masked
    if sudo systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${YELLOW}Dịch vụ mongod đang bị masked, đang unmask...${NC}"
        sudo systemctl unmask mongod &>/dev/null
        sudo systemctl daemon-reload
    fi
    
    # Xóa file dịch vụ mặc định nếu có xung đột
    if [ -f "/etc/systemd/system/mongod.service" ]; then
        echo "Xóa file dịch vụ mongod.service mặc định để tránh xung đột"
        sudo rm -f /etc/systemd/system/mongod.service
    fi
    
    # Cập nhật cấu hình với tham số security nếu cần
    create_config $WITH_SECURITY $2
    
    # Tạo file dịch vụ
    sudo cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server (Port ${PORT})
After=network.target
Documentation=https://docs.mongodb.org/manual

[Service]
User=mongodb
Group=mongodb
Type=simple
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown
Restart=on-failure
RestartSec=5
SyslogIdentifier=mongodb-${PORT}

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    
    # Unmask dịch vụ mới nếu đang bị masked
    if sudo systemctl is-enabled $SERVICE_NAME 2>&1 | grep -q "masked"; then
        echo -e "${YELLOW}Dịch vụ ${SERVICE_NAME} đang bị masked, đang unmask...${NC}"
        sudo systemctl unmask $SERVICE_NAME &>/dev/null
        sudo systemctl daemon-reload
    fi
    
    sudo systemctl enable $SERVICE_NAME
    
    echo -e "${GREEN}✅ Dịch vụ ${SERVICE_NAME} đã được tạo${NC}"
}

# Start MongoDB and check status
start_mongodb() {
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Kiểm tra và tạo thư mục log nếu không tồn tại
    if [ ! -d "/var/log/mongodb" ]; then
        echo -e "${YELLOW}Thư mục log không tồn tại, đang tạo...${NC}"
        sudo mkdir -p /var/log/mongodb
        sudo chown -R mongodb:mongodb /var/log/mongodb
        sudo chmod 755 /var/log/mongodb
    fi
    
    # Tạo file log nếu không tồn tại
    if [ ! -f "/var/log/mongodb/mongod.log" ]; then
        echo -e "${YELLOW}File log không tồn tại, đang tạo...${NC}"
        sudo touch /var/log/mongodb/mongod.log
        sudo chown mongodb:mongodb /var/log/mongodb/mongod.log
    fi
    
    # Unmask dịch vụ nếu đang bị masked
    if systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${YELLOW}Dịch vụ MongoDB đang bị masked, đang unmask...${NC}"
        sudo systemctl unmask mongod
        sudo systemctl daemon-reload
    fi
    
    # Khởi động MongoDB
    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl restart mongod
    sleep 5
    
    # Kiểm tra trạng thái MongoDB
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${GREEN}✅ MongoDB đã khởi động thành công${NC}"
        sudo systemctl status mongod --no-pager
        return 0
    else
        echo -e "${RED}❌ MongoDB không thể khởi động${NC}"
        sudo systemctl status mongod --no-pager
        echo -e "${YELLOW}Kiểm tra log tại /var/log/mongodb/mongod.log${NC}"
        sudo tail -n 20 /var/log/mongodb/mongod.log || echo -e "${RED}❌ Không thể đọc file log${NC}"
        return 1
    fi
}

# Configure firewall
configure_firewall() {
    echo -e "${YELLOW}Cấu hình tường lửa...${NC}"
    if command -v ufw &> /dev/null; then
        echo "UFW đã được cài đặt, cấu hình port 27017..."
        sudo ufw allow 27017/tcp
        echo -e "${GREEN}✅ Tường lửa đã được cấu hình${NC}"
    else
        echo "UFW chưa được cài đặt, bỏ qua cấu hình tường lửa"
    fi
}

# Verify MongoDB connection
verify_mongodb_connection() {
    local PORT=27017
    local AUTH=$1
    local USERNAME=$2
    local PASSWORD=$3
    local HOST=${4:-"localhost"}
    
    echo -e "${YELLOW}Kiểm tra kết nối MongoDB...${NC}"
    
    local cmd="db.version()"
    local auth_params=""
    
    if [ "$AUTH" = "true" ]; then
        auth_params="--authenticationDatabase admin -u $USERNAME -p $PASSWORD"
        cmd="rs.status()"
    fi
    
    # Thử kết nối với IP và localhost
    echo "Thử kết nối với $HOST:$PORT..."
    local result=$(mongosh --host $HOST --port $PORT $auth_params --eval "$cmd" --quiet 2>&1)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Đã kết nối thành công tới MongoDB tại $HOST:$PORT${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️ Không thể kết nối tới MongoDB tại $HOST:$PORT${NC}"
        echo "Lỗi: $result"
        
        # Nếu thất bại với IP, thử với localhost
        if [ "$HOST" != "localhost" ] && [ "$HOST" != "127.0.0.1" ]; then
            echo "Thử kết nối với localhost:$PORT..."
            local result_local=$(mongosh --host localhost --port $PORT $auth_params --eval "$cmd" --quiet 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Đã kết nối thành công tới MongoDB tại localhost:$PORT${NC}"
                echo -e "${YELLOW}⚠️ Chỉ có thể kết nối tới localhost, không phải IP. Đang tiếp tục với localhost.${NC}"
                HOST="localhost"
                return 0
            fi
        fi
        
        return 1
    fi
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017

    echo -e "${GREEN}=== THIẾT LẬP MONGODB PRIMARY NODE ===${NC}"
    
    # Thu thập tất cả thông tin cần thiết từ đầu
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
        echo "Detected server IP: $SERVER_IP"
        read -p "Sử dụng IP này? Nhập IP khác hoặc Enter để xác nhận: " INPUT_IP
        if [ ! -z "$INPUT_IP" ]; then
            SERVER_IP=$INPUT_IP
        fi
    fi
    
    # Thông tin đăng nhập cho admin
    echo "Nhập thông tin đăng nhập admin cho PRIMARY:"
    read -p "Tên người dùng [$ADMIN_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$ADMIN_USER}
    read -sp "Mật khẩu [$ADMIN_PASS]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$ADMIN_PASS}
    echo ""
    
    # Tạo keyfile ngay từ đầu
    echo -e "${YELLOW}Tạo keyfile xác thực cho PRIMARY node...${NC}"
    create_keyfile "/etc/mongodb.keyfile" $SERVER_IP
    
    # Xác nhận thông tin
    echo -e "${YELLOW}=== THÔNG TIN ĐÃ NHẬP ===${NC}"
    echo "Server IP: $SERVER_IP"
    echo "Admin User: $PRIMARY_USER"
    echo "Keyfile: /etc/mongodb.keyfile"
    echo -e "${YELLOW}=========================${NC}"
    read -p "Xác nhận thông tin trên? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Hủy thiết lập.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Khởi tạo MongoDB PRIMARY trên port $PRIMARY_PORT...${NC}"

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
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$PRIMARY_PORT${NC}"
    
    # Thử vài cách khởi tạo khác nhau
    local success=false
    
    # Cách 1: Khởi tạo với IP server trực tiếp
    echo "Phương pháp 1: Khởi tạo với IP server trực tiếp"
    local init_result=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 }
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
        local init_result2=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "rs.initiate()" --quiet)
        
        if echo "$init_result2" | grep -q "ok" && ! echo "$init_result2" | grep -q "NotYetInitialized"; then
            echo -e "${GREEN}✅ Khởi tạo replica set thành công (phương pháp 2)${NC}"
            success=true
            
            # Chờ một chút cho MongoDB ổn định
            echo "Đợi 10 giây cho MongoDB ổn định..."
            sleep 10
            
            # Cập nhật cấu hình với IP thực tế
            echo "Cập nhật cấu hình với IP thực tế..."
            local update_result=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "
            var config = rs.conf();
            config.members[0].host = '$SERVER_IP:$PRIMARY_PORT';
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
            local init_result3=$(mongosh --host localhost --port $PRIMARY_PORT --eval "
            rs.initiate({
                _id: 'rs0',
                members: [
                    { _id: 0, host: 'localhost:$PRIMARY_PORT', priority: 10 }
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
                local update_result=$(mongosh --host localhost --port $PRIMARY_PORT --eval "
                var config = rs.conf();
                config.members[0].host = '$SERVER_IP:$PRIMARY_PORT';
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
    local status=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "${GREEN}✅ Replica Set đã được khởi tạo thành công${NC}"
        echo "Config hiện tại:"
        mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "rs.conf()" --quiet
        
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
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin"
            echo ""
            echo -e "${YELLOW}Lưu ý:${NC} Nếu không thể kết nối qua IP, sử dụng lệnh:"
            echo "mongosh --host localhost --port $PRIMARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin"
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
    local SERVER_IP=$1
    local PRIMARY_IP=$2
    local SECONDARY_PORT=27017

    echo -e "${GREEN}=== THIẾT LẬP MONGODB SECONDARY NODE ===${NC}"

    # Thu thập tất cả thông tin cần thiết từ đầu
    if [ -z "$PRIMARY_IP" ]; then
        read -p "Nhập địa chỉ IP của PRIMARY: " PRIMARY_IP
        if [ -z "$PRIMARY_IP" ]; then
            echo -e "${RED}❌ Không có PRIMARY IP, không thể tiếp tục.${NC}"
            return 1
        fi
    fi
    
    # Thông tin đăng nhập cho PRIMARY
    echo "Nhập thông tin đăng nhập PRIMARY:"
    read -p "Tên người dùng [$ADMIN_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$ADMIN_USER}
    read -sp "Mật khẩu [$ADMIN_PASS]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$ADMIN_PASS}
    echo ""
    
    # Thông tin đăng nhập cho SECONDARY
    echo "Nhập thông tin đăng nhập admin cho SECONDARY:"
    read -p "Tên người dùng [$ADMIN_USER]: " SEC_USER
    SEC_USER=${SEC_USER:-$ADMIN_USER}
    read -sp "Mật khẩu [$ADMIN_PASS]: " SEC_PASS
    SEC_PASS=${SEC_PASS:-$ADMIN_PASS}
    echo ""
    
    # Tạo keyfile ngay từ đầu
    echo -e "${YELLOW}Lấy keyfile từ PRIMARY node...${NC}"
    if ! create_keyfile "/etc/mongodb.keyfile" $PRIMARY_IP; then
        echo -e "${RED}❌ Lỗi khi lấy keyfile từ PRIMARY.${NC}"
        echo -e "${YELLOW}Thử tạo keyfile mới...${NC}"
        openssl rand -base64 756 | sudo tee /etc/mongodb.keyfile > /dev/null
        sudo chmod 400 /etc/mongodb.keyfile
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
        echo -e "${YELLOW}⚠️ Đã tạo keyfile cục bộ. Cần sao chép thủ công sang PRIMARY.${NC}"
    fi
    
    # Xác nhận thông tin
    echo -e "${YELLOW}=== THÔNG TIN ĐÃ NHẬP ===${NC}"
    echo "Server IP: $SERVER_IP"
    echo "PRIMARY IP: $PRIMARY_IP"
    echo "PRIMARY User: $PRIMARY_USER"
    echo "SECONDARY User: $SEC_USER"
    echo "Keyfile: /etc/mongodb.keyfile"
    echo -e "${YELLOW}=========================${NC}"
    read -p "Xác nhận thông tin trên? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Hủy thiết lập.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Khởi tạo MongoDB SECONDARY trên port $SECONDARY_PORT...${NC}"

    # Dừng và xóa dữ liệu cũ
    stop_mongodb
    
    # Tạo thư mục dữ liệu và log
    create_dirs
    
    # Cấu hình tường lửa
    configure_firewall
    
    # BƯỚC 1: Khởi động MongoDB không bảo mật và không replica set
    echo -e "${YELLOW}BƯỚC 1: Khởi động MongoDB không bảo mật và không replica set...${NC}"
    create_config false "no_repl"
    create_systemd_service false "no_repl"
    
    if ! start_mongodb; then
        echo -e "${RED}❌ Không thể khởi động MongoDB không bảo mật${NC}"
        echo -e "${YELLOW}Đang thử khắc phục sự cố...${NC}"
        if ! check_and_restart_mongodb false; then
            echo -e "${RED}❌ Không thể khởi động MongoDB. Vui lòng chạy tùy chọn 'Troubleshoot' từ menu chính${NC}"
            return 1
        fi
    fi
    
    # Kiểm tra kết nối
    if ! verify_mongodb_connection false "" "" $SERVER_IP; then
        echo -e "${RED}❌ Không thể kết nối đến MongoDB${NC}"
        echo -e "${YELLOW}Thử kết nối với localhost...${NC}"
        if ! verify_mongodb_connection false "" "" "localhost"; then
            echo -e "${RED}❌ Không thể kết nối đến MongoDB ngay cả với localhost${NC}"
            echo -e "${YELLOW}Đang thử khắc phục sự cố...${NC}"
            check_and_restart_mongodb false
            if ! verify_mongodb_connection false "" "" "localhost"; then
                echo -e "${RED}❌ Vẫn không thể kết nối. Vui lòng chạy tùy chọn 'Troubleshoot' từ menu chính${NC}"
                return 1
            fi
        fi
    fi
    
    # BƯỚC 2: Tạo user admin
    echo -e "${YELLOW}BƯỚC 2: Tạo user admin trên node SECONDARY...${NC}"
    if ! create_admin_user $SEC_USER $SEC_PASS; then
        echo -e "${RED}❌ Không thể tạo user admin trên SECONDARY${NC}"
        echo -e "${YELLOW}Đang thử lại sau khi khởi động lại MongoDB...${NC}"
        check_and_restart_mongodb false
        if ! create_admin_user $SEC_USER $SEC_PASS; then
            echo -e "${RED}❌ Vẫn không thể tạo user admin. Vui lòng kiểm tra logs.${NC}"
            return 1
        fi
    fi
    
    # BƯỚC 3: Dừng MongoDB và cấu hình lại với replica set (nhưng chưa có bảo mật)
    echo -e "${YELLOW}BƯỚC 3: Cấu hình lại với replica set...${NC}"
    stop_mongodb
    
    create_config false
    create_systemd_service false
    
    if ! start_mongodb; then
        echo -e "${RED}❌ Không thể khởi động MongoDB với cấu hình replica set${NC}"
        check_and_restart_mongodb false
        if ! verify_mongodb_connection false "" "" "localhost"; then
            echo -e "${RED}❌ Vẫn không thể khởi động MongoDB. Vui lòng kiểm tra logs.${NC}"
            return 1
        fi
    fi
    
    # Kiểm tra kết nối
    if ! verify_mongodb_connection false "" "" $SERVER_IP; then
        echo -e "${RED}❌ Không thể kết nối đến MongoDB sau khi cấu hình replica set${NC}"
        echo -e "${YELLOW}Thử kết nối với localhost...${NC}"
        if ! verify_mongodb_connection false "" "" "localhost"; then
            echo -e "${RED}❌ Không thể kết nối đến MongoDB ngay cả với localhost${NC}"
            echo -e "${YELLOW}Đang thử khắc phục sự cố...${NC}"
            check_and_restart_mongodb false
            if ! verify_mongodb_connection false "" "" "localhost"; then
                echo -e "${RED}❌ Vẫn không thể kết nối. Vui lòng chạy tùy chọn 'Troubleshoot' từ menu chính${NC}"
                return 1
            fi
        fi
    fi
    
    # BƯỚC 4: Kết nối tới PRIMARY và thêm node này
    echo -e "${YELLOW}BƯỚC 4: Thêm node vào Replica Set...${NC}"
    echo -e "${GREEN}Kết nối tới PRIMARY $PRIMARY_IP và thêm node $SERVER_IP:$SECONDARY_PORT${NC}"
    
    # Kiểm tra xem node đã tồn tại trong replica set chưa
    if check_node_in_replicaset $PRIMARY_IP $SERVER_IP $SECONDARY_PORT $PRIMARY_USER $PRIMARY_PASS; then
        echo -e "${YELLOW}Node đã tồn tại trong replica set. Đang thử cập nhật cấu hình...${NC}"
        
        # Xóa node khỏi replica set (nếu đang không healthy)
        local remove_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
        try {
            rs.remove('$SERVER_IP:$SECONDARY_PORT');
            print('✅ Đã xóa node khỏi replica set');
        } catch (err) {
            print('❌ Lỗi: ' + err.message);
        }" --quiet)
        
        echo "$remove_result"
        echo -e "${YELLOW}Đợi 10 giây sau khi xóa node...${NC}"
        sleep 10
        
        # Thêm lại node
        local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
        try {
            rs.add('$SERVER_IP:$SECONDARY_PORT');
            print('✅ Đã thêm lại node vào replica set');
        } catch (err) {
            print('❌ Lỗi: ' + err.message);
        }" --quiet)
        
        echo "$add_result"
    else
        # Thêm node mới
        local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
        try {
            rs.add('$SERVER_IP:$SECONDARY_PORT');
            print('✅ Đã thêm node vào replica set');
        } catch (err) {
            print('❌ Lỗi: ' + err.message);
        }" --quiet)
        
        echo "$add_result"
    fi
    
    # Kiểm tra kết quả
    if [[ "$add_result" == *"❌ Lỗi"* ]]; then
        echo -e "${RED}❌ Không thể thêm node vào Replica Set${NC}"
        echo -e "${YELLOW}Kiểm tra kết nối với PRIMARY...${NC}"
        if ! ping -c 1 -W 2 $PRIMARY_IP > /dev/null; then
            echo -e "${RED}❌ Không thể ping tới PRIMARY server $PRIMARY_IP${NC}"
            echo -e "${YELLOW}Kiểm tra kết nối mạng và firewall.${NC}"
        fi
        echo -e "${YELLOW}Kiểm tra nếu PRIMARY đang chạy...${NC}"
        nc -z -v -w 5 $PRIMARY_IP 27017 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Không thể kết nối tới PRIMARY server $PRIMARY_IP:27017${NC}"
        fi
        
        # Hỏi người dùng có muốn tiếp tục
        read -p "Thêm node thất bại. Bạn có muốn tiếp tục bước tiếp theo? (y/n): " CONTINUE
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        echo -e "${GREEN}✅ Đã thêm node vào replica set${NC}"
    fi
    
    echo -e "${YELLOW}Đợi node được thêm vào...${NC}"
    sleep 10
    
    # Kiểm tra trạng thái node sau khi thêm
    echo -e "${YELLOW}Kiểm tra trạng thái node sau khi thêm...${NC}"
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra xem node có UNREACHABLE hoặc không healthy không
    if echo "$status" | grep -q "$SERVER_IP:$SECONDARY_PORT.*UNREACHABLE" || echo "$status" | grep -q "$SERVER_IP:$SECONDARY_PORT.*SECONDARY.*health.*false"; then
        echo -e "${RED}❌ Node $SERVER_IP:$SECONDARY_PORT không reachable hoặc không healthy${NC}"
        echo -e "${YELLOW}Đang kiểm tra và khắc phục...${NC}"
        
        # Kiểm tra và khắc phục lỗi
        if ! check_and_restart_mongodb false; then
            echo -e "${RED}❌ Không thể khắc phục lỗi node không reachable/healthy${NC}"
            echo -e "${YELLOW}Vui lòng kiểm tra thủ công:${NC}"
            echo "1. Kiểm tra tường lửa: sudo ufw status"
            echo "2. Kiểm tra log MongoDB: sudo tail -n 50 /var/log/mongodb/mongod_${SECONDARY_PORT}.log"
            echo "3. Kiểm tra kết nối mạng: ping $SERVER_IP"
            echo "4. Kiểm tra port: nc -zv $SERVER_IP $SECONDARY_PORT"
            echo "5. Kiểm tra cấu hình MongoDB: cat /etc/mongod_${SECONDARY_PORT}.conf"
            
            # Hỏi người dùng có muốn tiếp tục không
            read -p "Bạn có muốn tiếp tục thiết lập bảo mật không? (y/n): " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                return 1
            fi
        else
            echo -e "${GREEN}✅ Đã khắc phục lỗi node không reachable/healthy${NC}"
        fi
    fi
    
    # BƯỚC 5: Tạo keyfile và cấu hình bảo mật
    echo -e "${YELLOW}BƯỚC 5: Áp dụng bảo mật với keyfile...${NC}"
    
    # Kiểm tra và đảm bảo quyền keyfile đúng
    echo -e "${YELLOW}Kiểm tra và sửa quyền keyfile...${NC}"
    if [ -f "/etc/mongodb.keyfile" ]; then
        sudo chmod 400 /etc/mongodb.keyfile
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
        ls -la /etc/mongodb.keyfile
    else
        echo -e "${RED}❌ Không tìm thấy keyfile sau khi tạo/copy!${NC}"
        echo -e "${YELLOW}Đang tạo keyfile mới cục bộ...${NC}"
        openssl rand -base64 756 | sudo tee /etc/mongodb.keyfile > /dev/null
        sudo chmod 400 /etc/mongodb.keyfile 
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
        ls -la /etc/mongodb.keyfile
        echo -e "${YELLOW}⚠️ Đã tạo keyfile cục bộ. Cần sao chép thủ công sang PRIMARY.${NC}"
    fi
    
    # Áp dụng keyfile và khởi động với bảo mật
    echo -e "${YELLOW}Áp dụng keyfile và khởi động MongoDB với bảo mật...${NC}"
    if ! apply_keyfile "/etc/mongodb.keyfile" $PRIMARY_IP; then
        echo -e "${RED}❌ Không thể áp dụng keyfile và khởi động MongoDB với bảo mật.${NC}"
        echo -e "${YELLOW}Thử khắc phục...${NC}"
        
        # Thử khắc phục lỗi
        fix_keyfile_and_restart $PRIMARY_IP
        
        # Kiểm tra lại
        if ! verify_mongodb_connection true $SEC_USER $SEC_PASS "localhost"; then
            echo -e "${RED}❌ Vẫn không thể khởi động MongoDB với bảo mật.${NC}"
            echo -e "${YELLOW}Kiểm tra chi tiết MongoDB...${NC}"
            check_mongodb_status
            
            # Hỏi có muốn tiếp tục với MongoDB không bảo mật
            read -p "Bạn có muốn tiếp tục với MongoDB không bảo mật? (y/n): " CONTINUE_NO_SECURITY
            if [[ "$CONTINUE_NO_SECURITY" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Khởi động MongoDB không bảo mật...${NC}"
                create_systemd_service false
                if ! start_mongodb; then
                    echo -e "${RED}❌ MongoDB không thể khởi động được.${NC}"
                    return 1
                else
                    echo -e "${YELLOW}⚠️ MongoDB đã khởi động nhưng KHÔNG có bảo mật!${NC}"
                    echo -e "${YELLOW}⚠️ Replica set có thể không hoạt động đúng.${NC}"
                fi
            else
                echo -e "${RED}❌ Hủy thiết lập.${NC}"
                return 1
            fi
        else
            echo -e "${GREEN}✅ Đã sửa lỗi keyfile và MongoDB đã khởi động với bảo mật.${NC}"
        fi
    else
        echo -e "${GREEN}✅ MongoDB đã khởi động với bảo mật thành công.${NC}"
    fi
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra xem node mới có trong rs.status() không
    if echo "$status" | grep -q "$SERVER_IP:$SECONDARY_PORT"; then
        echo -e "\n${GREEN}=== THIẾT LẬP MONGODB SECONDARY HOÀN TẤT ===${NC}"
        echo -e "${GREEN}Lệnh kết nối:${NC}"
        echo "mongosh --host $SERVER_IP --port $SECONDARY_PORT -u $SEC_USER -p $SEC_PASS --authenticationDatabase admin"
        
        # Hiển thị trạng thái chi tiết của node
        echo -e "${YELLOW}Trạng thái chi tiết của node $SERVER_IP:$SECONDARY_PORT:${NC}"
        echo "$status" | grep -A 10 "$SERVER_IP:$SECONDARY_PORT"
    else
        echo -e "${RED}❌ Node không xuất hiện trong Replica Set${NC}"
        echo "$status"
        return 1
    fi
}

# Check and restart MongoDB if needed
check_and_restart_mongodb() {
    local with_security=${1:-false}
    
    echo -e "${YELLOW}Kiểm tra và khởi động lại MongoDB...${NC}"
    echo -e "${YELLOW}Kiểm tra trạng thái dịch vụ MongoDB...${NC}"
    
    # Kiểm tra nếu MongoDB được cài đặt
    if ! command -v mongod &> /dev/null; then
        echo -e "${RED}❌ MongoDB chưa được cài đặt!${NC}"
        return 1
    fi
    
    # Kiểm tra xem dịch vụ có bị masked không
    if sudo systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${RED}Dịch vụ mongod bị masked. Đang unmask...${NC}"
        sudo systemctl unmask mongod
    fi
    
    # Kiểm tra xem dịch vụ có đang chạy hay không
    if ! sudo systemctl is-active --quiet mongod; then
        echo -e "${YELLOW}MongoDB không chạy hoặc đang gặp sự cố${NC}"
        
        # Kiểm tra thư mục log
        echo -e "${YELLOW}Kiểm tra thư mục log...${NC}"
        if [ ! -d "/var/log/mongodb" ]; then
            echo -e "${YELLOW}Tạo thư mục log...${NC}"
            sudo mkdir -p /var/log/mongodb
            sudo chown -R mongodb:mongodb /var/log/mongodb
        fi
        
        # Kiểm tra quyền của file log
        echo -e "${YELLOW}Kiểm tra quyền của file log...${NC}"
        if [ ! -f "/var/log/mongodb/mongod.log" ]; then
            echo -e "${YELLOW}Tạo file log...${NC}"
            sudo touch /var/log/mongodb/mongod.log
            sudo chown mongodb:mongodb /var/log/mongodb/mongod.log
        fi
        
        # Kiểm tra log
        echo -e "${YELLOW}Kiểm tra log MongoDB...${NC}"
        sudo tail -n 30 /var/log/mongodb/mongod.log 2>/dev/null || echo -e "${YELLOW}Không có file log hoặc file log trống${NC}"
        
        # Kiểm tra thư mục dữ liệu
        echo -e "${YELLOW}Kiểm tra thư mục dữ liệu MongoDB...${NC}"
        if [ -d "/var/lib/mongodb" ]; then
            echo -e "${YELLOW}Đang sửa quyền thư mục dữ liệu...${NC}"
            sudo chown -R mongodb:mongodb /var/lib/mongodb
            sudo ls -la /var/lib/mongodb | head -n 20
            echo -e "${GREEN}✅ Đã sửa quyền thư mục dữ liệu${NC}"
        else
            echo -e "${YELLOW}Tạo thư mục dữ liệu...${NC}"
            sudo mkdir -p /var/lib/mongodb
            sudo chown -R mongodb:mongodb /var/lib/mongodb
        fi
        
        # Khởi động lại MongoDB
        echo -e "${YELLOW}Đang khởi động lại MongoDB...${NC}"
        sudo systemctl daemon-reload
        sudo systemctl restart mongod
        sleep 5
        
        # Kiểm tra lại trạng thái sau khi khởi động
        if sudo systemctl is-active --quiet mongod; then
            echo -e "${GREEN}✅ MongoDB đã khởi động lại thành công${NC}"
        else
            echo -e "${RED}❌ MongoDB vẫn không thể khởi động${NC}"
            echo -e "${YELLOW}Log gần nhất:${NC}"
            sudo tail -n 30 /var/log/mongodb/mongod.log
            echo -e "${YELLOW}Trạng thái dịch vụ:${NC}"
            sudo systemctl status mongod --no-pager -l || echo -e "${RED}❌ Không thể lấy trạng thái dịch vụ${NC}"
            
            # Thử khởi động lại với daemon-reload
            echo -e "${YELLOW}Thử reload daemon và khởi động lại...${NC}"
            sudo systemctl daemon-reload
            sudo systemctl restart mongod
            sleep 5
            
            if ! sudo systemctl is-active --quiet mongod; then
                echo -e "${RED}❌ MongoDB vẫn không thể khởi động. Vui lòng chạy tùy chọn 'Troubleshoot' từ menu chính${NC}"
                return 1
            fi
        fi
    else
        echo -e "${GREEN}✅ MongoDB đang chạy${NC}"
    fi
    
    return 0
}

# Check if node is in replica set
check_node_in_replicaset() {
    local PRIMARY_IP=$1
    local SERVER_IP=$2
    local PORT=$3
    local USERNAME=$4
    local PASSWORD=$5
    
    echo -e "${YELLOW}Kiểm tra xem node có trong replica set không...${NC}"
    local check_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "
    var config = rs.conf();
    var found = false;
    config.members.forEach(function(member) {
        if(member.host === '$SERVER_IP:$PORT') {
            found = true;
            print('✓ Node đã tồn tại trong replica set');
        }
    });
    if(!found) print('✗ Node chưa có trong replica set');
    found;" --quiet)
    
    echo "$check_result"
    if [[ "$check_result" == *"Node đã tồn tại"* ]]; then
        return 0
    else
        return 1
    fi
}

# Check MongoDB status in detail
check_mongodb_status() {
    echo -e "${YELLOW}=== Kiểm tra chi tiết MongoDB ===${NC}"
    
    # Kiểm tra dịch vụ
    echo -e "${YELLOW}1. Kiểm tra trạng thái dịch vụ ${NC}"
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${GREEN}✅ MongoDB đang chạy${NC}"
        sudo systemctl status mongod --no-pager | head -n 20
    else
        echo -e "${RED}❌ MongoDB KHÔNG chạy${NC}"
        sudo systemctl status mongod --no-pager || true
    fi
    
    # Kiểm tra log
    echo -e "\n${YELLOW}2. Kiểm tra log MongoDB ${NC}"
    if [ -f "/var/log/mongodb/mongod.log" ]; then
        echo -e "${GREEN}✅ File log tồn tại${NC}"
        echo -e "${YELLOW}Nội dung log gần đây:${NC}"
        sudo tail -n 20 /var/log/mongodb/mongod.log || echo -e "${RED}❌ Không thể đọc file log${NC}"
    else
        echo -e "${RED}❌ File log KHÔNG tồn tại${NC}"
    fi
    
    # Kiểm tra cấu hình
    echo -e "\n${YELLOW}3. Kiểm tra file cấu hình ${NC}"
    if [ -f "/etc/mongod.conf" ]; then
        echo -e "${GREEN}✅ File cấu hình tồn tại${NC}"
        echo -e "${YELLOW}Nội dung file cấu hình:${NC}"
        sudo cat /etc/mongod.conf
    else
        echo -e "${RED}❌ File cấu hình KHÔNG tồn tại${NC}"
    fi
    
    # Kiểm tra keyfile
    echo -e "\n${YELLOW}4. Kiểm tra keyfile ${NC}"
    if [ -f "/etc/mongodb.keyfile" ]; then
        echo -e "${GREEN}✅ Keyfile tồn tại${NC}"
        echo -e "${YELLOW}Quyền của keyfile:${NC}"
        sudo ls -la /etc/mongodb.keyfile
    else
        echo -e "${RED}❌ Keyfile KHÔNG tồn tại${NC}"
    fi
    
    # Kiểm tra thư mục dữ liệu
    echo -e "\n${YELLOW}5. Kiểm tra thư mục dữ liệu ${NC}"
    if [ -d "/var/lib/mongodb" ]; then
        echo -e "${GREEN}✅ Thư mục dữ liệu tồn tại${NC}"
        echo -e "${YELLOW}Dung lượng thư mục dữ liệu:${NC}"
        sudo du -sh /var/lib/mongodb
        echo -e "${YELLOW}Quyền thư mục dữ liệu:${NC}"
        sudo ls -la /var/lib/mongodb | head -n 5
    else
        echo -e "${RED}❌ Thư mục dữ liệu KHÔNG tồn tại${NC}"
    fi
    
    # Kiểm tra kết nối
    echo -e "\n${YELLOW}6. Kiểm tra kết nối cơ bản ${NC}"
    if nc -z -v -w 5 localhost 27017 2>/dev/null; then
        echo -e "${GREEN}✅ Có thể kết nối tới MongoDB tại localhost:27017${NC}"
        
        # Thử kết nối mongosh
        echo -e "${YELLOW}Thử kết nối với mongosh:${NC}"
        mongosh --eval "db.version()" --quiet || echo -e "${RED}❌ Không thể kết nối với mongosh${NC}"
    else
        echo -e "${RED}❌ KHÔNG thể kết nối tới MongoDB tại localhost:27017${NC}"
    fi
    
    echo -e "\n${YELLOW}=== Kết thúc kiểm tra ===${NC}"
}

# Fix keyfile permissions and restart MongoDB
fix_keyfile_and_restart() {
    local PRIMARY_IP=$1
    echo -e "${YELLOW}=== Sửa quyền keyfile và khởi động lại MongoDB ===${NC}"
    
    # Kiểm tra keyfile
    if [ -f "/etc/mongodb.keyfile" ]; then
        echo -e "${YELLOW}Xóa keyfile hiện tại và tạo keyfile mới...${NC}"
        sudo rm -f /etc/mongodb.keyfile
        
        # Tạo keyfile mới
        if [ -n "$PRIMARY_IP" ]; then
            echo -e "${YELLOW}Sao chép keyfile từ PRIMARY $PRIMARY_IP...${NC}"
            scp -o StrictHostKeyChecking=accept-new root@$PRIMARY_IP:/etc/mongodb.keyfile /etc/mongodb.keyfile 2>/dev/null
            if [ $? -ne 0 ]; then
                echo -e "${RED}❌ Không thể sao chép keyfile từ PRIMARY. Tạo keyfile mới cục bộ...${NC}"
                openssl rand -base64 756 | sudo tee /etc/mongodb.keyfile > /dev/null
            fi
        else
            echo -e "${YELLOW}Tạo keyfile mới cục bộ...${NC}"
            openssl rand -base64 756 | sudo tee /etc/mongodb.keyfile > /dev/null
        fi
        
        # Thiết lập quyền
        echo -e "${YELLOW}Thiết lập quyền cho keyfile...${NC}"
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
        sudo chmod 400 /etc/mongodb.keyfile
        ls -la /etc/mongodb.keyfile
    else
        echo -e "${RED}❌ Keyfile không tồn tại. Tạo keyfile mới...${NC}"
        openssl rand -base64 756 | sudo tee /etc/mongodb.keyfile > /dev/null
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
        sudo chmod 400 /etc/mongodb.keyfile
        ls -la /etc/mongodb.keyfile
    fi
    
    # Khởi động lại MongoDB
    echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
    sudo systemctl restart mongod
    sleep 5
    
    # Kiểm tra trạng thái
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${GREEN}✅ MongoDB đã khởi động lại thành công${NC}"
        return 0
    else
        echo -e "${RED}❌ MongoDB vẫn không thể khởi động${NC}"
        echo -e "${YELLOW}Kiểm tra log:${NC}"
        sudo tail -n 20 /var/log/mongodb/mongod.log || true
        return 1
    fi
}

# Unmask MongoDB service
unmask_mongodb() {
    echo -e "${YELLOW}=== Unmask dịch vụ MongoDB ===${NC}"
    
    # Kiểm tra trạng thái dịch vụ
    echo -e "${YELLOW}Kiểm tra trạng thái MongoDB...${NC}"
    if systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${RED}Dịch vụ MongoDB đang bị masked${NC}"
        echo -e "${YELLOW}Đang unmask dịch vụ...${NC}"
        sudo systemctl unmask mongod
        sudo systemctl daemon-reload
        echo -e "${GREEN}✅ Đã unmask dịch vụ MongoDB${NC}"
    else
        echo -e "${GREEN}✅ Dịch vụ MongoDB không bị masked${NC}"
    fi
    
    # Kiểm tra và khởi động dịch vụ nếu chưa chạy
    if ! systemctl is-active --quiet mongod; then
        echo -e "${YELLOW}Khởi động dịch vụ MongoDB...${NC}"
        sudo systemctl start mongod
        sleep 5
        
        if systemctl is-active --quiet mongod; then
            echo -e "${GREEN}✅ Đã khởi động MongoDB thành công${NC}"
        else
            echo -e "${RED}❌ Không thể khởi động MongoDB${NC}"
            echo -e "${YELLOW}Trạng thái dịch vụ:${NC}"
            sudo systemctl status mongod --no-pager
        fi
    else
        echo -e "${GREEN}✅ MongoDB đang chạy${NC}"
    fi
}

# Unmask và fix MongoDB từ đầu
unmask_and_fix_mongodb() {
    echo -e "${YELLOW}=== Unmask và fix MongoDB từ đầu ===${NC}"
    
    # Dừng tất cả dịch vụ MongoDB
    echo -e "${YELLOW}1. Dừng tất cả dịch vụ MongoDB...${NC}"
    sudo systemctl stop mongod mongod_27017 &>/dev/null || true
    
    # Kill các process MongoDB
    echo -e "${YELLOW}2. Kill tất cả process MongoDB...${NC}"
    sudo pkill -f mongod || true
    sleep 2
    
    # Unmask tất cả dịch vụ MongoDB
    echo -e "${YELLOW}3. Unmask tất cả dịch vụ MongoDB...${NC}"
    sudo systemctl unmask mongod mongod_27017 &>/dev/null || true
    
    # Xóa tất cả file service cũ
    echo -e "${YELLOW}4. Xóa tất cả file service cũ...${NC}"
    sudo rm -f /etc/systemd/system/mongod.service /etc/systemd/system/mongod_27017.service /lib/systemd/system/mongod.service &>/dev/null || true
    
    # Reload daemon
    echo -e "${YELLOW}5. Reload daemon...${NC}"
    sudo systemctl daemon-reload
    
    # Tạo file cấu hình mới
    echo -e "${YELLOW}6. Tạo file cấu hình mới...${NC}"
    create_config false
    
    # Tạo service mới
    echo -e "${YELLOW}7. Tạo service mới...${NC}"
    sudo tee /etc/systemd/system/mongod.service > /dev/null <<EOL
[Unit]
Description=MongoDB Database Server
After=network.target
Documentation=https://docs.mongodb.org/manual

[Service]
User=mongodb
Group=mongodb
Type=simple
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
ExecStop=/usr/bin/mongod --config /etc/mongod.conf --shutdown

[Install]
WantedBy=multi-user.target
EOL

    # Reload daemon
    echo -e "${YELLOW}8. Reload daemon lần nữa...${NC}"
    sudo systemctl daemon-reload
    
    # Enable và khởi động service
    echo -e "${YELLOW}9. Enable và khởi động service...${NC}"
    sudo systemctl enable mongod
    sudo systemctl start mongod
    sleep 5
    
    # Kiểm tra trạng thái
    echo -e "${YELLOW}10. Kiểm tra trạng thái dịch vụ...${NC}"
    if sudo systemctl is-active --quiet mongod; then
        echo -e "${GREEN}✅ MongoDB đã khởi động thành công${NC}"
        sudo systemctl status mongod --no-pager
    else
        echo -e "${RED}❌ MongoDB vẫn không thể khởi động${NC}"
        sudo systemctl status mongod --no-pager
    fi
}

# Display troubleshooting menu
troubleshoot_mongodb() {
    local option
    
    while true; do
        echo -e "${GREEN}=== Menu sửa lỗi MongoDB ===${NC}"
        echo "1. Kiểm tra chi tiết trạng thái MongoDB"
        echo "2. Khởi động lại MongoDB (không bảo mật)"
        echo "3. Khởi động lại MongoDB (có bảo mật)"
        echo "4. Sửa quyền keyfile và khởi động lại"
        echo "5. Xem log MongoDB"
        echo "6. Unmask dịch vụ MongoDB"
        echo "7. Fix triệt để (unmask và cài lại service)"
        echo "0. Quay lại menu chính"
        
        read -p "Chọn tùy chọn (0-7): " option
        
        case $option in
            1)
                check_mongodb_status
                ;;
            2)
                create_config false
                check_and_restart_mongodb false
                ;;
            3)
                create_config true
                check_and_restart_mongodb true
                ;;
            4)
                read -p "Nhập IP của PRIMARY (để trống nếu không có): " PRIMARY_IP
                fix_keyfile_and_restart "$PRIMARY_IP"
                ;;
            5)
                echo -e "${YELLOW}Xem log MongoDB:${NC}"
                sudo tail -n 50 /var/log/mongodb/mongod.log || echo -e "${RED}❌ Không thể đọc file log${NC}"
                ;;
            6)
                unmask_mongodb
                ;;
            7)
                unmask_and_fix_mongodb
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ!${NC}"
                ;;
        esac
        
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Main function for replica set setup
setup_replica_linux() {
    local option
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    
    while true; do
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}=== THIẾT LẬP MONGODB REPLICA SET - LINUX ===${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo -e "Server IP hiện tại: ${YELLOW}$SERVER_IP${NC}"
        echo "1. Thiết lập PRIMARY Node"
        echo "2. Thiết lập SECONDARY Node"
        echo "3. Sửa lỗi MongoDB (Troubleshoot)"
        echo "0. Quay lại menu chính"
        
        read -p "Chọn tùy chọn (0-3): " option
        
        case $option in
            1)
                setup_primary "$SERVER_IP"
                ;;
            2)
                read -p "Nhập địa chỉ IP của PRIMARY: " PRIMARY_IP
                setup_secondary "$SERVER_IP" "$PRIMARY_IP"
                ;;
            3)
                troubleshoot_mongodb
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