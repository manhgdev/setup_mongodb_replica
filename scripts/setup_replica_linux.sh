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

    echo -e "${GREEN}Thiết lập máy chủ PRIMARY trên port $PRIMARY_PORT${NC}"
    echo -e "${YELLOW}Lưu ý: Port 27017 luôn được cấu hình làm PRIMARY với priority cao nhất${NC}"

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
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$PRIMARY_PORT làm PRIMARY với priority=10${NC}"
    
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

    echo "Setting up SECONDARY MongoDB server at $SERVER_IP:$SECONDARY_PORT..."
    echo -e "${YELLOW}Lưu ý: Trong replica set, node chạy trên port 27017 nên là PRIMARY${NC}"
    echo -e "${YELLOW}Node này sẽ được cấu hình làm SECONDARY tạm thời để tham gia replica set${NC}"

    # Dừng tất cả tiến trình MongoDB hiện có
    stop_mongodb
    
    # Tạo thư mục cần thiết
    create_dirs $SECONDARY_PORT
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Nhận thông tin PRIMARY server
    echo -e "${YELLOW}Cần thông tin về PRIMARY server để kết nối replica set${NC}"
    read -p "Nhập IP của PRIMARY server: " PRIMARY_IP
    read -p "Nhập port của PRIMARY server (mặc định 27017): " PRIMARY_PORT
    PRIMARY_PORT=${PRIMARY_PORT:-27017}
    
    # Kiểm tra xem PRIMARY có chạy trên port 27017 không
    if [[ "$PRIMARY_PORT" != "27017" ]]; then
        echo -e "${RED}⚠️ Cảnh báo: PRIMARY không chạy trên port 27017!${NC}"
        echo -e "${YELLOW}Theo quy tắc, node chạy trên port 27017 nên là PRIMARY${NC}"
        read -p "Bạn có muốn tiếp tục không? (y/n): " CONTINUE
        if [[ "$CONTINUE" != "y" ]]; then
            echo "Hủy thiết lập. Vui lòng đảm bảo PRIMARY chạy trên port 27017."
            return 1
        fi
    fi
    
    # Nhận thông tin xác thực
    read -p "Nhập tên người dùng admin (mặc định $ADMIN_USER): " INPUT_ADMIN_USER
    ADMIN_USER=${INPUT_ADMIN_USER:-$ADMIN_USER}
    read -p "Nhập mật khẩu admin (mặc định $ADMIN_PASS): " INPUT_ADMIN_PASS
    ADMIN_PASS=${INPUT_ADMIN_PASS:-$ADMIN_PASS}
    
    # Tải keyfile từ PRIMARY server
    echo "Tải keyfile từ PRIMARY server..."
    read -p "Nhập đường dẫn ở PRIMARY server để lưu keyfile tạm (ví dụ: /tmp/mongodb.keyfile): " PRIMARY_KEYFILE_PATH
    PRIMARY_KEYFILE_PATH=${PRIMARY_KEYFILE_PATH:-"/tmp/mongodb.keyfile"}
    
    echo -e "${YELLOW}Thực hiện các lệnh sau trên PRIMARY server:${NC}"
    echo "sudo cp /etc/mongodb.keyfile $PRIMARY_KEYFILE_PATH"
    echo "sudo chmod 644 $PRIMARY_KEYFILE_PATH"
    echo "sudo chown $(whoami):$(whoami) $PRIMARY_KEYFILE_PATH"
    
    read -p "Đã thực hiện lệnh trên PRIMARY server? (y/n): " KEYFILE_READY
    if [[ "$KEYFILE_READY" != "y" ]]; then
        echo -e "${RED}❌ Bạn cần chuẩn bị keyfile trước khi tiếp tục${NC}"
        return 1
    fi
    
    # Sao chép keyfile từ PRIMARY server
    echo "Đang sao chép keyfile từ PRIMARY server..."
    scp ${PRIMARY_IP}:${PRIMARY_KEYFILE_PATH} /tmp/mongodb.keyfile
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Không thể sao chép keyfile từ PRIMARY server${NC}"
        echo "Thay vào đó, hãy tạo keyfile mới và đảm bảo nó giống với keyfile trên PRIMARY server"
        read -p "Tạo keyfile mới? (y/n): " CREATE_NEW_KEYFILE
        
        if [[ "$CREATE_NEW_KEYFILE" == "y" ]]; then
            read -p "Hãy sao chép nội dung keyfile từ PRIMARY server và dán vào đây: " KEYFILE_CONTENT
            echo "$KEYFILE_CONTENT" | sudo tee /etc/mongodb.keyfile > /dev/null
            sudo chmod 400 /etc/mongodb.keyfile
            sudo chown mongodb:mongodb /etc/mongodb.keyfile
        else
            echo -e "${RED}❌ Không thể thiết lập bảo mật không có keyfile${NC}"
            return 1
        fi
    else
        sudo mv /tmp/mongodb.keyfile /etc/mongodb.keyfile
        sudo chmod 400 /etc/mongodb.keyfile
        sudo chown mongodb:mongodb /etc/mongodb.keyfile
    fi
    
    # Tạo file cấu hình MongoDB BAN ĐẦU không bật bảo mật để kết nối replica
    echo "Tạo file cấu hình MongoDB ban đầu không bảo mật..."
    create_config $SECONDARY_PORT true false false
    
    # Kiểm tra kết nối tới PRIMARY trước khi tiếp tục
    echo "Kiểm tra kết nối tới PRIMARY server..."
    if ! ping -c 3 $PRIMARY_IP > /dev/null 2>&1; then
        echo -e "${RED}❌ Không thể kết nối tới PRIMARY server ${PRIMARY_IP}${NC}"
        echo "Kiểm tra kết nối mạng và tường lửa"
        return 1
    fi
    
    # Tạo systemd service
    echo "Tạo systemd service..."
    create_systemd_service $SECONDARY_PORT || return 1
    
    # Khởi động dịch vụ MongoDB
    echo "Khởi động dịch vụ MongoDB..."
    sudo systemctl start mongod_$SECONDARY_PORT
    sleep 5
    
    # Kiểm tra MongoDB đã khởi động chưa
    if ! mongosh --port $SECONDARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Không thể khởi động MongoDB. Đang thử sửa lỗi...${NC}"
        fix_mongodb_startup $SECONDARY_PORT
        sudo systemctl restart mongod_$SECONDARY_PORT
        sleep 5
        
        if ! mongosh --port $SECONDARY_PORT --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Khởi động MongoDB thất bại${NC}"
            echo "Xem log để biết chi tiết:"
            tail -n 50 /var/log/mongodb/mongod_${SECONDARY_PORT}.log
            return 1
        fi
    fi
    
    # Xác định priority dựa trên port
    local secondary_priority=1
    if [[ "$SECONDARY_PORT" == "27017" ]]; then
        # Nếu đây là node 27017 nhưng đang thêm làm SECONDARY,
        # hãy đặt priority cao hơn các node SECONDARY khác nhưng vẫn thấp hơn PRIMARY
        secondary_priority=5
        echo -e "${YELLOW}⚠️ Node này chạy trên port 27017 nhưng sẽ được thêm làm SECONDARY${NC}"
        echo -e "${YELLOW}Priority sẽ được đặt thành $secondary_priority (cao hơn SECONDARY thông thường nhưng thấp hơn PRIMARY)${NC}"
    fi
    
    # Thêm node vào replica set từ PRIMARY
    echo "Kết nối tới PRIMARY và thêm SECONDARY vào replica set..."
    local join_result=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    rs.add({host: '$SERVER_IP:$SECONDARY_PORT', priority: $secondary_priority})
    " --quiet)
    
    if [[ $join_result == *"E11000"* || $join_result == *"error"* ]]; then
        echo -e "${YELLOW}Lưu ý: ${join_result}${NC}"
        echo "Kiểm tra xem node có thể đã tồn tại trong replica set..."
        local rs_status=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
        if [[ $rs_status == *"$SERVER_IP:$SECONDARY_PORT"* ]]; then
            echo -e "${YELLOW}Node có thể đã tồn tại trong replica set. Tiếp tục với cài đặt xác thực...${NC}"
        else
            echo "Kiểm tra log MongoDB để biết thêm chi tiết:"
            tail -n 50 /var/log/mongodb/mongod_${SECONDARY_PORT}.log
        fi
    else
        echo -e "${GREEN}✅ Đã thêm node vào replica set thành công${NC}"
    fi
    
    # Đợi để SECONDARY đồng bộ với PRIMARY
    echo "Đợi SECONDARY đồng bộ với PRIMARY..."
    sleep 30
    
    # Kiểm tra trạng thái replica set
    echo "Kiểm tra trạng thái replica set từ SECONDARY..."
    local status=$(mongosh --port $SECONDARY_PORT --eval "rs.status()" --quiet 2>&1)
    
    if [[ $status == *"SECONDARY"* ]]; then
        echo -e "${GREEN}✅ Node hiện đang hoạt động ở chế độ SECONDARY${NC}"
        
        # Tạo admin user trên SECONDARY
        echo "Tạo admin user trên SECONDARY..."
        local create_user_result=$(mongosh --port $SECONDARY_PORT --eval "
        db.getSiblingDB('admin').createUser({
            user: '$ADMIN_USER',
            pwd: '$ADMIN_PASS',
            roles: [
                { role: 'root', db: 'admin' },
                { role: 'clusterAdmin', db: 'admin' }
            ]
        })" --quiet 2>&1)
        
        # Kiểm tra nếu user đã tồn tại
        if [[ $create_user_result == *"already exists"* ]]; then
            echo -e "${YELLOW}Admin user đã tồn tại${NC}"
        elif [[ $create_user_result == *"error"* ]]; then
            echo -e "${YELLOW}Không thể tạo user. Có thể là do đồng bộ hoặc quyền: ${create_user_result}${NC}"
        else
            echo -e "${GREEN}✅ Đã tạo admin user thành công${NC}"
        fi
        
        # Dừng MongoDB để cập nhật cấu hình
        echo "Dừng MongoDB để cập nhật cấu hình với bảo mật..."
        sudo systemctl stop mongod_$SECONDARY_PORT
        sleep 5
        
        # Cập nhật cấu hình với bảo mật
        echo "Cập nhật cấu hình với bảo mật..."
        create_config $SECONDARY_PORT true false true
        
        # Khởi động lại với bảo mật
        echo "Khởi động lại MongoDB với bảo mật..."
        sudo systemctl start mongod_$SECONDARY_PORT
        sleep 10
        
        # Thử kết nối với xác thực
        echo "Kiểm tra kết nối với xác thực..."
        local auth_test=$(mongosh --port $SECONDARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.adminCommand('ping')" --quiet 2>&1)
        
        if [[ $auth_test == *"ok"* ]]; then
            echo -e "${GREEN}✅ SECONDARY node đã được cấu hình thành công với xác thực${NC}"
            echo -e "\n${GREEN}Các lệnh kết nối:${NC}"
            echo "1. Kết nối tới SECONDARY:"
            echo "mongosh --host $SERVER_IP --port $SECONDARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "2. Kết nối tới Replica Set:"
            echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:$PRIMARY_PORT,$SERVER_IP:$SECONDARY_PORT/admin?replicaSet=rs0\""
            
            # Kiểm tra cấu hình port 27017
            if [[ "$SECONDARY_PORT" == "27017" && "$PRIMARY_PORT" == "27017" ]]; then
                echo -e "\n${YELLOW}⚠️ Cảnh báo: Cả PRIMARY và SECONDARY đang chạy trên port 27017${NC}"
                echo "Điều này có thể gây nhầm lẫn. Vui lòng xem xét cấu hình lại vai trò PRIMARY/SECONDARY."
                echo "Sử dụng chức năng 'Fix replica set roles' trong menu chính để đảm bảo node đúng là PRIMARY."
            elif [[ "$SECONDARY_PORT" == "27017" ]]; then
                echo -e "\n${YELLOW}⚠️ Lưu ý: Node này chạy trên port 27017 nhưng đang là SECONDARY${NC}"
                echo "Theo quy tắc, node chạy trên port 27017 nên là PRIMARY."
                echo "Sử dụng chức năng 'Fix replica set roles' trong menu chính để đặt node này làm PRIMARY."
            fi
        else
            echo -e "${RED}❌ Không thể kết nối với xác thực${NC}"
            echo "Lỗi: $auth_test"
            echo "Vui lòng kiểm tra:"
            echo "1. Quyền của keyfile: sudo ls -la /etc/mongodb.keyfile"
            echo "2. Nội dung keyfile có khớp với PRIMARY không"
            echo "3. Cấu hình bảo mật trong: /etc/mongod_${SECONDARY_PORT}.conf"
            echo "4. Log MongoDB: sudo tail -n 100 /var/log/mongodb/mongod_${SECONDARY_PORT}.log"
            
            # Cung cấp lệnh khắc phục
            echo -e "\n${YELLOW}Thử lệnh sửa lỗi:${NC}"
            echo "1. Kiểm tra keyfile: sudo cat /etc/mongodb.keyfile"
            echo "2. Sửa quyền: sudo chmod 400 /etc/mongodb.keyfile && sudo chown mongodb:mongodb /etc/mongodb.keyfile"
            echo "3. Khởi động lại: sudo systemctl restart mongod_${SECONDARY_PORT}"
        fi
    else
        echo -e "${RED}❌ Trạng thái replica set không như mong đợi${NC}"
        echo "Trạng thái hiện tại: $status"
        echo "Kiểm tra cấu hình và kết nối..."
        echo "Thử kiểm tra trạng thái từ PRIMARY:"
        mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet
    fi
}

# Fix authentication issues on SECONDARY server
fix_secondary_auth_issues() {
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    local SECONDARY_PORT=27017
    
    echo -e "${YELLOW}Khắc phục lỗi xác thực trên máy chủ SECONDARY${NC}"
    echo "=================================================="
    
    # 1. Kiểm tra keyfile
    echo -e "\n${GREEN}Bước 1: Kiểm tra tập tin keyfile${NC}"
    if [ ! -f "/etc/mongodb.keyfile" ]; then
        echo -e "${RED}❌ Không tìm thấy keyfile tại /etc/mongodb.keyfile${NC}"
        
        echo "Tạo keyfile mới từ máy chủ PRIMARY..."
        read -p "Nhập IP của PRIMARY server: " PRIMARY_IP
        read -p "Nhập port của PRIMARY server (mặc định 27017): " PRIMARY_PORT
        PRIMARY_PORT=${PRIMARY_PORT:-27017}
        read -p "Nhập đường dẫn keyfile tạm trên PRIMARY (ví dụ: /tmp/mongodb.keyfile): " PRIMARY_KEYFILE_PATH
        PRIMARY_KEYFILE_PATH=${PRIMARY_KEYFILE_PATH:-"/tmp/mongodb.keyfile"}
        
        echo -e "${YELLOW}Thực hiện các lệnh sau trên PRIMARY server:${NC}"
        echo "sudo cp /etc/mongodb.keyfile $PRIMARY_KEYFILE_PATH"
        echo "sudo chmod 644 $PRIMARY_KEYFILE_PATH"
        echo "sudo chown $(whoami):$(whoami) $PRIMARY_KEYFILE_PATH"
        
        read -p "Đã thực hiện lệnh trên PRIMARY server? (y/n): " KEYFILE_READY
        if [[ "$KEYFILE_READY" != "y" ]]; then
            echo -e "${RED}❌ Cần chuẩn bị keyfile trước khi tiếp tục${NC}"
            return 1
        fi
        
        echo "Đang sao chép keyfile từ PRIMARY server..."
        scp ${PRIMARY_IP}:${PRIMARY_KEYFILE_PATH} /tmp/mongodb.keyfile
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Không thể sao chép keyfile từ PRIMARY server${NC}"
            echo "Thay vào đó, hãy nhập nội dung keyfile thủ công"
            read -p "Tạo keyfile thủ công? (y/n): " CREATE_NEW_KEYFILE
            
            if [[ "$CREATE_NEW_KEYFILE" == "y" ]]; then
                echo "Nhập nội dung của keyfile (sao chép từ PRIMARY):"
                read KEYFILE_CONTENT
                echo "$KEYFILE_CONTENT" | sudo tee /etc/mongodb.keyfile > /dev/null
            else
                echo -e "${RED}❌ Không thể tiếp tục mà không có keyfile${NC}"
                return 1
            fi
        else
            sudo mv /tmp/mongodb.keyfile /etc/mongodb.keyfile
        fi
    else
        echo -e "${GREEN}✅ Đã tìm thấy keyfile tại /etc/mongodb.keyfile${NC}"
    fi
    
    # 2. Sửa quyền cho keyfile
    echo -e "\n${GREEN}Bước 2: Sửa quyền cho keyfile${NC}"
    sudo chmod 400 /etc/mongodb.keyfile
    sudo chown mongodb:mongodb /etc/mongodb.keyfile
    echo -e "${GREEN}✅ Đã cập nhật quyền cho keyfile${NC}"
    
    # 3. Dừng MongoDB
    echo -e "\n${GREEN}Bước 3: Dừng dịch vụ MongoDB${NC}"
    stop_mongodb
    
    # 4. Tạo cấu hình tạm thời không có bảo mật
    echo -e "\n${GREEN}Bước 4: Tạo cấu hình tạm thời không có bảo mật${NC}"
    create_config $SECONDARY_PORT true false false
    echo -e "${GREEN}✅ Đã tạo cấu hình tạm thời không có bảo mật${NC}"
    
    # 5. Khởi động MongoDB
    echo -e "\n${GREEN}Bước 5: Khởi động MongoDB với cấu hình không bảo mật${NC}"
    mongod --config /etc/mongod_${SECONDARY_PORT}.conf --fork
    sleep 5
    
    # Kiểm tra MongoDB đã khởi động chưa
    if ! mongosh --port $SECONDARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Không thể khởi động MongoDB${NC}"
        fix_mongodb_startup $SECONDARY_PORT
        mongod --config /etc/mongod_${SECONDARY_PORT}.conf --fork
        sleep 5
        
        if ! mongosh --port $SECONDARY_PORT --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${RED}❌ Khởi động MongoDB thất bại${NC}"
            echo "Xem log để biết chi tiết:"
            tail -n 50 /var/log/mongodb/mongod_${SECONDARY_PORT}.log
            return 1
        fi
    fi
    
    # 6. Kiểm tra trạng thái replica set
    echo -e "\n${GREEN}Bước 6: Kiểm tra trạng thái replica set${NC}"
    local status=$(mongosh --port $SECONDARY_PORT --eval "rs.status()" --quiet 2>&1)
    
    if [[ $status == *"SECONDARY"* ]]; then
        echo -e "${GREEN}✅ Node hiện đang hoạt động ở chế độ SECONDARY${NC}"
    else
        echo -e "${YELLOW}Node không ở trạng thái SECONDARY. Trạng thái hiện tại:${NC}"
        echo "$status"
        
        # Nếu không phải là SECONDARY, hỏi PRIMARY IP để kết nối
        read -p "Nhập IP của PRIMARY server để kết nối replica set: " PRIMARY_IP
        read -p "Nhập port của PRIMARY server (mặc định 27017): " PRIMARY_PORT
        PRIMARY_PORT=${PRIMARY_PORT:-27017}
        read -p "Nhập tên người dùng admin trên PRIMARY (mặc định $ADMIN_USER): " INPUT_ADMIN_USER
        ADMIN_USER=${INPUT_ADMIN_USER:-$ADMIN_USER}
        read -p "Nhập mật khẩu admin trên PRIMARY (mặc định $ADMIN_PASS): " INPUT_ADMIN_PASS
        ADMIN_PASS=${INPUT_ADMIN_PASS:-$ADMIN_PASS}
        
        # Thử thêm lại vào replica set
        echo "Thêm node vào replica set từ PRIMARY..."
        local join_result=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        rs.add('$SERVER_IP:$SECONDARY_PORT')
        " --quiet)
        
        if [[ $join_result == *"error"* ]]; then
            echo -e "${YELLOW}Có lỗi khi thêm vào replica set: $join_result${NC}"
        else
            echo -e "${GREEN}✅ Đã thêm node vào replica set${NC}"
        fi
        
        # Chờ node đồng bộ
        echo "Đợi node đồng bộ..."
        sleep 20
    fi
    
    # 7. Tạo admin user
    echo -e "\n${GREEN}Bước 7: Tạo admin user trên SECONDARY${NC}"
    
    # Nếu là SECONDARY, tạo user
    local create_user_result=$(mongosh --port $SECONDARY_PORT --eval "
    db.getSiblingDB('admin').createUser({
        user: '$ADMIN_USER',
        pwd: '$ADMIN_PASS',
        roles: [
            { role: 'root', db: 'admin' },
            { role: 'clusterAdmin', db: 'admin' }
        ]
    })" --quiet 2>&1)
    
    if [[ $create_user_result == *"already exists"* ]]; then
        echo -e "${YELLOW}Admin user đã tồn tại${NC}"
    elif [[ $create_user_result == *"error"* ]]; then
        echo -e "${YELLOW}Lỗi khi tạo user: $create_user_result${NC}"
        echo "Không thể tạo user. User có thể sẽ được đồng bộ từ PRIMARY."
    else
        echo -e "${GREEN}✅ Đã tạo admin user thành công${NC}"
    fi
    
    # 8. Dừng MongoDB
    echo -e "\n${GREEN}Bước 8: Dừng MongoDB để cập nhật cấu hình với bảo mật${NC}"
    sudo mongod --dbpath /var/lib/mongodb_${SECONDARY_PORT} --port ${SECONDARY_PORT} --shutdown
    sleep 5
    
    # 9. Cập nhật cấu hình với bảo mật
    echo -e "\n${GREEN}Bước 9: Cập nhật cấu hình với bảo mật${NC}"
    create_config $SECONDARY_PORT true false true
    echo -e "${GREEN}✅ Đã cập nhật cấu hình với bảo mật${NC}"
    
    # 10. Tạo systemd service nếu chưa có
    echo -e "\n${GREEN}Bước 10: Đảm bảo có dịch vụ systemd${NC}"
    if [ ! -f "/etc/systemd/system/mongod_${SECONDARY_PORT}.service" ]; then
        echo "Tạo systemd service..."
        create_systemd_service $SECONDARY_PORT || return 1
    else
        echo -e "${GREEN}✅ Dịch vụ systemd đã tồn tại${NC}"
    fi
    
    # 11. Khởi động lại với bảo mật
    echo -e "\n${GREEN}Bước 11: Khởi động lại MongoDB với bảo mật${NC}"
    sudo systemctl daemon-reload
    sudo systemctl restart mongod_$SECONDARY_PORT
    sleep 10
    
    # 12. Kiểm tra kết nối với xác thực
    echo -e "\n${GREEN}Bước 12: Kiểm tra kết nối với xác thực${NC}"
    local auth_test=$(mongosh --port $SECONDARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.adminCommand('ping')" --quiet 2>&1)
    
    if [[ $auth_test == *"ok"* ]]; then
        echo -e "${GREEN}✅ Đã kết nối thành công với xác thực!${NC}"
        echo -e "\n${GREEN}Khắc phục lỗi xác thực thành công!${NC}"
        echo -e "\n${GREEN}Các lệnh kết nối:${NC}"
        echo "1. Kết nối tới SECONDARY:"
        echo "mongosh --host $SERVER_IP --port $SECONDARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
        
        # Lấy PRIMARY IP nếu chưa có
        if [ -z "$PRIMARY_IP" ]; then
            read -p "Nhập IP của PRIMARY server cho chuỗi kết nối: " PRIMARY_IP
        fi
        echo "2. Kết nối tới Replica Set:"
        echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:$PRIMARY_PORT,$SERVER_IP:$SECONDARY_PORT/admin?replicaSet=rs0\""
    else
        echo -e "${RED}❌ Không thể kết nối với xác thực${NC}"
        echo "Lỗi: $auth_test"
        echo -e "\n${YELLOW}Kiểm tra thêm:${NC}"
        echo "1. Xem quyền của keyfile:"
        ls -la /etc/mongodb.keyfile
        echo "2. Kiểm tra cấu hình MongoDB:"
        cat /etc/mongod_${SECONDARY_PORT}.conf | grep -i security -A 5
        echo "3. Xem log MongoDB:"
        tail -n 20 /var/log/mongodb/mongod_${SECONDARY_PORT}.log
    fi
    
    echo -e "\n${GREEN}Quá trình khắc phục hoàn tất.${NC}"
    echo "Nếu vẫn gặp lỗi, hãy xem xét khởi động lại toàn bộ quá trình hoặc kiểm tra logs."
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

# Fix replica set roles (PRIMARY/SECONDARY)
fix_replica_set_roles() {
    echo -e "${YELLOW}Khắc phục lỗi vai trò PRIMARY/SECONDARY trong Replica Set${NC}"
    echo "========================================================="
    echo -e "${GREEN}Lưu ý: Đảm bảo node có port 27017 luôn là PRIMARY${NC}"
    
    # Nhận thông tin kết nối
    read -p "Nhập IP của node hiện tại: " CURRENT_IP
    read -p "Nhập port của node hiện tại (mặc định 27017): " CURRENT_PORT
    CURRENT_PORT=${CURRENT_PORT:-27017}
    
    # Nhận thông tin xác thực
    read -p "Nhập tên người dùng admin (mặc định $ADMIN_USER): " INPUT_ADMIN_USER
    ADMIN_USER=${INPUT_ADMIN_USER:-$ADMIN_USER}
    read -p "Nhập mật khẩu admin (mặc định $ADMIN_PASS): " INPUT_ADMIN_PASS
    ADMIN_PASS=${INPUT_ADMIN_PASS:-$ADMIN_PASS}
    
    # Kiểm tra nếu có thể kết nối với auth
    echo -e "\n${GREEN}Bước 1: Kiểm tra kết nối và trạng thái replica set${NC}"
    
    local status=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    if [[ $status == *"auth fail"* ]]; then
        echo -e "${RED}❌ Lỗi xác thực. Không thể kết nối với node${NC}"
        echo "Trước tiên hãy khắc phục vấn đề xác thực sử dụng tùy chọn 'Fix authentication issues'"
        return 1
    fi
    
    # Hiển thị trạng thái hiện tại
    echo -e "\n${GREEN}Trạng thái replica set hiện tại:${NC}"
    mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr + ' (priority: ' + m.priority + ')') })" --quiet
    
    # Hiển thị cấu hình hiện tại
    echo -e "\n${GREEN}Cấu hình replica set hiện tại:${NC}"
    mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.conf()" --quiet
    
    # Tìm node có port 27017 (sẽ trở thành PRIMARY)
    echo -e "\n${GREEN}Bước 2: Xác định node PRIMARY (port 27017)${NC}"
    
    # Lấy tất cả các node trong replica set
    local all_nodes=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.conf().members.map(m => m.host)" --quiet)
    echo "Các node hiện có trong replica set:"
    echo "$all_nodes"
    
    # Tìm node có port 27017
    local primary_nodes=$(echo "$all_nodes" | grep -E ':[0]?27017$' | tr -d '[]"')
    
    if [ -z "$primary_nodes" ]; then
        echo -e "${RED}❌ Không tìm thấy node nào chạy trên port 27017${NC}"
        echo "Vui lòng đảm bảo có ít nhất một node chạy trên port 27017"
        return 1
    fi
    
    if [[ $(echo "$primary_nodes" | wc -l) -gt 1 ]]; then
        echo -e "${YELLOW}Có nhiều node chạy trên port 27017. Vui lòng chọn một node làm PRIMARY:${NC}"
        echo "$primary_nodes"
        read -p "Nhập địa chỉ đầy đủ của node sẽ làm PRIMARY: " DESIRED_PRIMARY_HOST
    else
        DESIRED_PRIMARY_HOST="$primary_nodes"
        echo -e "${GREEN}Node sẽ làm PRIMARY: $DESIRED_PRIMARY_HOST${NC}"
    fi
    
    # Kiểm tra xem node đã chọn có trong replica set không
    local members=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.conf().members" --quiet)
    
    if [[ $members != *"$DESIRED_PRIMARY_HOST"* ]]; then
        echo -e "${RED}❌ Node đã chọn không tồn tại trong replica set${NC}"
        echo "Các node hiện có:"
        mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.conf().members.forEach(function(m) { print(m.host) })" --quiet
        return 1
    fi
    
    echo -e "\n${GREEN}Bước 3: Cập nhật cấu hình replica set${NC}"
    echo "Cập nhật priority - đặt node 27017 với priority cao (10) và các node khác thành 1 hoặc 0 (arbiter)..."
    
    # Tạo script JavaScript để cập nhật cấu hình
    local js_script="
    var conf = rs.conf();
    conf.members.forEach(function(member) {
        if (member.host === '$DESIRED_PRIMARY_HOST') {
            member.priority = 10;
            print('Đặt ' + member.host + ' với priority 10 (PRIMARY)');
        } else if (member.arbiterOnly) {
            member.priority = 0;
            print('Giữ ' + member.host + ' là arbiter với priority 0');
        } else {
            member.priority = 1;
            print('Đặt ' + member.host + ' với priority 1 (SECONDARY)');
        }
    });
    rs.reconfig(conf);
    "
    
    # Thực thi script
    echo "Đang cập nhật priority..."
    local reconfig_result=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "$js_script" --quiet)
    
    echo "$reconfig_result"
    
    if [[ $reconfig_result == *"error"* ]]; then
        echo -e "${RED}❌ Lỗi khi cập nhật cấu hình: $reconfig_result${NC}"
        
        # Kiểm tra xem có cần chạy từ PRIMARY hiện tại
        if [[ $reconfig_result == *"replSetReconfig should only be run on a writable PRIMARY"* ]]; then
            echo "Bạn cần thực hiện từ node PRIMARY hiện tại. Đang tìm PRIMARY..."
            local current_primary=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status().members.forEach(function(m) { if (m.stateStr === 'PRIMARY') print(m.name) })" --quiet)
            
            if [ -z "$current_primary" ]; then
                echo -e "${RED}❌ Không tìm thấy PRIMARY hiện tại${NC}"
                echo "Thử chạy lại từ node khác hoặc thử force election"
            else
                echo -e "${YELLOW}PRIMARY hiện tại là: $current_primary${NC}"
                echo "Hãy kết nối tới node này và chạy lại"
            fi
        fi
        
        # Hỏi người dùng có muốn thử force election không
        read -p "Thử force election? (y/n): " TRY_FORCE
        if [[ "$TRY_FORCE" == "y" ]]; then
            echo -e "\n${GREEN}Bước 4: Thử force election${NC}"
            echo "Cảnh báo: Đây là thao tác nâng cao và có thể gây mất ổn định tạm thời."
            
            # Lấy ID của node mong muốn làm PRIMARY
            local desired_id=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
            var conf = rs.conf();
            for (var i = 0; i < conf.members.length; i++) {
                if (conf.members[i].host === '$DESIRED_PRIMARY_HOST') {
                    print(conf.members[i]._id);
                    break;
                }
            }
            " --quiet)
            
            if [ -z "$desired_id" ]; then
                echo -e "${RED}❌ Không thể xác định ID của node mong muốn${NC}"
                return 1
            fi
            
            echo "Thực hiện stepDown trên PRIMARY hiện tại (nếu có)..."
            mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "if (rs.status().members.some(m => m.stateStr === 'PRIMARY')) { rs.stepDown(60); }" --quiet
            
            sleep 5
            
            echo "Thực hiện force cấu hình để đặt node $DESIRED_PRIMARY_HOST làm PRIMARY..."
            local force_script="
            var conf = rs.conf();
            conf.members.forEach(function(member) {
                if (member.host === '$DESIRED_PRIMARY_HOST') {
                    member.priority = 10;
                } else if (!member.arbiterOnly) {
                    member.priority = 1;
                }
            });
            rs.reconfig(conf, {force: true});
            "
            
            local force_result=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "$force_script" --quiet)
            
            echo "$force_result"
            
            if [[ $force_result == *"error"* ]]; then
                echo -e "${RED}❌ Force election thất bại${NC}"
                echo "Vui lòng chờ một thời gian để replica set ổn định, sau đó thử lại."
            else
                echo -e "${GREEN}✅ Đã force election thành công${NC}"
            fi
        fi
    else
        echo -e "${GREEN}✅ Đã cập nhật cấu hình replica set thành công${NC}"
    fi
    
    # Đợi bầu cử mới
    echo -e "\n${GREEN}Bước 5: Chờ bầu cử vai trò mới (60 giây)${NC}"
    echo "Đợi để replica set bầu cử PRIMARY mới..."
    
    # Hiển thị trạng thái mỗi 10 giây
    for i in {1..6}; do
        echo "Kiểm tra trạng thái lần $i..."
        mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr) })" --quiet
        
        # Kiểm tra xem node mong muốn đã là PRIMARY chưa
        local is_primary=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        var status = rs.status();
        for (var i = 0; i < status.members.length; i++) {
            if (status.members[i].name === '$DESIRED_PRIMARY_HOST' && status.members[i].stateStr === 'PRIMARY') {
                print('PRIMARY_FOUND');
                break;
            }
        }
        " --quiet)
        
        if [[ $is_primary == *"PRIMARY_FOUND"* ]]; then
            echo -e "${GREEN}✅ Node mong muốn đã trở thành PRIMARY!${NC}"
            break
        fi
        
        if [ $i -lt 6 ]; then
            echo "Đợi 10 giây..."
            sleep 10
        fi
    done
    
    # Kiểm tra trạng thái cuối cùng
    echo -e "\n${GREEN}Bước 6: Kiểm tra trạng thái cuối cùng${NC}"
    echo "Trạng thái replica set sau khi cấu hình:"
    mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr + ' (priority: ' + (rs.conf().members.find(c => c.host === m.name) || {}).priority + ')') })" --quiet
    
    # Kiểm tra xem node mong muốn có phải PRIMARY không
    local final_primary=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status().members.find(m => m.stateStr === 'PRIMARY').name" --quiet)
    
    if [[ "$final_primary" == "$DESIRED_PRIMARY_HOST" ]]; then
        echo -e "\n${GREEN}✅ Khắc phục thành công! $DESIRED_PRIMARY_HOST là PRIMARY${NC}"
    else
        if [ -z "$final_primary" ]; then
            echo -e "\n${RED}❌ Không tìm thấy PRIMARY nào trong replica set${NC}"
            echo "Thử chạy lại quá trình hoặc đợi thêm thời gian để replica set ổn định."
        else
            echo -e "\n${YELLOW}⚠️ Lưu ý: PRIMARY hiện tại là $final_primary, không phải $DESIRED_PRIMARY_HOST${NC}"
            echo "Cần thêm thời gian để replica set ổn định hoặc thử lại quá trình."
        fi
    fi
    
    echo -e "\n${GREEN}Quá trình khắc phục hoàn tất.${NC}"
    echo "Các lệnh kết nối:"
    echo "1. Kết nối tới replica set:"
    echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@$CURRENT_IP:$CURRENT_PORT/admin?replicaSet=rs0\""
}

# Main function
setup_replica_linux() {
    echo "MongoDB Replica Set Setup for Linux"
    echo "===================================="
    echo "1. Setup PRIMARY server"
    echo "2. Setup SECONDARY server"
    echo "3. Fix authentication issues on SECONDARY server"
    echo "4. Fix replica set roles (PRIMARY/SECONDARY)"
    echo "5. Return to main menu"
    read -p "Select option (1-5): " option

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "Using server IP: $SERVER_IP"

    case $option in
        1) setup_primary $SERVER_IP ;;
        2) setup_secondary $SERVER_IP ;;
        3) fix_secondary_auth_issues ;;
        4) fix_replica_set_roles ;;
        5) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


