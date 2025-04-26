#!/bin/bash

# Load config từ file chung
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config"
CONFIG_FILE="${CONFIG_DIR}/mongodb_settings.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Không tìm thấy file cấu hình: $CONFIG_FILE"
    exit 1
fi

# Đọc file cấu hình
source "$CONFIG_FILE"

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
    local primary_status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
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
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra node có trong replica set không
    if ! echo "$status" | grep -q "$NODE_IP:$NODE_PORT"; then
        echo -e "${YELLOW}⚠️ Node $NODE_IP:$NODE_PORT không có trong replica set${NC}"
        echo -e "${YELLOW}Đang thêm node vào replica set...${NC}"
        
        local add_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
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
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
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
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra node có trong replica set không
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT"; then
        echo -e "${YELLOW}⚠️ Node $NODE_IP:$NODE_PORT đã có trong replica set, đang xóa...${NC}"
        
        # Xóa node khỏi replica set
        local remove_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
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
    local add_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
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
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
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
    
    # Force reconfigure replica set
    echo -e "${YELLOW}Force reconfigure replica set...${NC}"
    local reconfigure_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    try {
        let config = rs.conf();
        let members = config.members;
        
        // Tìm node cần khôi phục
        let targetNode = members.find(m => m.host === '$NODE_IP:$NODE_PORT');
        
        if (targetNode) {
            // Nếu node đã tồn tại, cập nhật priority
            targetNode.priority = 10;
        } else {
            // Nếu node chưa tồn tại, thêm mới
            let maxId = Math.max(...members.map(m => m._id));
            members.push({
                _id: maxId + 1,
                host: '$NODE_IP:$NODE_PORT',
                priority: 10
            });
        }
        
        // Cập nhật cấu hình
        config.members = members;
        rs.reconfig(config, {force: true});
    } catch (e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if echo "$reconfigure_result" | grep -q "ok"; then
        echo -e "${GREEN}✅ Đã force reconfigure replica set thành công${NC}"
    else
        echo -e "${RED}❌ Không thể force reconfigure replica set${NC}"
        echo "Lỗi: $reconfigure_result"
        return 1
    fi
    
    # Đợi replica set ổn định
    echo -e "${YELLOW}Đợi replica set ổn định (30 giây)...${NC}"
    sleep 30
    
    # Kiểm tra trạng thái node
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    if echo "$status" | grep -q "$NODE_IP:$NODE_PORT.*SECONDARY"; then
        echo -e "${GREEN}✅ Node $NODE_IP:$NODE_PORT đã hoạt động bình thường${NC}"
        return 0
    else
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT vẫn không hoạt động bình thường${NC}"
        echo "Trạng thái: $status"
        return 1
    fi
}

# Xóa node không hoạt động khỏi replica set
remove_node() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Đang xóa node $NODE_IP:$NODE_PORT khỏi replica set...${NC}"
    
    # Kiểm tra trạng thái replica set
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet)
    
    # Kiểm tra node có trong replica set không
    if ! echo "$status" | grep -q "$NODE_IP:$NODE_PORT"; then
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT không có trong replica set${NC}"
        return 1
    fi
    
    # Xóa node khỏi replica set
    local remove_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    try {
        rs.remove('$NODE_IP:$NODE_PORT');
        print('OK');
    } catch (e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if echo "$remove_result" | grep -q "OK"; then
        echo -e "${GREEN}✅ Đã xóa node $NODE_IP:$NODE_PORT khỏi replica set${NC}"
        return 0
    else
        echo -e "${RED}❌ Không thể xóa node $NODE_IP:$NODE_PORT khỏi replica set${NC}"
        echo "Lỗi: $remove_result"
        return 1
    fi
}

