#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Đường dẫn
FIXUP_DIR="fixup"

clear
echo -e "${BLUE}
============================================================
  KIỂM TRA VÀ SỬA LỖI MONGODB REPLICA SET - MANHG DEV
============================================================${NC}"

# Kiểm tra thư mục fixup tồn tại không
if [ ! -d "$FIXUP_DIR" ]; then
    echo -e "${RED}Lỗi: Không tìm thấy thư mục $FIXUP_DIR${NC}"
    exit 1
fi

# Kiểm tra các script sửa lỗi
ERROR_14_SCRIPT="$FIXUP_DIR/mongodb_fixup_code14.sh"
ERROR_48_SCRIPT="$FIXUP_DIR/mongodb_fixup_code48.sh"
KEYFILE_SCRIPT="$FIXUP_DIR/mongodb_fixup_keyfile.sh"
PRIMARY_SCRIPT="$FIXUP_DIR/mongodb_fixup_primaryfailure.sh"
RESET_SCRIPT="$FIXUP_DIR/mongodb_reset.sh"
AUTH_SCRIPT="$FIXUP_DIR/mongodb_fixup_auth.sh"

for script in "$ERROR_14_SCRIPT" "$ERROR_48_SCRIPT" "$KEYFILE_SCRIPT" "$PRIMARY_SCRIPT" "$RESET_SCRIPT" "$AUTH_SCRIPT"; do
    if [ ! -f "$script" ]; then
        echo -e "${YELLOW}Cảnh báo: Không tìm thấy script $script${NC}"
    fi
done

# Kiểm tra Mongo version
echo -e "${YELLOW}Kiểm tra version MongoDB...${NC}"
mongod --version 2>/dev/null || echo -e "${RED}MongoDB chưa được cài đặt${NC}"

# Kiểm tra trạng thái dịch vụ
echo -e "${YELLOW}Kiểm tra trạng thái dịch vụ MongoDB...${NC}"
systemctl status mongod 2>/dev/null || echo -e "${YELLOW}MongoDB service không hoạt động hoặc không có systemctl${NC}"

# Kiểm tra cấu hình MongoDB nếu tồn tại
if [ -f "/etc/mongod.conf" ]; then
    echo -e "${YELLOW}Cấu hình MongoDB hiện tại:${NC}"
    cat /etc/mongod.conf | grep -v "#" | grep -v "^$" || true
fi

echo ""
echo -e "${BLUE}===== CÁC TÙY CHỌN SỬA LỖI =====${NC}"
echo "1. Sửa lỗi quyền (exit code 14)"
echo "2. Sửa lỗi port (exit code 48)"
echo "3. Sửa lỗi keyfile không đồng bộ"
echo "4. Sửa lỗi không thể bầu chọn primary"
echo "5. Xóa toàn bộ data và cài lại từ đầu"
echo "6. Xem log chi tiết"
echo "7. Kiểm tra trạng thái replica set"
echo "8. Sửa lỗi xác thực (Authentication failed)"
echo "9. Thoát"
read -p "Bạn muốn thực hiện sửa lỗi nào? (1-10): " choice

case $choice in
    1)
        echo -e "${YELLOW}Đang chạy script sửa lỗi quyền...${NC}"
        chmod +x "$ERROR_14_SCRIPT"
        sudo "$ERROR_14_SCRIPT"
        ;;
    2)
        echo -e "${YELLOW}Đang chạy script sửa lỗi port...${NC}"
        chmod +x "$ERROR_48_SCRIPT"
        sudo "$ERROR_48_SCRIPT"
        ;;
    3)
        echo -e "${YELLOW}Đang chạy script sửa lỗi keyfile...${NC}"
        chmod +x "$KEYFILE_SCRIPT"
        sudo "$KEYFILE_SCRIPT"
        ;;
    4)
        echo -e "${YELLOW}Đang chạy script sửa lỗi primary...${NC}"
        chmod +x "$PRIMARY_SCRIPT"
        sudo "$PRIMARY_SCRIPT"
        ;;
    5)
        echo -e "${YELLOW}Đang chạy script reset hoàn toàn...${NC}"
        chmod +x "$RESET_SCRIPT"
        sudo "$RESET_SCRIPT"
        ;;
    6)
        echo -e "${YELLOW}Xem log chi tiết...${NC}"
        if [ -f "/var/log/mongodb/mongod.log" ]; then
            sudo cat /var/log/mongodb/mongod.log | tail -n 100
        else
            echo -e "${RED}Không tìm thấy file log MongoDB${NC}"
        fi
        ;;
    7)
        echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
        read -p "Tên người dùng MongoDB [manhg]: " USERNAME
        USERNAME=${USERNAME:-manhg}
        read -p "Mật khẩu MongoDB [manhnk]: " PASSWORD
        PASSWORD=${PASSWORD:-manhnk}
        
        echo "Trạng thái replica set:"
        mongosh -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase admin --eval "rs.status()" 2>/dev/null || echo -e "${RED}Không thể kết nối MongoDB${NC}"
        
        echo "Cấu hình replica set:"
        mongosh -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase admin --eval "rs.conf()" 2>/dev/null || true
        
        echo "Primary:"
        mongosh -u "$USERNAME" -p "$PASSWORD" --authenticationDatabase admin --eval "rs.isMaster()" 2>/dev/null || true
        ;;
    8)
        echo -e "${YELLOW}Đang chạy script sửa lỗi xác thực...${NC}"
        chmod +x "$AUTH_SCRIPT"
        sudo "$AUTH_SCRIPT"
        ;;
    9)
        echo -e "${YELLOW}Thoát.${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Lựa chọn không hợp lệ${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}===== HOÀN THÀNH =====${NC}"
echo "Nếu MongoDB đã hoạt động, bạn có thể tiếp tục thiết lập Replica Set."
echo "Chạy lại script chính: ./run_setup_mongodb.sh" 