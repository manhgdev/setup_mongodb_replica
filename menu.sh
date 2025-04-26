#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Đường dẫn thư mục hiện tại
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hàm hiển thị menu
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       ${YELLOW}MONGODB REPLICA SET MANAGER${NC}          ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Cài đặt Primary Node                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Cài đặt Secondary Node                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Thêm Secondary Node                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Thêm Arbiter Node                       ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}5.${NC} Sửa lỗi node không reachable            ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${GREEN}6.${NC} Kiểm tra trạng thái                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} ${RED}0.${NC} Thoát                                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo
}

# Hàm chạy script
run_script() {
    local script=$1
    echo -e "${GREEN}Đang chạy $script...${NC}"
    bash "$CURRENT_DIR/$script"
    echo -e "${YELLOW}Nhấn Enter để tiếp tục...${NC}"
    read
}

# Vòng lặp menu chính
while true; do
    show_menu
    read -p "$(echo -e ${GREEN}">>${NC} Chọn chức năng [0-6]: ")" choice
    
    case $choice in
        1)
            run_script "./new/setup_primary.sh"
            ;;
        2)
            run_script "./new/setup_secondary.sh"
            ;;
        3)
            run_script "./new/add_secondary.sh"
            ;;
        4)
            run_script "./new/add_arbiter.sh"
            ;;
        5)
            run_script "./new/fix_reachable.sh"
            ;;
        6)
            echo -e "${YELLOW}Coming soon...${NC}"
            read
            ;;
        0)
            echo -e "${GREEN}✓ Tạm biệt!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
            sleep 2
            ;;
    esac
done