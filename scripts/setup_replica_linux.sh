#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Default admin credentials
ADMIN_USER="manhg"
ADMIN_PASS="manhnk"

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Stop all MongoDB services
    for port in 27017 27018 27019; do
        sudo systemctl stop mongod_${port} 2>/dev/null || true
    done
    
    # Kill any processes using MongoDB ports
    for port in 27017 27018 27019; do
        echo "Killing processes on port $port..."
        # Kill using lsof
        lsof -ti:$port | xargs kill -9 2>/dev/null || true
        # Kill using fuser
        fuser -k $port/tcp 2>/dev/null || true
        # Kill using netstat
        netstat -tulpn 2>/dev/null | grep ":$port" | awk '{print $7}' | cut -d'/' -f1 | xargs kill -9 2>/dev/null || true
    done
    
    # Wait for ports to be free
    sleep 5
    
    # Verify ports are free
    for port in 27017 27018 27019; do
        if lsof -i:$port &>/dev/null || netstat -tulpn 2>/dev/null | grep -q ":$port"; then
            echo -e "${RED}❌ Port $port is still in use${NC}"
            echo "Trying to kill again..."
            lsof -ti:$port | xargs kill -9 2>/dev/null || true
            fuser -k $port/tcp 2>/dev/null || true
            sleep 2
        fi
    done
    
    echo -e "${GREEN}✅ All MongoDB processes stopped successfully${NC}"
}

# Create directories
create_dirs() {
    local PORT=$1
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    mkdir -p $DB_PATH $LOG_PATH
    chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    chmod 755 $DB_PATH
}

# Create MongoDB config
create_config() {
    local PORT=$1
    local IS_INITIAL_SETUP=$2
    local IS_ARBITER=$3
    local WITH_SECURITY=$4
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Create config file
    cat > $CONFIG_FILE << EOF
# mongod.conf

# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb_${PORT}

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_${PORT}.log

# network interfaces
net:
  port: ${PORT}
  bindIp: 0.0.0.0

# how the process runs
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  fork: true

EOF

    # Chỉ thêm security nếu WITH_SECURITY = true
    if [ "$WITH_SECURITY" = "true" ]; then
        cat >> $CONFIG_FILE << EOF
# security
security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled
EOF
    fi

    # Phần replication luôn được thêm
    cat >> $CONFIG_FILE << EOF
# replication
replication:
  replSetName: rs0

# Cho phép nhiều arbiter
setParameter:
  allowMultipleArbiters: true
EOF
    
    # Set permissions
    chown mongodb:mongodb $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
}

