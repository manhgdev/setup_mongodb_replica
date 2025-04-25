#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Thư mục script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kiểm tra xem đã chạy với quyền root chưa
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Vui lòng chạy script với quyền root (sudo)${NC}"
    exit 1
fi

# Hàm dừng MongoDB
stop_mongodb() {
    echo "Đang dừng tất cả các instance MongoDB..."
    systemctl stop mongod || true
    pkill -f mongod || true
    sleep 3
    
    # Kiểm tra và buộc dừng nếu cần
    if pgrep -f mongod > /dev/null; then
        echo "MongoDB vẫn đang chạy, đang dừng lại..."
        pkill -9 -f mongod || true
        sleep 2
    fi
    
    # Xóa các socket file cũ
    rm -f /tmp/mongodb-*.sock
}

# Hàm thiết lập một node
setup_node() {
    local PORT=$1
    local NODE_TYPE=$2
    
    echo "Đang thiết lập node ${NODE_TYPE} trên port ${PORT}..."
    
    # Tạo thư mục cho node
    mkdir -p /var/lib/mongodb_${PORT}
    mkdir -p /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb_${PORT}
    chown -R mongodb:mongodb /var/log/mongodb
    
    # Tạo file config
    cat > /etc/mongod_${PORT}.conf << EOL
systemLog:
  destination: file
  path: /var/log/mongodb/mongod_${PORT}.log
  logAppend: true
storage:
  dbPath: /var/lib/mongodb_${PORT}
net:
  bindIp: 0.0.0.0
  port: ${PORT}
security:
  keyFile: /etc/mongodb.key
replication:
  replSetName: rs0
EOL
    
    # Khởi động node
    echo "Đang khởi động MongoDB trên port ${PORT}..."
    mongod --config /etc/mongod_${PORT}.conf --fork
    
    # Kiểm tra kết nối
    for i in {1..10}; do
        if mongosh --port ${PORT} --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Node MongoDB trên port ${PORT} đã sẵn sàng${NC}"
            return 0
        fi
        echo "Đang chờ MongoDB khởi động... (${i}/10)"
        sleep 3
    done
    
    echo -e "${RED}❌ Không thể kết nối đến MongoDB trên port ${PORT}${NC}"
    echo "Đang kiểm tra log file:"
    tail -n 20 /var/log/mongodb/mongod_${PORT}.log
    return 1
}

# Cài đặt MongoDB Replica Set PRIMARY
setup_replica_primary() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    
    # Lấy địa chỉ IP
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Địa chỉ IP tự động phát hiện: ${SERVER_IP}${NC}"
    read -p "Nhập địa chỉ IP (Enter để sử dụng IP trên): " input_ip
    SERVER_IP=${input_ip:-$SERVER_IP}
    
    # Thông tin user admin
    read -p "Nhập username admin (mặc định: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    
    read -p "Nhập password admin (mặc định: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
    # Dừng tất cả các instance MongoDB
    stop_mongodb
    
    # Tạo keyfile
    echo "Đang tạo keyFile..."
    openssl rand -base64 756 > /etc/mongodb.key
    chmod 400 /etc/mongodb.key
    chown mongodb:mongodb /etc/mongodb.key
    
    # Thiết lập các node
    if ! setup_node $PRIMARY_PORT "PRIMARY"; then
        echo -e "${RED}❌ Không thể thiết lập node PRIMARY${NC}"
        exit 1
    fi
    
    if ! setup_node $ARBITER1_PORT "ARBITER-1"; then
        echo -e "${RED}❌ Không thể thiết lập node ARBITER-1${NC}"
        exit 1
    fi
    
    if ! setup_node $ARBITER2_PORT "ARBITER-2"; then
        echo -e "${RED}❌ Không thể thiết lập node ARBITER-2${NC}"
        exit 1
    fi
    
    # Khởi tạo replica set
    echo "Đang khởi tạo replica set..."
    mongosh --port $PRIMARY_PORT --eval "
        rs.initiate({
            _id: 'rs0',
            members: [
                { _id: 0, host: '${SERVER_IP}:${PRIMARY_PORT}', priority: 2 },
                { _id: 1, host: '${SERVER_IP}:${ARBITER1_PORT}', arbiterOnly: true },
                { _id: 2, host: '${SERVER_IP}:${ARBITER2_PORT}', arbiterOnly: true }
            ]
        })
    "
    
    # Đợi replica set khởi tạo
    echo "Đang đợi replica set khởi tạo..."
    sleep 10
    
    # Kiểm tra trạng thái
    mongosh --port $PRIMARY_PORT --eval "rs.status()"
    
    # Tạo user admin
    echo "Đang tạo user admin..."
    mongosh --port $PRIMARY_PORT --eval "
        db = db.getSiblingDB('admin');
        db.createUser({
            user: '${admin_username}',
            pwd: '${admin_password}',
            roles: [
                { role: 'root', db: 'admin' },
                { role: 'clusterAdmin', db: 'admin' }
            ]
        })
    "
    
    # Khởi động lại với xác thực
    echo "Đang khởi động lại MongoDB với xác thực..."
    stop_mongodb
    
    # Cập nhật cấu hình với xác thực
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        sed -i '/security:/c\security:\n  authorization: enabled\n  keyFile: /etc/mongodb.key' /etc/mongod_${port}.conf
    done
    
    # Khởi động lại các node
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        echo "Đang khởi động MongoDB trên port ${port}..."
        mongod --config /etc/mongod_${port}.conf --fork
    done
    
    # Đợi MongoDB khởi động
    sleep 10
    
    # Kiểm tra kết nối với xác thực
    echo "Đang kiểm tra kết nối với xác thực..."
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval "db.adminCommand('ping')"
    
    # Kiểm tra trạng thái replica set
    echo "Trạng thái replica set:"
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval "rs.status()"
    
    # Tạo các service
    echo "Đang tạo các service..."
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        cat > /etc/systemd/system/mongod_${port}.service << EOL
[Unit]
Description=MongoDB Database Server on port ${port}
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod_${port}.conf
ExecStop=/usr/bin/mongod --config /etc/mongod_${port}.conf --shutdown
Restart=always
LimitNOFILE=64000
TimeoutStartSec=180
EnvironmentFile=-/etc/default/mongod

