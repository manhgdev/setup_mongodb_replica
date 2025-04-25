#!/bin/bash

# ĐẬP ĐI XÂY LẠI: Script cấu hình MongoDB Replica Set cho Linux
# Đảm bảo tạo thành công và đăng nhập được

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hàm tạo keyFile dùng chung cho các node
create_keyfile() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Tạo keyFile cho MongoDB..."
        sudo openssl rand -base64 756 > "$KEY_FILE"
        sudo chown mongodb:mongodb "$KEY_FILE"
        sudo chmod 600 "$KEY_FILE"
    fi
}

# Hàm tạo config và service cho từng node
setup_mongod_node() {
    local PORT=$1
    local DBPATH="/var/lib/mongodb_${PORT}"
    local LOGPATH="/var/log/mongodb/mongod_${PORT}.log"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local SERVICE_NAME="mongod_${PORT}"

    sudo mkdir -p "$DBPATH" /var/log/mongodb
    sudo chown -R mongodb:mongodb "$DBPATH" /var/log/mongodb

    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
systemLog:
  destination: file
  path: $LOGPATH
  logAppend: true
storage:
  dbPath: $DBPATH
net:
  bindIp: 0.0.0.0
  port: $PORT
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
EOF

    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=MongoDB Replica Node (Port $PORT)
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
    sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME
}

# Hàm tạo user admin (idempotent)
create_admin_user() {
    local PORT=$1
    local USERNAME=$2
    local PASSWORD=$3
    mongosh --port $PORT --eval '
        db = db.getSiblingDB("admin");
        if (!db.getUser("'$USERNAME'")) {
            db.createUser({user: "'$USERNAME'", pwd: "'$PASSWORD'", roles: [ { role: "root", db: "admin" }, { role: "clusterAdmin", db: "admin" } ]});
        }
    '
}

# Hàm cấu hình PRIMARY
setup_replica_primary_linux() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    read -p "Nhập username admin (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Nhập password admin (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}

    echo "Dừng mọi tiến trình mongod..."
    sudo pkill -f "mongod" || true
    sleep 2

    create_keyfile
    setup_mongod_node $PRIMARY_PORT
    setup_mongod_node $ARBITER1_PORT
    setup_mongod_node $ARBITER2_PORT
    sleep 5

    # Tạo user admin
    create_admin_user $PRIMARY_PORT $admin_username $admin_password
    sleep 2

    # Khởi tạo replica set nếu chưa có
    local rs_status=$(mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'try{rs.status()}catch(e){print(e)}' --quiet)
    if echo "$rs_status" | grep -q "NotYetInitialized"; then
        mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
            rs.initiate({
                _id: "rs0",
                members: [
                    { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
                    { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
                    { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
                ]
            })
        '
        sleep 5
    fi

    # Kiểm tra đăng nhập
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})'
    if [ $? -eq 0 ]; then
        echo "\n✅ Đã cấu hình và đăng nhập thành công PRIMARY node"
        echo "Kết nối: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
    else
        echo "❌ Đăng nhập thất bại. Kiểm tra lại log."
    fi
}

# Hàm cấu hình SECONDARY
setup_replica_secondary_linux() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    read -p "Nhập IP của PRIMARY server: " primary_ip
    if [ -z "$primary_ip" ]; then
        echo "❌ IP của PRIMARY server là bắt buộc"
        return 1
    fi
    read -p "Nhập username admin (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Nhập password admin (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}

    sudo pkill -f "mongod" || true
    sleep 2
    create_keyfile
    setup_mongod_node $PRIMARY_PORT
    setup_mongod_node $ARBITER1_PORT
    setup_mongod_node $ARBITER2_PORT
    sleep 5

    # Đợi PRIMARY sẵn sàng
    local max_attempts=30
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --host $primary_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})' &>/dev/null; then
            break
        fi
        echo "Chờ PRIMARY sẵn sàng... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt+1))
    done
    if [ $attempt -gt $max_attempts ]; then
        echo "❌ Không thể kết nối đến PRIMARY server"
        return 1
    fi

    # Thêm node vào replica set nếu chưa có
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        local host="$SERVER_IP:$port"
        local check=$(mongosh --host $primary_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status().members.map(m=>m.name)' --quiet | grep "$host")
        if [ -z "$check" ]; then
            if [ $port -eq $PRIMARY_PORT ]; then
                mongosh --host $primary_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.add("'$host'")'
            else
                mongosh --host $primary_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.addArb("'$host'")'
            fi
            sleep 2
        fi
    done

    # Kiểm tra đăng nhập
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})'
    if [ $? -eq 0 ]; then
        echo "\n✅ Đã cấu hình và đăng nhập thành công SECONDARY node"
        echo "Kết nối: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
    else
        echo "❌ Đăng nhập thất bại. Kiểm tra lại log."
    fi
}