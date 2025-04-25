setup_node_linux() {
    local PORT=$1
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"

    # Stop any running MongoDB on this port
    pkill -f "mongod.*--port $PORT" || true
    sleep 2

    # Create directories
    mkdir -p $DB_PATH $LOG_PATH
    chown -R mongodb:mongodb $DB_PATH $LOG_PATH 2>/dev/null || true

    # Create config file
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
    if [ "$2" = "yes" ]; then
        cat >> $CONFIG_FILE <<EOL
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOL
    fi

    # Start mongod
    mongod --config $CONFIG_FILE
    sleep 2
}

create_keyfile_linux() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Creating MongoDB keyFile..."
        openssl rand -base64 756 > $KEY_FILE
        chmod 600 $KEY_FILE
        chown mongodb:mongodb $KEY_FILE 2>/dev/null || true
    fi
}

setup_replica_primary_linux() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    # Step 1: Start all nodes WITHOUT security
    echo "Step 1: Starting MongoDB nodes without security..."
    pkill -f mongod || true
    sleep 2
    
    setup_node_linux $PRIMARY_PORT "no"
    setup_node_linux $ARBITER1_PORT "no"
    setup_node_linux $ARBITER2_PORT "no"
    sleep 5
    
    # Step 2: Initialize replica set
    echo "Step 2: Initializing replica set..."
    mongosh --port $PRIMARY_PORT --eval '
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
    
    # Step 3: Wait for primary to be elected
    echo "Step 3: Waiting for primary to be elected..."
    mongosh --port $PRIMARY_PORT --eval '
    let attempts = 0;
    while (attempts < 30) {
        let status = rs.status();
        if (status.members && status.members.find(m => m.state === 1)) {
            print("Primary elected successfully!");
            printjson(status);
            break;
        }
        print("Waiting for primary, attempt: " + (attempts + 1));
        sleep(1000);
        attempts++;
    }
    '

    # Step 4: Create admin user
    echo "Step 4: Creating admin user..."
    read -p "Enter admin username (default: admin): " admin_username
    admin_username=${admin_username:-admin}
    read -p "Enter admin password (default: adminpass): " admin_password
    admin_password=${admin_password:-adminpass}
    
    mongosh --port $PRIMARY_PORT --eval '
    db = db.getSiblingDB("admin");
    db.createUser({
        user: "'$admin_username'", 
        pwd: "'$admin_password'", 
        roles: [
            { role: "root", db: "admin" },
            { role: "clusterAdmin", db: "admin" }
        ]
    });
    '
    sleep 2
    
    # Step 5: Create keyFile and restart with security
    echo "Step 5: Creating keyFile and restarting with security..."
    create_keyfile_linux
    pkill -f mongod || true
    sleep 2
    
    setup_node_linux $PRIMARY_PORT "yes"
    setup_node_linux $ARBITER1_PORT "yes"
    setup_node_linux $ARBITER2_PORT "yes"
    sleep 5
    
    # Step 6: Verify setup
    echo "Step 6: Verifying replica set with authentication..."
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
    print("Authentication successful!");
    print("\nReplica set status:");
    printjson(rs.status());
    '
    
    # Final status
    echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
    echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
    echo "Admin user: $admin_username"
    echo "Connection command: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
}

setup_replica_secondary_linux() {
    echo -e "${RED}This script is designed to set up all replica nodes on a single server.${NC}"
    echo "Please use setup_replica_primary_linux instead."
    return 1
}

# Function to be called from main.sh
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
        1)
            setup_replica_primary_linux $SERVER_IP
            ;;
        2)
            setup_replica_secondary_linux $SERVER_IP
            ;;
        3)
            echo "Returning to main menu..."
            return 0
            ;;
        *)
            echo -e "${RED}❌ Invalid option${NC}"
            return 1
            ;;
    esac
}


