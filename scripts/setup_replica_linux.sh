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
            echo "Đợi 5 giây cho MongoDB ổn định..."
    sleep 5
    
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
    
    # Tạo keyfile
    echo -e "${YELLOW}1. Tạo keyfile...${NC}"
    create_keyfile "/etc/mongodb.keyfile" $PRIMARY_IP
    
    # Xác nhận thông tin
    echo -e "\n${YELLOW}=== XÁC NHẬN THÔNG TIN ===${NC}"
    echo -e "Server IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "PRIMARY IP: ${GREEN}$PRIMARY_IP${NC}"
    echo -e "Tài khoản admin: ${GREEN}$PRIMARY_USER${NC}"
    echo -e "Keyfile: ${GREEN}/etc/mongodb.keyfile${NC}"
    read -p "Xác nhận thông tin trên là chính xác? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Hủy thiết lập SECONDARY${NC}"
        return 1
    fi
    
    # Kiểm tra kết nối mạng chi tiết
    echo -e "${YELLOW}2. Kiểm tra kết nối mạng chi tiết...${NC}"
    echo -e "Ping tới PRIMARY ($PRIMARY_IP):"
    ping -c 2 $PRIMARY_IP
    
    echo -e "Kiểm tra port 27017 trên PRIMARY:"
    nc -zv $PRIMARY_IP 27017 || echo -e "${RED}❌ Không thể kết nối tới port 27017 trên PRIMARY${NC}"
    
    echo -e "Kiểm tra IP của máy này (SERVER_IP):"
    ip addr show | grep -w inet
    
    # Unmask dịch vụ nếu đang bị masked
    echo -e "${YELLOW}3. Kiểm tra và unmask dịch vụ MongoDB...${NC}"
    if sudo systemctl is-enabled mongod 2>&1 | grep -q "masked"; then
        echo -e "${YELLOW}Dịch vụ đang bị masked, đang unmask...${NC}"
        sudo systemctl unmask mongod
        sudo systemctl daemon-reload
    fi
    
    # Dừng MongoDB hiện tại nếu đang chạy
    echo -e "${YELLOW}4. Dừng MongoDB hiện tại...${NC}"
    sudo systemctl stop mongod
    sudo pkill -f mongod 2>/dev/null || true
    sleep 3
    
    # Tạo thư mục nếu chưa tồn tại
    echo -e "${YELLOW}5. Tạo thư mục cần thiết...${NC}"
    sudo mkdir -p /var/lib/mongodb /var/log/mongodb
    sudo chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb
    
    # PHẦN 1: Tạo cấu hình MongoDB không có bảo mật và replica set trước
    echo -e "${YELLOW}6. Chạy MongoDB không có bảo mật và replica set trước...${NC}"
    sudo tee /etc/mongod.conf > /dev/null <<EOL
# mongod.conf tạm thời không replica set
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0
EOL
    
    # Khởi động MongoDB tạm thời
    echo -e "${YELLOW}7. Khởi động MongoDB tạm thời...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart mongod
        sleep 5
    
    # Kiểm tra MongoDB có đang chạy không
    if ! sudo systemctl is-active --quiet mongod; then
        echo -e "${RED}❌ MongoDB không thể khởi động. Kiểm tra lỗi:${NC}"
        sudo systemctl status mongod --no-pager
        sudo tail -n 20 /var/log/mongodb/mongod.log
        return 1
    else
        echo -e "${GREEN}✅ MongoDB tạm thời đã khởi động thành công${NC}"
        
        # Kiểm tra khả năng kết nối cục bộ
        echo -e "${YELLOW}Kiểm tra kết nối cục bộ tới MongoDB...${NC}"
        mongosh --host localhost --port 27017 --eval "db.version()" --quiet || echo -e "${RED}❌ Không thể kết nối tới MongoDB cục bộ${NC}"
    fi
    
    # PHẦN 2: Dừng và cấu hình MongoDB với replica set
    echo -e "${YELLOW}8. Dừng MongoDB để cấu hình lại với replica set...${NC}"
    sudo systemctl stop mongod
    sleep 3
    
    # Tạo cấu hình MongoDB với replica set
    echo -e "${YELLOW}9. Tạo cấu hình MongoDB với replica set...${NC}"
    sudo tee /etc/mongod.conf > /dev/null <<EOL
