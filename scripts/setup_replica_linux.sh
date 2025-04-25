#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'

# Default admin credentials
ADMIN_USER="manhg"
ADMIN_PASS="manhnk"

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Stop MongoDB service
    sudo systemctl stop mongod_27017 2>/dev/null || true
    
    # Kill any processes using MongoDB port
    echo "Killing processes on port 27017..."
    lsof -ti:27017 | xargs kill -9 2>/dev/null || true
    fuser -k 27017/tcp 2>/dev/null || true
    
    # Wait for port to be free
    sleep 3
    
    echo -e "${GREEN}✅ MongoDB process stopped successfully${NC}"
}

# Create directories
create_dirs() {
    local PORT=27017
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    mkdir -p $DB_PATH $LOG_PATH
    chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    chmod 755 $DB_PATH
}

# Create MongoDB config
create_config() {
    local PORT=27017
    local WITH_SECURITY=$1
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Create config file
    cat > $CONFIG_FILE << EOF
# mongod.conf
storage:
  dbPath: /var/lib/mongodb_${PORT}
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1

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
EOF
    
    # Set permissions
    chown mongodb:mongodb $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
}

# Create keyfile
create_keyfile() {
  echo -e "${GREEN}Tạo keyfile xác thực...${NC}"
  local keyfile=${1:-"/etc/mongodb.keyfile"}
  
  if [ ! -f "$keyfile" ]; then
    openssl rand -base64 756 | sudo tee $keyfile > /dev/null
    sudo chmod 400 $keyfile
    sudo chown mongodb:mongodb $keyfile
    echo -e "${GREEN}✅ Đã tạo keyfile tại $keyfile${NC}"
  else
    sudo chown mongodb:mongodb $keyfile
    sudo chmod 400 $keyfile
    echo -e "${GREEN}✅ Keyfile đã tồn tại tại $keyfile${NC}"
  fi
}

