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

# Đường dẫn
HOME_DIR="${HOME}"
MONGODB_DATA_DIR="/data/rs0"
MONGODB_LOG_PATH="/var/log/mongodb/mongod.log"
MONGODB_CONFIG="/etc/mongod.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"

