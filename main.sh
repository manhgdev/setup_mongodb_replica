#!/bin/bash

# Import các script khác
source scripts/install_mongodb.sh
source scripts/setup_replica.sh

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


check_status() {
    echo -e "${YELLOW}=== Kiểm tra trạng thái ===${NC}"
    
    # Kiểm tra MongoDB đã cài đặt chưa
    if ! command -v mongod &> /dev/null; then
        echo -e "${RED}❌ MongoDB chưa được cài đặt${NC}"
        read -p "Bạn có muốn cài đặt MongoDB không? (y/n): " install_choice
        if [[ "$install_choice" == "y" ]]; then
            install_mongodb
            return 0
        fi
        return 1
    fi
    
    # Kiểm tra MongoDB đang chạy
    if ! mongosh --eval 'db.runCommand({ ping: 1 })' &> /dev/null; then
        echo -e "${RED}❌ MongoDB chưa chạy${NC}"
        read -p "Bạn có muốn khởi động MongoDB không? (y/n): " start_choice
        if [[ "$start_choice" == "y" ]]; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                brew services start mongodb-community
            else
                sudo systemctl start mongod
            fi
            echo -e "${GREEN}✅ Đã khởi động MongoDB${NC}"
            sleep 2
            return 0
        fi
        return 1
    fi
    
    # Hiển thị thông tin
    echo -e "${GREEN}MongoDB Status:${NC}"
    mongod --version
    
    echo -e "\n${GREEN}Service Status:${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        brew services list | grep mongodb
    else
        systemctl status mongod
    fi
    
    echo -e "\n${GREEN}Replica Set Status:${NC}"
    mongosh --eval 'rs.status()'
    
    # Kiểm tra lỗi và đề xuất fix
    local error=$(mongosh --eval 'rs.status()' 2>&1 | grep "not running with --replSet")
    if [ ! -z "$error" ]; then
        echo -e "\n${RED}❌ MongoDB chưa được cấu hình Replica Set${NC}"
        read -p "Bạn có muốn cấu hình Replica Set không? (y/n): " setup_choice
        if [[ "$setup_choice" == "y" ]]; then
            setup_replica
            return 0
        fi
    fi
}

uninstall_mongodb() {
    echo -e "${YELLOW}=== Xóa MongoDB ===${NC}"
    
    # Kiểm tra quyền sudo
    if [[ "$(uname -s)" == "Linux" ]] && [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Cần quyền sudo để xóa MongoDB trên Linux${NC}"
        return 1
    fi
    
    # Dừng MongoDB trước khi xóa
    if [[ "$(uname -s)" == "Darwin" ]]; then
        brew services stop mongodb-community || true
    else
        systemctl stop mongod || true
    fi
    
    # Thực hiện xóa
    bash scripts/uninstall_mongodb.sh
    
    echo -e "${GREEN}✅ Đã xóa MongoDB thành công${NC}"
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