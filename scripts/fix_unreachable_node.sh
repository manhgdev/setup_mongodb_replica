#!/bin/bash

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Kiểm tra và sửa các vấn đề có thể gây ra lỗi không reachable
check_and_fix_unreachable() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Kiểm tra node $NODE_IP:$NODE_PORT...${NC}"
    
    # Kiểm tra kết nối mạng
    if ! ping -c 1 $NODE_IP &>/dev/null; then
        echo -e "${RED}❌ Không thể ping tới node $NODE_IP${NC}"
        return 1
    fi
    
    # Kiểm tra port có mở không
    echo -e "${YELLOW}Kiểm tra port $NODE_PORT có đang chạy không...${NC}"
    if ! nc -z -w 5 $NODE_IP $NODE_PORT &>/dev/null; then
        echo -e "${RED}❌ Port $NODE_PORT không mở trên node $NODE_IP${NC}"
        echo -e "${YELLOW}Hãy kiểm tra:${NC}"
        echo "1. MongoDB có đang chạy không: systemctl status mongod_${NODE_PORT}"
        echo "2. Cấu hình bindIp trong /etc/mongod_${NODE_PORT}.conf có đúng không"
        echo "3. Tường lửa có cho phép kết nối đến port $NODE_PORT không"
        return 1
    else
        echo -e "${GREEN}✅ Port $NODE_PORT đang mở trên node $NODE_IP${NC}"
    fi
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    local status=$(mongosh --host $NODE_IP --port $NODE_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    # Kiểm tra lỗi xác thực
    if echo "$status" | grep -q "AuthenticationFailed"; then
        echo -e "${RED}❌ Lỗi xác thực khi kết nối tới node $NODE_IP:$NODE_PORT${NC}"
        return 1
    fi
    
    # Kiểm tra node có được khởi tạo chưa
    if echo "$status" | grep -q "NotYetInitialized"; then
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT chưa được khởi tạo replica set${NC}"
        return 1
    fi
    
    # Kiểm tra kết nối từ PRIMARY
    echo -e "${YELLOW}Kiểm tra kết nối từ PRIMARY...${NC}"
    local primary_status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    local primary_host=$(echo "$primary_status" | grep -A 5 "PRIMARY" | grep "name" | awk -F'"' '{print $4}')
    
    if [ -n "$primary_host" ]; then
        echo -e "${YELLOW}Kiểm tra kết nối từ PRIMARY ($primary_host) tới node $NODE_IP:$NODE_PORT...${NC}"
        local check_result=$(mongosh --host $primary_host -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        try {
            result = db.adminCommand({
                ping: 1,
                host: '$NODE_IP:$NODE_PORT'
            });
            print('PING_RESULT: ' + JSON.stringify(result));
        } catch (e) {
            print('ERROR: ' + e.message);
        }
        " --quiet)
        
        if echo "$check_result" | grep -q "ERROR"; then
            echo -e "${RED}❌ PRIMARY không thể kết nối tới node $NODE_IP:$NODE_PORT${NC}"
            echo "Lỗi: $check_result"
            return 1
        else
            echo -e "${GREEN}✅ PRIMARY có thể kết nối tới node $NODE_IP:$NODE_PORT${NC}"
        fi
    fi
    
    return 0
}

# Sửa lỗi node không reachable trong replica set
fix_unreachable_node() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Đang sửa lỗi node không reachable $NODE_IP:$NODE_PORT...${NC}"
    
    # Kiểm tra node có reachable không
    if ! check_and_fix_unreachable $NODE_IP $NODE_PORT $ADMIN_USER $ADMIN_PASS $PRIMARY_IP; then
        echo -e "${RED}❌ Không thể sửa lỗi node không reachable $NODE_IP:$NODE_PORT${NC}"
        return 1
    fi
    
    # Kiểm tra trạng thái replica set
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra node có trong replica set không
    if ! echo "$status" | grep -q "$NODE_IP:$NODE_PORT"; then
        echo -e "${YELLOW}⚠️ Node $NODE_IP:$NODE_PORT không có trong replica set${NC}"
        echo -e "${YELLOW}Đang thêm node vào replica set...${NC}"
        
        local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        rs.add('$NODE_IP:$NODE_PORT')" --quiet)
        
        if echo "$add_result" | grep -q "ok"; then
            echo -e "${GREEN}✅ Đã thêm node $NODE_IP:$NODE_PORT vào replica set${NC}"
        else
            echo -e "${RED}❌ Không thể thêm node $NODE_IP:$NODE_PORT vào replica set${NC}"
            echo "Lỗi: $add_result"
            return 1
        fi
    fi
    
    # Đợi node được thêm vào
    echo -e "${YELLOW}Đợi node được thêm vào (10 giây)...${NC}"
    sleep 10
    
    # Kiểm tra trạng thái node
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT.*SECONDARY"; then
        echo -e "${GREEN}✅ Node $NODE_IP:$NODE_PORT đã hoạt động bình thường${NC}"
        return 0
    else
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT vẫn không hoạt động bình thường${NC}"
        echo "Trạng thái: $status"
        return 1
    fi
}

