#!/bin/bash

# Import các script khác
source config/mongodb_settings.sh
source config/mongodb_functions.sh
source scripts/setup_replica.sh        # File gốc tự phát hiện OS
source scripts/check_status.sh
source scripts/uninstall_mongodb.sh
source scripts/fix_unreachable_node.sh
ARBITER_SCRIPT="multil_server/mongodb_arbiter.sh"

# Màu sắc cho output đã được định nghĩa trong mongodb_settings.sh

# Hàm cài đặt MongoDB
install_mongodb() {
    echo -e "${YELLOW}=== Cài đặt MongoDB ===${NC}"
    check_mongodb
    echo -e "${GREEN}MongoDB đã được cài đặt thành công!${NC}"
}

# Hàm hiển thị menu
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       ${YELLOW}MONGODB REPLICA SET MANAGER${NC}          ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Cài đặt MongoDB                         ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Kiểm tra trạng thái                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Cấu hình Replica Set                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Thêm Arbiter                            ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}5.${NC} Sửa lỗi node không reachable            ${BLUE}║${NC}" 
    echo -e "${BLUE}║${NC} ${GREEN}6.${NC} Xóa MongoDB                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${RED}0.${NC} Thoát                                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Server IP: $(get_server_ip true)${NC}"
    echo -e "${YELLOW}MongoDB Version: ${MONGO_VERSION} | Port: ${MONGODB_PORT} | Replica: ${REPLICA_SET_NAME}${NC}"
    echo
    read -p "$(echo -e ${GREEN}">>${NC} Chọn chức năng [0-6]: ")" choice
    
    case $choice in
        1)
            install_mongodb
            ;;
        2)
            check_status
            ;;
        3)
            # Sử dụng setup_replica từ file setup_replica.sh (tự phát hiện OS)
            setup_replica
            ;;
        4)   
            if [ -f "$ARBITER_SCRIPT" ]; then
                chmod +x "$ARBITER_SCRIPT"
                "./$ARBITER_SCRIPT"
            else
                echo -e "${RED}❌ File script không tồn tại: $ARBITER_SCRIPT${NC}"
            fi
            ;;
        5)
            fix_unreachable_node_menu
            ;;
        6)
            uninstall_mongodb
            ;;
        0)
            echo -e "${GREEN}✓ Tạm biệt! Cảm ơn đã sử dụng MongoDB Replica Set Manager.${NC}"
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
    echo -e "${BLUE}[${YELLOW}*${BLUE}] ${NC}Nhấn Enter để tiếp tục..."
    read
done 