# Fix MongoDB startup issues
fix_mongodb_startup() {
    local PORT=$1
    
    echo "Attempting to fix MongoDB startup for port $PORT..."
    
    # Check if process is already running
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo "MongoDB process for port $PORT is already running"
        return 0
    fi
    
    # Check logs
    echo "Checking MongoDB logs..."
    if [ -f "/var/log/mongodb/mongod_${PORT}.log" ]; then
        local auth_errors=$(grep -i "auth" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        local perm_errors=$(grep -i "permission" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        local keyfile_errors=$(grep -i "keyfile" /var/log/mongodb/mongod_${PORT}.log | grep -i "error" | tail -n 5)
        
        if [ ! -z "$auth_errors" ]; then
            echo "Authentication errors found:"
            echo "$auth_errors"
        fi
        
        if [ ! -z "$perm_errors" ]; then
            echo "Permission errors found:"
            echo "$perm_errors"
            
            # Fix data directory permissions
            local DB_PATH="/var/lib/mongodb_${PORT}"
            echo "Fixing data directory permissions..."
            sudo mkdir -p $DB_PATH
            sudo chown -R mongodb:mongodb $DB_PATH
            sudo chmod -R 755 $DB_PATH
        fi
        
        if [ ! -z "$keyfile_errors" ]; then
            echo "Keyfile errors found:"
            echo "$keyfile_errors"
            
            # Fix keyfile permissions
            echo "Fixing keyfile permissions..."
            sudo chown mongodb:mongodb /etc/mongodb.keyfile
            sudo chmod 400 /etc/mongodb.keyfile
        fi
    fi
    
    # Try starting mongod manually first to see errors
    echo "Starting MongoDB manually to check for errors..."
    sudo -u mongodb mongod --config /etc/mongod_${PORT}.conf
    sleep 5
    
    # Check if process started
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo -e "${GREEN}✅ MongoDB started successfully using manual command${NC}"
        return 0
    fi
    
    echo "Failed to start MongoDB manually. Starting without config to check for basic startup issues..."
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb/mongod_${PORT}.log"
    
    # Try starting with minimal options
    sudo -u mongodb mongod --dbpath $DB_PATH --port $PORT --fork --logpath $LOG_PATH
    sleep 5
    
    # Check if process started
    if pgrep -f "mongod.*$PORT" > /dev/null; then
        echo -e "${GREEN}✅ MongoDB started with minimal options${NC}"
        # Stop it
        sudo mongod --dbpath $DB_PATH --port $PORT --shutdown
        sleep 5
        echo "Issue might be with the config file. Check above for specific errors."
    else
        echo -e "${RED}❌ Could not start MongoDB even with minimal options${NC}"
        echo "This might indicate a deeper issue with MongoDB installation or system configuration."
        echo "Checking system resources..."
        echo "Disk space:"
        df -h
        echo "Memory:"
        free -m
    fi
    
    return 1
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    stop_mongodb
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER1_PORT
    create_dirs $ARBITER2_PORT
    
    # Configure firewall
    configure_firewall
    
    # Create initial configs WITHOUT security
    create_config $PRIMARY_PORT true false false
    create_config $ARBITER1_PORT true true false 
    create_config $ARBITER2_PORT true true false
    
    # Start all nodes
    echo "Starting PRIMARY node..."
    mongod --config /etc/mongod_27017.conf --fork
    sleep 5
    
    # Check if PRIMARY is running
    if ! mongosh --port $PRIMARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start PRIMARY node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27017.log
        return 1
    fi
    
    echo "Starting ARBITER 1 node..."
    mongod --config /etc/mongod_27018.conf --fork
    sleep 5
    
    # Check if ARBITER 1 is running
    if ! mongosh --port $ARBITER1_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start ARBITER 1 node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27018.log
        return 1
    fi
    
    echo "Starting ARBITER 2 node..."
    mongod --config /etc/mongod_27019.conf --fork
    sleep 5
    
    # Check if ARBITER 2 is running
    if ! mongosh --port $ARBITER2_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start ARBITER 2 node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27019.log
        return 1
    fi
    
    # Initialize replica set using private IP
    echo "Initializing replica set..."
    local init_result=$(mongosh --port $PRIMARY_PORT --eval "
rs.initiate({
    _id: 'rs0',
    members: [
        { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 },
        { _id: 1, host: '$SERVER_IP:$ARBITER1_PORT', arbiterOnly: true, priority: 0 },
        { _id: 2, host: '$SERVER_IP:$ARBITER2_PORT', arbiterOnly: true, priority: 0 }
    ]
})")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize replica set${NC}"
        echo "Error: $init_result"
        echo "Checking node statuses..."
        echo "PRIMARY node status:"
        mongosh --port $PRIMARY_PORT --eval "db.serverStatus()" --quiet
        echo "ARBITER 1 node status:"
        mongosh --port $ARBITER1_PORT --eval "db.serverStatus()" --quiet
        echo "ARBITER 2 node status:"
        mongosh --port $ARBITER2_PORT --eval "db.serverStatus()" --quiet
        return 1
    fi
    
    echo "Waiting for PRIMARY election..."
    sleep 20
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
        echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
        echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
        
        # Create admin user with default values
        create_admin_user $PRIMARY_PORT $ADMIN_USER $ADMIN_PASS || return 1
        
        # Create keyfile and update configs WITH security
        create_keyfile "/etc/mongodb.keyfile"
        create_config $PRIMARY_PORT true false true
        create_config $ARBITER1_PORT true true true
        create_config $ARBITER2_PORT true true true
        
        # Create systemd services
        echo "Creating systemd services..."
        create_systemd_service $PRIMARY_PORT || return 1
        create_systemd_service $ARBITER1_PORT || return 1
        create_systemd_service $ARBITER2_PORT || return 1
        
        # Restart services with security
        echo "Restarting services with security..."
        sudo systemctl restart mongod_27017
        sleep 5
        sudo systemctl restart mongod_27018
        sleep 5
        sudo systemctl restart mongod_27019
        sleep 5
        
        # Verify connection with auth
        echo "Verifying connection with authentication..."
        local auth_result=$(mongosh --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Authentication verified successfully${NC}"
            echo -e "\n${GREEN}Connection Commands:${NC}"
            echo "1. Connect to PRIMARY:"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "2. Connect to ARBITER 1:"
            echo "mongosh --host $SERVER_IP --port $ARBITER1_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "3. Connect to ARBITER 2:"
            echo "mongosh --host $SERVER_IP --port $ARBITER2_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
            echo "4. Connect to Replica Set:"
            echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@$SERVER_IP:$PRIMARY_PORT,$SERVER_IP:$ARBITER1_PORT,$SERVER_IP:$ARBITER2_PORT/admin?replicaSet=rs0\""
        else
            echo -e "${RED}❌ Authentication verification failed${NC}"
            echo "Error details:"
            echo "$auth_result"
            echo "Trying to check MongoDB status..."
            sudo systemctl status mongod_27017
            sudo systemctl status mongod_27018
            sudo systemctl status mongod_27019
            return 1
        fi
    else
        echo -e "${RED}❌ Replica set initialization failed - Node not promoted to PRIMARY${NC}"
        echo "Current status:"
        echo "$status"
        return 1
    fi
}

# Setup SECONDARY server
setup_secondary() {
    local SERVER_IP=$1
    local SECONDARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    
    read -p "PRIMARY server IP: " PRIMARY_IP
    [ -z "$PRIMARY_IP" ] && echo -e "${RED}❌ Cần IP PRIMARY${NC}" && return 1
    
    # Kiểm tra kết nối
    echo "Kiểm tra kết nối..."
    ping -c 1 $PRIMARY_IP &>/dev/null || { echo -e "${RED}❌ Không ping được PRIMARY${NC}"; return 1; }
    nc -zv $PRIMARY_IP 27017 2>/dev/null || { echo -e "${RED}❌ Port 27017 trên PRIMARY đóng${NC}"; return 1; }
    
    # Dọn dẹp
    echo "Dọn dẹp MongoDB..."
    sudo systemctl stop mongod_27017 mongod_27018 mongod_27019 2>/dev/null
    sudo pkill -f mongod 2>/dev/null
    sudo rm -f /tmp/mongodb-*.sock /var/lib/mongodb_*/mongod.lock
    sudo rm -rf /var/lib/mongodb_27017/* /var/lib/mongodb_27018/* /var/lib/mongodb_27019/*
    
    # Tạo thư mục
    echo "Tạo thư mục và cấu hình..."
    for port in $SECONDARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        sudo mkdir -p /var/lib/mongodb_${port} /var/log/mongodb
        sudo chown -R mongodb:mongodb /var/lib/mongodb_${port} /var/log/mongodb
        sudo chmod 755 /var/lib/mongodb_${port}
    done
    
    # Keyfile
    local KEYFILE="/etc/mongodb.keyfile"
    [ ! -f "$KEYFILE" ] && sudo openssl rand -base64 756 > $KEYFILE
    sudo chown mongodb:mongodb $KEYFILE && sudo chmod 400 $KEYFILE
    
    # Config files
    for port in $SECONDARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        local IS_ARBITER="false"
        if [ "$port" != "$SECONDARY_PORT" ]; then
            IS_ARBITER="true"
        fi
        create_config $port false $IS_ARBITER true
    done
    
    # Systemd services
    for port in $SECONDARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        sudo bash -c "cat > /etc/systemd/system/mongod_${port}.service << EOF
[Unit]
Description=MongoDB Database Server (Port ${port})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod_${port}.conf
ExecStop=/usr/bin/mongod --config /etc/mongod_${port}.conf --shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOF"
    done
    sudo systemctl daemon-reload
    
    # Khởi động services
    echo "Khởi động MongoDB..."
    sudo systemctl start mongod_$SECONDARY_PORT mongod_$ARBITER1_PORT mongod_$ARBITER2_PORT
    sleep 5
    
    # Kiểm tra kết nối
    mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "db.version()" --quiet &>/dev/null || { 
        echo -e "${RED}❌ Không kết nối được PRIMARY${NC}"; 
        return 1; 
    }
    
    # Thêm vào replica set
    echo "Thêm vào replica set..."
    local rs_status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    for node in "$SERVER_IP:$SECONDARY_PORT" "$SERVER_IP:$ARBITER1_PORT" "$SERVER_IP:$ARBITER2_PORT"; do
        if echo "$rs_status" | grep -q "$node"; then
            if ! echo "$rs_status" | grep -A 10 "$node" | grep -q "health.*:.*1"; then
                mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.remove('$node')" --quiet
                sleep 2
                if [[ "$node" == *":$SECONDARY_PORT" ]]; then
                    mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.add({host: '$node', priority: 0})" --quiet
                else
                    mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.addArb('$node')" --quiet
                fi
            fi
        else
            if [[ "$node" == *":$SECONDARY_PORT" ]]; then
                mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.add({host: '$node', priority: 0})" --quiet
            else
                mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.addArb('$node')" --quiet
            fi
        fi
    done
    
    # Hoàn tất
    echo -e "\n${GREEN}✅ Thiết lập xong${NC}"
    echo -e "\n${GREEN}Connection string:${NC}"
    echo "mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:27017,$SERVER_IP:27017,$SERVER_IP:27018,$SERVER_IP:27019/admin?replicaSet=rs0&readPreference=primary&retryWrites=true&w=majority"
    
    echo -e "\n${GREEN}Lệnh kiểm tra:${NC}"
    echo "mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval \"rs.status()\""
}

# Create keyfile
create_keyfile() {
  echo -e "${GREEN}Tạo keyfile xác thực...${NC}"
  local keyfile=${1:-"/etc/mongodb.keyfile"}
  
  if [ ! -f "$keyfile" ]; then
    openssl rand -base64 756 | sudo tee $keyfile > /dev/null
    sudo chmod 400 $keyfile
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $keyfile
    echo -e "${GREEN}✅ Đã tạo keyfile tại $keyfile${NC}"
  else
    local mongo_user="mongodb"
    if ! getent passwd mongodb > /dev/null && getent passwd mongod > /dev/null; then
      mongo_user="mongod"
    fi
    sudo chown $mongo_user:$mongo_user $keyfile
    sudo chmod 400 $keyfile
    echo -e "${GREEN}✅ Keyfile đã tồn tại tại $keyfile${NC}"
  fi
}

# Create admin user
create_admin_user() {
    local PORT=$1
    local USERNAME=$2
    local PASSWORD=$3
    
    echo "Creating admin user..."
    local result=$(mongosh --port $PORT --eval "
    db.getSiblingDB('admin').createUser({
        user: '$USERNAME',
        pwd: '$PASSWORD',
        roles: [
            { role: 'root', db: 'admin' },
            { role: 'clusterAdmin', db: 'admin' }
        ]
    })")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to create admin user${NC}"
        echo "Error: $result"
        return 1
    fi
    echo -e "${GREEN}✅ Admin user created successfully${NC}"
}

# Start MongoDB
start_mongodb() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    
    echo "Starting MongoDB nodes..."
    setup_node $PRIMARY_PORT || return 1
    setup_node $ARBITER1_PORT || return 1
    setup_node $ARBITER2_PORT || return 1
    
    echo -e "${GREEN}✅ All MongoDB nodes started successfully${NC}"
}

# Create systemd service
create_systemd_service() {
    local PORT=$1
    local SERVICE_NAME="mongod_${PORT}"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server (Port ${PORT})
After=network.target
Wants=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown
Restart=always
RestartSec=3
StartLimitInterval=60
StartLimitBurst=3
TimeoutStartSec=60
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME
    
    if sudo systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ Service ${SERVICE_NAME} created and started successfully${NC}"
        echo "Service will auto-start on system boot"
    else
        echo -e "${RED}❌ Failed to start service ${SERVICE_NAME}${NC}"
        sudo systemctl status $SERVICE_NAME
        return 1
    fi
}

# Configure firewall
configure_firewall() {
    echo "Configuring firewall..."
    if command -v ufw &> /dev/null; then
        echo "UFW is installed, configuring ports..."
        sudo ufw allow 27017/tcp
        sudo ufw allow 27018/tcp
        sudo ufw allow 27019/tcp
        echo -e "${GREEN}✅ Firewall configured successfully${NC}"
    else
        echo "UFW is not installed, skipping firewall configuration"
    fi
}

# Dọn dẹp môi trường MongoDB
cleanup_mongodb() {
    echo "Cleaning up MongoDB environment..."
    
    # Dừng tất cả dịch vụ MongoDB
    stop_mongodb
    
    # Xóa các socket cũ
    echo "Removing old socket files..."
    sudo rm -f /tmp/mongodb-*.sock
    
    # Xóa file lock
    echo "Removing lock files..."
    for port in 27017 27018 27019; do
        sudo rm -f /var/lib/mongodb_${port}/mongod.lock
        sudo rm -f /var/lib/mongodb_${port}/WiredTiger.lock
    done
    
    echo -e "${GREEN}✅ MongoDB environment cleaned up${NC}"
}

# Main function
setup_replica_linux() {
    echo "MongoDB Replica Set Setup for Linux"
    echo "===================================="
    echo "1. Setup PRIMARY server"
    echo "2. Setup SECONDARY server"
    echo "3. Return to main menu"
    read -p "Select option (1-3): " option

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "Using server IP: $SERVER_IP"

    case $option in
        1) setup_primary $SERVER_IP ;;
        2) setup_secondary $SERVER_IP ;;
        3) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


