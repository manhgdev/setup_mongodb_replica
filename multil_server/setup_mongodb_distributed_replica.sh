#!/bin/bash

# Thiết lập MongoDB Replica Set phân tán với tự động failover
# Màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Biến cấu hình
REPLICA_SET="rs0"
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
KEYFILE="/etc/mongodb-keyfile"
BASE_PORT=27017
MAX_SERVERS=7

# Thông tin node
declare -A NODES=(
    ["node1"]="$BASE_PORT"
    ["node2"]="$((BASE_PORT + 1))"
    ["node3"]="$((BASE_PORT + 2))"
)

echo -e "${BLUE}=== THIẾT LẬP MONGODB REPLICA SET (3 NODE) ===${NC}"

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

# 2. Tạo thư mục và file cấu hình cho từng node
for NODE in "${!NODES[@]}"; do
    PORT="${NODES[$NODE]}"
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

# 3. Đợi các node khởi động
echo -e "${YELLOW}Đợi các node khởi động (30 giây)...${NC}"
sleep 30

# 4. Khởi tạo replica set
echo -e "${YELLOW}Khởi tạo replica set...${NC}"
mongosh "mongodb://localhost:$BASE_PORT" --eval "
rs.initiate({
    _id: '$REPLICA_SET',
    members: [
        { _id: 0, host: 'localhost:$BASE_PORT', priority: 2 },
        { _id: 1, host: 'localhost:$((BASE_PORT + 1))', priority: 1 },
        { _id: 2, host: 'localhost:$((BASE_PORT + 2))', priority: 1 }
    ]
})"

# 5. Đợi PRIMARY được bầu
echo -e "${YELLOW}Đợi PRIMARY được bầu (15 giây)...${NC}"
sleep 15

# 6. Tạo user admin
echo -e "${YELLOW}Tạo user admin...${NC}"
mongosh "mongodb://localhost:$BASE_PORT" --eval "
db.getSiblingDB('admin').createUser({
    user: '$USERNAME',
    pwd: '$PASSWORD',
    roles: ['root']
})"

# 7. Kiểm tra trạng thái cuối cùng
echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
mongosh "mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin" --eval "rs.status()" --quiet | grep -E "name|stateStr"

echo -e "${GREEN}=== HOÀN THÀNH THIẾT LẬP ===${NC}"
echo -e "Các node đã được thiết lập:"
for NODE in "${!NODES[@]}"; do
    PORT="${NODES[$NODE]}"
    echo -e "- $NODE: localhost:$PORT"
done
echo -e "Lệnh kiểm tra trạng thái:"
echo -e "  mongosh \"mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin\" --eval \"rs.status()\""

exit 0