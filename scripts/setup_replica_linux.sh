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
    
    # Stop MongoDB service
    sudo systemctl stop mongod_27017 2>/dev/null || true
    
    # Kill any processes using MongoDB port
    echo "Killing processes on port 27017..."
    lsof -ti:27017 | xargs kill -9 2>/dev/null || true
    fuser -k 27017/tcp 2>/dev/null || true
    
    # Wait for port to be free
    sleep 3
    
    echo -e "${GREEN}✅ MongoDB process stopped successfully${NC}"
}

# Create directories
create_dirs() {
    local PORT=27017
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    mkdir -p $DB_PATH $LOG_PATH
    chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    chmod 755 $DB_PATH
}

# Create MongoDB config
create_config() {
    local PORT=27017
    local WITH_SECURITY=$1
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Create config file
    cat > $CONFIG_FILE << EOF
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

# network interfaces
net:
  port: ${PORT}
  bindIp: 0.0.0.0

# how the process runs
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
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
EOF
    
    # Set permissions
    chown mongodb:mongodb $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
}

# Create keyfile
create_keyfile() {
  echo -e "${GREEN}Tạo keyfile xác thực...${NC}"
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

# Create systemd service
create_systemd_service() {
    local PORT=27017
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
        echo -e "${GREEN}✅ Firewall configured successfully${NC}"
    else
        echo "UFW is not installed, skipping firewall configuration"
    fi
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017

    echo -e "${GREEN}Thiết lập MongoDB Replica Set trên port $PRIMARY_PORT${NC}"

    stop_mongodb
    create_dirs
    
    # Configure firewall
    configure_firewall
    
    # Create initial config WITHOUT security
    create_config false
    
    # Start MongoDB
    echo "Starting MongoDB node..."
    mongod --config /etc/mongod_27017.conf --fork
    sleep 5
    
    # Check if MongoDB is running
    if ! mongosh --port $PRIMARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start MongoDB node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27017.log
        return 1
    fi
    
    # Initialize replica set using private IP
    echo "Initializing replica set..."
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$PRIMARY_PORT${NC}"
    
    local init_result=$(mongosh --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 }
        ]
    })")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize replica set${NC}"
        echo "Error: $init_result"
        return 1
    fi
    
    echo "Waiting for PRIMARY election..."
    sleep 10
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
        echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
        
        # Create admin user with default values
        create_admin_user $ADMIN_USER $ADMIN_PASS || return 1
        
        # Create keyfile and update config WITH security
        create_keyfile "/etc/mongodb.keyfile"
        create_config true
        
        # Create systemd service
        echo "Creating systemd service..."
        create_systemd_service || return 1
        
        # Restart service with security
        echo "Restarting service with security..."
        sudo systemctl restart mongod_27017
        sleep 5
        
        # Verify connection with auth
        echo "Verifying connection with authentication..."
        local auth_result=$(mongosh --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Authentication verified successfully${NC}"
            echo -e "\n${GREEN}Connection Command:${NC}"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
        else
            echo -e "${RED}❌ Authentication verification failed${NC}"
            echo "Error details:"
            echo "$auth_result"
            sudo systemctl status mongod_27017
            return 1
        fi
    else
        echo -e "${RED}❌ Replica set initialization failed - Node not promoted to PRIMARY${NC}"
        echo "Current status:"
        echo "$status"
        return 1
    fi
}

