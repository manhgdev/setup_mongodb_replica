#!/bin/bash

# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import required configuration files
if [ -f "$SCRIPT_DIR/../config/mongodb_settings.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_settings.sh"
fi

if [ -f "$SCRIPT_DIR/../config/mongodb_functions.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_functions.sh"
fi

# Define colors if not defined
if [ -z "$BLUE" ] || [ -z "$GREEN" ] || [ -z "$YELLOW" ] || [ -z "$RED" ] || [ -z "$NC" ]; then
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    NC='\033[0m'
fi

setup_replica_macos() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       ${YELLOW}MONGODB REPLICA SET CONFIG (macOS)${NC}    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    
    # Check if MongoDB is installed
    if ! command -v mongod &> /dev/null; then
        echo -e "${RED}❌ MongoDB is not installed. Please install MongoDB first.${NC}"
        echo -e "${YELLOW}You can install MongoDB using Homebrew:${NC}"
        echo -e "${YELLOW}brew tap mongodb/brew${NC}"
        echo -e "${YELLOW}brew install mongodb-community${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ Please run this script as root (sudo)${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi

    # Create necessary directories
    mkdir -p "$MONGODB_DATA_DIR"
    mkdir -p "$MONGODB_LOG_DIR"
    mkdir -p "$MONGODB_CONFIG_DIR"

    # Generate keyfile if not exists
    if [ ! -f "$MONGODB_KEYFILE" ]; then
        openssl rand -base64 756 > "$MONGODB_KEYFILE"
        chmod 400 "$MONGODB_KEYFILE"
    fi

    # Create MongoDB configuration
    cat > "$MONGODB_CONFIG" << EOF
systemLog:
  destination: file
  path: "$MONGODB_LOG_PATH"
  logAppend: true
storage:
  dbPath: "$MONGODB_DATA_DIR"
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0
security:
  keyFile: "$MONGODB_KEYFILE"
replication:
  replSetName: "$REPLICA_SET_NAME"
EOF

    # Stop MongoDB if running
    brew services stop mongodb-community

    # Start MongoDB
    brew services start mongodb-community

    # Wait for MongoDB to start
    sleep 5

    # Initialize replica set
    mongosh --port $MONGO_PORT --eval "
        rs.initiate({
            _id: '$REPLICA_SET_NAME',
            members: [
                {_id: 0, host: 'localhost:$MONGO_PORT'}
            ]
        })
    "

    echo -e "${GREEN}✓ MongoDB Replica Set has been configured successfully!${NC}"
    echo -e "${YELLOW}You can now add more nodes to the replica set.${NC}"
    read -p "Press Enter to continue..."
}

# Chỉ chạy setup_replica_macos nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica_macos
fi