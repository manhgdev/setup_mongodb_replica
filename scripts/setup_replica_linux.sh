#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ $(id -u) -ne 0 ]; then
    echo -e "${RED}❌ This script must be run as root${NC}"
    exit 1
fi

# Stop MongoDB
stop_mongodb() {
    echo "Stopping MongoDB..."
    pkill -f mongod || true
    sleep 2
}

# Create directories
create_dirs() {
    local PORT=$1
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    
    sudo mkdir -p $DB_PATH $LOG_PATH
    sudo chown -R mongodb:mongodb $DB_PATH $LOG_PATH
    sudo chmod 755 $DB_PATH
}

# Create keyfile
create_keyfile() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Creating MongoDB keyFile..."
        openssl rand -base64 756 > $KEY_FILE
        chmod 600 $KEY_FILE
        chown mongodb:mongodb $KEY_FILE
    fi
}

# Setup MongoDB node
setup_node() {
    local PORT=$1
    local SECURITY=$2
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
processManagement:
  fork: true
EOL

    # Add security if enabled
    if [ "$SECURITY" = "yes" ]; then
        cat >> $CONFIG_FILE <<EOL
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOL
    fi

    # Start MongoDB
    echo "Starting MongoDB on port $PORT..."
    if ! mongod --config "$CONFIG_FILE" --fork; then
        echo -e "${RED}❌ Failed to start MongoDB on port $PORT${NC}"
        echo "Error log:"
        grep -i "error\|failed\|exception" "$LOG_PATH/mongod_${PORT}.log" | tail -n 20
        return 1
    fi
    
    # Wait for MongoDB to start
    local attempt=1
    while [ $attempt -le 3 ]; do
        echo "Waiting for MongoDB to start (attempt $attempt/3)..."
        sleep 3
        
        if mongosh --port $PORT --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${GREEN}✅ MongoDB started successfully on port $PORT${NC}"
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}❌ Failed to connect to MongoDB on port $PORT${NC}"
    echo "Error log:"
    grep -i "error\|failed\|exception" "$LOG_PATH/mongod_${PORT}.log" | tail -n 20
    return 1
}

# Setup PRIMARY server
setup_primary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    # Stop any running MongoDB
    stop_mongodb
    
    # Create directories
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER1_PORT
    create_dirs $ARBITER2_PORT
    
    # Start nodes without security
    echo "Starting nodes without security..."
    setup_node $PRIMARY_PORT "no" || return 1
    setup_node $ARBITER1_PORT "no" || return 1
    setup_node $ARBITER2_PORT "no" || return 1
    
    sleep 5
    
    # Initialize replica set
    echo "Initializing replica set..."
    mongosh --port $PRIMARY_PORT --eval "
    rs.initiate({
        _id: 'rs0',
        members: [
            { _id: 0, host: '$SERVER_IP:$PRIMARY_PORT', priority: 2 },
            { _id: 1, host: '$SERVER_IP:$ARBITER1_PORT', arbiterOnly: true, priority: 0 },
            { _id: 2, host: '$SERVER_IP:$ARBITER2_PORT', arbiterOnly: true, priority: 0 }
        ]
    })"
    
    sleep 5
    
    # Create admin user
    echo "Creating admin user..."
    read -p "Enter admin username (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
    mongosh --port $PRIMARY_PORT --eval "
    db = db.getSiblingDB('admin');
    db.createUser({
        user: '$admin_username',
        pwd: '$admin_password',
        roles: [
            { role: 'root', db: 'admin' },
            { role: 'clusterAdmin', db: 'admin' }
        ]
    })"
    
    # Create keyfile and restart with security
    create_keyfile
    stop_mongodb
    sleep 5
    
    # Restart with security
    echo "Restarting with security..."
    setup_node $PRIMARY_PORT "yes" || return 1
    setup_node $ARBITER1_PORT "yes" || return 1
    setup_node $ARBITER2_PORT "yes" || return 1
    
    sleep 5
    
    # Verify setup
    echo "Verifying setup..."
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval "
    print('Replica set status:');
    printjson(rs.status())"
    
    echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
    echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
    echo "Admin user: $admin_username"
    echo "Connection command: mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
}

# Setup SECONDARY server
setup_secondary() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER_PORT=27018
    
    # Get primary server info
    echo -e "${YELLOW}Setting up SECONDARY server${NC}"
    read -p "Enter PRIMARY server IP: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}❌ PRIMARY server IP is required${NC}"
        return 1
    fi
    
    read -p "Enter admin username (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
    # Stop any running MongoDB
    stop_mongodb
    
    # Create directories
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER_PORT
    
    # Create keyfile
    create_keyfile
    
    # Start without security
    echo "Starting without security..."
    setup_node $PRIMARY_PORT "no" || return 1
    setup_node $ARBITER_PORT "no" || return 1
    
    sleep 5
    
    # Add to replica set
    echo "Adding to replica set..."
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval "
    rs.add('$SERVER_IP:$PRIMARY_PORT');
    rs.addArb('$SERVER_IP:$ARBITER_PORT')"
    
    # Restart with security
    stop_mongodb
    sleep 5
    
    echo "Restarting with security..."
    setup_node $PRIMARY_PORT "yes" || return 1
    setup_node $ARBITER_PORT "yes" || return 1
    
    sleep 5
    
    # Verify setup
    echo "Verifying setup..."
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval "
    print('Replica set status:');
    printjson(rs.status())"
    
    echo -e "\n${GREEN}✅ SECONDARY setup completed${NC}"
    echo "This server (SECONDARY): $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter node: $SERVER_IP:$ARBITER_PORT"
    echo "Connected to PRIMARY: $PRIMARY_IP:$PRIMARY_PORT"
    echo "Connect to this SECONDARY: mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
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


