#!/bin/bash

setup_node_linux() {
    local PORT=$1
    local NODE_TYPE=$2
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Tạo thư mục data cho node
    sudo mkdir -p "/var/lib/mongodb_${PORT}"
    sudo mkdir -p "/var/log/mongodb"
    sudo chown -R mongodb:mongodb "/var/lib/mongodb_${PORT}"
    sudo chown -R mongodb:mongodb "/var/log/mongodb"
    
    # Tạo file config cho node
    sudo tee "$CONFIG_FILE" > /dev/null << EOL
systemLog:
  destination: file
  path: /var/log/mongodb/mongod_${PORT}.log
  logAppend: true
storage:
  dbPath: /var/lib/mongodb_${PORT}
net:
  bindIp: 0.0.0.0
  port: ${PORT}
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
processManagement:
  fork: true
EOL

    # Dừng instance MongoDB hiện tại nếu có
    sudo pkill -f "mongod.*${PORT}" || true
    sleep 2
    
    # Khởi động node MongoDB
    echo "Đang khởi động MongoDB trên port $PORT..."
    sudo mongod --config "$CONFIG_FILE"
    
    # Kiểm tra kết nối
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --port $PORT --eval 'db.runCommand({ ping: 1 })' &> /dev/null; then
            echo "✅ Node MongoDB trên port $PORT đã sẵn sàng"
            return 0
        fi
        echo "Đang chờ node MongoDB trên port $PORT khởi động... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ Không thể kết nối đến node MongoDB trên port $PORT"
    return 1
}

setup_replica_primary_linux() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    # Dừng các instance MongoDB hiện tại
    sudo systemctl stop mongod || true
    sleep 2
    
    # Thiết lập các node
    echo "Đang thiết lập node PRIMARY..."
    if ! setup_node_linux $PRIMARY_PORT "primary"; then
        echo -e "${RED}❌ Không thể khởi động node PRIMARY${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 1..."
    if ! setup_node_linux $ARBITER1_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 1${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 2..."
    if ! setup_node_linux $ARBITER2_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 2${NC}"
        return 1
    fi
    
    sleep 5
    
    # Khởi tạo replica set
    echo "Đang khởi tạo replica set..."
    mongosh --port $PRIMARY_PORT --eval 'rs.initiate({
        _id: "rs0",
        members: [
            { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
            { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
            { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
        ]
    })'
    
    # Kiểm tra trạng thái
    if check_replica_status $PRIMARY_PORT; then
        echo -e "${GREEN}✅ Đã cấu hình MongoDB Replica Set PRIMARY thành công${NC}"
        echo "Thông tin kết nối:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (PRIMARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
    else
        echo -e "${RED}❌ Có lỗi xảy ra khi cấu hình PRIMARY${NC}"
    fi
}

setup_replica_secondary_linux() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    echo "Nhập IP của PRIMARY server: "
    read -r primary_server_ip
    if [ -z "$primary_server_ip" ]; then
        echo -e "${RED}❌ IP của PRIMARY server là bắt buộc${NC}"
        return 1
    fi
    
    # Dừng các instance MongoDB hiện tại
    sudo systemctl stop mongod || true
    sleep 2
    
    # Thiết lập các node
    echo "Đang thiết lập node SECONDARY..."
    if ! setup_node_linux $PRIMARY_PORT "secondary"; then
        echo -e "${RED}❌ Không thể khởi động node SECONDARY${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 1..."
    if ! setup_node_linux $ARBITER1_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 1${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 2..."
    if ! setup_node_linux $ARBITER2_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 2${NC}"
        return 1
    fi
    
    sleep 5
    
    # Kết nối với PRIMARY server
    echo "Đang kết nối với PRIMARY server..."
    
    # Đợi PRIMARY server sẵn sàng
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --host $primary_server_ip --port $PRIMARY_PORT --eval 'rs.status()' &> /dev/null; then
            echo "✅ PRIMARY server đã sẵn sàng"
            break
        fi
        echo "Đang chờ PRIMARY server sẵn sàng... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}❌ Không thể kết nối đến PRIMARY server${NC}"
        return 1
    fi
    
    # Thêm các node vào replica set
    echo "Đang thêm node SECONDARY vào replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT --eval 'rs.add("'$SERVER_IP:$PRIMARY_PORT'")'
    
    echo "Đang thêm node ARBITER 1 vào replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT --eval 'rs.addArb("'$SERVER_IP:$ARBITER1_PORT'")'
    
    echo "Đang thêm node ARBITER 2 vào replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT --eval 'rs.addArb("'$SERVER_IP:$ARBITER2_PORT'")'
    
    # Kiểm tra trạng thái
    if check_replica_status $PRIMARY_PORT; then
        echo -e "${GREEN}✅ Đã cấu hình MongoDB Replica Set SECONDARY thành công${NC}"
        echo "Thông tin kết nối:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (SECONDARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
        echo "Đã kết nối với PRIMARY server: $primary_server_ip"
    else
        echo -e "${RED}❌ Có lỗi xảy ra khi cấu hình SECONDARY${NC}"
    fi
} 