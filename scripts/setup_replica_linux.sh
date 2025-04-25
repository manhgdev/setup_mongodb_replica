#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Stop MongoDB
stop_mongodb() {
    echo "Stopping all MongoDB processes..."
    
    # Kill all mongod processes
    pkill -9 -f mongod || true
    sleep 2
    
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
            pkill -9 -f mongod
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

# Setup MongoDB node
setup_node() {
    local PORT=$1
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    # Create config
    cat > $CONFIG_FILE <<EOL
systemLog:
  destination: file
  path: $LOG_PATH/mongod_${PORT}.log
  logAppend: true
storage:
  dbPath: $DB_PATH
net:
  bindIp: 0.0.0.0
  port: $PORT
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
EOL

    # Start MongoDB
    echo "Starting MongoDB on port $PORT..."
    mongod --config "$CONFIG_FILE" > "$LOG_PATH/mongod_${PORT}.log" 2>&1 &
    local mongod_pid=$!
    
    # Wait for MongoDB to start
    local attempt=1
    while [ $attempt -le 30 ]; do
        sleep 1
        if mongosh --port $PORT --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${GREEN}✅ MongoDB started successfully on port $PORT${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}❌ Failed to connect to MongoDB on port $PORT${NC}"
    echo "Last 50 lines of log file:"
    tail -n 50 "$LOG_PATH/mongod_${PORT}.log"
    return 1
}

# Create keyfile
create_keyfile() {
    local KEYFILE="/etc/mongodb.keyfile"
    openssl rand -base64 756 > $KEYFILE
    chown mongodb:mongodb $KEYFILE
    chmod 400 $KEYFILE
    echo -e "${GREEN}✅ Keyfile created successfully${NC}"
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

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config ${CONFIG_FILE}
ExecStop=/usr/bin/mongod --config ${CONFIG_FILE} --shutdown
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ Service ${SERVICE_NAME} created and started successfully${NC}"
    else
        echo -e "${RED}❌ Failed to start service ${SERVICE_NAME}${NC}"
        systemctl status $SERVICE_NAME
        return 1
    fi
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
    
    # Create keyfile
    create_keyfile
    
    # Update config with keyfile for all nodes
    for port in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        local CONFIG_FILE="/etc/mongod_${port}.conf"
        echo "security:
  keyFile: /etc/mongodb.keyfile
  authorization: enabled" >> $CONFIG_FILE
    done
    
    start_mongodb || return 1
    
    sleep 2
    
    # Initialize replica set
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
        return 1
    fi
    
    echo "Waiting for PRIMARY election..."
    sleep 15
    
    # Check replica set status
    echo "Checking replica set status..."
    local status=$(mongosh --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    local primary_state=$(echo "$status" | grep -A 5 "stateStr" | grep "PRIMARY")
    
    if [ -n "$primary_state" ]; then
        echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
        echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
        echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
        
        # Create admin user
        read -p "Enter admin username: " ADMIN_USER
        read -sp "Enter admin password: " ADMIN_PASS
        echo
        create_admin_user $PRIMARY_PORT $ADMIN_USER $ADMIN_PASS || return 1
        
        # Create systemd services
        echo "Creating systemd services..."
        create_systemd_service $PRIMARY_PORT || return 1
        create_systemd_service $ARBITER1_PORT || return 1
        create_systemd_service $ARBITER2_PORT || return 1
        
        # Restart with authentication
        echo "Restarting MongoDB with authentication..."
        stop_mongodb
        sleep 5
        
        # Start services in order
        echo "Starting PRIMARY node..."
        sudo systemctl start mongod_27017
        sleep 10
        
        echo "Starting ARBITER nodes..."
        sudo systemctl start mongod_27018
        sudo systemctl start mongod_27019
        sleep 5
        
        # Verify connection with auth
        echo "Verifying connection with authentication..."
        local auth_result=$(mongosh --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Authentication verified successfully${NC}"
            echo "Connection command: mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
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
    local PRIMARY_PORT=27017
    local ARBITER_PORT=27018
    
    read -p "Enter PRIMARY server IP: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}❌ PRIMARY server IP is required${NC}"
        return 1
    fi
    
    stop_mongodb
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER_PORT
    
    setup_node $PRIMARY_PORT || return 1
    setup_node $ARBITER_PORT || return 1
    
    sleep 2
    
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT --eval "
    rs.add('$SERVER_IP:$PRIMARY_PORT');
    rs.addArb('$SERVER_IP:$ARBITER_PORT')" &>/dev/null
    
    sleep 2
    
    # Check replica set status
    local status=$(mongosh --host $PRIMARY_IP --port $PRIMARY_PORT --eval "rs.status()" --quiet)
    if echo "$status" | grep -q "SECONDARY"; then
        echo -e "\n${GREEN}✅ SECONDARY setup completed${NC}"
        echo "This server (SECONDARY): $SERVER_IP:$PRIMARY_PORT"
        echo "Arbiter node: $SERVER_IP:$ARBITER_PORT"
        echo "Connected to PRIMARY: $PRIMARY_IP:$PRIMARY_PORT"
        echo "Connect to this SECONDARY: mongosh --host $SERVER_IP --port $PRIMARY_PORT"
    else
        echo -e "${RED}❌ Secondary setup failed${NC}"
        return 1
    fi
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