[Install]
WantedBy=multi-user.target
EOL
    done
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable services
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        systemctl enable mongod_${port}
    done
    
    # Hiển thị thông tin kết nối
    echo -e "\n${GREEN}✅ Đã cấu hình MongoDB Replica Set PRIMARY thành công${NC}"
    echo "Thông tin kết nối:"
    echo "IP: $SERVER_IP"
    echo "Ports: $PRIMARY_PORT (PRIMARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
    echo "Username: $admin_username"
    echo "Password: $admin_password"
    echo "Connection string: mongodb://${admin_username}:${admin_password}@${SERVER_IP}:${PRIMARY_PORT}/?authSource=admin&replicaSet=rs0"
    
    # Tạo hướng dẫn
    cat > mongodb_replica_guide.txt << EOL
HƯỚNG DẪN SỬ DỤNG MONGODB REPLICA SET

IP Server: ${SERVER_IP}
Ports: ${PRIMARY_PORT} (PRIMARY), ${ARBITER1_PORT} (ARBITER), ${ARBITER2_PORT} (ARBITER)
Username: ${admin_username}
Password: ${admin_password}

1. Kết nối đến MongoDB:
   mongosh --host ${SERVER_IP} --port ${PRIMARY_PORT} -u ${admin_username} -p ${admin_password} --authenticationDatabase admin

2. Connection string:
   mongodb://${admin_username}:${admin_password}@${SERVER_IP}:${PRIMARY_PORT}/?authSource=admin&replicaSet=rs0

3. Kiểm tra trạng thái replica set:
   rs.status()

4. Xem cấu hình replica set:
   rs.conf()

5. Quản lý service:
   sudo systemctl start|stop|restart|status mongod_${PRIMARY_PORT}
   sudo systemctl start|stop|restart|status mongod_${ARBITER1_PORT}
   sudo systemctl start|stop|restart|status mongod_${ARBITER2_PORT}

6. Xem log:
   sudo tail -f /var/log/mongodb/mongod_${PRIMARY_PORT}.log
EOL
    
    echo -e "\n${GREEN}Hướng dẫn đã được lưu vào file: mongodb_replica_guide.txt${NC}"
}

# Menu chính
main_menu() {
    echo -e "${YELLOW}=== THIẾT LẬP MONGODB REPLICA SET ===${NC}"
    echo "1. Thiết lập MongoDB Replica Set PRIMARY"
    echo "0. Thoát"
    
    read -p "Chọn một tùy chọn: " choice
    
    case $choice in
        1)
            setup_replica_primary
            ;;
        0)
            echo "Đã thoát."
            exit 0
            ;;
        *)
            echo -e "${RED}Tùy chọn không hợp lệ.${NC}"
            exit 1
            ;;
    esac
}

# Chạy menu chính
main_menu 