# Fix authentication issues
fix_auth_issues() {
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    local PORT=27017
    
    echo -e "${YELLOW}Khắc phục lỗi xác thực MongoDB${NC}"
    echo "=================================================="
    
    # 1. Kiểm tra keyfile
    echo -e "\n${GREEN}Bước 1: Kiểm tra tập tin keyfile${NC}"
    if [ ! -f "/etc/mongodb.keyfile" ]; then
        echo -e "${RED}❌ Không tìm thấy keyfile tại /etc/mongodb.keyfile${NC}"
        echo "Tạo keyfile mới..."
        create_keyfile "/etc/mongodb.keyfile"
    else
        echo -e "${GREEN}✅ Đã tìm thấy keyfile tại /etc/mongodb.keyfile${NC}"
        sudo chmod 400 /etc/mongodb.keyfile
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
    fi
    
    # 2. Dừng MongoDB
    echo -e "\n${GREEN}Bước 2: Dừng dịch vụ MongoDB${NC}"
    stop_mongodb
    
    # 3. Tạo cấu hình với bảo mật
    echo -e "\n${GREEN}Bước 3: Cập nhật cấu hình với bảo mật${NC}"
    create_config true
    
    # 4. Khởi động lại với bảo mật
    echo -e "\n${GREEN}Bước 4: Khởi động lại MongoDB với bảo mật${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart mongod_$PORT
    sleep 5
    
    # 5. Kiểm tra kết nối với xác thực
    echo -e "\n${GREEN}Bước 5: Kiểm tra kết nối với xác thực${NC}"
    echo "Thử kết nối với người dùng mặc định..."
    
    local auth_test=$(mongosh --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.adminCommand('ping')" --quiet 2>&1)
    
    if [[ $auth_test == *"ok"* ]]; then
        echo -e "${GREEN}✅ Đã kết nối thành công với xác thực!${NC}"
        echo -e "\n${GREEN}Khắc phục lỗi xác thực thành công!${NC}"
        echo -e "\n${GREEN}Lệnh kết nối:${NC}"
        echo "mongosh --host $SERVER_IP --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    else
        echo -e "${RED}❌ Không thể kết nối với xác thực${NC}"
        echo "Lỗi: $auth_test"
        
        # Tạo lại user
        echo -e "\n${YELLOW}Thử tạo lại user admin...${NC}"
        # Tạm thời tắt xác thực
        create_config false
        sudo systemctl restart mongod_$PORT
        sleep 5
        
        # Tạo lại user admin
        create_admin_user $ADMIN_USER $ADMIN_PASS
        
        # Bật lại xác thực
        create_config true
        sudo systemctl restart mongod_$PORT
        sleep 5
        
        # Kiểm tra lại
        local auth_test2=$(mongosh --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.adminCommand('ping')" --quiet 2>&1)
        
        if [[ $auth_test2 == *"ok"* ]]; then
            echo -e "${GREEN}✅ Đã kết nối thành công sau khi tạo lại user!${NC}"
        else
            echo -e "${RED}❌ Vẫn không thể kết nối với xác thực sau khi tạo lại user${NC}"
            echo "Xem log để kiểm tra lỗi:"
            tail -n 20 /var/log/mongodb/mongod_${PORT}.log
        fi
    fi
}

# Emergency fix for replica set
emergency_fix_replica() {
    echo -e "${RED}===== KHẮC PHỤC KHẨN CẤP REPLICA SET =====${NC}"
    
    # Nhận thông tin kết nối
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    local PORT=27017
    
    # Bước 1: Kiểm tra trạng thái hiện tại
    echo -e "\n${YELLOW}Bước 1: Kiểm tra trạng thái hiện tại của MongoDB${NC}"
    
    # Dừng dịch vụ hiện tại
    stop_mongodb
    
    # Bước 2: Cấu hình lại MongoDB
    echo -e "\n${YELLOW}Bước 2: Tạo cấu hình mới không có bảo mật${NC}"
    create_config false
    
    # Bước 3: Khởi động MongoDB
    echo -e "\n${YELLOW}Bước 3: Khởi động lại MongoDB${NC}"
    mongod --config /etc/mongod_${PORT}.conf --fork
    sleep 5
    
    # Bước 4: Khởi tạo lại replica set
    echo -e "\n${YELLOW}Bước 4: Khởi tạo lại replica set${NC}"
    
    # Tạo script khởi tạo
    local init_script="
    try {
        rs.initiate({
            _id: 'rs0',
            members: [
                { _id: 0, host: '$SERVER_IP:$PORT', priority: 10 }
            ]
        });
        print('Đã khởi tạo replica set');
    } catch (e) {
        print('Lỗi khi khởi tạo: ' + e);
    }
    "
    
    echo "Thực hiện khởi tạo replica set..."
    local init_result=$(mongosh --host $SERVER_IP --port $PORT --eval "$init_script" --quiet)
    
    echo "$init_result"
    
    # Bước 5: Chờ PRIMARY được bầu
    echo -e "\n${YELLOW}Bước 5: Chờ PRIMARY được bầu (15 giây)${NC}"
    sleep 15
    
    # Kiểm tra trạng thái
    local status_check=$(mongosh --host $SERVER_IP --port $PORT --eval "rs.status()" --quiet)
    echo "$status_check"
    
    # Bước 6: Tạo admin user và bật xác thực
    echo -e "\n${YELLOW}Bước 6: Tạo admin user và bật xác thực${NC}"
    
    # Tạo admin user
    create_admin_user $ADMIN_USER $ADMIN_PASS
    
    # Tạo keyfile và bật xác thực
    create_keyfile "/etc/mongodb.keyfile"
    create_config true
    
    # Khởi động lại với xác thực
    sudo mongod --dbpath /var/lib/mongodb_${PORT} --port ${PORT} --shutdown
    sleep 5
    sudo systemctl daemon-reload
    sudo systemctl restart mongod_$PORT
    sleep 10
    
    # Bước 7: Kiểm tra kết nối với xác thực
    echo -e "\n${YELLOW}Bước 7: Kiểm tra kết nối với xác thực${NC}"
    
    local auth_test=$(mongosh --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    if [[ $auth_test == *"PRIMARY"* ]]; then
        echo -e "${GREEN}✅ Replica set đã được khôi phục thành công!${NC}"
        echo -e "\n${GREEN}Lệnh kết nối:${NC}"
        echo "mongosh --host $SERVER_IP --port $PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    else
        echo -e "${RED}❌ Không thể kết nối với xác thực sau khi khôi phục${NC}"
        echo "Lỗi: $auth_test"
        echo "Xem log để biết thêm chi tiết:"
        tail -n 20 /var/log/mongodb/mongod_${PORT}.log
    fi
}

# Main function
setup_replica_linux() {
    echo "MongoDB Replica Set Setup for Linux"
    echo "===================================="
    echo "1. Setup MongoDB Replica Set"
    echo "2. Fix authentication issues"
    echo "3. Emergency fix replica set"
    echo "4. Return to main menu"
    read -p "Select option (1-4): " option

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "Using server IP: $SERVER_IP"

    case $option in
        1) setup_primary $SERVER_IP ;;
        2) fix_auth_issues ;;
        3) emergency_fix_replica ;;
        4) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


