#!/bin/bash

# Import các script khác
source scripts/install_mongodb.sh
source scripts/setup_replica.sh
source scripts/setup_replica_linux.sh
source scripts/setup_replica_macos.sh
source scripts/check_status.sh
source scripts/uninstall_mongodb.sh
source scripts/fix_unreachable_node.sh
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

# Hàm hiển thị menu
show_menu() {
    echo -e "${YELLOW}=== MongoDB Replica Set Setup ===${NC}"
    echo "1. Cài đặt MongoDB"
    echo "2. Kiểm tra trạng thái"
    echo "3. Cấu hình Replica Set"
    echo "4. Thêm Arbiter"
    echo "5. Sửa lỗi node không reachable"
    echo "6. Xóa MongoDB"
    echo "0. Thoát"
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
            fix_unreachable_node_menu
            ;;
        6)
            uninstall_mongodb
            ;;
        0)
            echo -e "${GREEN}Tạm biệt!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
            ;;
    esac
}

# Chạy menu
while true; do
    show_menu
    echo
    read -p "Nhấn Enter để tiếp tục..."
done 