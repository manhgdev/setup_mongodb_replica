#!/bin/bash

setup_node_linux() {
    local PORT=$1
    local NODE_TYPE=$2
    local ENABLE_SECURITY=$3 # "yes" or "no"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local LOG_FILE="/var/log/mongodb/mongod_${PORT}.log"
    local DB_PATH="/var/lib/mongodb_${PORT}"

    # Ensure no conflicting MongoDB instance is running on this port
    echo "Stopping any MongoDB process running on port $PORT..."
    pkill -f "mongod.*--port ${PORT}" || true
    sleep 3

    # Clean up database directory if needed
    if [ "$NODE_TYPE" = "arbiter" ]; then
        echo "Cleaning up arbiter database directory..."
        rm -rf "${DB_PATH}"/*
    fi

    # Create necessary directories
    echo "Creating directories for MongoDB on port $PORT..."
    mkdir -p "${DB_PATH}"
    mkdir -p "/var/log/mongodb"
    
    # Set permissions - handle potential permission errors gracefully
    echo "Setting permissions..."
    if ! chown -R mongodb:mongodb "${DB_PATH}" 2>/dev/null; then
        echo "Note: Could not set permissions on ${DB_PATH} - may need sudo"
    fi
    
    if ! chown -R mongodb:mongodb "/var/log/mongodb" 2>/dev/null; then
        echo "Note: Could not set permissions on /var/log/mongodb - may need sudo"
    fi

    # Create MongoDB configuration file
    echo "Creating MongoDB config file for port $PORT..."
    cat > "$CONFIG_FILE" <<EOL
systemLog:
  destination: file
  path: ${LOG_FILE}
  logAppend: true
storage:
  dbPath: ${DB_PATH}
net:
  bindIp: 0.0.0.0
  port: ${PORT}
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
processManagement:
  fork: true
EOL

    if [ "$ENABLE_SECURITY" = "yes" ]; then
        cat >> "$CONFIG_FILE" <<EOL
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOL
    fi

    # Try to start MongoDB
    echo "Starting MongoDB on port $PORT..."
    mongod --config "$CONFIG_FILE"
    
    # Check if MongoDB is running
    sleep 3
    if pgrep -f "mongod.*--port ${PORT}" > /dev/null; then
        echo -e "${GREEN}✅ MongoDB started successfully on port $PORT${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to start MongoDB on port $PORT. Checking logs...${NC}"
        if [ -f "$LOG_FILE" ]; then
            tail -n 20 "$LOG_FILE"
        else
            echo "Log file $LOG_FILE doesn't exist!"
        fi
        return 1
    fi
}

create_keyfile_linux() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Creating keyFile for MongoDB..."
        openssl rand -base64 756 > "$KEY_FILE"
        chown mongodb:mongodb "$KEY_FILE" 2>/dev/null || true
        chmod 600 "$KEY_FILE"
    fi
}

check_replica_status() {
    local PORT=$1
    local status=$(mongosh --port $PORT --eval "rs.status().ok" --quiet 2>/dev/null)
    
    if [[ "$status" == "1" ]]; then
        return 0
    else
        return 1
    fi
}

wait_for_mongodb_ready() {
    local HOST=$1
    local PORT=$2
    local AUTH=$3  # "yes" or "no"
    local USERNAME=$4
    local PASSWORD=$5
    
    local max_attempts=30
    local attempt=1
    
    echo "Waiting for MongoDB on $HOST:$PORT to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if [ "$AUTH" = "yes" ]; then
            if mongosh --host $HOST --port $PORT -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase admin --eval "db.runCommand({ping:1})" --quiet &>/dev/null; then
                echo -e "${GREEN}✅ MongoDB on $HOST:$PORT is ready (authenticated)${NC}"
                return 0
            fi
        else
            if mongosh --host $HOST --port $PORT --eval "db.runCommand({ping:1})" --quiet &>/dev/null; then
                echo -e "${GREEN}✅ MongoDB on $HOST:$PORT is ready${NC}"
                return 0
            fi
        fi
        
        echo "Attempt $attempt/$max_attempts: MongoDB on $HOST:$PORT not ready yet, waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}❌ MongoDB on $HOST:$PORT failed to become ready after $max_attempts attempts${NC}"
    return 1
}

setup_replica_primary_linux() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1

    read -p "Enter admin username (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}

    # Stop all MongoDB instances
    echo "Stopping any running MongoDB instances..."
    pkill -f mongod || true
    sleep 5
    
    # Check if any MongoDB processes are still running
    if pgrep -f mongod > /dev/null; then
        echo -e "${YELLOW}⚠️ Some MongoDB processes are still running. They might interfere with setup.${NC}"
        ps aux | grep mongod | grep -v grep
    fi

    # Step 1: Start nodes WITHOUT security
    echo -e "\n${YELLOW}Step 1: Starting nodes WITHOUT security${NC}"
    
    echo "Starting PRIMARY node without security..."
    if ! setup_node_linux $PRIMARY_PORT "primary" "no"; then
        echo -e "${RED}❌ Failed to start PRIMARY node${NC}"
        return 1
    fi
    
    echo "Starting ARBITER 1 node without security..."
    if ! setup_node_linux $ARBITER1_PORT "arbiter" "no"; then
        echo -e "${RED}❌ Failed to start ARBITER 1 node${NC}"
        return 1
    fi
    
    echo "Starting ARBITER 2 node without security..."
    if ! setup_node_linux $ARBITER2_PORT "arbiter" "no"; then
        echo -e "${RED}❌ Failed to start ARBITER 2 node${NC}"
        return 1
    fi
    
    echo "Waiting for all MongoDB instances to be ready..."
    sleep 10
    
    # Check all MongoDB instances are running
    for PORT in $PRIMARY_PORT $ARBITER1_PORT $ARBITER2_PORT; do
        if ! pgrep -f "mongod.*--port ${PORT}" > /dev/null; then
            echo -e "${RED}❌ MongoDB on port $PORT is not running${NC}"
            return 1
        fi
    done

    # Step 2: Initialize replica set
    echo -e "\n${YELLOW}Step 2: Initializing replica set${NC}"
    mongosh --port $PRIMARY_PORT --eval '
        print("Initializing replica set...");
        var config = {
            _id: "rs0",
            members: [
                { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
                { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
                { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
            ]
        };
        rs.initiate(config);
        
        // Wait for replica set to initialize
        var attempts = 0;
        var maxAttempts = 30;
        while(attempts < maxAttempts) {
            var status = rs.status();
            if(status.ok === 1) {
                print("Replica set initialized successfully");
                printjson(status);
                break;
            }
            print("Waiting for replica set to initialize... Attempt " + (attempts + 1) + "/" + maxAttempts);
            sleep(1000);
            attempts++;
        }
        
        if(attempts >= maxAttempts) {
            print("Failed to initialize replica set after " + maxAttempts + " attempts");
        }
    '
    
    # Step 3: Create admin user
    echo -e "\n${YELLOW}Step 3: Creating admin user${NC}"
    mongosh --port $PRIMARY_PORT --eval '
        // Wait for primary to be ready
        var attempts = 0;
        var maxAttempts = 30;
        while(attempts < maxAttempts) {
            var status = rs.status();
            if(status.ok === 1 && status.members.find(m => m.state === 1)) {
                print("Primary node is ready");
                break;
            }
            print("Waiting for primary node... Attempt " + (attempts + 1) + "/" + maxAttempts);
            sleep(1000);
            attempts++;
        }
        
        if(attempts >= maxAttempts) {
            print("Failed to find primary node after " + maxAttempts + " attempts");
            quit(1);
        }
        
        // Create admin user
        db = db.getSiblingDB("admin");
        if(!db.getUser("'$admin_username'")) {
            print("Creating admin user: '$admin_username'");
            db.createUser({
                user: "'$admin_username'", 
                pwd: "'$admin_password'", 
                roles: [ 
                    { role: "root", db: "admin" }, 
                    { role: "clusterAdmin", db: "admin" } 
                ]
            });
            print("Admin user created successfully");
        } else {
            print("Admin user already exists");
        }
    '

    # Step 4: Enable security, restart nodes
    echo -e "\n${YELLOW}Step 4: Enabling security and restarting nodes${NC}"
    create_keyfile_linux
    
    echo "Stopping all MongoDB instances..."
    pkill -f mongod || true
    sleep 5
    
    echo "Starting PRIMARY node with security enabled..."
    if ! setup_node_linux $PRIMARY_PORT "primary" "yes"; then
        echo -e "${RED}❌ Failed to start PRIMARY node with security${NC}"
        return 1
    fi
    
    echo "Starting ARBITER 1 node with security enabled..."
    if ! setup_node_linux $ARBITER1_PORT "arbiter" "yes"; then
        echo -e "${RED}❌ Failed to start ARBITER 1 node with security${NC}"
        return 1
    fi
    
    echo "Starting ARBITER 2 node with security enabled..."
    if ! setup_node_linux $ARBITER2_PORT "arbiter" "yes"; then
        echo -e "${RED}❌ Failed to start ARBITER 2 node with security${NC}"
        return 1
    fi
    
    # Wait for MongoDB instances to be ready with security
    echo "Waiting for MongoDB instances to be ready with security..."
    sleep 15

    # Step 5: Check login and verify replica set status
    echo -e "\n${YELLOW}Step 5: Verifying replica set status${NC}"
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
        try {
            print("Testing connection...");
            db.runCommand({ping: 1});
            print("Connection successful!");
            
            print("\nReplica set status:");
            var status = rs.status();
            printjson(status);
            
            print("\nReplica set configuration:");
            var config = rs.conf();
            printjson(config);
        } catch(err) {
            print("Error verifying replica set: " + err);
            quit(1);
        }
    '
    
    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}✅ Successfully configured MongoDB Replica Set PRIMARY${NC}"
        echo "Connection: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
    else
        echo -e "${RED}❌ Failed to verify replica set. Check logs.${NC}"
    fi
}

setup_replica_secondary_linux() {
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019
    local SERVER_IP=$1
    
    echo "Enter PRIMARY server IP: "
    read -r primary_server_ip
    if [ -z "$primary_server_ip" ]; then
        echo -e "${RED}❌ PRIMARY server IP is required${NC}"
        return 1
    fi
    
    read -p "Enter admin username for PRIMARY (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password for PRIMARY (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
    # Stop current MongoDB instances
    pkill -f mongod || true
    sleep 2
    
    # First setup nodes WITHOUT security
    echo "Setting up SECONDARY node without security..."
    setup_node_linux $PRIMARY_PORT "secondary" "no"
    
    echo "Setting up ARBITER 1 node without security..."
    setup_node_linux $ARBITER1_PORT "arbiter" "no"
    
    echo "Setting up ARBITER 2 node without security..."
    setup_node_linux $ARBITER2_PORT "arbiter" "no"
    
    sleep 5
    
    # Connect to PRIMARY server
    echo "Connecting to PRIMARY server..."
    
    # Wait for PRIMARY server to be ready
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status()' &> /dev/null; then
            echo -e "${GREEN}✅ PRIMARY server is ready${NC}"
            break
        fi
        echo "Waiting for PRIMARY server to be ready... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}❌ Could not connect to PRIMARY server${NC}"
        return 1
    fi
    
    # Add nodes to replica set
    echo "Adding SECONDARY node to replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.add("'$SERVER_IP:$PRIMARY_PORT'")'
    
    echo "Adding ARBITER 1 node to replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.addArb("'$SERVER_IP:$ARBITER1_PORT'")'
    
    echo "Adding ARBITER 2 node to replica set..."
    mongosh --host $primary_server_ip --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.addArb("'$SERVER_IP:$ARBITER2_PORT'")'
    
    sleep 5
    
    # Now create keyfile and restart with security enabled
    create_keyfile_linux
    pkill -f mongod || true
    sleep 2
    
    # Restart nodes WITH security
    echo "Restarting SECONDARY node with security..."
    setup_node_linux $PRIMARY_PORT "secondary" "yes"
    
    echo "Restarting ARBITER 1 node with security..."
    setup_node_linux $ARBITER1_PORT "arbiter" "yes"
    
    echo "Restarting ARBITER 2 node with security..."
    setup_node_linux $ARBITER2_PORT "arbiter" "yes"
    
    sleep 5
    
    # Check status
    if mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'rs.status()' &> /dev/null; then
        echo -e "${GREEN}✅ Successfully configured MongoDB Replica Set SECONDARY${NC}"
        echo "Connection information:"
        echo "IP: $SERVER_IP"
        echo "Ports: $PRIMARY_PORT (SECONDARY), $ARBITER1_PORT (ARBITER), $ARBITER2_PORT (ARBITER)"
        echo "Connected to PRIMARY server: $primary_server_ip"
    else
        echo -e "${RED}❌ Error occurred when configuring SECONDARY${NC}"
    fi
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