# mongod.conf
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0

replication:
  replSetName: rs0

security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled
EOL
    
    # Đảm bảo keyfile có quyền đúng
    echo -e "${YELLOW}10. Đảm bảo keyfile có quyền đúng...${NC}"
    sudo chmod 400 /etc/mongodb.keyfile
    sudo chown mongodb:mongodb /etc/mongodb.keyfile
    ls -la /etc/mongodb.keyfile
    
    # Khởi động MongoDB với cấu hình replica set
    echo -e "${YELLOW}11. Khởi động MongoDB với cấu hình replica set...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl start mongod
    
    # Kiểm tra MongoDB có đang chạy không sau 5 giây
    echo -e "${YELLOW}Đợi MongoDB khởi động...${NC}"
        sleep 5
    if ! sudo systemctl is-active --quiet mongod; then
        echo -e "${RED}❌ MongoDB không thể khởi động với cấu hình replica set. Kiểm tra lỗi:${NC}"
        sudo systemctl status mongod --no-pager
        sudo tail -n 30 /var/log/mongodb/mongod.log
        
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
    
    # Thêm kiểm tra kết nối MongoDB tại local
    echo -e "${YELLOW}12. Kiểm tra kết nối MongoDB tại local...${NC}"
    mongosh --host localhost --port 27017 --eval "try { db.version(); print('✅ Kết nối tới MongoDB local thành công'); } catch(e) { print('❌ Lỗi kết nối: ' + e.message); }" --quiet
    
    # Kiểm tra kết nối với PRIMARY
    echo -e "${YELLOW}13. Kiểm tra kết nối với PRIMARY...${NC}"
    if ! ping -c 1 -W 2 $PRIMARY_IP > /dev/null; then
        echo -e "${RED}❌ Không thể ping tới PRIMARY. Kiểm tra kết nối mạng.${NC}"
        echo -e "${YELLOW}Thử kiểm tra lại với ping chi tiết hơn:${NC}"
        ping -c 4 $PRIMARY_IP
        echo -e "${YELLOW}Kiểm tra bảng định tuyến:${NC}"
        ip route
        return 1
    else
        echo -e "${GREEN}✅ Ping tới PRIMARY thành công${NC}"
    fi
    
    if ! nc -z -v -w 5 $PRIMARY_IP 27017 2>/dev/null; then
        echo -e "${RED}❌ Không thể kết nối tới PRIMARY:27017. Kiểm tra firewall trên PRIMARY.${NC}"
        echo -e "${YELLOW}Kiểm tra chi tiết:${NC}"
        nc -zv $PRIMARY_IP 27017
        echo -e "${YELLOW}Kiểm tra firewall:${NC}"
        sudo iptables -L -n | grep 27017 || echo "Không tìm thấy quy tắc firewall cho cổng 27017"
            return 1
    else
        echo -e "${GREEN}✅ Kết nối tới PRIMARY:27017 thành công${NC}"
    fi
    
    # Kiểm tra PRIMARY có đang hoạt động không
    echo -e "${YELLOW}14. Kiểm tra PRIMARY có đang hoạt động không...${NC}"
    local rs_status=$(mongosh --host "$PRIMARY_IP" --port 27017 --eval "rs.status()" --quiet 2>&1)
    
    if echo "$rs_status" | grep -q "MongoNetworkError\|failed\|error"; then
        echo -e "${RED}❌ Không thể kết nối tới PRIMARY. Lỗi:${NC}"
        echo "$rs_status"
        return 1
    fi
    
    echo -e "${GREEN}✅ Kết nối tới PRIMARY thành công${NC}"
    
    # Kiểm tra trạng thái của PRIMARY
    local primary_status=$(mongosh --host "$PRIMARY_IP" --port 27017 --eval "rs.status().members[0].stateStr" --quiet)
    if [ "$primary_status" != "PRIMARY" ]; then
        echo -e "${RED}❌ Node $PRIMARY_IP không phải là PRIMARY! Trạng thái hiện tại:${NC}"
        echo -e "      stateStr: '$primary_status',"
        echo -e "${YELLOW}Vui lòng chạy 'initialize_primary' trên node $PRIMARY_IP trước.${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Node $PRIMARY_IP đã là PRIMARY node${NC}"
    
    # Kiểm tra node có đã trong replica set không
    echo -e "${YELLOW}15. Kiểm tra node trong replica set...${NC}"
    if echo "$primary_status" | grep -q "$SERVER_IP:27017"; then
        echo -e "${YELLOW}Node đã tồn tại trong replica set, xóa và thêm lại...${NC}"
        local remove_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
        try {
            rs.remove('$SERVER_IP:27017');
            print('✅ Đã xóa node khỏi replica set');
        } catch (err) {
            print('⚠️ Lỗi khi xóa: ' + err.message);
        }
        " --quiet)
        echo "$remove_result"
        sleep 5
    fi
    
    # Mở các port cần thiết
    echo -e "${YELLOW}16. Đảm bảo các port cần thiết đã được mở...${NC}"
    if command -v ufw > /dev/null; then
        echo -e "Kiểm tra ufw..."
        sudo ufw status | grep 27017 || sudo ufw allow 27017/tcp
    fi
    
    # Kiểm tra và cập nhật host
    echo -e "${YELLOW}17. Kiểm tra và cập nhật host nếu cần...${NC}"
    if ! grep -q "$PRIMARY_IP" /etc/hosts; then
        echo -e "${YELLOW}Thêm PRIMARY vào /etc/hosts...${NC}"
        echo "$PRIMARY_IP primary" | sudo tee -a /etc/hosts
    fi
    
    # Thêm node vào replica set với priority thấp
    echo -e "${YELLOW}18. Thêm node vào replica set...${NC}"
    local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
    try {
        rs.add({host:'$SERVER_IP:27017', priority:0.5});
        print('✅ Đã thêm node vào replica set với priority 0.5');
    } catch (err) {
        print('❌ Lỗi khi thêm: ' + err.message);
        print('Chi tiết lỗi: ' + err.toString());
    }
    " --quiet)
    echo "$add_result"
    
    if echo "$add_result" | grep -q "❌"; then
        echo -e "${RED}❌ Không thể thêm node vào replica set.${NC}"
        
        # Kiểm tra chi tiết hơn
        if echo "$add_result" | grep -q "already exists"; then
            echo -e "${YELLOW}Node đã tồn tại trong replica set. Thử force remove và thêm lại...${NC}"
            
            mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
            try {
                rs.remove('$SERVER_IP:27017');
                print('✅ Đã xóa node khỏi replica set');
                sleep(2000);
                rs.add({host:'$SERVER_IP:27017', priority:0.5});
                print('✅ Đã thêm lại node vào replica set');
            } catch (err) {
                print('❌ Lỗi: ' + err.message);
            }
            " --quiet
        fi
        
        return 1
    fi
    
    # Đợi node đồng bộ
    echo -e "${YELLOW}19. Đợi node đồng bộ (60 giây)...${NC}"
    echo -e "Đây là thời gian cần thiết để node đồng bộ dữ liệu với PRIMARY."
    local seconds=60
    while [ $seconds -gt 0 ]; do
        echo -ne "${YELLOW}Còn lại: ${seconds}s${NC}\r"
        sleep 5
        seconds=$((seconds-5))
        
        # Kiểm tra nhanh sau 30 giây để xem node đã lên SECONDARY chưa
        if [ $seconds -eq 30 ]; then
            echo -e "${YELLOW}Kiểm tra trạng thái giữa chừng...${NC}"
            local current_status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
            rs.status().members.forEach(function(m) {
                if(m.name == '$SERVER_IP:27017') {
                    print('Trạng thái: ' + m.stateStr);
                    if(m.stateStr != 'SECONDARY') {
                        print('Health: ' + m.health);
                        print('Uptime: ' + m.uptime);
                        if(m.lastHeartbeat) print('Last heartbeat: ' + m.lastHeartbeat);
                        if(m.syncSourceHost) print('Sync source: ' + m.syncSourceHost);
                    }
                }
            })
            " --quiet)
            echo -e "\n${YELLOW}Trạng thái hiện tại: $current_status${NC}"
            
            # Nếu node not reachable, thử khắc phục
            if echo "$current_status" | grep -q "not reachable"; then
                echo -e "${RED}❌ Node không reachable, thử khắc phục...${NC}"
                echo -e "${YELLOW}1. Kiểm tra MongoDB đang chạy không...${NC}"
                sudo systemctl status mongod --no-pager
                
                echo -e "${YELLOW}2. Kiểm tra log...${NC}"
                sudo tail -n 30 /var/log/mongodb/mongod.log
                
                echo -e "${YELLOW}3. Thử khởi động lại MongoDB...${NC}"
                sudo systemctl restart mongod
                sleep 10
                
                echo -e "${YELLOW}4. Kiểm tra kết nối sau khi khởi động lại...${NC}"
                mongosh --host localhost --port 27017 --eval "db.version()" --quiet || echo -e "${RED}❌ Vẫn không thể kết nối tới MongoDB cục bộ${NC}"
            fi
            
            if echo "$current_status" | grep -q "SECONDARY"; then
                echo -e "${GREEN}✅ Node đã lên SECONDARY!${NC}"
                seconds=0
            fi
        fi
    done
    
    # Kiểm tra trạng thái cuối cùng
    echo -e "${YELLOW}20. Kiểm tra trạng thái cuối cùng...${NC}"
    local final_status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
    var found = false;
    rs.status().members.forEach(function(m) {
        if(m.name == '$SERVER_IP:27017') {
            found = true;
            print('Trạng thái: ' + m.stateStr);
            print('Health: ' + m.health);
            if(m.stateStr != 'SECONDARY') {
                print('Thông tin chi tiết:');
                print('Uptime: ' + m.uptime);
                if(m.lastHeartbeat) print('Last heartbeat: ' + m.lastHeartbeat);
                if(m.syncSourceHost) print('Sync source: ' + m.syncSourceHost);
                if(m.infoMessage) print('Info message: ' + m.infoMessage);
            }
        }
    });
    if(!found) print('❌ Node không tìm thấy trong replica set');
    " --quiet)
    echo "$final_status"
    
    if echo "$final_status" | grep -q "SECONDARY"; then
        echo -e "${GREEN}✅ Node đã lên SECONDARY thành công!${NC}"
        
        # Tăng priority lên 1
        echo -e "${YELLOW}21. Tăng priority lên 1...${NC}"
        local update_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
        var conf = rs.conf();
        for(var i = 0; i < conf.members.length; i++) {
            if(conf.members[i].host == '$SERVER_IP:27017') {
                conf.members[i].priority = 1;
                print('✅ Đã cập nhật priority thành 1');
            }
        }
        rs.reconfig(conf);
        " --quiet)
        echo "$update_result"
        
        echo -e "${GREEN}====================================${NC}"
        echo -e "${GREEN}✅ THIẾT LẬP SECONDARY THÀNH CÔNG${NC}"
        echo -e "${GREEN}====================================${NC}"
        
        # Hiển thị lệnh kết nối
        echo -e "${GREEN}Lệnh kết nối tới SECONDARY:${NC}"
        echo "mongosh --host $SERVER_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin"
        echo ""
        
        return 0
    else
        echo -e "${RED}❌ Node chưa lên SECONDARY sau khi thiết lập${NC}"
        echo -e "${YELLOW}Kiểm tra log MongoDB:${NC}"
        sudo tail -n 30 /var/log/mongodb/mongod.log
        
        echo -e "${YELLOW}Gợi ý: ${NC}"
        echo "1. Kiểm tra port 27017 đã mở trên cả hai server chưa"
        echo "2. Kiểm tra keyfile có giống nhau giữa các node không"
        echo "3. Xem log để tìm chi tiết lỗi (sudo tail -n 100 /var/log/mongodb/mongod.log)"
        echo "4. Đảm bảo IP được cấu hình đúng (không dùng localhost)"
        echo "5. Kiểm tra firewall: sudo ufw status"
        return 1
    fi
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
        echo "0. Quay lại menu chính"
        
        read -p "Chọn tùy chọn (0-2): " option
        
        case $option in
            1)
                setup_primary "$SERVER_IP"
                ;;
            2)
                read -p "Nhập địa chỉ IP của PRIMARY: " PRIMARY_IP
                setup_secondary "$SERVER_IP" "$PRIMARY_IP"
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