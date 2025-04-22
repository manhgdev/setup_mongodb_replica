#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Đường dẫn script
SINGLE_SERVER_SCRIPT="one_server/setup_mongodb_replica.sh"
MULTI_SERVER_SCRIPT="multil_server/setup_mongodb_distributed_replica.sh"
DEPLOY_SCRIPT="ssh/deploy_mongodb_replica.sh"
PRIMARY_SCRIPT="primary_setup/mongodb_elect_primary.sh"
FIX_SCRIPT="run_fix_all_configs.sh"

clear
echo -e "${BLUE}
============================================================
  THIẾT LẬP MONGODB REPLICA SET - MANHG DEV
============================================================${NC}"

# Kiểm tra các script tồn tại
if [ ! -f "$SINGLE_SERVER_SCRIPT" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy script $SINGLE_SERVER_SCRIPT${NC}"
fi

if [ ! -f "$MULTI_SERVER_SCRIPT" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy script $MULTI_SERVER_SCRIPT${NC}"
fi

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy script $DEPLOY_SCRIPT${NC}"
fi

if [ ! -f "$PRIMARY_SCRIPT" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy script $PRIMARY_SCRIPT${NC}"
fi

if [ ! -f "$FIX_SCRIPT" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy script $FIX_SCRIPT${NC}"
fi

# Kiểm tra thư mục
if [ ! -d "one_server" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy thư mục one_server${NC}"
fi

if [ ! -d "multil_server" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy thư mục multil_server${NC}"
fi

if [ ! -d "ssh" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy thư mục ssh${NC}"
fi

if [ ! -d "primary_setup" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy thư mục primary_setup${NC}"
fi

if [ ! -d "fixup" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy thư mục fixup${NC}"
fi

echo -e "${BLUE}===== MENU =====${NC}"
echo "1. Thiết lập Replica Set trên một máy chủ (3 node cùng một server)"
echo "2. Thiết lập Replica Set phân tán (nhiều máy chủ khác nhau)"
echo "3. Triển khai Replica Set từ xa (qua SSH)"
echo "4. Bầu chọn PRIMARY node mới"
echo "5. Sửa lỗi và khôi phục"
echo "6. Thoát"
read -p "Lựa chọn của bạn (1-6): " choice

case $choice in
    1)
        echo -e "${YELLOW}Đang chạy script thiết lập trên một máy chủ...${NC}"
        chmod +x "$SINGLE_SERVER_SCRIPT"
        "./$SINGLE_SERVER_SCRIPT"
        ;;
    2)
        echo -e "${YELLOW}Đang chạy script thiết lập phân tán...${NC}"
        chmod +x "$MULTI_SERVER_SCRIPT"
        "./$MULTI_SERVER_SCRIPT"
        ;;
    3)
        if [ -f "$DEPLOY_SCRIPT" ]; then
            echo -e "${YELLOW}Đang chạy script triển khai từ xa...${NC}"
            chmod +x "$DEPLOY_SCRIPT"
            "./$DEPLOY_SCRIPT"
        else
            echo -e "${RED}Không tìm thấy script triển khai từ xa. Vui lòng kiểm tra lại đường dẫn.${NC}"
            exit 1
        fi
        ;;
    4)
        if [ -f "$PRIMARY_SCRIPT" ]; then
            echo -e "${YELLOW}Đang chạy script bầu chọn PRIMARY node mới...${NC}"
            chmod +x "$PRIMARY_SCRIPT"
            "./$PRIMARY_SCRIPT"
        else
            echo -e "${RED}Không tìm thấy script bầu chọn PRIMARY. Vui lòng kiểm tra lại đường dẫn.${NC}"
            exit 1
        fi
        ;;
    5)
        if [ -f "$FIX_SCRIPT" ]; then
            echo -e "${YELLOW}Đang chạy script sửa lỗi và khôi phục...${NC}"
            chmod +x "$FIX_SCRIPT"
            "./$FIX_SCRIPT"
        else
            echo -e "${RED}Không tìm thấy script sửa lỗi. Vui lòng kiểm tra lại đường dẫn.${NC}"
            exit 1
        fi
        ;;
    6)
        echo -e "${YELLOW}Thoát.${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Lựa chọn không hợp lệ${NC}"
        exit 1
        ;;
esac
