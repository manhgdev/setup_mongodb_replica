#!/bin/bash
# check_mongodb_connection.sh
# Hàm kiểm tra kết nối MongoDB

# Hàm kiểm tra kết nối MongoDB
check_mongodb_connection() {
    local host=$1
    local user=$2
    local pass=$3
    local auth_db=$4
    
    echo "Đang kiểm tra kết nối tới: $host với user: $user"
    
    local result
    if [ -z "$user" ]; then
        result=$(mongosh --host "$host" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null)
    else
        result=$(mongosh --host "$host" -u "$user" -p "$pass" --authenticationDatabase "$auth_db" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null)
    fi
    
    echo "Kết quả kết nối: $result"
    
    # Kiểm tra kết quả
    if [ "$result" = "1" ]; then
        echo "Kết nối thành công"
        return 0
    else
        echo "Kết nối thất bại"
        return 1
    fi
}