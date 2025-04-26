#!/bin/bash
# File cấu hình chung cho MongoDB Replica Set

# MongoDB Configuration
MONGODB_PORT=27017
REPLICA_SET_NAME="rs0"

# Directory Configuration
MONGODB_DATA_DIR="/usr/local/var/mongodb"
MONGODB_LOG_DIR="/usr/local/var/log/mongodb"
MONGODB_CONFIG_DIR="/usr/local/etc/mongodb"
MONGODB_LOG_PATH="$MONGODB_LOG_DIR/mongod.log"
MONGODB_CONFIG_PATH="$MONGODB_CONFIG_DIR/mongod.conf"
KEYFILE_PATH="$MONGODB_CONFIG_DIR/keyfile"

# Color Configuration
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Biến cấu hình MongoDB
MONGO_PORT="27017"
BIND_IP="0.0.0.0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MONGO_VERSION="8.0"
MAX_SERVERS=7
