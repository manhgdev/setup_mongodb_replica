#!/bin/bash

# Thiết lập MongoDB Replica Set phân tán với tự động failover
# Màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Thông tin cấu hình
REPLICA_SET="rs0"
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
KEYFILE="/etc/mongodb-keyfile"
BASE_PORT=27017

# Lấy IP của server hiện tại
THIS_SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${BLUE}=== THIẾT LẬP MONGODB REPLICA SET (NHIỀU SERVER) ===${NC}"

# Hỏi thông tin server
read -p "Server này là PRIMARY? (y/n): " IS_PRIMARY
read -p "Số lượng server khác (không tính server này): " OTHER_SERVER_COUNT

# Lưu danh sách IP của các server khác
OTHER_SERVER_IPS=()
for ((i=1; i<=$OTHER_SERVER_COUNT; i++)); do
    read -p "Địa chỉ IP của server $i: " IP
    OTHER_SERVER_IPS+=($IP)
done

# 1. Kiểm tra và tạo keyfile
echo -e "${YELLOW}Kiểm tra keyfile...${NC}"
if [ ! -f "$KEYFILE" ]; then
    openssl rand -base64 756 > "$KEYFILE"
    chmod 400 "$KEYFILE"
    chown mongodb:mongodb "$KEYFILE"
    echo -e "${GREEN}✓ Đã tạo keyfile mới${NC}"
else
    echo -e "${GREEN}✓ Keyfile đã tồn tại${NC}"
fi

# 2. Tạo thư mục và file cấu hình cho PRIMARY/SECONDARY
echo -e "${YELLOW}Thiết lập PRIMARY/SECONDARY (Port $BASE_PORT)...${NC}"

# Tạo thư mục data
mkdir -p "/var/lib/mongodb"
chown -R mongodb:mongodb "/var/lib/mongodb"
chmod 750 "/var/lib/mongodb"

# Tạo file cấu hình
cat > "/etc/mongod.conf" << EOF
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true

net:
  port: $BASE_PORT
  bindIp: 0.0.0.0

security:
  keyFile: $KEYFILE
  authorization: enabled

replication:
  replSetName: $REPLICA_SET
EOF

# Tạo service
cat > "/etc/systemd/system/mongod.service" << EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
EnvironmentFile=-/etc/default/mongod
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
PIDFile=/var/run/mongodb/mongod.pid
RuntimeDirectory=mongodb
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

# Khởi động service
systemctl daemon-reload
systemctl enable mongod
systemctl restart mongod

echo -e "${GREEN}✓ Đã thiết lập PRIMARY/SECONDARY${NC}"

# 3. Tạo thư mục và file cấu hình cho 2 ARBITER
for i in {1..2}; do
    PORT=$((BASE_PORT + i))
    NODE="arbiter$i"
    echo -e "${YELLOW}Thiết lập $NODE (Port $PORT)...${NC}"
    
    # Tạo thư mục data
    mkdir -p "/var/lib/mongodb-$NODE"
    chown -R mongodb:mongodb "/var/lib/mongodb-$NODE"
    chmod 750 "/var/lib/mongodb-$NODE"
    
    # Tạo file cấu hình
    cat > "/etc/mongod-$NODE.conf" << EOF
storage:
  dbPath: /var/lib/mongodb-$NODE

systemLog:
  destination: file
  path: /var/log/mongodb/mongod-$NODE.log
  logAppend: true

net:
  port: $PORT
  bindIp: 0.0.0.0

security:
  keyFile: $KEYFILE
  authorization: enabled

replication:
  replSetName: $REPLICA_SET
EOF

    # Tạo service
    cat > "/etc/systemd/system/mongod-$NODE.service" << EOF
