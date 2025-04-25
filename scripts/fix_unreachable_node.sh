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
    
    # Kiểm tra MongoDB có đang chạy không
    echo -e "${YELLOW}Kiểm tra MongoDB có đang chạy không...${NC}"
    local mongo_status=$(ssh $NODE_IP "sudo systemctl status mongod_${NODE_PORT}" 2>&1)
    
    if ! echo "$mongo_status" | grep -q "Active: active (running)"; then
        echo -e "${YELLOW}⚠️ MongoDB không chạy, đang khởi động lại...${NC}"
        ssh $NODE_IP "sudo systemctl start mongod_${NODE_PORT}"
        sleep 5
    fi
    
    # Kiểm tra cấu hình bindIp
    echo -e "${YELLOW}Kiểm tra cấu hình bindIp...${NC}"
    ssh $NODE_IP "sudo sed -i 's/bindIp: .*/bindIp: 0.0.0.0/' /etc/mongod_${NODE_PORT}.conf"
    ssh $NODE_IP "sudo systemctl restart mongod_${NODE_PORT}"
    sleep 5
    
    # Kiểm tra tường lửa
    echo -e "${YELLOW}Kiểm tra tường lửa...${NC}"
    ssh $NODE_IP "sudo ufw allow $NODE_PORT/tcp" &>/dev/null
    
    # Kiểm tra trạng thái replica set
    local status=$(mongosh --host $NODE_IP --port $NODE_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    # Kiểm tra node có được khởi tạo chưa
    if echo "$status" | grep -q "NotYetInitialized"; then
        echo -e "${RED}❌ Node $NODE_IP:$NODE_PORT chưa được khởi tạo replica set${NC}"
        return 1
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
    
    # Kiểm tra MongoDB có đang chạy không
    echo -e "${YELLOW}Kiểm tra MongoDB có đang chạy không...${NC}"
    local mongo_status=$(ssh $NODE_IP "sudo systemctl status mongod_${NODE_PORT}" 2>&1)
    
    if ! echo "$mongo_status" | grep -q "Active: active (running)"; then
        echo -e "${YELLOW}⚠️ MongoDB không chạy, đang khởi động lại...${NC}"
        ssh $NODE_IP "sudo systemctl start mongod_${NODE_PORT}"
        sleep 5
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
    
    # Kiểm tra cấu hình bindIp
    echo -e "${YELLOW}Kiểm tra cấu hình bindIp...${NC}"
    ssh $NODE_IP "sudo sed -i 's/bindIp: .*/bindIp: 0.0.0.0/' /etc/mongod_${NODE_PORT}.conf"
    ssh $NODE_IP "sudo systemctl restart mongod_${NODE_PORT}"
    sleep 5
    
    # Kiểm tra tường lửa
    echo -e "${YELLOW}Kiểm tra tường lửa...${NC}"
    ssh $NODE_IP "sudo ufw allow $NODE_PORT/tcp" &>/dev/null
    
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
    echo -e "${YELLOW}Đợi node được thêm vào (30 giây)...${NC}"
    sleep 30
    
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
    
    # Sử dụng giá trị mặc định cho username và password
    ADMIN_USER="manhg"
    ADMIN_PASS="manhnk"
    
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
    read -p "Lựa chọn (1-3): " action
    
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
        *)
            echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
            ;;
    esac
}

# Chạy hàm chính nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_unreachable_node_menu
fi