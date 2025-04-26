#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Hàm kiểm tra kết nối MongoDB
check_mongodb_connection() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    if mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Kết nối thành công đến $host:$port"
        return 0
    else
        echo -e "${RED}✗${NC} Không thể kết nối đến $host:$port"
        return 1
    fi
}

# Hàm lấy thông tin replica set
get_replica_set_info() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${BLUE}Thông tin Replica Set:${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.status()" | grep -E "name|stateStr|health|uptime|lastHeartbeat"
}

# Hàm kiểm tra replication lag
check_replication_lag() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${BLUE}Kiểm tra Replication Lag:${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "db.printSlaveReplicationInfo()"
}

# Hàm kiểm tra trạng thái các node
check_nodes_status() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${BLUE}Trạng thái các Node:${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.status().members.forEach(function(member) { print(member.name + ': ' + member.stateStr + ' (Health: ' + member.health + ')') })"
}

# Main
echo -e "${YELLOW}Kiểm tra trạng thái MongoDB Replica Set${NC}"
echo -e "${YELLOW}========================================${NC}"

# Nhập thông tin kết nối
read -p "Nhập host (mặc định: localhost): " host
host=${host:-localhost}

read -p "Nhập port (mặc định: 27017): " port
port=${port:-27017}

read -p "Nhập username: " username
username="manhg"
read -s -p "Nhập password: " password
password="manhnk"
echo
read -p "Nhập authentication database (mặc định: admin): " auth_db
auth_db=${auth_db:-admin}

# Kiểm tra kết nối
if check_mongodb_connection $host $port $username $password $auth_db; then
    # Lấy thông tin replica set
    get_replica_set_info $host $port $username $password $auth_db
    
    # Kiểm tra trạng thái các node
    check_nodes_status $host $port $username $password $auth_db
    
    # Kiểm tra replication lag
    check_replication_lag $host $port $username $password $auth_db
else
    echo -e "${RED}Không thể kết nối đến MongoDB. Vui lòng kiểm tra lại thông tin kết nối.${NC}"
fi 