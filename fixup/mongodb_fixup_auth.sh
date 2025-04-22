#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Thông tin xác thực
MONGODB_USER="manhg"
MONGODB_PASSWORD="manhnk"

echo -e "${BLUE}====== SỬA LỖI XÁC THỰC MONGODB ======${NC}"

# 1. Xác nhận thông tin xác thực
echo -e "${YELLOW}Xác thực hiện tại:${NC}"
echo "Username: $MONGODB_USER"
echo "Password: $MONGODB_PASSWORD"
read -p "Bạn muốn tiếp tục với thông tin này? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  read -p "Nhập username mới: " NEW_USER
  read -s -p "Nhập password mới: " NEW_PASSWORD
  echo ""
  MONGODB_USER=${NEW_USER:-$MONGODB_USER}
  MONGODB_PASSWORD=${NEW_PASSWORD:-$MONGODB_PASSWORD}
fi

# 2. Kiểm tra MongoDB đang chạy
if ! systemctl is-active --quiet mongod; then
  echo -e "${RED}MongoDB không chạy. Đang khởi động lại...${NC}"
  sudo systemctl start mongod
  sleep 3
  
  if ! systemctl is-active --quiet mongod; then
    echo -e "${RED}Không thể khởi động MongoDB. Vui lòng kiểm tra lỗi.${NC}"
    sudo systemctl status mongod
    exit 1
  fi
fi

# 3. Vô hiệu hóa tạm thời xác thực
echo -e "${YELLOW}Tạm thời vô hiệu hóa xác thực...${NC}"
sudo sed -i '/^security:/,/^\([^:]\|$\)/s/authorization: enabled/authorization: disabled/' /etc/mongod.conf

# 4. Khởi động lại MongoDB
echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
sudo systemctl restart mongod
sleep 5

# 5. Kiểm tra lại trạng thái
if ! systemctl is-active --quiet mongod; then
  echo -e "${RED}Không thể khởi động MongoDB sau khi tắt xác thực. Vui lòng kiểm tra.${NC}"
  sudo systemctl status mongod
  exit 1
fi

# 6. Lấy thông tin Replica Set
echo -e "${YELLOW}Lấy thông tin Replica Set...${NC}"
rs_info=$(mongosh --quiet --eval "rs.status()")
primary_node=$(mongosh --quiet --eval "rs.isMaster().primary")
echo "Primary node: $primary_node"

# 7. Đặt lại user admin
echo -e "${YELLOW}Đặt lại user admin...${NC}"
result=$(mongosh --quiet --eval "
db = db.getSiblingDB('admin');
try {
  db.dropUser('$MONGODB_USER');
  print('✓ Đã xóa user cũ nếu tồn tại');
} catch(e) {
  print('✓ Không có user cũ');
}

try {
  db.createUser({
    user: '$MONGODB_USER',
    pwd: '$MONGODB_PASSWORD',
    roles: [ { role: 'root', db: 'admin' } ]
  });
  print('✓ Đã tạo user admin thành công');
} catch(e) {
  print('✗ Lỗi khi tạo user: ' + e.message);
}
")

echo -e "${GREEN}$result${NC}"

# 8. Bật lại xác thực
echo -e "${YELLOW}Bật lại xác thực...${NC}"
sudo sed -i '/^security:/,/^\([^:]\|$\)/s/authorization: disabled/authorization: enabled/' /etc/mongod.conf

# 9. Khởi động lại MongoDB
echo -e "${YELLOW}Khởi động lại MongoDB...${NC}"
sudo systemctl restart mongod
sleep 5

# 10. Kiểm tra kết nối
echo -e "${YELLOW}Kiểm tra kết nối...${NC}"
conn_test=$(mongosh --quiet -u "$MONGODB_USER" -p "$MONGODB_PASSWORD" --authenticationDatabase admin --eval "try { print('✓ Kết nối thành công!'); } catch(e) { print('✗ Lỗi kết nối: ' + e.message); }")

if [[ "$conn_test" == *"Kết nối thành công"* ]]; then
  echo -e "${GREEN}$conn_test${NC}"
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${GREEN}✅ SỬA LỖI XÁC THỰC THÀNH CÔNG!${NC}"
  echo -e "${GREEN}==================================================${NC}"
  
  # Hiển thị thông tin kết nối
  echo -e "${YELLOW}Để kết nối MongoDB Replica Set:${NC}"
  echo "mongosh -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin"
  
  # Thông tin Replica Set
  echo -e "${YELLOW}Kiểm tra trạng thái replica set:${NC}"
  mongosh -u "$MONGODB_USER" -p "$MONGODB_PASSWORD" --authenticationDatabase admin --eval "rs.status()" | grep -E "name|stateStr|health|state"
else
  echo -e "${RED}$conn_test${NC}"
  echo -e "${RED}==================================================${NC}"
  echo -e "${RED}❌ SỬA LỖI XÁC THỰC THẤT BẠI!${NC}"
  echo -e "${RED}==================================================${NC}"
  
  echo -e "${YELLOW}Đang kiểm tra lỗi...${NC}"
  sudo systemctl status mongod
  
  echo -e "${YELLOW}Xem log MongoDB...${NC}"
  sudo tail -n 20 /var/log/mongodb/mongod.log
  
  echo -e "${YELLOW}Cách sửa thủ công:${NC}"
  echo "1. Tắt xác thực bằng cách chỉnh sửa file /etc/mongod.conf"
  echo "2. Khởi động lại MongoDB: sudo systemctl restart mongod"
  echo "3. Tạo người dùng mới: mongosh --eval \"db.getSiblingDB('admin').createUser({user: 'manhg', pwd: 'manhnk', roles: [ { role: 'root', db: 'admin' } ]})\""
  echo "4. Bật lại xác thực và khởi động lại MongoDB"
fi

exit 0 