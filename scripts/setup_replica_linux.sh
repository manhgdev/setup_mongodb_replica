#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

# Default admin credentials
ADMIN_USER="manhg"
ADMIN_PASS="manhnk"

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Stop all MongoDB services
    for port in 27017 27018 27019; do
        sudo systemctl stop mongod_${port} 2>/dev/null || true
    done
    
    # Kill any processes using MongoDB ports
    for port in 27017 27018 27019; do
        echo "Killing processes on port $port..."
        # Kill using lsof
        lsof -ti:$port | xargs kill -9 2>/dev/null || true
        # Kill using fuser
        fuser -k $port/tcp 2>/dev/null || true
        # Kill using netstat
        netstat -tulpn 2>/dev/null | grep ":$port" | awk '{print $7}' | cut -d'/' -f1 | xargs kill -9 2>/dev/null || true
    done
    
    # Wait for ports to be free
    sleep 5
    
    # Verify ports are free
    for port in 27017 27018 27019; do
        if lsof -i:$port &>/dev/null || netstat -tulpn 2>/dev/null | grep -q ":$port"; then
            echo -e "${RED}❌ Port $port is still in use${NC}"
            echo "Trying to kill again..."
            lsof -ti:$port | xargs kill -9 2>/dev/null || true
            fuser -k $port/tcp 2>/dev/null || true
            sleep 2
        fi
    done
    
    echo -e "${GREEN}✅ All MongoDB processes stopped successfully${NC}"
}

# Create directories
create_dirs() {
    local PORT=$1
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    mkdir -p $DB_PATH $LOG_PATH
    chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    chmod 755 $DB_PATH
}

# Create MongoDB config
create_config() {
    local PORT=$1
    local IS_INITIAL_SETUP=$2
    local IS_ARBITER=$3
    local WITH_SECURITY=$4
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Create config file
    cat > $CONFIG_FILE << EOF
# mongod.conf

# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

# Where and how to store data.
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

# network interfaces
net:
  port: ${PORT}
  bindIp: 0.0.0.0

# how the process runs
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  # fork: true

EOF

    # Chỉ thêm security nếu WITH_SECURITY = true
    if [ "$WITH_SECURITY" = "true" ]; then
        cat >> $CONFIG_FILE << EOF
# security
security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled
EOF
    fi

    # Phần replication luôn được thêm
    cat >> $CONFIG_FILE << EOF
# replication
replication:
  replSetName: rs0

# Cho phép nhiều arbiter
setParameter:
  allowMultipleArbiters: true
EOF
    
    # Set permissions
    chown mongodb:mongodb $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
}

