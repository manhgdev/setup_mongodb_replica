#!/bin/bash

setup_node_linux() {
    local PORT=$1
    local NODE_TYPE=$2
    local ENABLE_SECURITY=$3 # "yes" or "no"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"

    mkdir -p "/var/lib/mongodb_${PORT}"
    mkdir -p "/var/log/mongodb"
    chown -R mongodb:mongodb "/var/lib/mongodb_${PORT}"
    chown -R mongodb:mongodb "/var/log/mongodb"

    cat > "$CONFIG_FILE" <<EOL
systemLog:
  destination: file
  path: /var/log/mongodb/mongod_${PORT}.log
  logAppend: true
storage:
  dbPath: /var/lib/mongodb_${PORT}
net:
  bindIp: 0.0.0.0
  port: ${PORT}
replication:
  replSetName: rs0
setParameter:
  allowMultipleArbiters: true
EOL

    if [ "$ENABLE_SECURITY" = "yes" ]; then
        cat >> "$CONFIG_FILE" <<EOL
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOL
    fi

    mongod --config "$CONFIG_FILE" --fork
}

create_keyfile_linux() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Creating keyFile for MongoDB..."
        openssl rand -base64 756 > "$KEY_FILE"
        chown mongodb:mongodb "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
}

check_replica_status() {
    local PORT=$1
    local status=$(mongosh --port $PORT --eval "rs.status().ok" --quiet)
    
    if [[ "$status" == "1" ]]; then
        return 0
    else
        return 1
    fi
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

    pkill mongod || true
    sleep 2

    # Step 1: Start nodes WITHOUT security
    setup_node_linux $PRIMARY_PORT "primary" "no"
    setup_node_linux $ARBITER1_PORT "arbiter" "no"
    setup_node_linux $ARBITER2_PORT "arbiter" "no"
    sleep 5

    # Step 2: Initialize replica set
    mongosh --port $PRIMARY_PORT --eval 'rs.initiate({
        _id: "rs0",
        members: [
            { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
            { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true },
            { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true }
        ]
    })'
    sleep 3

    # Step 3: Create admin user
    mongosh --port $PRIMARY_PORT --eval '
        db = db.getSiblingDB("admin");
        if (!db.getUser("'$admin_username'")) {
            db.createUser({user: "'$admin_username'", pwd: "'$admin_password'", roles: [ { role: "root", db: "admin" }, { role: "clusterAdmin", db: "admin" } ]});
        }
    '
    sleep 2

    # Step 4: Enable security, restart nodes
    create_keyfile_linux
    pkill mongod || true
    sleep 2
    setup_node_linux $PRIMARY_PORT "primary" "yes"
    setup_node_linux $ARBITER1_PORT "arbiter" "yes"
    setup_node_linux $ARBITER2_PORT "arbiter" "yes"
    sleep 5

    # Step 5: Check login
    mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})'
    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}✅ Successfully configured and logged into PRIMARY node${NC}"
        echo "Connection: mongosh --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
    else
        echo -e "${RED}❌ Login failed. Check logs.${NC}"
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
    pkill mongod || true
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
    pkill mongod || true
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


