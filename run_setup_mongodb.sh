#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Đường dẫn
SINGLE_SERVER_SCRIPT="one_server/setup_mongodb_replica.sh"
MULTI_SERVER_SCRIPT="multil_server/setup_mongodb_distributed_replica.sh"
DEPLOY_SCRIPT="ssh/deploy_mongodb_replica.sh"
PRIMARY_SCRIPT="primary_setup/mongodb_elect_primary.sh"
PRIMARY_DIR="primary_setup"
FIXUP_DIR="fixup"

clear
echo -e "${BLUE}
============================================================
      MONGODB REPLICA SET SETUP - MANHG DEV
============================================================${NC}"

# Kiểm tra các script có tồn tại không
if [ ! -f "$SINGLE_SERVER_SCRIPT" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy script $SINGLE_SERVER_SCRIPT${NC}"
    exit 1
fi

if [ ! -f "$MULTI_SERVER_SCRIPT" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy script $MULTI_SERVER_SCRIPT${NC}"
    exit 1
fi

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo -e "${YELLOW}Cảnh báo: Không tìm thấy script $DEPLOY_SCRIPT${NC}"
fi

# Kiểm tra thư mục primary_setup
if [ ! -d "$PRIMARY_DIR" ]; then
    echo -e "${YELLOW}Tạo thư mục $PRIMARY_DIR cho cấu hình PRIMARY...${NC}"
    mkdir -p $PRIMARY_DIR
fi

# Hiển thị menu
echo -e "${YELLOW}Chọn loại thiết lập MongoDB Replica Set:${NC}"
echo ""
echo -e "${GREEN}1. Thiết lập trên một server (Single Server)${NC}"
echo "   - Tạo replica set với nhiều node trên cùng một máy chủ"
echo "   - Phù hợp cho môi trường phát triển và kiểm thử"
echo "   - Sử dụng nhiều port khác nhau"
echo ""
echo -e "${GREEN}2. Thiết lập phân tán trên nhiều server (Multiple Servers)${NC}"
echo "   - Tạo replica set phân tán trên nhiều máy chủ vật lý"
echo "   - Phù hợp cho môi trường sản xuất với khả năng chịu lỗi cao"
echo "   - Tự động failover khi một server gặp sự cố"
echo ""
echo -e "${GREEN}3. Triển khai từ xa (Remote Deployment)${NC}"
echo "   - Triển khai MongoDB Replica Set từ máy local lên nhiều VPS từ xa"
echo "   - Tự động hóa quá trình cài đặt trên nhiều server"
echo ""
echo -e "${GREEN}4. Bầu/Chuyển PRIMARY (Election)${NC}"
echo "   - Chuyển vai trò PRIMARY từ một server sang server khác"
echo "   - Gộp các replica set khác nhau thành một"
echo "   - Force server 157.66.46.252 làm PRIMARY"
echo ""
echo -e "${GREEN}5. Sửa lỗi MongoDB (Fix Issues)${NC}"
echo "   - Khắc phục các lỗi khi cài đặt MongoDB"
echo "   - Sửa lỗi quyền truy cập, port, keyfile, primary election..."
echo ""
echo -e "${GREEN}6. Thoát${NC}"
echo ""

# Lấy lựa chọn từ người dùng
read -p "Nhập lựa chọn của bạn (1-6): " choice

# Xử lý lựa chọn
case $choice in
    1)
        echo -e "${BLUE}Đang khởi chạy thiết lập MongoDB Replica Set trên một server...${NC}"
        chmod +x $SINGLE_SERVER_SCRIPT
        ./$SINGLE_SERVER_SCRIPT
        ;;
    2)
        echo -e "${BLUE}Đang khởi chạy thiết lập MongoDB Replica Set phân tán...${NC}"
        chmod +x $MULTI_SERVER_SCRIPT
        ./$MULTI_SERVER_SCRIPT
        ;;
    3)
        if [ -f "$DEPLOY_SCRIPT" ]; then
            echo -e "${BLUE}Đang khởi chạy triển khai từ xa...${NC}"
            chmod +x $DEPLOY_SCRIPT
            ./$DEPLOY_SCRIPT
        else
            echo -e "${RED}Lỗi: Script triển khai từ xa không tồn tại.${NC}"
            exit 1
        fi
        ;;
    4)
        echo -e "${BLUE}Đang khởi chạy công cụ bầu/chuyển PRIMARY...${NC}"
        chmod +x $PRIMARY_SCRIPT
        ./$PRIMARY_SCRIPT
        ;;
    5)
        echo -e "${BLUE}Đang khởi chạy công cụ sửa lỗi...${NC}"
        chmod +x run_fix_all_configs.sh
        ./run_fix_all_configs.sh
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