# Khôi phục node không reachable bằng cách xóa và thêm lại
force_recover_node() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Đang khôi phục node $NODE_IP:$NODE_PORT...${NC}"
    
    # Kiểm tra port có mở không
    echo -e "${YELLOW}Kiểm tra port $NODE_PORT có đang chạy không...${NC}"
    if ! nc -z -w 5 $NODE_IP $NODE_PORT &>/dev/null; then
        echo -e "${RED}❌ Port $NODE_PORT không mở trên node $NODE_IP${NC}"
        echo -e "${YELLOW}Hãy kiểm tra:${NC}"
        echo "1. MongoDB có đang chạy không: systemctl status mongod_${NODE_PORT}"
        echo "2. Cấu hình bindIp trong /etc/mongod_${NODE_PORT}.conf có đúng không"
        echo "3. Tường lửa có cho phép kết nối đến port $NODE_PORT không"
        return 1
    else
        echo -e "${GREEN}✅ Port $NODE_PORT đang mở trên node $NODE_IP${NC}"
    fi
    
    # Kiểm tra trạng thái replica set
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra node có trong replica set không
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT"; then
        echo -e "${YELLOW}⚠️ Node $NODE_IP:$NODE_PORT đã có trong replica set, đang xóa...${NC}"
        
        # Xóa node khỏi replica set
        local remove_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        rs.remove('$NODE_IP:$NODE_PORT')" --quiet)
        
        if echo "$remove_result" | grep -q "ok"; then
            echo -e "${GREEN}✅ Đã xóa node $NODE_IP:$NODE_PORT khỏi replica set${NC}"
        else
            echo -e "${RED}❌ Không thể xóa node $NODE_IP:$NODE_PORT khỏi replica set${NC}"
            echo "Lỗi: $remove_result"
            return 1
        fi
        
        # Đợi node được xóa
        echo -e "${YELLOW}Đợi node được xóa (10 giây)...${NC}"
        sleep 10
    fi
    
    # Thêm lại node vào replica set
    echo -e "${YELLOW}Đang thêm lại node vào replica set...${NC}"
    local add_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    rs.add('$NODE_IP:$NODE_PORT')" --quiet)
    
    if echo "$add_result" | grep -q "ok"; then
        echo -e "${GREEN}✅ Đã thêm node $NODE_IP:$NODE_PORT vào replica set${NC}"
    else
        echo -e "${RED}❌ Không thể thêm node $NODE_IP:$NODE_PORT vào replica set${NC}"
        echo "Lỗi: $add_result"
        return 1
    fi
    
    # Đợi node được thêm vào
    echo -e "${YELLOW}Đợi node được thêm vào (5 giây)...${NC}"
    sleep 5
    
    # Kiểm tra trạng thái node
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT.*SECONDARY"; then
        echo -e "${GREEN}✅ Node $NODE_IP:$NODE_PORT đã hoạt động bình thường${NC}"
        return 0
    else
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT vẫn không hoạt động bình thường${NC}"
        echo "Trạng thái: $status"
        return 1
    fi
}

