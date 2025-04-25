#!/bin/bash

# Import các script khác
source scripts/install_mongodb.sh
source scripts/setup_replica.sh
source scripts/setup_replica_linux.sh
source scripts/setup_replica_macos.sh
source scripts/check_status.sh
source scripts/uninstall_mongodb.sh
ARBITER_SCRIPT="multil_server/mongodb_arbiter.sh"

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Export các biến màu sắc để các script khác có thể sử dụng
export RED
export GREEN
export YELLOW
export NC

print_header() {
    echo -e "${YELLOW}=== MongoDB Replica Set Setup ===${NC}"
    echo "1. Cài đặt MongoDB"
    echo "2. Kiểm tra trạng thái"
    echo "3. Cấu hình Replica Set"
    echo "4. Thêm Arbiter"
    echo "5. Xóa MongoDB"
    echo "6. Sửa lỗi node không reachable"
    echo "0. Thoát"
}

fix_node_menu() {
    echo -e "${YELLOW}=== Sửa lỗi node không reachable ===${NC}"
    
    # Lấy IP của server hiện tại
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    
    read -p "Nhập IP của node (Enter để dùng IP server $SERVER_IP): " NODE_IP
    NODE_IP=${NODE_IP:-$SERVER_IP}  # Nếu không nhập thì dùng SERVER_IP
    
    read -p "Nhập Port của node (Enter để dùng 27018): " NODE_PORT
    NODE_PORT=${NODE_PORT:-27018}  # Nếu không nhập thì dùng 27018
    
    read -p "Nhập username admin (Enter để dùng manhg): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-manhg}  # Nếu không nhập thì dùng manhg
    
    read -s -p "Nhập password admin (Enter để dùng manhnk): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-manhnk}  # Nếu không nhập thì dùng manhnk
    echo
    
    echo -e "${YELLOW}Thông tin node:${NC}"
    echo "IP: $NODE_IP"
    echo "Port: $NODE_PORT"
    echo "Username: $ADMIN_USER"
    echo
    
    echo -e "${YELLOW}Chọn hành động:${NC}"
    echo "1. Kiểm tra và sửa các vấn đề"
    echo "2. Sửa lỗi và thêm lại vào replica set"
    read -p "Lựa chọn (1-2): " action
    
    case $action in
        1)
            check_and_fix_unreachable "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS"
            ;;
        2)
            fix_unreachable_node "$NODE_IP" "$NODE_PORT" "$ADMIN_USER" "$ADMIN_PASS"
            ;;
        *)
            echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
            ;;
    esac
}

main() {
    while true; do
        print_header
        read -p "Chọn chức năng (0-6): " choice
        
        case $choice in
            1)
                install_mongodb
                ;;
            2)
                check_status
                ;;
            3)
                setup_replica
                ;;
            4)   
                chmod +x "$ARBITER_SCRIPT"
                "./$ARBITER_SCRIPT"
                ;;
            5)
                uninstall_mongodb
                ;;
            6)
                fix_node_menu
                ;;
            0)
                echo -e "${GREEN}Tạm biệt!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
                ;;
        esac
        
        echo
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Chạy main nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi 