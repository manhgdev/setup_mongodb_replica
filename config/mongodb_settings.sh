#!/bin/bash
# File cấu hình chung cho MongoDB Replica Set

# Cấu hình màu sắc
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Biến cấu hình MongoDB
MONGO_VERSION="8.0"
MONGO_PORT="27017"
REPLICA_SET_NAME="rs0"
BIND_IP="0.0.0.0"
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"
AUTH_DATABASE="admin"
MAX_SERVERS=7

# Đường dẫn - Linux
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    HOME_DIR="${HOME}"
    MONGODB_DATA_DIR="${HOME_DIR}/.mongodb/data"
    MONGODB_LOG_DIR="${HOME_DIR}/.mongodb/logs"
    MONGODB_CONFIG_DIR="${HOME_DIR}/.mongodb/config"
    MONGODB_LOG_PATH="${MONGODB_LOG_DIR}/mongod.log"
    MONGODB_CONFIG="${MONGODB_CONFIG_DIR}/mongod.conf"
    MONGODB_KEYFILE="${MONGODB_CONFIG_DIR}/mongodb-keyfile"
# Đường dẫn - macOS
elif [[ "$OSTYPE" == "darwin"* ]]; then
    MONGODB_DATA_DIR="/usr/local/var/mongodb"
    MONGODB_LOG_DIR="/usr/local/var/log/mongodb"
    MONGODB_CONFIG_DIR="/usr/local/etc/mongodb"
    MONGODB_LOG_PATH="$MONGODB_LOG_DIR/mongod.log"
    MONGODB_CONFIG="$MONGODB_CONFIG_DIR/mongod.conf"
    MONGODB_KEYFILE="$MONGODB_CONFIG_DIR/mongodb-keyfile"
# Mặc định
else
    HOME_DIR="${HOME}"
    MONGODB_DATA_DIR="${HOME_DIR}/.mongodb/data"
    MONGODB_LOG_DIR="${HOME_DIR}/.mongodb/logs"
    MONGODB_CONFIG_DIR="${HOME_DIR}/.mongodb/config"
    MONGODB_LOG_PATH="${MONGODB_LOG_DIR}/mongod.log"
    MONGODB_CONFIG="${MONGODB_CONFIG_DIR}/mongod.conf"
    MONGODB_KEYFILE="${MONGODB_CONFIG_DIR}/mongodb-keyfile"
fi

# Đồng bộ các biến trùng lặp
MONGODB_PORT="$MONGO_PORT"

