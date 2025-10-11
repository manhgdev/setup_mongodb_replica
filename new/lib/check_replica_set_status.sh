#!/bin/bash
# check_replica_set_status.sh
# Hàm kiểm tra trạng thái replica set

# Hàm kiểm tra trạng thái replica set
check_replica_set_status() {
    local host=$1
    local user=$2
    local pass=$3
    local auth_db=$4
    
    if [ -z "$user" ]; then
        mongosh --host "$host" --quiet --eval "rs.status().ok" 2>/dev/null
    else
        mongosh --host "$host" -u "$user" -p "$pass" --authenticationDatabase "$auth_db" --quiet --eval "rs.status().ok" 2>/dev/null
    fi
}