# Xử lý triệt để node không hoạt động
force_fix_node() {
    local NODE_IP=$1
    local NODE_PORT=$2
    local ADMIN_USER=$3
    local ADMIN_PASS=$4
    local PRIMARY_IP=$5
    
    echo -e "${YELLOW}Đang xử lý triệt để node $NODE_IP:$NODE_PORT...${NC}"
    
    # 1. Xóa node khỏi replica set trước
    echo -e "${YELLOW}1. Xóa node khỏi replica set...${NC}"
    mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    try {
        rs.remove('$NODE_IP:$NODE_PORT');
        print('OK');
    } catch (e) {
        // Bỏ qua lỗi nếu node không tồn tại
    }" --quiet
    
    # 2. Dừng MongoDB trên node
    echo -e "${YELLOW}2. Dừng MongoDB trên node...${NC}"
    ssh $NODE_IP "sudo systemctl stop mongod_$NODE_PORT" || true
    
    # 3. Xóa data và log
    echo -e "${YELLOW}3. Xóa data và log...${NC}"
    ssh $NODE_IP "sudo rm -rf /var/lib/mongodb_$NODE_PORT/* /var/log/mongodb/mongod_$NODE_PORT.log" || true
    
    # 4. Khởi động lại MongoDB
    echo -e "${YELLOW}4. Khởi động lại MongoDB...${NC}"
    ssh $NODE_IP "sudo systemctl start mongod_$NODE_PORT"
    
    # 5. Đợi MongoDB khởi động
    echo -e "${YELLOW}5. Đợi MongoDB khởi động (30 giây)...${NC}"
    sleep 30
    
    # 6. Kiểm tra MongoDB có chạy không
    echo -e "${YELLOW}6. Kiểm tra MongoDB có chạy không...${NC}"
    if ! nc -z -w 5 $NODE_IP $NODE_PORT; then
        echo -e "${RED}❌ MongoDB không chạy được${NC}"
        return 1
    fi
    
    # 7. Thêm lại node vào replica set với priority thấp
    echo -e "${YELLOW}7. Thêm lại node vào replica set...${NC}"
    local add_result=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    try {
        rs.add({
            host: '$NODE_IP:$NODE_PORT',
            priority: 0.5
        });
        print('OK');
    } catch (e) {
        print('ERROR: ' + e.message);
    }" --quiet)
    
    if ! echo "$add_result" | grep -q "OK"; then
        echo -e "${RED}❌ Không thể thêm lại node${NC}"
        echo "Lỗi: $add_result"
        return 1
    fi
    
    # 8. Đợi node đồng bộ
    echo -e "${YELLOW}8. Đợi node đồng bộ (60 giây)...${NC}"
    sleep 60
    
    # 9. Kiểm tra trạng thái cuối cùng
    echo -e "${YELLOW}9. Kiểm tra trạng thái cuối cùng...${NC}"
    local status=$(mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
    let status = rs.status();
    let member = status.members.find(m => m.name === '$NODE_IP:$NODE_PORT');
    if (member) {
        print('STATE: ' + member.stateStr);
        print('HEALTH: ' + member.health);
    } else {
        print('NOT_FOUND');
    }" --quiet)
    
    if echo "$status" | grep -q "SECONDARY" && echo "$status" | grep -q "HEALTH: 1"; then
        echo -e "${GREEN}✅ Node đã hoạt động bình thường${NC}"
        
        # 10. Tăng priority lên bình thường
        echo -e "${YELLOW}10. Tăng priority lên bình thường...${NC}"
        mongosh --host $PRIMARY_IP --port ${MONGO_PORT} -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "
        try {
            let config = rs.conf();
            let member = config.members.find(m => m.host === '$NODE_IP:$NODE_PORT');
            if (member) {
                member.priority = 1;
                rs.reconfig(config);
            }
        } catch (e) {
            print('ERROR: ' + e.message);
        }" --quiet
        
        return 0
    else
        echo -e "${RED}❌ Node vẫn không hoạt động bình thường${NC}"
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
    
    read -p "Nhập username admin (Enter để dùng $MONGODB_USER): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-$MONGODB_USER}  # Nếu không nhập thì dùng MONGODB_USER
    
    read -s -p "Nhập password admin (Enter để dùng $MONGODB_PASSWORD): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-$MONGODB_PASSWORD}  # Nếu không nhập thì dùng MONGODB_PASSWORD
    echo
    
    echo -e "${YELLOW}Thông tin node:${NC}"
    echo "IP: $NODE_IP"
    echo "Port: $NODE_PORT"
    echo "PRIMARY IP: $PRIMARY_IP"
    echo "Username: $ADMIN_USER"
    echo "Config file: $CONFIG_FILE"
    echo
    
    echo -e "${YELLOW}Chọn hành động:${NC}"
    echo "1. Kiểm tra và sửa các vấn đề"
    echo "2. Sửa lỗi và thêm lại vào replica set"
    echo "3. Khôi phục node bằng cách xóa và thêm lại"
    echo "4. Khôi phục node bằng cách force reconfigure"
    echo "5. Xóa node không hoạt động khỏi replica set"
    echo "6. Xử lý triệt để (xóa data và cài lại)"
    read -p "Lựa chọn (1-6): " action
    
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
        5)
            remove_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
            ;;
        6)
            force_fix_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS" "$PRIMARY_IP"
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