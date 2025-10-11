#!/bin/bash
# check_mongodb_connection.sh
# Hàm kiểm tra kết nối MongoDB

# Hàm kiểm tra kết nối MongoDB
check_mongodb_connection() {
    local host=$1
    local user=$2
    local pass=$3
    local auth_db=$4
    
    if [ -z "$user" ]; then
        mongosh --host "$host" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null
    else
        mongosh --host "$host" -u "$user" -p "$pass" --authenticationDatabase "$auth_db" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null
    fi
}