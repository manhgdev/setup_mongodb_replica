#!/bin/bash

# Import các hàm từ file khác
if [ -f "$(dirname "$0")/generate_guide.sh" ]; then
    source "$(dirname "$0")/generate_guide.sh"
else
    echo "⚠️ Không tìm thấy file generate_guide.sh"
    echo "Đang tạo file hướng dẫn mới..."
    cat > "$(dirname "$0")/generate_guide.sh" << 'EOL'
#!/bin/bash

generate_setup_guide() {
    local SERVER_IP=$1
    local PRIMARY_PORT=$2
    local ARBITER1_PORT=$3
    local ARBITER2_PORT=$4
    local ADMIN_USERNAME=$5
    local ADMIN_PASSWORD=$6
    
    local GUIDE_FILE="mongodb_replica_setup_guide.txt"
    
    cat > "$GUIDE_FILE" << EOL
=== Hướng dẫn cài đặt MongoDB Replica Set ===

1. Thông tin kết nối:
   - IP: $SERVER_IP
   - Ports:
     + $PRIMARY_PORT (PRIMARY)
     + $ARBITER1_PORT (ARBITER)
     + $ARBITER2_PORT (ARBITER)
   - Username: $ADMIN_USERNAME
   - Password: $ADMIN_PASSWORD

2. Kết nối đến MongoDB:
   mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin

3. Kiểm tra trạng thái replica set:
   rs.status()

4. Các lệnh hữu ích:
   - Xem cấu hình replica set: rs.conf()
   - Xem trạng thái các node: rs.status()
   - Thêm node mới: rs.add("host:port")
   - Thêm arbiter: rs.addArb("host:port")
   - Xóa node: rs.remove("host:port")

5. Lưu ý:
   - Giữ keyFile an toàn: /etc/mongodb.key
   - Log files nằm ở: /var/log/mongodb/
   - Data files nằm ở: /var/lib/mongodb_*
EOL
    
    echo "✅ Đã tạo file hướng dẫn: $GUIDE_FILE"
}
EOL
    chmod +x "$(dirname "$0")/generate_guide.sh"
    source "$(dirname "$0")/generate_guide.sh"
fi

setup_node_linux() {
    local PORT=$1
    local NODE_TYPE=$2
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Tạo thư mục data cho node
    sudo mkdir -p "/var/lib/mongodb_${PORT}"
    sudo mkdir -p "/var/log/mongodb"
    sudo chown -R mongodb:mongodb "/var/lib/mongodb_${PORT}"
    sudo chown -R mongodb:mongodb "/var/log/mongodb"
    
    # Tạo keyFile nếu chưa tồn tại
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Đang tạo keyFile..."
        openssl rand -base64 756 > "$KEY_FILE"
        sudo chown mongodb:mongodb "$KEY_FILE"
        sudo chmod 600 "$KEY_FILE"
    fi
    
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
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
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
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --port $PORT --eval 'db.runCommand({ ping: 1 })' &> /dev/null; then
            echo "✅ Node MongoDB trên port $PORT đã sẵn sàng"
            # Đợi thêm một chút để đảm bảo MongoDB hoàn toàn sẵn sàng
            sleep 5
            return 0
        fi
        echo "Đang chờ node MongoDB trên port $PORT khởi động... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ Không thể kết nối đến node MongoDB trên port $PORT"
    echo "Đang kiểm tra log file..."
    sudo tail -n 50 /var/log/mongodb/mongod_${PORT}.log
    return 1
}

create_admin_user() {
    local PORT=$1
    local USERNAME=$2
    local PASSWORD=$3
    
    echo "Đang tạo user admin..."
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --port $PORT --eval '
            db = db.getSiblingDB("admin");
            db.createUser({
                user: "'$USERNAME'",
                pwd: "'$PASSWORD'",
                roles: [
                    { role: "root", db: "admin" },
                    { role: "clusterAdmin", db: "admin" }
                ]
            });
        ' &> /dev/null; then
            echo "✅ Đã tạo user admin thành công"
            return 0
        fi
        echo "Đang thử lại tạo user admin... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ Không thể tạo user admin"
    return 1
}

setup_replica_primary_linux() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    # Nhập thông tin user admin
    echo "Nhập username admin (mặc định: manhg): "
    read -r admin_username
    admin_username=${admin_username:-manhg}
    
    echo "Nhập password admin (mặc định: manhnk): "
    read -r admin_password
    admin_password=${admin_password:-manhnk}
    
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
    
    # Khởi tạo replica set trước
    echo "Đang khởi tạo replica set..."
    local init_result=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT --eval 'rs.initiate({
        _id: "rs0",
        members: [
            { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
            { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
            { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
        ]
    })' 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Lỗi khi khởi tạo replica set:${NC}"
        echo "$init_result"
        echo "Đang kiểm tra log file..."
        sudo tail -n 50 /var/log/mongodb/mongod_${PRIMARY_PORT}.log
        return 1
    fi
    
    # Kiểm tra trạng thái replica set ngay lập tức
    echo "Đang kiểm tra trạng thái replica set..."
    local status_result=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT --eval 'rs.status()' 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Lỗi khi kiểm tra trạng thái replica set:${NC}"
        echo "$status_result"
        echo "Đang kiểm tra log file..."
        sudo tail -n 50 /var/log/mongodb/mongod_${PRIMARY_PORT}.log
        return 1
    fi
    
    echo "Trạng thái replica set:"
    echo "$status_result"
    
    # Tạo user admin
    echo "Đang tạo user admin..."
    local create_user_result=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT --eval '
        db = db.getSiblingDB("admin");
        db.createUser({
            user: "'$admin_username'",
            pwd: "'$admin_password'",
            roles: [
                { role: "root", db: "admin" },
                { role: "clusterAdmin", db: "admin" }
            ]
        });
    ' 2>&1)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Lỗi khi tạo user admin:${NC}"
        echo "$create_user_result"
        echo "Đang kiểm tra log file..."
        sudo tail -n 50 /var/log/mongodb/mongod_${PRIMARY_PORT}.log
        return 1
    fi
    
    # Kiểm tra trạng thái cuối cùng
    echo "Đang kiểm tra trạng thái cuối cùng..."
    local final_status=$(mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status()' 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Lỗi khi kiểm tra trạng thái cuối cùng:${NC}"
        echo "$final_status"
        echo "Đang kiểm tra log file..."
        sudo tail -n 50 /var/log/mongodb/mongod_${PRIMARY_PORT}.log
        return 1
    fi
    
    echo -e "${GREEN}✅ Đã cấu hình MongoDB Replica Set PRIMARY thành công${NC}"
    echo "Thông tin kết nối:"
    echo "IP: $SERVER_IP"
    echo "Ports: $PRIMARY_PORT (PRIMARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
    echo "Username: $admin_username"
    echo "Password: $admin_password"
    
    # Tạo file hướng dẫn
    generate_setup_guide $SERVER_IP $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT $admin_username $admin_password
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
    
    # Nhập thông tin user admin
    echo "Nhập username admin (mặc định: manhg): "
    read -r admin_username
    admin_username=${admin_username:-manhg}
    
    echo "Nhập password admin (mặc định: manhnk): "
    read -r admin_password
    admin_password=${admin_password:-manhnk}
    
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
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status()' &> /dev/null; then
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
    
    # Kiểm tra và thêm các node vào replica set
    echo "Đang kiểm tra và thêm các node vào replica set..."
    local rs_status=$(mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status()' --quiet)
    
    # Thêm node SECONDARY nếu chưa tồn tại
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$PRIMARY_PORT"; then
        echo "Đang thêm node SECONDARY vào replica set..."
        mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.add("'$SERVER_IP:$PRIMARY_PORT'")'
        sleep 2
    else
        echo "✅ Node SECONDARY đã tồn tại trong replica set"
    fi
    
    # Thêm node ARBITER 1 nếu chưa tồn tại
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$ARBITER1_PORT"; then
        echo "Đang thêm node ARBITER 1 vào replica set..."
        mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.addArb("'$SERVER_IP:$ARBITER1_PORT'")'
        sleep 2
    else
        echo "✅ Node ARBITER 1 đã tồn tại trong replica set"
    fi
    
    # Thêm node ARBITER 2 nếu chưa tồn tại
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$ARBITER2_PORT"; then
        echo "Đang thêm node ARBITER 2 vào replica set..."
        mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.addArb("'$SERVER_IP:$ARBITER2_PORT'")'
        sleep 2
    else
        echo "✅ Node ARBITER 2 đã tồn tại trong replica set"
    fi
    
    # Kiểm tra trạng thái
    if check_replica_status $PRIMARY_PORT $admin_username $admin_password; then
        echo -e "${GREEN}✅ Đã cấu hình MongoDB Replica Set SECONDARY thành công${NC}"
        echo "Thông tin kết nối:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (SECONDARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
        echo "Đã kết nối với PRIMARY server: $primary_server_ip"
        echo "Username: $admin_username"
        echo "Password: $admin_password"
    else
        echo -e "${RED}❌ Có lỗi xảy ra khi cấu hình SECONDARY${NC}"
    fi
} 