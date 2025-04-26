#!/bin/bash
# File cấu hình chung cho MongoDB Replica Set

# Color Configuration
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# MongoDB Configuration
MONGO_VERSION="8.0"
MONGO_PORT="27017"
REPLICA_SET_NAME="rs0"
BIND_IP="0.0.0.0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MAX_SERVERS=7

# Directory Configuration
HOME_DIR="${HOME}"
MONGODB_DATA_DIR="${HOME_DIR}/.mongodb/data"
MONGODB_LOG_DIR="${HOME_DIR}/.mongodb/logs"
MONGODB_CONFIG_DIR="${HOME_DIR}/.mongodb/config"
MONGODB_LOG_PATH="${MONGODB_LOG_DIR}/mongod.log"
MONGODB_CONFIG="${MONGODB_CONFIG_DIR}/mongod.conf"
MONGODB_KEYFILE="${MONGODB_CONFIG_DIR}/keyfile" 