# Khôi phục node không reachable bằng cách force reconfigure
force_reconfigure_node() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Đang khôi phục node $NODE_IP:$NODE_PORT bằng cách force reconfigure...${NC}"
    
    # Kiểm tra trạng thái replica set
    echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Lấy danh sách các node trong replica set
    echo -e "${YELLOW}Lấy danh sách các node trong replica set...${NC}"
    local members=$(echo "$status" | grep -A 100 "members" | grep "name" | awk -F'"' '{print $4}')
    
    # Tạo cấu hình mới cho replica set
    echo -e "${YELLOW}Tạo cấu hình mới cho replica set...${NC}"
    local config="{ _id: 'rs0', members: ["
    
    # Thêm các node vào cấu hình
    local first=true
    for member in $members; do
        if [ "$first" = true ]; then
            first=false
        else
            config="$config,"
        fi
        
        # Kiểm tra node có phải là node cần khôi phục không
        if [ "$member" = "$NODE_IP:$NODE_PORT" ]; then
            # Đặt priority cao hơn để node này trở thành PRIMARY
            config="$config{ _id: $(echo "$status" | grep -A 10 "$member" | grep "_id" | awk '{print $2}' | tr -d ','), host: '$member', priority: 10 }"
        else
            # Các node khác giữ nguyên priority
            config="$config{ _id: $(echo "$status" | grep -A 10 "$member" | grep "_id" | awk '{print $2}' | tr -d ','), host: '$member' }"
        fi
    done
    
    # Thêm node cần khôi phục nếu chưa có trong danh sách
    if ! echo "$members" | grep -q "$NODE_IP:$NODE_PORT"; then
        if [ "$first" = true ]; then
            first=false
        else
            config="$config,"
        fi
        
        # Tìm ID cao nhất và tăng thêm 1
        local max_id=$(echo "$status" | grep "_id" | awk '{print $2}' | sort -n | tail -1)
        local new_id=$((max_id + 1))
        
        config="$config{ _id: $new_id, host: '$NODE_IP:$NODE_PORT', priority: 10 }"
    fi
    
    config="$config ] }"
    
    # In ra cấu hình mới
    echo -e "${YELLOW}Cấu hình mới:${NC}"
    echo "$config"
    
    # Force reconfigure replica set
    echo -e "${YELLOW}Force reconfigure replica set...${NC}"
    local reconfigure_result=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    rs.reconfig($config, {force: true})" --quiet)
    
    if echo "$reconfigure_result" | grep -q "ok"; then
        echo -e "${GREEN}✅ Đã force reconfigure replica set thành công${NC}"
    else
        echo -e "${RED}❌ Không thể force reconfigure replica set${NC}"
        echo "Lỗi: $reconfigure_result"
        return 1
    fi
    
    # Đợi replica set ổn định
    echo -e "${YELLOW}Đợi replica set ổn định (5 giây)...${NC}"
    sleep 5
    
    # Kiểm tra trạng thái node
    local status=$(mongosh --host $PRIMARY_IP --port 27017 -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT.*SECONDARY"; then
        echo -e "${GREEN}✅ Node $NODE_IP:$NODE_PORT đã hoạt động bình thường${NC}"
        return 0
    else
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT vẫn không hoạt động bình thường${NC}"
        echo "Trạng thái: $status"
        return 1
    fi
}

# Hàm chính để sửa lỗi node không reachable
fix_unreachable_node_menu() {
    echo -e "${YELLOW}=== Sửa lỗi node không reachable ===${NC}"
    
    # Lấy IP của server hiện tại
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    
    read -p "Nhập IP của node (Enter để dùng IP server $SERVER_IP): " NODE_IP
    NODE_IP=${NODE_IP:-$SERVER_IP}  # Nếu không nhập thì dùng SERVER_IP
    
    read -p "Nhập Port của node (Enter để dùng 27018): " NODE_PORT
    NODE_PORT=${NODE_PORT:-27018}  # Nếu không nhập thì dùng 27018
    
    read -p "Nhập IP của PRIMARY node (Enter để dùng 171.244.21.188): " PRIMARY_IP
    PRIMARY_IP=${PRIMARY_IP:-171.244.21.188}  # Nếu không nhập thì dùng 171.244.21.188
    
    read -p "Nhập username admin (Enter để dùng manhg): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-manhg}  # Nếu không nhập thì dùng manhg
    
    read -s -p "Nhập password admin (Enter để dùng manhnk): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-manhnk}  # Nếu không nhập thì dùng manhnk
    echo
    
    echo -e "${YELLOW}Thông tin node:${NC}"
    echo "IP: $NODE_IP"
    echo "Port: $NODE_PORT"
    echo "PRIMARY IP: $PRIMARY_IP"
    echo "Username: $ADMIN_USER"
    echo
    
    echo -e "${YELLOW}Chọn hành động:${NC}"
    echo "1. Kiểm tra và sửa các vấn đề"
    echo "2. Sửa lỗi và thêm lại vào replica set"
    echo "3. Khôi phục node bằng cách xóa và thêm lại"
    echo "4. Khôi phục node bằng cách force reconfigure"
    read -p "Lựa chọn (1-4): " action
    
    case $action in
        1)
            check_and_fix_unreachable "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
            ;;
        2)
            fix_unreachable_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
            ;;
        3)
            force_recover_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
            ;;
        4)
            force_reconfigure_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
            ;;
        *)
            echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
            ;;
    esac
}

# Chạy hàm chính nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_unreachable_node_menu
fi