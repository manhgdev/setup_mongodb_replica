#!/bin/bash
# File cấu hình chung cho MongoDB Replica Set

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

# Biến cấu hình MongoDB
MONGO_PORT="27017"
BIND_IP="0.0.0.0"
REPLICA_SET_NAME="rs0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MONGO_VERSION="8.0"
MAX_SERVERS=7

# Đường dẫn
HOME_DIR="${HOME}"
MONGODB_KEYFILE="${HOME_DIR}/.mongodb-keyfile"
MONGODB_CONFIG="${HOME_DIR}/.mongodb/mongod.conf"
MONGODB_DATA_DIR="${HOME_DIR}/.mongodb/data"
MONGODB_LOG_PATH="${HOME_DIR}/.mongodb/logs/mongod.log" 