# Fix MongoDB startup issues
fix_mongodb_startup() {
    local PORT=$1
    
    echo "Attempting to fix MongoDB startup for port $PORT..."
    
    # Check if process is already running
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo "MongoDB process for port $PORT is already running"
        return 0
    fi
    
    # Check logs
    echo "Checking MongoDB logs..."
    if [ -f "/var/log/mongodb/mongod_${PORT}.log" ]; then
        local auth_errors=$(grep -i "auth" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        local perm_errors=$(grep -i "permission" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        local keyfile_errors=$(grep -i "keyfile" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        
        if [ ! -z "$auth_errors" ]; then
            echo "Authentication errors found:"
            echo "$auth_errors"
        fi
        
        if [ ! -z "$perm_errors" ]; then
            echo "Permission errors found:"
            echo "$perm_errors"
            
            # Fix data directory permissions
            local DB_PATH="/var/lib/mongodb_${PORT}"
            echo "Fixing data directory permissions..."
            sudo mkdir -p $DB_PATH
            sudo chown -R mongodb:mongodb $DB_PATH
            sudo chmod -R 755 $DB_PATH
        fi
        
        if [ ! -z "$keyfile_errors" ]; then
            echo "Keyfile errors found:"
            echo "$keyfile_errors"
            
            # Fix keyfile permissions
            echo "Fixing keyfile permissions..."
            sudo chown mongodb:mongodb /etc/mongodb.keyfile
            sudo chmod 400 /etc/mongodb.keyfile
        fi
    fi
    
    # Try starting mongod manually first to see errors
    echo "Starting MongoDB manually to check for errors..."
    sudo -u mongodb mongod --config /etc/mongod_${PORT}.conf
    sleep 5
    
    # Check if process started
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo -e "${GREEN}✅ MongoDB started successfully using manual command${NC}"
        return 0
    fi
    
    echo "Failed to start MongoDB manually. Starting without config to check for basic startup issues..."
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb/mongod_${PORT}.log"
    
    # Try starting with minimal options
    sudo -u mongodb mongod --dbpath $DB_PATH --port $PORT --fork --logpath $LOG_PATH
    sleep 5
    
    # Check if process started
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo -e "${GREEN}✅ MongoDB started with minimal options${NC}"
        # Stop it
        sudo mongod --dbpath $DB_PATH --port $PORT --shutdown
        sleep 5
        echo "Issue might be with the config file. Check above for specific errors."
    else
        echo -e "${RED}❌ Could not start MongoDB even with minimal options${NC}"
        echo "This might indicate a deeper issue with MongoDB installation or system configuration."
        echo "Checking system resources..."
        echo "Disk space:"
        df -h
        echo "Memory:"
        free -m
    fi
    
    return 1
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    stop_mongodb
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER1_PORT
    create_dirs $ARBITER2_PORT
    
    # Configure firewall
    configure_firewall
    
    # Create initial configs WITHOUT security
    create_config $PRIMARY_PORT true false false
    create_config $ARBITER1_PORT true true false 
    create_config $ARBITER2_PORT true true false
    
    # Start all nodes
    echo "Starting PRIMARY node..."
    mongod --config /etc/mongod_27017.conf --fork
    sleep 5
    
    # Check if PRIMARY is running
    if ! mongosh --port $PRIMARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start PRIMARY node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27017.log
        return 1
    fi
    
    echo "Starting ARBITER 1 node..."
    mongod --config /etc/mongod_27018.conf --fork
    sleep 5
    
    # Check if ARBITER 1 is running
    if ! mongosh --port $ARBITER1_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start ARBITER 1 node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27018.log
        return 1
    fi
    
    echo "Starting ARBITER 2 node..."
    mongod --config /etc/mongod_27019.conf --fork
    sleep 5
    
    # Check if ARBITER 2 is running
    if ! mongosh --port $ARBITER2_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start ARBITER 2 node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27019.log
        return 1
    fi
    
    # Initialize replica set using private IP
    echo "Initializing replica set..."
    local init_result=$(mongosh --port $PRIMARY_PORT --eval "
rs.initiate({
    _id: 'rs0',
    members: [
        { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 },
        { _id: 1, host: '$SERVER_IP:$ARBITER1_PORT', arbiterOnly: true, priority: 0 },
        { _id: 2, host: '$SERVER_IP:$ARBITER2_PORT', arbiterOnly: true, priority: 0 }
    ]
})")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize replica set${NC}"
        echo "Error: $init_result"
        echo "Checking node statuses..."
        echo "PRIMARY node status:"
        mongosh --port $PRIMARY_PORT --eval "db.serverStatus()" --quiet
        echo "ARBITER 1 node status:"
        mongosh --port $ARBITER1_PORT --eval "db.serverStatus()" --quiet
        echo "ARBITER 2 node status:"
        mongosh --port $ARBITER2_PORT --eval "db.serverStatus()" --quiet
        return 1
    fi
    
    echo "Waiting for PRIMARY election..."
    sleep 20
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
        echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
        echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
        
        # Create admin user with default values
        create_admin_user $PRIMARY_PORT $ADMIN_USER $ADMIN_PASS || return 1
        
        # Create keyfile and update configs WITH security
        create_keyfile "/etc/mongodb.keyfile"
        create_config $PRIMARY_PORT true false true
        create_config $ARBITER1_PORT true true true
        create_config $ARBITER2_PORT true true true
        
        # Create systemd services
        echo "Creating systemd services..."
        create_systemd_service $PRIMARY_PORT || return 1
        create_systemd_service $ARBITER1_PORT || return 1
        create_systemd_service $ARBITER2_PORT || return 1
        
        # Restart services with security
        echo "Restarting services with security..."
        sudo systemctl restart mongod_27017
        sleep 5
        sudo systemctl restart mongod_27018
        sleep 5
        sudo systemctl restart mongod_27019
        sleep 5
        
        # Verify connection with auth
        echo "Verifying connection with authentication..."
        local auth_result=$(mongosh --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Authentication verified successfully${NC}"
            echo -e "\n${GREEN}Connection Commands:${NC}"
            echo "1. Connect to PRIMARY:"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "2. Connect to ARBITER 1:"
            echo "mongosh --host $SERVER_IP --port $ARBITER1_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "3. Connect to ARBITER 2:"
            echo "mongosh --host $SERVER_IP --port $ARBITER2_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "4. Connect to Replica Set:"
            echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@$SERVER_IP:$PRIMARY_PORT,$SERVER_IP:$ARBITER1_PORT,$SERVER_IP:$ARBITER2_PORT/admin?replicaSet=rs0\""
        else
            echo -e "${RED}❌ Authentication verification failed${NC}"
            echo "Error details:"
            echo "$auth_result"
            echo "Trying to check MongoDB status..."
            sudo systemctl status mongod_27017
            sudo systemctl status mongod_27018
            sudo systemctl status mongod_27019
            return 1
        fi
    else
        echo -e "${RED}❌ Replica set initialization failed - Node not promoted to PRIMARY${NC}"
        echo "Current status:"
        echo "$status"
        return 1
    fi
}

# Setup SECONDARY server
setup_secondary() {
    local SERVER_IP=$1
    local SECONDARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    
    clear
    echo -e "${BLUE}=== THIẾT LẬP SECONDARY SERVER CHO MONGODB REPLICA SET ===${NC}"
    
    # Lấy thông tin PRIMARY
    read -p "Nhập IP của PRIMARY server: " PRIMARY_IP
    [ -z "$PRIMARY_IP" ] && echo -e "${RED}❌ Cần IP của PRIMARY server${NC}" && return 1
    
    # Kiểm tra kết nối đến PRIMARY
    echo -e "${YELLOW}Kiểm tra kết nối đến PRIMARY server...${NC}"
    if ! nc -z -w5 $PRIMARY_IP 27017 &>/dev/null; then
        echo -e "${RED}❌ Không thể kết nối đến PRIMARY server $PRIMARY_IP:27017${NC}"
        echo -e "${YELLOW}Vui lòng kiểm tra:${NC}"
        echo -e "  - PRIMARY server đang chạy"
        echo -e "  - Cổng 27017 đã mở"
        echo -e "  - Kết nối mạng giữa hai server"
        return 1
    fi
    echo -e "${GREEN}✓ Kết nối thành công đến PRIMARY server${NC}"
    
    # Kiểm tra xác thực trên PRIMARY
    echo -e "${YELLOW}Kiểm tra xác thực trên PRIMARY server...${NC}"
    NEED_AUTH=false
    if mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.version()" --quiet &>/dev/null; then
        NEED_AUTH=true
        echo -e "${GREEN}✓ PRIMARY server có xác thực, sẽ thiết lập SECONDARY với xác thực${NC}"
    else
        # Thử kết nối không xác thực
        if mongosh --host $PRIMARY_IP --port 27017 --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${YELLOW}⚠️ PRIMARY server không có xác thực${NC}"
        else
            echo -e "${RED}❌ Không thể kết nối đến PRIMARY server - kiểm tra xác thực và kết nối${NC}"
            return 1
        fi
    fi
    
    # Dọn dẹp môi trường hiện tại
    echo -e "${YELLOW}Dọn dẹp môi trường MongoDB hiện tại...${NC}"
    {
        # Dừng dịch vụ
        sudo systemctl stop mongod_27017 mongod_27018 mongod_27019 &>/dev/null || true
        sudo systemctl stop mongod &>/dev/null || true
        sleep 2
        
        # Kill các process
        sudo pkill -f mongod &>/dev/null || true
        sleep 1
        sudo pkill -9 -f mongod &>/dev/null || true
        sleep 2
        
        # Kill các process trên cổng cụ thể
        for port in 27017 27018 27019; do
            PID=$(sudo lsof -ti:$port 2>/dev/null)
            if [ ! -z "$PID" ]; then
                sudo kill -9 $PID &>/dev/null || true
            fi
        done
        
        # Xóa các file socket và lock
        sudo rm -f /tmp/mongodb-*.sock
        sudo rm -f /var/lib/mongodb_*/mongod.lock
        sudo rm -f /var/lib/mongodb_*/WiredTiger.lock
        
        # Xóa dữ liệu cũ
        sudo rm -rf /var/lib/mongodb_27017/* /var/lib/mongodb_27018/* /var/lib/mongodb_27019/*
    } &>/dev/null
    echo -e "${GREEN}✓ Đã dọn dẹp môi trường${NC}"
    
    
    # Tạo thư mục cần thiết
    echo -e "${YELLOW}Tạo thư mục dữ liệu và log...${NC}"
    {
        for port in $SECONDARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
            sudo mkdir -p /var/lib/mongodb_${port}
            sudo mkdir -p /var/log/mongodb
            sudo chmod 770 /var/lib/mongodb_${port}
            sudo chown -R mongodb:mongodb /var/lib/mongodb_${port}
            sudo chown -R mongodb:mongodb /var/log/mongodb
        done
    } &>/dev/null
    echo -e "${GREEN}✓ Đã tạo thư mục dữ liệu và log${NC}"
    
    # BƯỚC 1: KHỞI ĐỘNG KHÔNG AUTH - CHỈ SECONDARY
    echo -e "${BLUE}BƯỚC 1: KHỞI ĐỘNG SECONDARY KHÔNG XÁC THỰC${NC}"
    echo -e "${YELLOW}Tạo file cấu hình tạm thời...${NC}"
    {
        sudo bash -c "cat > /etc/mongod_27017_temp.conf << EOF
storage:
  dbPath: /var/lib/mongodb_27017
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_27017.log
net:
  port: 27017
  bindIp: 0.0.0.0
replication:
  replSetName: rs0
EOF"
        sudo chown mongodb:mongodb /etc/mongod_27017_temp.conf
        sudo chmod 644 /etc/mongod_27017_temp.conf
    } &>/dev/null
    echo -e "${GREEN}✓ Đã tạo file cấu hình tạm thời${NC}"
    
    # Khởi động MongoDB tạm thời
    echo -e "${YELLOW}Khởi động MongoDB tạm thời...${NC}"
    sudo -u mongodb mongod --config /etc/mongod_27017_temp.conf --fork &>/dev/null
    sleep 5
    
    # Kiểm tra xem MongoDB đã chạy chưa
    if ! pgrep -f "mongod.*27017" > /dev/null; then
        echo -e "${RED}❌ Không thể khởi động MongoDB tạm thời${NC}"
        echo -e "${YELLOW}Log lỗi:${NC}"
        sudo cat /var/log/mongodb/mongod_27017.log | tail -n 20
        return 1
    fi
    echo -e "${GREEN}✓ MongoDB tạm thời đã khởi động${NC}"
    
    # Khởi tạo replica set đơn giản trên local
    echo -e "${YELLOW}Khởi tạo replica set cục bộ...${NC}"
    sleep 2
    INIT_RESULT=$(mongosh --port 27017 --eval "
    try {
        rs.initiate({
            _id: 'rs0',
            members: [{_id: 0, host: 'localhost:27017'}]
        });
        print('SUCCESS');
    } catch(e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if [[ "$INIT_RESULT" == *"SUCCESS"* ]] || [[ "$INIT_RESULT" == *"already initialized"* ]]; then
        echo -e "${GREEN}✓ Đã khởi tạo replica set cục bộ${NC}"
    else
        echo -e "${YELLOW}⚠️ Không thể khởi tạo replica set: $INIT_RESULT${NC}"
    fi
    sleep 5
    
    # Tạo admin user nếu cần
    if [ "$NEED_AUTH" = true ]; then
        echo -e "${YELLOW}Tạo admin user...${NC}"
        CREATE_USER_RESULT=$(mongosh --port 27017 --eval "
        try {
            db.getSiblingDB('admin').createUser({
                user: '$ADMIN_USER',
                pwd: '$ADMIN_PASS',
                roles: [
                    {role: 'root', db: 'admin'},
                    {role: 'clusterAdmin', db: 'admin'},
                    {role: 'userAdminAnyDatabase', db: 'admin'},
                    {role: 'dbAdminAnyDatabase', db: 'admin'},
                    {role: 'readWriteAnyDatabase', db: 'admin'}
                ]
            });
            print('SUCCESS');
        } catch(e) {
            print('ERROR: ' + e.message);
        }" --quiet)
        
        if [[ "$CREATE_USER_RESULT" == *"SUCCESS"* ]]; then
            echo -e "${GREEN}✓ Đã tạo admin user${NC}"
        else
            echo -e "${YELLOW}⚠️ Có lỗi khi tạo user: $CREATE_USER_RESULT${NC}"
        fi
    fi
    
    # Tắt MongoDB tạm thời
    echo -e "${YELLOW}Tắt MongoDB tạm thời...${NC}"
    {
        mongosh --port 27017 --eval "db.adminCommand({shutdown:1})" --quiet || true
        sleep 3
        sudo pkill -f "mongod.*27017" &>/dev/null || true
        sleep 2
    } &>/dev/null
    echo -e "${GREEN}✓ Đã tắt MongoDB tạm thời${NC}"
    
    # BƯỚC 2: TẠO CẤU HÌNH CHÍNH THỨC
    echo -e "${BLUE}BƯỚC 2: TẠO CẤU HÌNH CHÍNH THỨC${NC}"
    echo -e "${YELLOW}Tạo cấu hình cho các node...${NC}"
    {
        # Cấu hình SECONDARY
        local security_config=""
        if [ "$NEED_AUTH" = true ]; then
            security_config="security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled"
        fi
        
        # Tạo cấu hình SECONDARY
        sudo bash -c "cat > /etc/mongod_27017.conf << EOF
storage:
  dbPath: /var/lib/mongodb_27017
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_27017.log
net:
  port: 27017
  bindIp: 0.0.0.0,127.0.0.1
replication:
  replSetName: rs0
$security_config
setParameter:
  allowMultipleArbiters: true
EOF"

        # Tạo cấu hình cho ARBITER
        for port in 27018 27019; do
            sudo bash -c "cat > /etc/mongod_${port}.conf << EOF
storage:
  dbPath: /var/lib/mongodb_${port}
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_${port}.log
net:
  port: ${port}
  bindIp: 0.0.0.0,127.0.0.1
replication:
  replSetName: rs0
$security_config
setParameter:
  allowMultipleArbiters: true
EOF"
        done
        
        # Set quyền
        sudo chown mongodb:mongodb /etc/mongod_*.conf
        sudo chmod 644 /etc/mongod_*.conf
        
        # Tạo systemd service
        for port in 27017 27018 27019; do
            sudo bash -c "cat > /etc/systemd/system/mongod_${port}.service << EOF
[Unit]
Description=MongoDB Database Server (Port ${port})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod_${port}.conf
ExecStop=/usr/bin/mongod --config /etc/mongod_${port}.conf --shutdown

[Install]
WantedBy=multi-user.target
EOF"
        done
        
        sudo systemctl daemon-reload
    } &>/dev/null
    echo -e "${GREEN}✓ Đã tạo cấu hình chính thức${NC}"
    
    # BƯỚC 3: KHỞI ĐỘNG VỚI AUTHENTICATION
    echo -e "${BLUE}BƯỚC 3: KHỞI ĐỘNG CÁC NODE MONGODB${NC}"
    
    # Khởi động SECONDARY
    echo -e "${YELLOW}Khởi động SECONDARY node...${NC}"
    sudo systemctl start mongod_27017
    sleep 5
    
    # Kiểm tra SECONDARY đã chạy chưa
    if ! pgrep -f "mongod.*27017" > /dev/null; then
        echo -e "${RED}❌ Không thể khởi động SECONDARY${NC}"
        echo -e "${YELLOW}Log lỗi:${NC}"
        sudo cat /var/log/mongodb/mongod_27017.log | tail -n 20
        return 1
    fi
    echo -e "${GREEN}✓ SECONDARY đã khởi động thành công${NC}"
    
    # Kiểm tra kết nối local 
    if [ "$NEED_AUTH" = true ]; then
        echo -e "${YELLOW}Kiểm tra kết nối local với xác thực...${NC}"
        if ! mongosh --host 127.0.0.1 --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Không thể kết nối đến SECONDARY local với xác thực${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Kết nối local thành công${NC}"
    else
        echo -e "${YELLOW}Kiểm tra kết nối local...${NC}"
        if ! mongosh --host 127.0.0.1 --port 27017 --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Không thể kết nối đến SECONDARY local${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Kết nối local thành công${NC}"
    fi
    
    # Khởi động ARBITER
    echo -e "${YELLOW}Khởi động các ARBITER node...${NC}"
    sudo systemctl start mongod_27018 mongod_27019
    sleep 5
    echo -e "${GREEN}✓ Các ARBITER đã khởi động${NC}"
    
    # BƯỚC 4: THÊM VÀO REPLICA SET
    echo -e "${BLUE}BƯỚC 4: THÊM VÀO REPLICA SET${NC}"
    echo -e "${YELLOW}Kiểm tra kết nối đến PRIMARY...${NC}"
    
    # Chuẩn bị lệnh kết nối đến PRIMARY
    local auth_params=""
    if [ "$NEED_AUTH" = true ]; then
        auth_params="-u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    fi
    
    # Kiểm tra kết nối đến PRIMARY
    if [ "$NEED_AUTH" = true ]; then
        if ! mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Không thể kết nối đến PRIMARY với xác thực${NC}"
            return 1
        fi
    else
        if ! mongosh --host $PRIMARY_IP --port 27017 --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Không thể kết nối đến PRIMARY${NC}"
            return 1
        fi
    fi
    echo -e "${GREEN}✓ Kết nối đến PRIMARY thành công${NC}"
    
    # Thêm các node vào replica set
    echo -e "${YELLOW}Thêm SECONDARY node vào replica set...${NC}"
    ADD_RESULT=$(mongosh --host $PRIMARY_IP --port 27017 $auth_params --eval "
    try {
        rs.add('$SERVER_IP:27017');
        print('SUCCESS');
    } catch(e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if [[ "$ADD_RESULT" == *"SUCCESS"* ]] || [[ "$ADD_RESULT" == *"already a member"* ]]; then
        echo -e "${GREEN}✓ Đã thêm SECONDARY vào replica set${NC}"
    else
        echo -e "${RED}❌ Không thể thêm SECONDARY: $ADD_RESULT${NC}"
    fi
    sleep 5
    
    echo -e "${YELLOW}Thêm ARBITER 1 vào replica set...${NC}"
    ADD_ARB1_RESULT=$(mongosh --host $PRIMARY_IP --port 27017 $auth_params --eval "
    try {
        rs.addArb('$SERVER_IP:27018');
        print('SUCCESS');
    } catch(e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if [[ "$ADD_ARB1_RESULT" == *"SUCCESS"* ]] || [[ "$ADD_ARB1_RESULT" == *"already a member"* ]]; then
        echo -e "${GREEN}✓ Đã thêm ARBITER 1 vào replica set${NC}"
    else
        echo -e "${YELLOW}⚠️ Không thể thêm ARBITER 1: $ADD_ARB1_RESULT${NC}"
    fi
    sleep 5
    
    echo -e "${YELLOW}Thêm ARBITER 2 vào replica set...${NC}"
    ADD_ARB2_RESULT=$(mongosh --host $PRIMARY_IP --port 27017 $auth_params --eval "
    try {
        rs.addArb('$SERVER_IP:27019');
        print('SUCCESS');
    } catch(e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if [[ "$ADD_ARB2_RESULT" == *"SUCCESS"* ]] || [[ "$ADD_ARB2_RESULT" == *"already a member"* ]]; then
        echo -e "${GREEN}✓ Đã thêm ARBITER 2 vào replica set${NC}"
    else
        echo -e "${YELLOW}⚠️ Không thể thêm ARBITER 2: $ADD_ARB2_RESULT${NC}"
    fi
    
    # Thiết lập service khởi động cùng hệ thống
    echo -e "${YELLOW}Thiết lập service khởi động cùng hệ thống...${NC}"
    sudo systemctl enable mongod_27017 mongod_27018 mongod_27019 &>/dev/null
    echo -e "${GREEN}✓ Đã thiết lập service khởi động cùng hệ thống${NC}"
    
    # Xóa file cấu hình tạm thời
    sudo rm -f /etc/mongod_27017_temp.conf &>/dev/null
    
    # Hiển thị trạng thái replica set
    echo -e "${YELLOW}Trạng thái replica set:${NC}"
    mongosh --host $PRIMARY_IP --port 27017 $auth_params --eval "
    rs.status().members.forEach(function(member) {
        print(member.name + ' - ' + member.stateStr + 
              (member.stateStr === 'PRIMARY' ? ' ⭐' : 
               member.stateStr === 'SECONDARY' ? ' 🔄' : 
               member.stateStr === 'ARBITER' ? ' ⚖️' : ''));
    });" --quiet
    
    # Hoàn tất
    echo ""
    echo -e "${GREEN}=== THIẾT LẬP SECONDARY THÀNH CÔNG ===${NC}"
    
    # Connection string
    echo -e "${BLUE}Connection string cho ứng dụng:${NC}"
    if [ "$NEED_AUTH" = true ]; then
        echo -e "${GREEN}mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:27017,$SERVER_IP:27017/admin?replicaSet=rs0&readPreference=primary&retryWrites=true&w=majority${NC}"
    else
        echo -e "${GREEN}mongodb://$PRIMARY_IP:27017,$SERVER_IP:27017/admin?replicaSet=rs0&readPreference=primary&retryWrites=true&w=majority${NC}"
    fi
    
    # Lệnh kiểm tra
    echo -e "${BLUE}Lệnh kiểm tra replica set:${NC}"
    if [ "$NEED_AUTH" = true ]; then
        echo -e "${GREEN}mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval \"rs.status()\"${NC}"
    else
        echo -e "${GREEN}mongosh --host $PRIMARY_IP --port 27017 --eval \"rs.status()\"${NC}"
    fi
}

# Create keyfile
create_keyfile() {
  echo -e "${GREEN}Tạo keyfile xác thực...${NC}"
  local keyfile=${1:-"/etc/mongodb.keyfile"}
  
  if [ ! -f "$keyfile" ]; then
    openssl rand -base64 756 | sudo tee $keyfile > /dev/null
    sudo chmod 400 $keyfile
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $keyfile
    echo -e "${GREEN}✅ Đã tạo keyfile tại $keyfile${NC}"
  else
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $keyfile
    sudo chmod 400 $keyfile
    echo -e "${GREEN}✅ Keyfile đã tồn tại tại $keyfile${NC}"
  fi
}

# Create admin user
create_admin_user() {
    local PORT=$1
    local USERNAME=$2
    local PASSWORD=$3
    
    echo "Creating admin user..."
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
        echo -e "${RED}❌ Failed to create admin user${NC}"
        echo "Error: $result"
        return 1
    fi
    echo -e "${GREEN}✅ Admin user created successfully${NC}"
}

# Start MongoDB
start_mongodb() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    
    echo "Starting MongoDB nodes..."
    setup_node $PRIMARY_PORT || return 1
    setup_node $ARBITER1_PORT || return 1
    setup_node $ARBITER2_PORT || return 1
    
    echo -e "${GREEN}✅ All MongoDB nodes started successfully${NC}"
}

# Create systemd service
create_systemd_service() {
    local PORT=$1
    local SERVICE_NAME="mongod_${PORT}"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server (Port ${PORT})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME
    
    if sudo systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ Service ${SERVICE_NAME} created and started successfully${NC}"
        echo "Service will auto-start on system boot"
    else
        echo -e "${RED}❌ Failed to start service ${SERVICE_NAME}${NC}"
        sudo systemctl status $SERVICE_NAME
        return 1
    fi
}

# Configure firewall
configure_firewall() {
    echo "Configuring firewall..."
    if command -v ufw &> /dev/null; then
        echo "UFW is installed, configuring ports..."
        sudo ufw allow 27017/tcp
        sudo ufw allow 27018/tcp
        sudo ufw allow 27019/tcp
        echo -e "${GREEN}✅ Firewall configured successfully${NC}"
    else
        echo "UFW is not installed, skipping firewall configuration"
    fi
}

# Dọn dẹp môi trường MongoDB
cleanup_mongodb() {
    echo "Cleaning up MongoDB environment..."
    
    # Dừng tất cả dịch vụ MongoDB
    stop_mongodb
    
    # Xóa các socket cũ
    echo "Removing old socket files..."
    sudo rm -f /tmp/mongodb-*.sock
    
    # Xóa file lock
    echo "Removing lock files..."
    for port in 27017 27018 27019; do
        sudo rm -f /var/lib/mongodb_${port}/mongod.lock
        sudo rm -f /var/lib/mongodb_${port}/WiredTiger.lock
    done
    
    echo -e "${GREEN}✅ MongoDB environment cleaned up${NC}"
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
        2) setup_secondary $SERVER_IP ;;
        3) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


