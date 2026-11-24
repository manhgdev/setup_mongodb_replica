#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/mongo_auth.sh" || exit 1
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
        mongo_eval "$user" "$pass" "$auth_db" --host "$host" --quiet --eval "rs.status().ok" 2>/dev/null
    fi
}