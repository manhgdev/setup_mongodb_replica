#!/bin/bash
# check_mongodb_connection.sh
# Hàm kiểm tra kết nối MongoDB

# Hàm kiểm tra kết nối MongoDB
check_mongodb_connection() {
    local host=$1
    local user=$2
    local pass=$3
    local auth_db=$4
    
    echo "Đang kiểm tra kết nối tới: $host"
    
    # Thử kết nối cơ bản trước
    if ! nc -z $(echo $host | cut -d: -f1) $(echo $host | cut -d: -f2) 2>/dev/null; then
        echo "Không thể kết nối TCP tới $host"
        return 1
    fi
    
    local result
    if [ -z "$user" ]; then
        echo "Kiểm tra kết nối không có auth..."
        result=$(timeout 10 mongosh --host "$host" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null)
    else
        echo "Kiểm tra kết nối với auth (user: $user)..."
        result=$(timeout 10 mongosh --host "$host" -u "$user" -p "$pass" --authenticationDatabase "$auth_db" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null)
    fi
    
    echo "Kết quả ping MongoDB: '$result'"
    
    # Kiểm tra kết quả - cần trim whitespace
    result=$(echo "$result" | tr -d ' \n\r\t')
    if [ "$result" = "1" ]; then
        echo "✓ Kết nối MongoDB thành công"
        return 0
    else
        echo "✗ Kết nối MongoDB thất bại"
        
        # Thử kiểm tra thêm thông tin lỗi
        echo "Chi tiết lỗi:"
        if [ -z "$user" ]; then
            timeout 5 mongosh --host "$host" --eval "db.runCommand({ping: 1})" 2>&1 | head -5
        else
            timeout 5 mongosh --host "$host" -u "$user" -p "$pass" --authenticationDatabase "$auth_db" --eval "db.runCommand({ping: 1})" 2>&1 | head -5
        fi
        
        return 1
    fi
}