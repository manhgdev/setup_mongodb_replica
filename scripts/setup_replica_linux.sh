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
    sleep 2
    
    # Tạo thư mục với quyền hạn chặt chẽ
    sudo mkdir -p $DB_PATH $LOG_PATH
    
    # Xóa lock file và log cũ nếu cần
    sudo rm -rf $DB_PATH/mongod.lock 2>/dev/null || true
    sudo rm -f $LOG_PATH/mongod_${PORT}.log 2>/dev/null || true
    
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
    
    echo "Creating MongoDB configuration file..."
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
        sudo cat >> $CONFIG_FILE << EOF
# security
security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled
EOF
    fi

    # Phần replication luôn được thêm
    sudo cat >> $CONFIG_FILE << EOF
# replication
replication:
  replSetName: rs0
EOF
    
    # Set permissions
    sudo chown mongodb:mongodb $CONFIG_FILE
    sudo chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
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
    
    # Cập nhật cấu hình với tham số security nếu cần
    create_config $WITH_SECURITY
    
    # Tạo file dịch vụ
    sudo cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server (Port ${PORT})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    
    echo -e "${GREEN}✅ Dịch vụ ${SERVICE_NAME} đã được tạo${NC}"
}

# Start MongoDB and check status
start_mongodb() {
    local PORT=27017
    local SERVICE_NAME="mongod_${PORT}"
    
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Kiểm tra và dừng MongoDB nếu đang chạy
    if sudo systemctl is-active --quiet $SERVICE_NAME; then
        sudo systemctl stop $SERVICE_NAME
        sleep 3
    fi
    
    # Xóa lock file nếu tồn tại
    sudo rm -f /var/lib/mongodb_${PORT}/mongod.lock 2>/dev/null || true
    
    # Kiểm tra lại quyền trước khi khởi động
    sudo chown -R mongodb:mongodb /var/lib/mongodb_${PORT} /var/log/mongodb
    sudo chmod 750 /var/lib/mongodb_${PORT} /var/log/mongodb
    sudo touch /var/log/mongodb/mongod_${PORT}.log
    sudo chown mongodb:mongodb /var/log/mongodb/mongod_${PORT}.log
    
    # Thử chạy trực tiếp để kiểm tra lỗi
    echo -e "${YELLOW}Kiểm tra cấu hình trước khi khởi động...${NC}"
    sudo -u mongodb mongod --config /etc/mongod_${PORT}.conf --dbpath /var/lib/mongodb_${PORT} --shutdown &>/dev/null || true
    sleep 1
    
    # Khởi động MongoDB
    sudo systemctl daemon-reload
    sudo systemctl start $SERVICE_NAME
    
    # Đợi lâu hơn và kiểm tra nhiều lần
    echo "Đợi MongoDB khởi động..."
    for i in {1..5}; do
        sleep 2
        if sudo systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
            return 0
        fi
        echo "Đang chờ... ($i/5)"
    done
    
    # Hiển thị thông tin lỗi chi tiết
    echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
    echo "Trạng thái dịch vụ:"
    sudo systemctl status $SERVICE_NAME
    echo "Kiểm tra log MongoDB:"
    sudo tail -n 30 /var/log/mongodb/mongod_${PORT}.log
    
    # Kiểm tra thư mục dữ liệu
    echo "Kiểm tra quyền thư mục dữ liệu:"
    ls -la /var/lib/mongodb_${PORT}
    ls -la /var/log/mongodb
    
    # Kiểm tra SELinux
    if command -v sestatus &>/dev/null; then
        echo "Trạng thái SELinux:"
        sestatus
        echo "Thử tắt tạm thời SELinux và khởi động lại:"
        sudo setenforce 0 2>/dev/null || true
        sudo systemctl restart $SERVICE_NAME
        sleep 3
        if sudo systemctl is-active --quiet $SERVICE_NAME; then
            echo -e "${GREEN}✓ MongoDB đã khởi động thành công sau khi tắt SELinux${NC}"
            echo -e "${YELLOW}Cần cấu hình SELinux đúng cách cho MongoDB${NC}"
            return 0
        fi
    fi
    
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
    
    local result=$(mongosh --host $HOST --port $PORT $auth_params --eval "$cmd" --quiet 2>&1)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Đã kết nối thành công tới MongoDB${NC}"
        return 0
    else
        echo -e "${RED}❌ Không thể kết nối tới MongoDB${NC}"
        echo "Lỗi: $result"
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
    
    # Khởi tạo replica set
    echo -e "${YELLOW}Khởi tạo Replica Set...${NC}"
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$PRIMARY_PORT${NC}"
    
    local init_result=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 }
        ]
    })")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Không thể khởi tạo Replica Set${NC}"
        echo "Lỗi: $init_result"
        return 1
    fi
    
    echo -e "${YELLOW}Khởi tạo PRIMARY (không phải bầu chọn)...${NC}"
    sleep 10
    
    # Kiểm tra trạng thái replica set - Sử dụng IP của server
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    local status=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "${GREEN}✅ Replica Set đã được khởi tạo thành công${NC}"
        echo "Node PRIMARY: $SERVER_IP:$PRIMARY_PORT"
        
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
        if verify_mongodb_connection true $ADMIN_USER $ADMIN_PASS $SERVER_IP; then
            echo -e "\n${GREEN}=== THIẾT LẬP MONGODB PRIMARY HOÀN TẤT ===${NC}"
            echo -e "${GREEN}Lệnh kết nối:${NC}"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
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


