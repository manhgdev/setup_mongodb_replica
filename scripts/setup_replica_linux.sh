setup_node_linux() {
    local PORT=$1
    local SECURITY=$2  # "yes" or "no"
    local CONFIG_FILE="/etc/mongod_${PORT}.conf"
    local DB_PATH="/var/lib/mongodb_${PORT}"
    local LOG_PATH="/var/log/mongodb"
    local SOCKET_FILE="/tmp/mongodb-${PORT}.sock"

    # Stop the system MongoDB service if it exists and is running
    if systemctl is-active --quiet mongod; then
        echo "Stopping system MongoDB service..."
        sudo systemctl stop mongod
        sleep 2
    fi

    # Disable system MongoDB service to prevent it from starting automatically
    if systemctl is-enabled --quiet mongod; then
        echo "Disabling system MongoDB service during setup..."
        sudo systemctl disable mongod
    fi
    
    # Stop any running MongoDB on this port
    pkill -f "mongod.*--port $PORT" || true
    sleep 2
    
    # Check and remove socket file if it exists
    if [ -e "$SOCKET_FILE" ]; then
        echo "Removing old socket file $SOCKET_FILE"
        sudo rm -f "$SOCKET_FILE"
    fi

    # Create directories
    sudo mkdir -p $DB_PATH $LOG_PATH
    sudo chown -R mongodb:mongodb $DB_PATH $LOG_PATH

    # Clean up database directory for fresh start if needed
    if [ "$3" = "clean" ]; then
        echo "Cleaning up MongoDB data directory for port $PORT..."
        sudo rm -rf $DB_PATH/*
    fi

    # Create config file with enhanced settings
    sudo bash -c "cat > $CONFIG_FILE" <<EOL
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
  timeZoneInfo: /usr/share/zoneinfo
EOL

    # Add security if enabled
    if [ "$SECURITY" = "yes" ]; then
        sudo bash -c "cat >> $CONFIG_FILE" <<EOL
security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOL
    fi

    # Ensure ports are not in use
    if netstat -tuln | grep -q ":$PORT "; then
        echo "Warning: Port $PORT is already in use. Trying to close any existing connections..."
        sudo lsof -i :$PORT | awk 'NR>1 {print $2}' | xargs -r sudo kill -9
        sleep 2
    fi
    
    # Fix file permissions in /tmp directory
    sudo chmod 1777 /tmp

    # Start mongod with sudo for proper permissions
    echo "Starting MongoDB on port $PORT..."
    sudo mongod --config "$CONFIG_FILE" --fork
    
    # Check if MongoDB started successfully with more thorough verification
    local max_attempts=30
    local attempt=1
    local started=false
    
    while [ $attempt -le $max_attempts ]; do
        echo "Waiting for MongoDB to start (attempt $attempt/$max_attempts)..."
        sleep 5
        
        # Check if process exists
        if ! pgrep -f "mongod.*--port $PORT" > /dev/null; then
            echo "MongoDB process not found, checking log for errors..."
            if [ -r "$LOG_PATH/mongod_${PORT}.log" ]; then
                tail -n 20 "$LOG_PATH/mongod_${PORT}.log"
            else
                sudo tail -n 20 "$LOG_PATH/mongod_${PORT}.log"
            fi
            return 1
        fi
        
        # Try to connect
        if mongosh --port $PORT --eval "db.version()" --quiet &>/dev/null; then
            echo -e "${GREEN}✅ MongoDB started successfully on port $PORT${NC}"
            started=true
            break
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$started" = "false" ]; then
        echo -e "${RED}❌ Failed to start MongoDB on port $PORT${NC}"
        echo "Last 20 lines of log:"
        if [ -r "$LOG_PATH/mongod_${PORT}.log" ]; then
            tail -n 20 "$LOG_PATH/mongod_${PORT}.log"
        else
            sudo tail -n 20 "$LOG_PATH/mongod_${PORT}.log"
        fi
        
        # Try to get more detailed error information
        echo "Checking for common issues:"
        if [ ! -d "$DB_PATH" ]; then
            echo "- Database directory does not exist: $DB_PATH"
        fi
        if [ ! -w "$DB_PATH" ]; then
            echo "- Database directory is not writable: $DB_PATH"
        fi
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "- Config file does not exist: $CONFIG_FILE"
        fi
        if [ ! -r "$CONFIG_FILE" ]; then
            echo "- Config file is not readable: $CONFIG_FILE"
        fi
        
        # Check process status
        echo "MongoDB process status:"
        ps aux | grep mongod | grep -v grep
        
        # Check port status
        echo "Port status:"
        netstat -tuln | grep $PORT
        
        return 1
    fi
    
    return 0
}

create_keyfile_linux() {
    local KEY_FILE="/etc/mongodb.key"
    if [ ! -f "$KEY_FILE" ]; then
        echo "Creating MongoDB keyFile..."
        if [ $(id -u) -eq 0 ]; then
            openssl rand -base64 756 > $KEY_FILE
            chmod 600 $KEY_FILE
            chown mongodb:mongodb $KEY_FILE
        else
            sudo bash -c "openssl rand -base64 756 > $KEY_FILE"
            sudo chmod 600 $KEY_FILE
            sudo chown mongodb:mongodb $KEY_FILE
        fi
    fi
}

# Function to be called at the start of either primary or secondary setup
prepare_system() {
    echo "Preparing system for MongoDB replica set..."
    
    # Check if running as root
    if [ $(id -u) -ne 0 ]; then
        echo -e "${YELLOW}Warning: Not running as root. Using sudo for required operations.${NC}"
    fi
    
    # Check for system MongoDB
    if systemctl list-units --full -all | grep -Fq "mongod.service"; then
        echo "Detected system MongoDB service."
        if systemctl is-active --quiet mongod; then
            echo "System MongoDB service is active. Stopping it..."
            sudo systemctl stop mongod
        fi
    fi
    
    # Remove any existing socket files
    for PORT in 27017 27018 27019; do
        if [ -e "/tmp/mongodb-${PORT}.sock" ]; then
            echo "Removing existing socket file for port $PORT"
            sudo rm -f "/tmp/mongodb-${PORT}.sock"
        fi
    done
    
    # Ensure /tmp has correct permissions
    echo "Setting correct permissions on /tmp directory"
    sudo chmod 1777 /tmp
    
    # Create directories with proper permissions
    echo "Creating MongoDB directories..."
    for PORT in 27017 27018 27019; do
        sudo mkdir -p "/var/lib/mongodb_${PORT}"
        sudo mkdir -p "/var/log/mongodb"
        sudo chown -R mongodb:mongodb "/var/lib/mongodb_${PORT}"
        sudo chown -R mongodb:mongodb "/var/log/mongodb"
        sudo chmod 755 "/var/lib/mongodb_${PORT}"
    done
    
    # Check if mongodb user exists
    if ! id -u mongodb >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: mongodb user does not exist. Creating it...${NC}"
        sudo useradd -r -s /bin/false mongodb
    fi
}

setup_replica_primary_linux() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER1_PORT=27018
    local ARBITER2_PORT=27019

    # Prepare system
    prepare_system
    
    # Step 1: Start all nodes WITHOUT security and clean data
    echo "Step 1: Starting MongoDB nodes without security..."
    pkill -f mongod || true
    sleep 2
    
    # Clean start for better initialization
    echo "Starting PRIMARY node..."
    if ! setup_node_linux $PRIMARY_PORT "no" "clean"; then
        echo -e "${RED}❌ Failed to start PRIMARY node${NC}"
        return 1
    fi
    
    echo "Starting ARBITER1 node..."
    if ! setup_node_linux $ARBITER1_PORT "no" "clean"; then
        echo -e "${RED}❌ Failed to start ARBITER1 node${NC}"
        return 1
    fi
    
    echo "Starting ARBITER2 node..."
    if ! setup_node_linux $ARBITER2_PORT "no" "clean"; then
        echo -e "${RED}❌ Failed to start ARBITER2 node${NC}"
        return 1
    fi
    
    echo "Waiting for MongoDB instances to be ready..."
    sleep 10
    
    # Step 2: Initialize replica set with explicit options
    echo "Step 2: Initializing replica set..."
    mongosh --port $PRIMARY_PORT --eval '
    try {
        print("Initializing replica set with forced configuration...");
        var config = {
            _id: "rs0",
            members: [
                { _id: 0, host: "'$SERVER_IP:$PRIMARY_PORT'", priority: 2 },
                { _id: 1, host: "'$SERVER_IP:$ARBITER1_PORT'", arbiterOnly: true, priority: 0 },
                { _id: 2, host: "'$SERVER_IP:$ARBITER2_PORT'", arbiterOnly: true, priority: 0 }
            ],
            settings: {
                heartbeatTimeoutSecs: 10,
                electionTimeoutMillis: 10000,
                catchUpTimeoutMillis: 60000
            }
        };
        rs.initiate(config);
        print("Initialization command sent, waiting for completion...");
    } catch(err) {
        print("Error during initialization: " + err);
        quit(1);
    }
    '
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to initialize replica set${NC}"
        return 1
    fi
    
    sleep 10
    
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
    read -p "Enter admin username (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
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
    sleep 5
    
    # Check if all MongoDB processes stopped
    if pgrep -f mongod > /dev/null; then
        echo "Warning: Some MongoDB processes are still running. Forcing shutdown..."
        pkill -9 -f mongod
        sleep 2
    fi
    
    echo "Restarting PRIMARY node with security..."
    if ! setup_node_linux $PRIMARY_PORT "yes"; then
        echo -e "${RED}❌ Failed to restart PRIMARY node with security${NC}"
        return 1
    fi
    
    echo "Restarting ARBITER1 node with security..."
    if ! setup_node_linux $ARBITER1_PORT "yes"; then
        echo -e "${RED}❌ Failed to restart ARBITER1 node with security${NC}"
        return 1
    fi
    
    echo "Restarting ARBITER2 node with security..."
    if ! setup_node_linux $ARBITER2_PORT "yes"; then
        echo -e "${RED}❌ Failed to restart ARBITER2 node with security${NC}"
        return 1
    fi
    
    # Wait for MongoDB to be fully ready
    echo "Waiting for MongoDB to be ready with security..."
    sleep 10
    
    # Step 6: Verify setup
    echo "Step 6: Verifying replica set with authentication..."
    
    # Try both localhost and server IP
    echo "Trying to connect to MongoDB..."
    if mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})' &>/dev/null; then
        echo -e "${GREEN}✅ Connection successful using server IP${NC}"
        SERVER_HOST=$SERVER_IP
    elif mongosh --host localhost --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})' &>/dev/null; then
        echo -e "${GREEN}✅ Connection successful using localhost${NC}"
        SERVER_HOST="localhost"
    else
        echo -e "${RED}❌ Failed to connect to MongoDB${NC}"
        echo "Showing MongoDB processes:"
        ps aux | grep mongod | grep -v grep
        echo "Showing network connections:"
        netstat -tuln | grep -E "27017|27018|27019" || echo "No MongoDB ports found"
        return 1
    fi
    
    # Get replica set status
    mongosh --host $SERVER_HOST --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
    try {
        print("Authentication successful!");
        print("\nReplica set status:");
        printjson(rs.status());
    } catch(err) {
        print("Error: " + err);
    }
    '
    
    # Final status
    echo -e "\n${GREEN}✅ MongoDB Replica Set setup completed successfully.${NC}"
    echo "Primary node: $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter nodes: $SERVER_IP:$ARBITER1_PORT, $SERVER_IP:$ARBITER2_PORT"
    echo "Admin user: $admin_username"
    echo "Connection command: mongosh --host $SERVER_HOST --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
}

setup_replica_secondary_linux() {
    local SERVER_IP=$1
    local PRIMARY_PORT=27017
    local ARBITER_PORT=27018
    
    # Get primary server information
    echo -e "${YELLOW}Setting up a SECONDARY MongoDB server${NC}"
    read -p "Enter PRIMARY server IP address: " PRIMARY_IP
    if [ -z "$PRIMARY_IP" ]; then
        echo -e "${RED}❌ ERROR: PRIMARY server IP is required${NC}"
        return 1
    fi
    
    read -p "Enter admin username on PRIMARY (default: manhg): " admin_username
    admin_username=${admin_username:-manhg}
    read -p "Enter admin password on PRIMARY (default: manhnk): " admin_password
    admin_password=${admin_password:-manhnk}
    
    # Step 1: Stop any existing MongoDB processes
    echo "Step 1: Stopping any existing MongoDB processes..."
    pkill -f mongod || true
    sleep 5
    
    # Step 2: Create keyfile (needs to be the same as primary)
    echo "Step 2: Creating keyFile..."
    create_keyfile_linux
    
    # Step 3: Start MongoDB without security first
    echo "Step 3: Starting MongoDB without security..."
    setup_node_linux $PRIMARY_PORT "no" "clean"  # Add clean flag
    setup_node_linux $ARBITER_PORT "no" "clean"  # Add clean flag
    
    # Step 4: Test connection to primary
    echo "Step 4: Testing connection to PRIMARY server..."
    if ! mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval 'db.runCommand({ping:1})' &>/dev/null; then
        echo -e "${RED}❌ Failed to connect to PRIMARY server. Check IP address and credentials.${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Connection to PRIMARY server successful${NC}"
    
    # Step 5: Add this server to replica set
    echo "Step 5: Adding this server to replica set..."
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
    try {
        print("Adding secondary node: "'$SERVER_IP:$PRIMARY_PORT'");
        rs.add("'$SERVER_IP:$PRIMARY_PORT'");
        
        print("Adding arbiter node: "'$SERVER_IP:$ARBITER_PORT'");
        rs.addArb("'$SERVER_IP:$ARBITER_PORT'");
        
        print("Updated replica set configuration:");
        printjson(rs.conf());
    } catch(err) {
        print("Error: " + err);
        quit(1);
    }
    '
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to add server to replica set${NC}"
        return 1
    fi
    
    # Step 6: Restart with security enabled
    echo "Step 6: Restarting MongoDB with security enabled..."
    pkill -f mongod || true
    sleep 5
    
    setup_node_linux $PRIMARY_PORT "yes"
    setup_node_linux $ARBITER_PORT "yes"
    sleep 10
    
    # Step 7: Verify replica set status
    echo "Step 7: Verifying replica set status..."
    mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin --eval '
    try {
        print("Replica set status:");
        printjson(rs.status());
        
        const members = rs.status().members;
        const secondary = members.find(m => m.name.includes("'$SERVER_IP:$PRIMARY_PORT'"));
        const arbiter = members.find(m => m.name.includes("'$SERVER_IP:$ARBITER_PORT'"));
        
        if (secondary && (secondary.state === 2 || secondary.stateStr === "SECONDARY")) {
            print("✅ SECONDARY node is properly configured");
        } else if (secondary) {
            print("⚠️ SECONDARY node found but not yet fully synced. Current state: " + (secondary.stateStr || secondary.state));
        } else {
            print("❌ SECONDARY node not found in replica set");
        }
        
        if (arbiter && (arbiter.state === 7 || arbiter.stateStr === "ARBITER")) {
            print("✅ ARBITER node is properly configured");
        } else if (arbiter) {
            print("⚠️ ARBITER node found but in unexpected state: " + (arbiter.stateStr || arbiter.state));
        } else {
            print("❌ ARBITER node not found in replica set");
        }
    } catch(err) {
        print("Error verifying replica set: " + err);
    }
    '
    
    # Final status
    echo -e "\n${GREEN}✅ MongoDB SECONDARY setup completed${NC}"
    echo "This server (SECONDARY): $SERVER_IP:$PRIMARY_PORT"
    echo "Arbiter node on this server: $SERVER_IP:$ARBITER_PORT"
    echo "Connected to PRIMARY server: $PRIMARY_IP:$PRIMARY_PORT"
    echo "Connect to this SECONDARY: mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $admin_username -p $admin_password --authenticationDatabase admin"
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
            
            # After completion, check if we need to re-enable system MongoDB
            echo "Checking if system MongoDB service needs to be re-enabled..."
            if [ -f "/etc/mongod.conf" ]; then
                read -p "Do you want to re-enable the system MongoDB service? (y/n): " enable_system_mongo
                if [[ "$enable_system_mongo" =~ ^[Yy]$ ]]; then
                    echo "Re-enabling system MongoDB service..."
                    sudo systemctl enable mongod
                    echo "Note: To start the system MongoDB, run 'sudo systemctl start mongod'"
                else
                    echo "System MongoDB service remains disabled."
                fi
            fi
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