[Unit]
Description=MongoDB Database Server - $NODE
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
EnvironmentFile=-/etc/default/mongod
ExecStart=/usr/bin/mongod --config /etc/mongod-$NODE.conf
PIDFile=/var/run/mongodb/mongod-$NODE.pid
RuntimeDirectory=mongodb
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    # Khởi động service
    systemctl daemon-reload
    systemctl enable "mongod-$NODE"
    systemctl restart "mongod-$NODE"
    
    echo -e "${GREEN}✓ Đã thiết lập $NODE${NC}"
done

# 4. Đợi các node khởi động
echo -e "${YELLOW}Đợi các node khởi động (5 giây)...${NC}"
sleep 5

# 5. Nếu là PRIMARY, khởi tạo replica set
if [[ "$IS_PRIMARY" == "y" ]]; then
    echo -e "${YELLOW}Khởi tạo replica set...${NC}"
    
    # Tạo chuỗi members cho replica set
    MEMBERS_JSON="[
        { _id: 0, host: '$THIS_SERVER_IP:$BASE_PORT', priority: 2 },
        { _id: 1, host: '$THIS_SERVER_IP:$((BASE_PORT + 1))', arbiterOnly: true },
        { _id: 2, host: '$THIS_SERVER_IP:$((BASE_PORT + 2))', arbiterOnly: true }"
    
    # Thêm các server khác vào members
    MEMBER_ID=3
    for IP in "${OTHER_SERVER_IPS[@]}"; do
        MEMBERS_JSON+=",
        { _id: $MEMBER_ID, host: '$IP:$BASE_PORT', priority: 1 },
        { _id: $((MEMBER_ID + 1)), host: '$IP:$((BASE_PORT + 1))', arbiterOnly: true },
        { _id: $((MEMBER_ID + 2)), host: '$IP:$((BASE_PORT + 2))', arbiterOnly: true }"
        MEMBER_ID=$((MEMBER_ID + 3))
    done
    
    MEMBERS_JSON+="]"
    
    # Khởi tạo replica set
    mongosh "mongodb://localhost:$BASE_PORT" --eval "
    rs.initiate({
        _id: '$REPLICA_SET',
        members: $MEMBERS_JSON
    })"

    # Đợi PRIMARY được bầu
    echo -e "${YELLOW}Đợi PRIMARY được bầu (5 giây)...${NC}"
    sleep 5

    # Tạo user admin
    echo -e "${YELLOW}Tạo user admin...${NC}"
    mongosh "mongodb://localhost:$BASE_PORT" --eval "
    db.getSiblingDB('admin').createUser({
        user: '$USERNAME',
        pwd: '$PASSWORD',
        roles: ['root']
    })"
else
    # Nếu là SECONDARY, đợi PRIMARY khởi tạo xong
    echo -e "${YELLOW}Đợi PRIMARY khởi tạo replica set (10 giây)...${NC}"
    sleep 10
fi

# 6. Kiểm tra trạng thái cuối cùng
echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
mongosh "mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin" --eval "rs.status()" --quiet | grep -E "name|stateStr"

echo -e "${GREEN}=== HOÀN THÀNH THIẾT LẬP ===${NC}"
echo -e "Các node đã được thiết lập:"
echo -e "Server hiện tại ($THIS_SERVER_IP):"
echo -e "- PRIMARY/SECONDARY: $THIS_SERVER_IP:$BASE_PORT"
echo -e "- ARBITER 1: $THIS_SERVER_IP:$((BASE_PORT + 1))"
echo -e "- ARBITER 2: $THIS_SERVER_IP:$((BASE_PORT + 2))"

for IP in "${OTHER_SERVER_IPS[@]}"; do
    echo -e "Server khác ($IP):"
    echo -e "- PRIMARY/SECONDARY: $IP:$BASE_PORT"
    echo -e "- ARBITER 1: $IP:$((BASE_PORT + 1))"
    echo -e "- ARBITER 2: $IP:$((BASE_PORT + 2))"
done

echo -e "Lệnh kiểm tra trạng thái:"
echo -e "  mongosh \"mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin\" --eval \"rs.status()\""

exit 0