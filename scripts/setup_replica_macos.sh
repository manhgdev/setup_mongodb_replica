#!/bin/bash

setup_node_macos() {
    local PORT=$1
    local NODE_TYPE=$2
    local ENABLE_SECURITY=$3 # "yes" hoặc "no"
    local CONFIG_FILE="/opt/homebrew/etc/mongod_${PORT}.conf"

    mkdir -p "/opt/homebrew/var/mongodb_${PORT}"
    mkdir -p "/opt/homebrew/var/log/mongodb"

    cat > "$CONFIG_FILE" <<EOL
systemLog:
  destination: file
  path: /opt/homebrew/var/log/mongodb/mongod_${PORT}.log
  logAppend: true
storage:
  dbPath: /opt/homebrew/var/mongodb_${PORT}
net:
  bindIp: 0.0.0.0
  port: ${PORT}
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
EOL

    if [ "$ENABLE_SECURITY" = "yes" ]; then
        cat >> "$CONFIG_FILE" <<EOL
security:
  authorization: enabled
  keyFile: /opt/homebrew/etc/mongodb.key
EOL
    fi

    mongod --config "$CONFIG_FILE" --fork
}

create_keyfile_macos() {
    local KEY_FILE="/opt/homebrew/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Tạo keyFile cho MongoDB..."
        openssl rand -base64 756 > "$KEY_FILE"
        chown $(whoami) "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
}

setup_replica_primary_macos() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1

    read -p "Nhập username admin (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Nhập password admin (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}

    pkill mongod || true
    sleep 2

    # Bước 1: KHÔNG bật security, khởi động các node
    setup_node_macos $PRIMARY_PORT "primary" "no"
    setup_node_macos $ARBITER1_PORT "arbiter" "no"
    setup_node_macos $ARBITER2_PORT "arbiter" "no"
    sleep 5

    # Bước 2: Khởi tạo replica set
    mongosh --port $PRIMARY_PORT --eval 'rs.initiate({
        _id: "rs0",
        members: [
            { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
            { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
            { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
        ]
    })'
    sleep 3

    # Bước 3: Tạo user admin
    mongosh --port $PRIMARY_PORT --eval '
        db = db.getSiblingDB("admin");
        if (!db.getUser("'$admin_username'")) {
            db.createUser({user: "'$admin_username'", pwd: "'$admin_password'", roles: [ { role: "root", db: "admin" }, { role: "clusterAdmin", db: "admin" } ]});
        }
    '
    sleep 2

    # Bước 4: Bật security, restart các node
    create_keyfile_macos
    pkill mongod || true
    sleep 2
    setup_node_macos $PRIMARY_PORT "primary" "yes"
    setup_node_macos $ARBITER1_PORT "arbiter" "yes"
    setup_node_macos $ARBITER2_PORT "arbiter" "yes"
    sleep 5

    # Bước 5: Kiểm tra đăng nhập
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})'
    if [ $? -eq 0 ]; then
        echo "\n✅ Đã cấu hình và đăng nhập thành công PRIMARY node"
        echo "Kết nối: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
    else
        echo "❌ Đăng nhập thất bại. Kiểm tra lại log."
    fi
}

setup_replica_secondary_macos() {
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
    pkill mongod || true
    sleep 2
    
    # Thiết lập các node
    echo "Đang thiết lập node SECONDARY..."
    if ! setup_node_macos $PRIMARY_PORT "secondary"; then
        echo -e "${RED}❌ Không thể khởi động node SECONDARY${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 1..."
    if ! setup_node_macos $ARBITER1_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 1${NC}"
        return 1
    fi
    
    echo "Đang thiết lập node ARBITER 2..."
    if ! setup_node_macos $ARBITER2_PORT "arbiter"; then
        echo -e "${RED}❌ Không thể khởi động node ARBITER 2${NC}"
        return 1
    fi
    
    sleep 5
    
    # Kết nối với PRIMARY server
    echo "Đang kết nối với PRIMARY server..."
    
    # Đợi PRIMARY server sẵn sàng
    local max_attempts=10
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