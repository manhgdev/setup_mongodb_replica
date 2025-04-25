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
    local IS_SECONDARY=$2
    local IS_ARBITER=$3
    
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    
    # Create config file
    cat > $CONFIG_FILE << EOF
# mongod.conf

# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

# Where and how to store data.
storage:
  dbPath: /var/lib/mongodb_${PORT}
  journal:
    enabled: true
#  engine:
#  wiredTiger:

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod_${PORT}.log

# network interfaces
net:
  port: ${PORT}
  bindIp: 0.0.0.0
  ipv6: false

# how the process runs
processManagement:
  timeZoneInfo: /usr/share/zoneinfo

#security:
security:
  authorization: enabled
  keyFile: /etc/mongodb.keyfile

#operationProfiling:

#replication:
replication:
  replSetName: rs0
EOF
    
    # Set permissions
    chown mongodb:mongodb $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    
    echo -e "${GREEN}✅ Config file created: $CONFIG_FILE${NC}"
}

# Setup MongoDB node
setup_node() {
    local PORT=$1
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    # Create config
    create_config $PORT
    
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
    
    # Create initial configs without security
    create_config $PRIMARY_PORT false false false
    create_config $ARBITER1_PORT false true false
    create_config $ARBITER2_PORT false true false
    
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
        
        # Create keyfile and update configs with security
        create_keyfile
        create_config $PRIMARY_PORT true false true
        create_config $ARBITER1_PORT true true false
        create_config $ARBITER2_PORT true true false
        
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
    
    read -p "Enter PRIMARY server IP: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}❌ PRIMARY server IP is required${NC}"
        return 1
    fi
    
    # Check if this server is already a PRIMARY
    echo "Checking if this server is already a PRIMARY..."
    if mongosh --port $SECONDARY_PORT --eval "rs.status()" --quiet &>/dev/null; then
        local current_status=$(mongosh --port $SECONDARY_PORT --eval "rs.status()" --quiet)
        if echo "$current_status" | grep -q "stateStr.*PRIMARY"; then
            echo -e "${RED}❌ This server is already a PRIMARY node${NC}"
            echo "Please stop all MongoDB services and remove data before setting up as SECONDARY"
            return 1
        fi
    fi
    
    # Check connection to PRIMARY
    echo "Checking connection to PRIMARY server..."
    if ! ping -c 1 $PRIMARY_IP &>/dev/null; then
        echo -e "${RED}❌ Cannot connect to PRIMARY server${NC}"
        return 1
    fi
    
    # Configure firewall
    configure_firewall
    
    # Stop all MongoDB processes and remove data
    echo "Stopping all MongoDB processes and removing data..."
    stop_mongodb
    sudo rm -rf /var/lib/mongodb_27017/* /var/lib/mongodb_27018/* /var/lib/mongodb_27019/*
    
    create_dirs $SECONDARY_PORT
    create_dirs $ARBITER1_PORT
    create_dirs $ARBITER2_PORT
    
    # Check if keyfile exists
    if [ ! -f "/etc/mongodb.keyfile" ]; then
        echo -e "${RED}❌ Keyfile not found${NC}"
        echo "Please copy keyfile from PRIMARY server first:"
        echo "scp root@$PRIMARY_IP:/etc/mongodb.keyfile /etc/mongodb.keyfile"
        echo "sudo chown mongodb:mongodb /etc/mongodb.keyfile"
        echo "sudo chmod 400 /etc/mongodb.keyfile"
        return 1
    fi
    
    # Check keyfile permissions
    local keyfile_owner=$(stat -c %U /etc/mongodb.keyfile)
    local keyfile_group=$(stat -c %G /etc/mongodb.keyfile)
    local keyfile_perms=$(stat -c %a /etc/mongodb.keyfile)
    
    if [ "$keyfile_owner" != "mongodb" ] || [ "$keyfile_group" != "mongodb" ] || [ "$keyfile_perms" != "400" ]; then
        echo -e "${RED}❌ Keyfile permissions incorrect${NC}"
        echo "Current permissions:"
        echo "Owner: $keyfile_owner"
        echo "Group: $keyfile_group"
        echo "Permissions: $keyfile_perms"
        echo "Please set correct permissions:"
        echo "sudo chown mongodb:mongodb /etc/mongodb.keyfile"
        echo "sudo chmod 400 /etc/mongodb.keyfile"
        return 1
    fi
    
    # Create configs with security
    create_config $SECONDARY_PORT true false false
    create_config $ARBITER1_PORT true true false
    create_config $ARBITER2_PORT true true false
    
    # Start SECONDARY node
    echo "Starting SECONDARY node..."
    mongod --config /etc/mongod_${SECONDARY_PORT}.conf --fork
    sleep 2
    
    # Start ARBITER 1 node
    echo "Starting ARBITER 1 node..."
    mongod --config /etc/mongod_${ARBITER1_PORT}.conf --fork
    sleep 2
    
    # Start ARBITER 2 node
    echo "Starting ARBITER 2 node..."
    mongod --config /etc/mongod_${ARBITER2_PORT}.conf --fork
    sleep 2
    
    # Create systemd services
    echo "Creating systemd services..."
    create_systemd_service $SECONDARY_PORT || return 1
    create_systemd_service $ARBITER1_PORT || return 1
    create_systemd_service $ARBITER2_PORT || return 1
    
    # Restart services
    echo "Restarting services..."
    sudo systemctl restart mongod_${SECONDARY_PORT}
    sudo systemctl restart mongod_${ARBITER1_PORT}
    sudo systemctl restart mongod_${ARBITER2_PORT}
    sleep 2
    
    # Check if nodes already exist in replica set
    echo "Checking if nodes already exist in replica set..."
    local rs_status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Check SECONDARY node
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$SECONDARY_PORT"; then
        echo "Adding SECONDARY node to replica set..."
        mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.add('$SERVER_IP:$SECONDARY_PORT')" --quiet
    else
        echo "SECONDARY node already exists in replica set"
    fi
    
    # Check ARBITER 1 node
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$ARBITER1_PORT"; then
        echo "Adding ARBITER 1 node to replica set..."
        mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.addArb('$SERVER_IP:$ARBITER1_PORT')" --quiet
    else
        echo "ARBITER 1 node already exists in replica set"
    fi
    
    # Check ARBITER 2 node
    if ! echo "$rs_status" | grep -q "$SERVER_IP:$ARBITER2_PORT"; then
        echo "Adding ARBITER 2 node to replica set..."
        mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.addArb('$SERVER_IP:$ARBITER2_PORT')" --quiet
    else
        echo "ARBITER 2 node already exists in replica set"
    fi
    
    echo -e "\n${GREEN}✅ SECONDARY setup completed successfully${NC}"
    echo -e "\n${GREEN}Connection strings for your application:${NC}"
    echo "1. Full connection string (all nodes):"
    echo "   mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:27017,$SERVER_IP:27017,$PRIMARY_IP:27018,$PRIMARY_IP:27019,$SERVER_IP:27018,$SERVER_IP:27019/admin?replicaSet=rs0"
    echo ""
    echo "2. Optimized connection string (PRIMARY and SECONDARY only):"
    echo "   mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:27017,$SERVER_IP:27017/admin?replicaSet=rs0"
    echo ""
    echo "3. Connection string with additional options:"
    echo "   mongodb://$ADMIN_USER:$ADMIN_PASS@$PRIMARY_IP:27017,$SERVER_IP:27017/admin?replicaSet=rs0&readPreference=primary&retryWrites=true&w=majority"
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