# Create admin user
create_admin_user() {
    local PORT=27017
    local USERNAME=$1
    local PASSWORD=$2
    
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

# Create systemd service
create_systemd_service() {
    local PORT=27017
    local SERVICE_NAME="mongod_${PORT}"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    cat > $SERVICE_FILE <<EOL
[Unit]
Description=MongoDB Database Server (Port ${PORT})
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown

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
        echo -e "${GREEN}✅ Firewall configured successfully${NC}"
    else
        echo "UFW is not installed, skipping firewall configuration"
    fi
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017

    echo -e "${GREEN}Thiết lập MongoDB Replica Set trên port $PRIMARY_PORT${NC}"

    stop_mongodb
    create_dirs
    
    # Configure firewall
    configure_firewall
    
    # Create initial config WITHOUT security
    create_config false
    
    # Start MongoDB
    echo "Starting MongoDB node..."
    # Khởi động MongoDB sử dụng systemctl
    if systemctl is-active --quiet mongod_27017; then
      sudo systemctl stop mongod_27017
      sleep 2
    fi
    
    # Đảm bảo thư mục và quyền
    sudo mkdir -p /var/lib/mongodb_27017 /var/log/mongodb 2>/dev/null
    sudo chown -R mongodb:mongodb /var/lib/mongodb_27017 /var/log/mongodb
    sudo chmod 755 /var/lib/mongodb_27017
    sudo rm -rf /var/lib/mongodb_27017/mongod.lock 2>/dev/null || true
    
    # Tạo service trước khi khởi động
    create_systemd_service
    
    # Khởi động MongoDB
    sudo systemctl daemon-reload
    sudo systemctl enable mongod_27017
    sudo systemctl start mongod_27017
    
    # Kiểm tra kết quả
    sleep 5
    if sudo systemctl is-active mongod_27017 &>/dev/null; then
      echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    else
      echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
      sudo systemctl status mongod_27017
      echo "Kiểm tra log:"
      sudo tail -n 20 /var/log/mongodb/mongod_27017.log
      return 1
    fi
    
    # Check if MongoDB is running
    if ! mongosh --port $PRIMARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start MongoDB node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27017.log
        return 1
    fi
    
    # Initialize replica set using private IP
    echo "Initializing replica set..."
    echo -e "${GREEN}Cấu hình node $SERVER_IP:$PRIMARY_PORT${NC}"
    
    local init_result=$(mongosh --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 10 }
        ]
    })")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize replica set${NC}"
        echo "Error: $init_result"
        return 1
    fi
    
    echo "Waiting for PRIMARY election..."
    sleep 10
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
        echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
        
        # Create admin user with default values
        create_admin_user $ADMIN_USER $ADMIN_PASS || return 1
        
        # Create keyfile and update config WITH security
        create_keyfile "/etc/mongodb.keyfile"
        create_config true
        
        # Create systemd service
        echo "Creating systemd service..."
        create_systemd_service || return 1
        
        # Restart service with security
        echo "Restarting service with security..."
        sudo systemctl restart mongod_27017
        sleep 5
        
        # Verify connection with auth
        echo "Verifying connection with authentication..."
        local auth_result=$(mongosh --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Authentication verified successfully${NC}"
            echo -e "\n${GREEN}Connection Command:${NC}"
            echo "mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
        else
            echo -e "${RED}❌ Authentication verification failed${NC}"
            echo "Error details:"
            echo "$auth_result"
            sudo systemctl status mongod_27017
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
    local PRIMARY_IP=$2
    local SECONDARY_PORT=27017

    if [ -z "$PRIMARY_IP" ]; then
        read -p "Enter PRIMARY server IP: " PRIMARY_IP
    fi

    echo -e "${GREEN}Thiết lập MongoDB SECONDARY node trên port $SECONDARY_PORT${NC}"

    stop_mongodb
    create_dirs
    
    # Configure firewall
    configure_firewall
    
    # Create initial config WITHOUT security first
    create_config false
    
    # Start MongoDB
    echo "Starting MongoDB node..."
    # Khởi động MongoDB sử dụng systemctl
    if systemctl is-active --quiet mongod_27017; then
      sudo systemctl stop mongod_27017
      sleep 2
    fi
    
    # Đảm bảo thư mục và quyền
    sudo mkdir -p /var/lib/mongodb_27017 /var/log/mongodb 2>/dev/null
    sudo chown -R mongodb:mongodb /var/lib/mongodb_27017 /var/log/mongodb
    sudo chmod 755 /var/lib/mongodb_27017
    sudo rm -rf /var/lib/mongodb_27017/mongod.lock 2>/dev/null || true
    
    # Tạo service trước khi khởi động
    create_systemd_service
    
    # Khởi động MongoDB
    sudo systemctl daemon-reload
    sudo systemctl enable mongod_27017
    sudo systemctl start mongod_27017
    
    # Kiểm tra kết quả
    sleep 5
    if sudo systemctl is-active mongod_27017 &>/dev/null; then
      echo -e "${GREEN}✓ MongoDB đã khởi động thành công${NC}"
    else
      echo -e "${RED}✗ Không thể khởi động MongoDB${NC}"
      sudo systemctl status mongod_27017
      echo "Kiểm tra log:"
      sudo tail -n 20 /var/log/mongodb/mongod_27017.log
      return 1
    fi
    
    # Check if MongoDB is running
    if ! mongosh --port $SECONDARY_PORT --eval "db.version()" --quiet &>/dev/null; then
        echo -e "${RED}❌ Failed to start MongoDB node${NC}"
        echo "Last 50 lines of log:"
        tail -n 50 /var/log/mongodb/mongod_27017.log
        return 1
    fi
    
    # Connect to Primary and add this node
    echo "Adding node to replica set..."
    echo -e "${GREEN}Kết nối tới PRIMARY $PRIMARY_IP và thêm node $SERVER_IP:$SECONDARY_PORT${NC}"
    
    echo "Please enter PRIMARY server credentials:"
    read -p "Username [$ADMIN_USER]: " PRIMARY_USER
    PRIMARY_USER=${PRIMARY_USER:-$ADMIN_USER}
    read -sp "Password [$ADMIN_PASS]: " PRIMARY_PASS
    PRIMARY_PASS=${PRIMARY_PASS:-$ADMIN_PASS}
    echo ""
    
    local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "
    rs.add('$SERVER_IP:$SECONDARY_PORT')")
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to add node to replica set${NC}"
        echo "Error: $add_result"
        return 1
    fi
    
    echo "Waiting for node to be added..."
    sleep 10
    
    # Create keyfile and update config WITH security
    create_keyfile "/etc/mongodb.keyfile"
    create_config true
    
    # Create systemd service
    echo "Creating systemd service..."
    create_systemd_service || return 1
    
    # Restart service with security
    echo "Restarting service with security..."
    sudo systemctl restart mongod_27017
    sleep 5
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    echo -e "\n${GREEN}✅ MongoDB SECONDARY node setup completed.${NC}"
    echo "Connection Command:"
    echo "mongosh --host $SERVER_IP --port $SECONDARY_PORT -u $PRIMARY_USER -p $PRIMARY_PASS --authenticationDatabase admin"
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
        2) 
           read -p "Enter PRIMARY server IP: " PRIMARY_IP
           setup_secondary $SERVER_IP $PRIMARY_IP ;;
        3) return 0 ;;
        *) echo -e "${RED}❌ Invalid option${NC}" && return 1 ;;
    esac
}


