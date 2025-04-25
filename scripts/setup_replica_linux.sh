#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Stop MongoDB
stop_mongodb() {
    pkill -f mongod || true
    sleep 2
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
processManagement:
  fork: true
EOL

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

    stop_mongodb
    create_dirs $PRIMARY_PORT
    create_dirs $ARBITER1_PORT
    create_dirs $ARBITER2_PORT
    
    setup_node $PRIMARY_PORT || return 1
    setup_node $ARBITER1_PORT || return 1
    setup_node $ARBITER2_PORT || return 1
    
    sleep 5
    
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
    
    mongosh --port $PRIMARY_PORT --eval "
    print('Replica set status:');
    printjson(rs.status())"
    
    echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
    echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
    echo "Connection command: mongosh --host $SERVER_IP --port $PRIMARY_PORT"
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
    
    sleep 5
    
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT --eval "
    rs.add('$SERVER_IP:$PRIMARY_PORT');
    rs.addArb('$SERVER_IP:$ARBITER_PORT')"
    
    sleep 5
    
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT --eval "
    print('Replica set status:');
    printjson(rs.status())"
    
    echo -e "\n${GREEN}✅ SECONDARY setup completed${NC}"
    echo "This server (SECONDARY): $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter node: $SERVER_IP:$ARBITER_PORT"
    echo "Connected to PRIMARY: $PRIMARY_IP:$PRIMARY_PORT"
    echo "Connect to this SECONDARY: mongosh --host $SERVER_IP --port $PRIMARY_PORT"
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


