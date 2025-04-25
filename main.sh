#!/bin/bash

# Import các script khác
source scripts/install_mongodb.sh
source scripts/setup_replica.sh
source scripts/check_status.sh
source scripts/uninstall_mongodb.sh

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() {
    echo -e "${YELLOW}=== MongoDB Replica Set Setup ===${NC}"
    echo "1. Cài đặt MongoDB"
    echo "2. Kiểm tra trạng thái"
    echo "3. Cấu hình Replica Set"
    echo "4. Xóa MongoDB"
    echo "0. Thoát"
}

main() {
    while true; do
        print_header
        read -p "Chọn chức năng (0-5): " choice
        
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
        
        echo
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Chạy main nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi 