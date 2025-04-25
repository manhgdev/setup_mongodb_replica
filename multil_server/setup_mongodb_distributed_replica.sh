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

echo -e "${BLUE}=== THIẾT LẬP MONGODB REPLICA SET (1 PRIMARY/SECONDARY + 2 ARBITER) ===${NC}"

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

# 5. Khởi tạo replica set
echo -e "${YELLOW}Khởi tạo replica set...${NC}"
mongosh "mongodb://localhost:$BASE_PORT" --eval "
rs.initiate({
    _id: '$REPLICA_SET',
    members: [
        { _id: 0, host: '$THIS_SERVER_IP:$BASE_PORT', priority: 2 },
        { _id: 1, host: '$THIS_SERVER_IP:$((BASE_PORT + 1))', arbiterOnly: true },
        { _id: 2, host: '$THIS_SERVER_IP:$((BASE_PORT + 2))', arbiterOnly: true }
    ]
})"

# 6. Đợi PRIMARY được bầu
echo -e "${YELLOW}Đợi PRIMARY được bầu (5 giây)...${NC}"
sleep 5

# 7. Tạo user admin
echo -e "${YELLOW}Tạo user admin...${NC}"
mongosh "mongodb://localhost:$BASE_PORT" --eval "
db.getSiblingDB('admin').createUser({
    user: '$USERNAME',
    pwd: '$PASSWORD',
    roles: ['root']
})"

# 8. Kiểm tra trạng thái cuối cùng
echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
mongosh "mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin" --eval "rs.status()" --quiet | grep -E "name|stateStr"

echo -e "${GREEN}=== HOÀN THÀNH THIẾT LẬP ===${NC}"
echo -e "Các node đã được thiết lập:"
echo -e "- PRIMARY/SECONDARY: $THIS_SERVER_IP:$BASE_PORT"
echo -e "- ARBITER 1: $THIS_SERVER_IP:$((BASE_PORT + 1))"
echo -e "- ARBITER 2: $THIS_SERVER_IP:$((BASE_PORT + 2))"
echo -e "Lệnh kiểm tra trạng thái:"
echo -e "  mongosh \"mongodb://$USERNAME:$PASSWORD@localhost:$BASE_PORT/admin\" --eval \"rs.status()\""

exit 0