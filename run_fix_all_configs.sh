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
echo "5. Reset hoàn toàn MongoDB"
echo "6. Xem log chi tiết"
echo "7. Kiểm tra trạng thái replica set"
echo "8. Sửa lỗi xác thực (Authentication failed)"
echo "9. Xóa toàn bộ data và cài lại từ đầu"
echo "10. Thoát"
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
        echo -e "${YELLOW}Xóa toàn bộ data và cài đặt lại MongoDB từ đầu...${NC}"
        echo -e "${RED}CẢNH BÁO: Thao tác này sẽ xóa TẤT CẢ dữ liệu MongoDB hiện tại!${NC}"
        read -p "Bạn có chắc chắn muốn tiếp tục? (yes/no): " confirmation
        if [ "$confirmation" != "yes" ]; then
            echo -e "${YELLOW}Đã hủy thao tác.${NC}"
            exit 0
        fi
        
        # Dừng service MongoDB
        echo -e "${YELLOW}Dừng service MongoDB...${NC}"
        sudo systemctl stop mongod
        
        # Xóa dữ liệu
        echo -e "${YELLOW}Xóa toàn bộ dữ liệu MongoDB...${NC}"
        read -p "Đường dẫn thư mục dữ liệu MongoDB [/var/lib/mongodb]: " DB_PATH
        DB_PATH=${DB_PATH:-/var/lib/mongodb}
        
        sudo rm -rf $DB_PATH/*
        
        # Xóa file keyfile cũ nếu có
        echo -e "${YELLOW}Xóa file keyfile cũ...${NC}"
        read -p "Đường dẫn keyfile [/etc/mongodb-keyfile]: " KEYFILE_PATH
        KEYFILE_PATH=${KEYFILE_PATH:-/etc/mongodb-keyfile}
        
        if [ -f "$KEYFILE_PATH" ]; then
            sudo rm -f $KEYFILE_PATH
        fi
        
        # Xóa file cấu hình cũ
        echo -e "${YELLOW}Tạo lại file cấu hình...${NC}"
        sudo mv /etc/mongod.conf /etc/mongod.conf.bak
        
        # Tạo keyfile mới
        echo -e "${YELLOW}Tạo keyfile mới...${NC}"
        sudo openssl rand -base64 756 | sudo tee $KEYFILE_PATH > /dev/null
        sudo chmod 400 $KEYFILE_PATH
        sudo chown mongodb:mongodb $KEYFILE_PATH
        
        # Tạo file cấu hình mới
        echo -e "${YELLOW}Tạo file cấu hình MongoDB mới...${NC}"
        read -p "Port MongoDB [27017]: " MONGO_PORT
        MONGO_PORT=${MONGO_PORT:-27017}
        
        read -p "Tên Replica Set [rs0]: " REPLICA_SET
        REPLICA_SET=${REPLICA_SET:-rs0}
        
        sudo tee /etc/mongod.conf > /dev/null << EOF
# MongoDB configuration file
storage:
  dbPath: $DB_PATH
  
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true

security:
  keyFile: $KEYFILE_PATH
  authorization: enabled
EOF
        
        # Đảm bảo quyền truy cập đúng
        echo -e "${YELLOW}Thiết lập quyền truy cập...${NC}"
        sudo mkdir -p $DB_PATH
        sudo mkdir -p /var/log/mongodb
        sudo chown -R mongodb:mongodb $DB_PATH
        sudo chown -R mongodb:mongodb /var/log/mongodb
        sudo chmod -R 750 $DB_PATH
        
        # Khởi động lại MongoDB
        echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
        sudo systemctl start mongod
        sleep 5
        
        # Kiểm tra trạng thái
        if sudo systemctl is-active mongod &> /dev/null; then
            echo -e "${GREEN}MongoDB đã khởi động thành công!${NC}"
        else
            echo -e "${RED}MongoDB không thể khởi động. Kiểm tra log tại /var/log/mongodb/mongod.log${NC}"
        fi
        
        # Khởi tạo replica set
        echo -e "${YELLOW}Khởi tạo replica set...${NC}"
        sleep 10
        
        IP_ADDRESS=$(hostname -I | awk '{print $1}')
        echo -e "${YELLOW}Địa chỉ IP phát hiện: $IP_ADDRESS${NC}"
        read -p "Sử dụng địa chỉ IP này cho replica set? (yes/no): " USE_IP
        
        if [ "$USE_IP" != "yes" ]; then
            read -p "Nhập địa chỉ IP hoặc hostname cho replica set: " IP_ADDRESS
        fi
        
        # Khởi tạo replica set
        echo -e "${YELLOW}Khởi tạo replica set với địa chỉ: $IP_ADDRESS:$MONGO_PORT${NC}"
        
        init_result=$(mongosh --eval "rs.initiate({_id: '$REPLICA_SET', members: [{_id: 0, host: '$IP_ADDRESS:$MONGO_PORT', priority: 10}]})")
        
        echo "$init_result"
        
        echo -e "${YELLOW}Waiting for replica set to initialize...${NC}"
        sleep 15
        
        # Tạo user admin
        echo -e "${YELLOW}Tạo user admin...${NC}"
        read -p "Tên người dùng [manhg]: " ADMIN_USER
        ADMIN_USER=${ADMIN_USER:-manhg}
        
        read -p "Mật khẩu [manhnk]: " ADMIN_PASS
        ADMIN_PASS=${ADMIN_PASS:-manhnk}
        
        user_result=$(mongosh --eval "
        db = db.getSiblingDB('admin');
        try {
          db.createUser({
            user: '$ADMIN_USER',
            pwd: '$ADMIN_PASS',
            roles: [ { role: 'root', db: 'admin' } ]
          });
          print('✓ Tạo user thành công');
        } catch(e) {
          print('⚠ Lỗi: ' + e.message);
        }
        ")
        
        echo "$user_result"
        
        echo -e "${GREEN}MongoDB đã được cài đặt lại từ đầu với replica set mới!${NC}"
        echo -e "${YELLOW}Bạn có thể kết nối với MongoDB bằng lệnh:${NC}"
        echo "mongosh -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
        ;;
    10)
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