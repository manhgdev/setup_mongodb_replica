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
    local PORT=27017
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    echo -e "${YELLOW}Tạo thư mục dữ liệu và log...${NC}"
    
    # Dừng dịch vụ trước khi tạo lại thư mục
    sudo systemctl stop mongod_${PORT} &>/dev/null || true
    sudo systemctl stop mongod &>/dev/null || true
    sleep 2
    
    # Xóa hoàn toàn thư mục dữ liệu cũ để tránh lỗi repl
    echo -e "${YELLOW}Xóa dữ liệu MongoDB cũ...${NC}"
    sudo rm -rf $DB_PATH/*
    sudo rm -f $LOG_PATH/mongod_${PORT}.log
    
    # Tạo thư mục với quyền hạn chặt chẽ
    sudo mkdir -p $DB_PATH $LOG_PATH
    
    # Cấp quyền đúng
    sudo chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    sudo chmod 750 $DB_PATH $LOG_PATH
    
    # Nếu có SELinux, cập nhật context
    if command -v sestatus &>/dev/null && sestatus | grep -q "enabled"; then
        echo "SELinux được kích hoạt, đang cập nhật context..."
        sudo chcon -R -t mongod_var_lib_t $DB_PATH 2>/dev/null || true
        sudo chcon -R -t mongod_log_t $LOG_PATH 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✅ Thư mục MongoDB đã được chuẩn bị${NC}"
}

# Create MongoDB config
create_config() {
    local PORT=27017
    local WITH_SECURITY=$1
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
    # Create config file
    sudo cat > $CONFIG_FILE << EOF
# mongod.conf
storage:
  dbPath: /var/lib/mongodb_${PORT}
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_${PORT}.log
  verbosity: 1

# network interfaces
net:
  port: ${PORT}
  bindIp: 0.0.0.0
  ipv6: false

# how the process runs
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  fork: false
EOF

    # Chỉ thêm security nếu WITH_SECURITY = true
    if [ "$WITH_SECURITY" = "true" ]; then
        sudo cat >> $CONFIG_FILE << EOF
# security
security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled
EOF
    fi

    # Phần replication luôn được thêm NHƯNG không thêm replSetName khi cài đặt lần đầu
    if [ "$2" = "no_repl" ]; then
        # Không thêm phần replication
        echo "Bỏ qua cấu hình replication cho lần cài đặt đầu tiên"
    else
        sudo cat >> $CONFIG_FILE << EOF
# replication
replication:
  replSetName: rs0
EOF
    fi
    
    # Set permissions
    sudo chown mongodb:mongodb $CONFIG_FILE
    sudo chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ File cấu hình đã tạo: $CONFIG_FILE${NC}"
}

# Create keyfile
create_keyfile() {
  echo -e "${YELLOW}Tạo keyfile xác thực...${NC}"
  local keyfile=${1:-"/etc/mongodb.keyfile"}
  
  if [ ! -f "$keyfile" ]; then
    openssl rand -base64 756 | sudo tee $keyfile > /dev/null
    sudo chmod 400 $keyfile
    sudo chown mongodb:mongodb $keyfile
    echo -e "${GREEN}✅ Đã tạo keyfile tại $keyfile${NC}"
  else
    sudo chown mongodb:mongodb $keyfile
    sudo chmod 400 $keyfile
    echo -e "${GREEN}✅ Keyfile đã tồn tại tại $keyfile${NC}"
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
    
    # Vô hiệu hóa và mask dịch vụ MongoDB mặc định
    sudo systemctl stop mongod &>/dev/null || true
    sudo systemctl disable mongod &>/dev/null || true
    sudo systemctl mask mongod &>/dev/null || true
    
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
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mongodb-${PORT}

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl unmask $SERVICE_NAME &>/dev/null || true
    sudo systemctl enable $SERVICE_NAME
    
    echo -e "${GREEN}✅ Dịch vụ ${SERVICE_NAME} đã được tạo${NC}"
}

# Start MongoDB and check status
start_mongodb() {
    local PORT=27017
    local SERVICE_NAME="mongod_${PORT}"
    
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Kiểm tra xung đột với dịch vụ mặc định
    if systemctl is-enabled mongod &>/dev/null && ! systemctl is-masked mongod &>/dev/null; then
        echo -e "${YELLOW}⚠️ Dịch vụ mongod mặc định đang được bật, đang vô hiệu hóa...${NC}"
        sudo systemctl stop mongod &>/dev/null || true
        sudo systemctl disable mongod &>/dev/null || true
        sudo systemctl mask mongod &>/dev/null || true
    fi
    
    # Kiểm tra và dừng MongoDB nếu đang chạy
    if sudo systemctl is-active --quiet $SERVICE_NAME; then
        sudo systemctl stop $SERVICE_NAME
        sleep 3
    fi
    
    # Dừng tất cả quy trình MongoDB đang chạy
    sudo pkill -f mongod || true
    sleep 2
    
    # Xóa lock file nếu tồn tại
    sudo rm -f /var/lib/mongodb_${PORT}/mongod.lock 2>/dev/null || true
    sudo rm -f /tmp/mongodb-*.sock 2>/dev/null || true
    
    # Kiểm tra lại quyền trước khi khởi động
    sudo chown -R mongodb:mongodb /var/lib/mongodb_${PORT} /var/log/mongodb
    sudo chmod 750 /var/lib/mongodb_${PORT} /var/log/mongodb
    sudo touch /var/log/mongodb/mongod_${PORT}.log
    sudo chown mongodb:mongodb /var/log/mongodb/mongod_${PORT}.log
    
    # Khởi động MongoDB qua systemd
    sudo systemctl daemon-reload
    sudo systemctl unmask $SERVICE_NAME &>/dev/null || true
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME
    
    # Đợi lâu hơn và kiểm tra nhiều lần
    echo "Đợi MongoDB khởi động..."
    for i in {1..10}; do
        sleep 3
        if sudo systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
            echo -e "${GREEN}✅ MongoDB đã được cài đặt thành công${NC}"
            
            # Hiển thị phiên bản MongoDB
            mongosh --quiet --eval "db.version()" || true
            
            return 0
        fi
        echo "Đang chờ... ($i/10)"
    done
    
    # Hiển thị thông tin lỗi chi tiết
    echo -e "${RED}✗ Không thể khởi động MongoDB qua systemd${NC}"
    echo "Trạng thái dịch vụ:"
    sudo systemctl status $SERVICE_NAME
    
    # Nếu systemd thất bại, thử khởi động trực tiếp
    echo -e "${YELLOW}Thử khởi động trực tiếp...${NC}"
    sudo -u mongodb mongod --config /etc/mongod_${PORT}.conf --fork --logpath /var/log/mongodb/mongod_direct.log
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ MongoDB đã khởi động thành công (trực tiếp)${NC}"
        echo -e "${YELLOW}⚠️ Dịch vụ systemd thất bại, nhưng MongoDB đang chạy trực tiếp${NC}"
        echo -e "${GREEN}✅ MongoDB đã được cài đặt thành công${NC}"
        
        # Hiển thị phiên bản MongoDB
        mongosh --quiet --eval "db.version()" || true
        
        return 0
    fi
    
    echo -e "${RED}✗ Không thể khởi động MongoDB bằng bất kỳ cách nào${NC}"
    echo "Xem log để biết thêm chi tiết:"
    sudo tail -n 30 /var/log/mongodb/mongod_direct.log
    
    return 1
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

# Kiểm tra và khắc phục lỗi node không reachable/healthy
check_and_fix_unreachable() {
    local SERVER_IP=$1
    local PORT=27017
    local ADMIN_USER=$2
    local ADMIN_PASS=$3
    
    echo -e "${YELLOW}Kiểm tra trạng thái node $SERVER_IP:$PORT...${NC}"
    
    # Kiểm tra kết nối tới node
    if ! ping -c 1 -W 1 $SERVER_IP &>/dev/null; then
        echo -e "${RED}❌ Không thể ping tới node $SERVER_IP${NC}"
        echo -e "${YELLOW}Kiểm tra tường lửa và kết nối mạng...${NC}"
        return 1
    fi
    
    # Kiểm tra port có đang lắng nghe không
    if ! nc -z -w 5 $SERVER_IP $PORT &>/dev/null; then
        echo -e "${RED}❌ Port $PORT không mở trên node $SERVER_IP${NC}"
        echo -e "${YELLOW}Kiểm tra tường lửa và dịch vụ MongoDB...${NC}"
        return 1
    fi
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    local status=$(mongosh --host $SERVER_IP --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    # Kiểm tra lỗi xác thực
    if echo "$status" | grep -q "AuthenticationFailed"; then
        echo -e "${RED}❌ Lỗi xác thực khi kết nối tới node $SERVER_IP:$PORT${NC}"
        echo -e "${YELLOW}Kiểm tra thông tin đăng nhập...${NC}"
        return 1
    fi
    
    # Kiểm tra node có trong replica set không
    if echo "$status" | grep -q "NotYetInitialized"; then
        echo -e "${RED}❌ Node $SERVER_IP:$PORT chưa được khởi tạo replica set${NC}"
        echo -e "${YELLOW}Khởi tạo replica set cho node...${NC}"
        
        # Khởi tạo replica set
        local init_result=$(mongosh --host $SERVER_IP --port $PORT --eval "
        rs.initiate({
            _id: 'rs0',
            members: [
                { _id: 0, host: '$SERVER_IP:$PORT', priority: 1 }
            ]
        })" --quiet)
        
        if echo "$init_result" | grep -q "ok"; then
            echo -e "${GREEN}✅ Đã khởi tạo replica set cho node $SERVER_IP:$PORT${NC}"
        else
            echo -e "${RED}❌ Không thể khởi tạo replica set cho node $SERVER_IP:$PORT${NC}"
            echo "Lỗi: $init_result"
            return 1
        fi
        
        # Đợi node khởi tạo
        echo -e "${YELLOW}Đợi node khởi tạo (10 giây)...${NC}"
        sleep 10
    fi
    
    # Kiểm tra node có reachable không
    if echo "$status" | grep -q "UNREACHABLE"; then
        echo -e "${RED}❌ Node $SERVER_IP:$PORT không reachable${NC}"
        echo -e "${YELLOW}Kiểm tra cấu hình mạng và tường lửa...${NC}"
        
        # Kiểm tra bindIp trong cấu hình
        echo -e "${YELLOW}Kiểm tra cấu hình bindIp...${NC}"
        local config=$(cat /etc/mongod_${PORT}.conf | grep -A 5 "net:")
        echo "Cấu hình hiện tại:"
        echo "$config"
        
        # Kiểm tra tường lửa
        echo -e "${YELLOW}Kiểm tra tường lửa...${NC}"
        if command -v ufw &> /dev/null; then
            echo "Trạng thái UFW:"
            sudo ufw status | grep $PORT
        elif command -v firewall-cmd &> /dev/null; then
            echo "Trạng thái firewalld:"
            sudo firewall-cmd --list-all
        else
            echo "Không tìm thấy tường lửa phổ biến"
        fi
        
        # Kiểm tra kết nối từ các node khác
        echo -e "${YELLOW}Kiểm tra kết nối từ các node khác...${NC}"
        local primary_status=$(mongosh --host localhost --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        local primary_host=$(echo "$primary_status" | grep -A 5 "PRIMARY" | grep "name" | awk -F'"' '{print $4}')
        
        if [ -n "$primary_host" ]; then
            echo "Kiểm tra kết nối từ PRIMARY ($primary_host) tới node $SERVER_IP:$PORT..."
            local check_result=$(mongosh --host $primary_host -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
            try {
                result = db.adminCommand({
                    ping: 1,
                    host: '$SERVER_IP:$PORT'
                });
                print('PING_RESULT: ' + JSON.stringify(result));
            } catch (e) {
                print('ERROR: ' + e.message);
            }
            " --quiet)
            
            echo "$check_result"
        fi
        
        return 1
    fi
    
    # Kiểm tra node có healthy không
    if echo "$status" | grep -q "SECONDARY" || echo "$status" | grep -q "PRIMARY"; then
        echo -e "${GREEN}✅ Node $SERVER_IP:$PORT đang hoạt động bình thường${NC}"
        return 0
    else
        echo -e "${RED}❌ Node $SERVER_IP:$PORT không healthy${NC}"
        echo "Trạng thái: $status"
        
        # Kiểm tra log
        echo -e "${YELLOW}Kiểm tra log MongoDB...${NC}"
        if [ -f "/var/log/mongodb/mongod_${PORT}.log" ]; then
            echo "10 dòng log cuối cùng:"
            sudo tail -n 10 /var/log/mongodb/mongod_${PORT}.log
        else
            echo "Không tìm thấy file log"
        fi
        
        # Kiểm tra tài nguyên hệ thống
        echo -e "${YELLOW}Kiểm tra tài nguyên hệ thống...${NC}"
        echo "CPU:"
        top -bn1 | head -n 5
        echo "Bộ nhớ:"
        free -h
        echo "Đĩa:"
        df -h
        
        return 1
    fi
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017

    echo -e "${GREEN}=== THIẾT LẬP MONGODB PRIMARY NODE ===${NC}"
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
    
    # Cách 1: Khởi tạo với localhost trước
    echo "Phương pháp 1: Khởi tạo với localhost"
    local init_result=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: 'localhost:$PRIMARY_PORT', priority: 10 }
        ]
    })" --quiet)
    
    if echo "$init_result" | grep -q "ok" && ! echo "$init_result" | grep -q "NotYetInitialized"; then
        echo -e "${GREEN}✅ Khởi tạo replica set với localhost thành công${NC}"
        success=true
        
        # Chờ một chút cho MongoDB ổn định
        sleep 10
        
        # Cập nhật cấu hình với IP thực
        echo "Cập nhật cấu hình với IP thực tế..."
        local update_result=$(mongosh --host localhost --port $PRIMARY_PORT --eval "
        var config = rs.conf();
        config.members[0].host = '$SERVER_IP:$PRIMARY_PORT';
        rs.reconfig(config, {force: true});" --quiet)
        
        if echo "$update_result" | grep -q "ok"; then
            echo -e "${GREEN}✅ Cập nhật cấu hình với IP thực tế thành công${NC}"
        else
            echo -e "${YELLOW}⚠️ Không thể cập nhật cấu hình, nhưng replica set đã hoạt động với localhost${NC}"
            echo "Lỗi: $update_result"
        fi
    else
        echo -e "${YELLOW}⚠️ Phương pháp 1 thất bại, đang thử phương pháp 2...${NC}"
        echo "Lỗi: $init_result"
        
        # Cách 2: Khởi tạo đơn giản
        echo "Phương pháp 2: Khởi tạo đơn giản"
        local init_result2=$(mongosh --host $CONNECT_HOST --port $PRIMARY_PORT --eval "rs.initiate()" --quiet)
        
        if echo "$init_result2" | grep -q "ok" && ! echo "$init_result2" | grep -q "NotYetInitialized"; then
            echo -e "${GREEN}✅ Khởi tạo replica set thành công (phương pháp 2)${NC}"
            success=true
        else
            echo -e "${YELLOW}⚠️ Phương pháp 2 thất bại, đang thử phương pháp 3...${NC}"
            echo "Lỗi: $init_result2"
            
            # Cách 3: Force khởi tạo
            echo "Phương pháp 3: Khởi tạo với localhost và force"
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
        create_admin_user $ADMIN_USER $ADMIN_PASS || return 1
        
        # Tạo keyfile
        create_keyfile "/etc/mongodb.keyfile"
        
        # Bật bảo mật và khởi động lại
        echo -e "${YELLOW}Khởi động lại với bảo mật...${NC}"
        create_systemd_service true
        if ! start_mongodb; then
            return 1
        fi
        
        # Xác minh kết nối với xác thực
        echo -e "${YELLOW}Xác minh kết nối với xác thực...${NC}"
        if verify_mongodb_connection true $ADMIN_USER $ADMIN_PASS $CONNECT_HOST; then
            echo -e "\n${GREEN}=== THIẾT LẬP MONGODB PRIMARY HOÀN TẤT ===${NC}"
            echo -e "${GREEN}Lệnh kết nối:${NC}"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo ""
            echo -e "${YELLOW}Lưu ý:${NC} Nếu không thể kết nối qua IP, sử dụng lệnh:"
            echo "mongosh --host localhost --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
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

    if [ -z "$PRIMARY_IP" ]; then
        read -p "Nhập địa chỉ IP của PRIMARY: " PRIMARY_IP
    fi

    echo -e "${GREEN}=== THIẾT LẬP MONGODB SECONDARY NODE ===${NC}"
    echo -e "${YELLOW}Khởi tạo MongoDB SECONDARY trên port $SECONDARY_PORT...${NC}"

    # Dừng và xóa dữ liệu cũ
    stop_mongodb
    
    # Tạo thư mục dữ liệu và log
    create_dirs
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Tạo cấu hình không có bảo mật
    create_config false
    
    # Tạo và khởi động dịch vụ
    create_systemd_service false
    if ! start_mongodb; then
        return 1
    fi
    
    # Kiểm tra kết nối
    if ! verify_mongodb_connection false "" "" $SERVER_IP; then
        return 1
    fi
    
    # Kết nối tới PRIMARY và thêm node này
    echo -e "${YELLOW}Thêm node vào Replica Set...${NC}"
    echo -e "${GREEN}Kết nối tới PRIMARY $PRIMARY_IP và thêm node $SERVER_IP:$SECONDARY_PORT${NC}"
    
    echo "Nhập thông tin đăng nhập PRIMARY:"
    read -p "Tên người dùng [$ADMIN_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$ADMIN_USER}
    read -sp "Mật khẩu [$ADMIN_PASS]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$ADMIN_PASS}
    echo ""
    
    local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
    rs.add('$SERVER_IP:$SECONDARY_PORT')")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Không thể thêm node vào Replica Set${NC}"
        echo "Lỗi: $add_result"
        return 1
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
        if ! check_and_fix_unreachable $SERVER_IP $SECONDARY_PORT $PRIMARY_USER $PRIMARY_PASS; then
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
    
    # Tạo keyfile
    create_keyfile "/etc/mongodb.keyfile"
    
    # Bật bảo mật và khởi động lại
    echo -e "${YELLOW}Khởi động lại với bảo mật...${NC}"
    create_systemd_service true
    if ! start_mongodb; then
        return 1
    fi
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra xem node mới có trong rs.status() không
    if echo "$status" | grep -q "$SERVER_IP:$SECONDARY_PORT"; then
        echo -e "\n${GREEN}=== THIẾT LẬP MONGODB SECONDARY HOÀN TẤT ===${NC}"
        echo -e "${GREEN}Lệnh kết nối:${NC}"
        echo "mongosh --host $SERVER_IP --port $SECONDARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin"
        
        # Hiển thị trạng thái chi tiết của node
        echo -e "${YELLOW}Trạng thái chi tiết của node $SERVER_IP:$SECONDARY_PORT:${NC}"
        echo "$status" | grep -A 10 "$SERVER_IP:$SECONDARY_PORT"
    else
        echo -e "${RED}❌ Node không xuất hiện trong Replica Set${NC}"
        echo "$status"
        return 1
    fi
}

# Main function
setup_replica_linux() {
    echo "MongoDB Replica Set Setup for Linux"
    echo "===================================="
    echo "1. Setup PRIMARY server"
    echo "2. Setup SECONDARY server"
    echo "3. Return to main menu"
    read -p "Select option (1-3): " option

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "Using server IP: $SERVER_IP"

    case $option in
        1) setup_primary $SERVER_IP ;;
        2) 
           read -p "Enter PRIMARY server IP: " PRIMARY_IP
           setup_secondary $SERVER_IP $PRIMARY_IP ;;
        3) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


