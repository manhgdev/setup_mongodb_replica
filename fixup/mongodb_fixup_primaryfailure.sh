#!/bin/bash

echo "====== FIX LỖI KHÔNG THỂ BẦU CHỌN PRIMARY NODE ======"

# Variables
PORT="27017"
REPLICA_SET="rs0"
USERNAME="manhg"
PASSWORD="manhnk"

# Prompt for values
read -p "Port MongoDB [$PORT]: " USER_PORT
PORT=${USER_PORT:-$PORT}

read -p "Tên replica set [$REPLICA_SET]: " USER_RS
REPLICA_SET=${USER_RS:-$REPLICA_SET}

read -p "Tên người dùng MongoDB [$USERNAME]: " USER_NAME
USERNAME=${USER_NAME:-$USERNAME}

read -p "Mật khẩu MongoDB [$PASSWORD]: " USER_PASS
PASSWORD=${USER_PASS:-$PASSWORD}

# Kiểm tra trạng thái của replica set
echo "Kiểm tra trạng thái replica set..."
rs_status=$(mongosh --port $PORT --eval "rs.status()")
echo "$rs_status" | grep -E "name|stateStr|health"

# Kiểm tra cấu hình
echo "Kiểm tra cấu hình replica set..."
rs_config=$(mongosh --port $PORT --eval "rs.conf()")
echo "$rs_config" | grep -E "host|_id|priority"

# Các tùy chọn sửa lỗi
echo ""
echo "=== TÙY CHỌN SỬA LỖI ==="
echo "1. Force bầu chọn lại (reconfig with force)"
echo "2. Dừng một node lỗi (stop)"
echo "3. Thiết lập lại cấu hình replica (reconfigure)"
echo "4. Thoát (exit)"
read -p "Lựa chọn của bạn (1-4): " choice

case $choice in
    1)
        echo "Đang force bầu chọn lại..."
        mongosh --port $PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "rs.reconfig(rs.conf(), {force: true})"
        
        echo "Đợi 10 giây để thiết lập mới..."
        sleep 10
        
        echo "Kiểm tra lại trạng thái..."
        mongosh --port $PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "rs.status()"
        ;;
    2)
        read -p "Nhập tên node để dừng (ví dụ: 192.168.1.10:27017): " NODE_NAME
        
        if [ -z "$NODE_NAME" ]; then
            echo "Tên node không hợp lệ"
            exit 1
        fi
        
        # Nếu node này là node local
        if [[ "$NODE_NAME" == *"$(hostname -I | awk '{print $1}')"* ]] || [[ "$NODE_NAME" == *"127.0.0.1"* ]] || [[ "$NODE_NAME" == *"localhost"* ]]; then
            echo "Dừng MongoDB trên node này..."
            sudo systemctl stop mongod
        else
            echo "Node này không phải node local."
            echo "Bạn cần SSH vào $NODE_NAME và chạy lệnh: sudo systemctl stop mongod"
        fi
        ;;
    3)
        echo "Thiết lập lại cấu hình replica set..."
        read -p "Nhập IP của server primary: " PRIMARY_IP
        read -p "Nhập IP của server secondary: " SECONDARY_IP
        
        if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ]; then
            echo "IP không hợp lệ"
            exit 1
        fi
        
        config_cmd="rs.initiate({
          _id: '$REPLICA_SET',
          members: [
            { _id: 0, host: '$PRIMARY_IP:$PORT', priority: 10 },
            { _id: 1, host: '$SECONDARY_IP:$PORT', priority: 5 }
          ]
        })"
        
        echo "Đang áp dụng cấu hình mới..."
        mongosh --port $PORT --eval "$config_cmd"
        
        echo "Đợi 15 giây để thiết lập..."
        sleep 15
        
        echo "Kiểm tra trạng thái..."
        mongosh --port $PORT --eval "rs.status()"
        ;;
    4)
        echo "Thoát."
        exit 0
        ;;
    *)
        echo "Lựa chọn không hợp lệ"
        exit 1
        ;;
esac

echo ""
echo "Nếu MongoDB replica set đã hoạt động bình thường, bạn có thể tiếp tục với ứng dụng của mình."
echo "Sử dụng chuỗi kết nối từ script chính để kết nối đến MongoDB Replica Set." 