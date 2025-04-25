#!/bin/bash

get_server_ip() {
    # Thử lấy IP từ hostname -I (Linux)
    local IP=$(hostname -I | awk '{print $1}')
    
    # Nếu không có IP, thử lấy từ ipconfig (macOS)
    if [ -z "$IP" ]; then
        IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
    fi
    
    # Nếu vẫn không có IP, thử lấy từ ifconfig
    if [ -z "$IP" ]; then
        IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)
    fi
    
    echo "$IP"
}

setup_node() {
    local PORT=$1
    local NODE_TYPE=$2
    local CONFIG_FILE="/opt/homebrew/etc/mongod_${PORT}.conf"
    
    # Tạo thư mục data cho node
    mkdir -p "/opt/homebrew/var/mongodb_${PORT}"
    mkdir -p "/opt/homebrew/var/log/mongodb"
    
    # Tạo file config cho node
    cat > "$CONFIG_FILE" << EOL
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

    # Khởi động node MongoDB
    mongod --config "$CONFIG_FILE" --fork
}

check_replica_status() {
    local PORT=$1
    echo "Kiểm tra trạng thái replica set trên port $PORT..."
    
    # Đợi replica set khởi tạo
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local status=$(mongosh --port $PORT --eval 'rs.status()' --quiet 2>/dev/null)
        
        if [ $? -eq 0 ] && [ ! -z "$status" ]; then
            echo "✅ Replica set đã sẵn sàng"
            echo "Thông tin chi tiết:"
            mongosh --port $PORT --eval 'rs.status()' --quiet
            return 0
        fi
        
        echo "Đang chờ replica set khởi tạo... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ Không thể kết nối đến replica set sau $max_attempts lần thử"
    return 1
}

setup_replica_primary() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    # Dừng các instance MongoDB hiện tại
    pkill mongod || true
    sleep 2
    
    # Thiết lập các node
    setup_node $PRIMARY_PORT "primary"
    setup_node $ARBITER1_PORT "arbiter"
    setup_node $ARBITER2_PORT "arbiter"
    
    sleep 5
    
    # Khởi tạo replica set với tham số allowMultipleArbiters
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
        echo "✅ Đã cấu hình MongoDB Replica Set PRIMARY thành công"
        echo "Thông tin kết nối:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (PRIMARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
    else
        echo "❌ Có lỗi xảy ra khi cấu hình PRIMARY"
    fi
}

setup_replica_secondary() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    echo "Nhập IP của PRIMARY server: "
    read -r primary_server_ip
    if [ -z "$primary_server_ip" ]; then
        echo "❌ IP của PRIMARY server là bắt buộc"
        return 1
    fi
    
    # Dừng các instance MongoDB hiện tại
    pkill mongod || true
    sleep 2
    
    # Thiết lập các node
    setup_node $PRIMARY_PORT "secondary"
    setup_node $ARBITER1_PORT "arbiter"
    setup_node $ARBITER2_PORT "arbiter"
    
    sleep 5
    
    # Kết nối với PRIMARY server
    echo "Đang kết nối với PRIMARY server..."
    mongosh --port $PRIMARY_PORT --eval 'rs.add("'$SERVER_IP:$PRIMARY_PORT'")'
    mongosh --port $PRIMARY_PORT --eval 'rs.addArb("'$SERVER_IP:$ARBITER1_PORT'")'
    mongosh --port $PRIMARY_PORT --eval 'rs.addArb("'$SERVER_IP:$ARBITER2_PORT'")'
    
    # Kiểm tra trạng thái
    if check_replica_status $PRIMARY_PORT; then
        echo "✅ Đã cấu hình MongoDB Replica Set SECONDARY thành công"
        echo "Thông tin kết nối:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (SECONDARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
        echo "Đã kết nối với PRIMARY server: $primary_server_ip"
    else
        echo "❌ Có lỗi xảy ra khi cấu hình SECONDARY"
    fi
}

show_menu() {
    echo "=== MongoDB Replica Set Setup ==="
    echo "1. Cấu hình Server PRIMARY"
    echo "2. Cấu hình Server SECONDARY"
    echo "3. Thoát"
    echo "Chọn một tùy chọn (1-3): "
}

main() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1|2)
                echo "Nhập IP của server này [Enter để tự động lấy IP]: "
                read -r server_ip
                if [ -z "$server_ip" ]; then
                    server_ip=$(get_server_ip)
                    echo "Đã tự động lấy IP: $server_ip"
                fi
                
                if [ "$choice" == "1" ]; then
                    setup_replica_primary "$server_ip"
                else
                    setup_replica_secondary "$server_ip"
                fi
                ;;
            3)
                echo "Thoát chương trình"
                exit 0
                ;;
            *)
                echo "❌ Lựa chọn không hợp lệ"
                ;;
        esac
    done
}

# Chỉ chạy main() nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi 