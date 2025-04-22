#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Biến cấu hình mặc định
BACKUP_DIR="/root/mongodb_backup"
DATE_FORMAT=$(date +"%Y%m%d_%H%M%S")
MONGODB_HOST="localhost"
MONGODB_PORT="27017"
MONGODB_USER=""
MONGODB_PASSWORD=""
AUTH_DB="admin"
COMPRESS=true

echo -e "${BLUE}
============================================================
  BACKUP DỮ LIỆU MONGODB - MANHG DEV
============================================================${NC}"

# Đảm bảo mongodump đã được cài đặt
if ! command -v mongodump &> /dev/null; then
  echo -e "${RED}mongodump không tìm thấy. Đảm bảo MongoDB Database Tools đã được cài đặt.${NC}"
  read -p "Bạn muốn cài đặt MongoDB Database Tools không? (y/n): " INSTALL_TOOLS
  
  if [[ "$INSTALL_TOOLS" =~ ^[Yy]$ ]]; then
    # Cài đặt MongoDB Database Tools
    echo -e "${YELLOW}Đang cài đặt MongoDB Database Tools...${NC}"
    
    # Kiểm tra nền tảng
    if command -v apt &> /dev/null; then
      # Debian/Ubuntu
      wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2204-x86_64-100.7.0.deb
      sudo apt install ./mongodb-database-tools-*-100.7.0.deb
      rm mongodb-database-tools-*-100.7.0.deb
    elif command -v yum &> /dev/null; then
      # RHEL/CentOS
      wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-rhel80-x86_64-100.7.0.rpm
      sudo yum install -y ./mongodb-database-tools-*-100.7.0.rpm
      rm mongodb-database-tools-*-100.7.0.rpm
    else
      echo -e "${RED}Không thể xác định hệ điều hành. Vui lòng cài đặt MongoDB Database Tools thủ công.${NC}"
      exit 1
    fi
    
    # Kiểm tra lại
    if ! command -v mongodump &> /dev/null; then
      echo -e "${RED}Không thể cài đặt MongoDB Database Tools. Vui lòng cài đặt thủ công.${NC}"
      exit 1
    fi
    
    echo -e "${GREEN}MongoDB Database Tools đã được cài đặt thành công.${NC}"
  else
    echo -e "${RED}Không thể tiếp tục mà không có MongoDB Database Tools.${NC}"
    exit 1
  fi
fi

# Lấy thông tin xác thực
echo -e "${YELLOW}THÔNG TIN XÁC THỰC MONGODB${NC}"
read -p "Bạn có cần xác thực để kết nối MongoDB không? (y/n): " NEED_AUTH

if [[ "$NEED_AUTH" =~ ^[Yy]$ ]]; then
  read -p "Tên người dùng MongoDB: " MONGODB_USER
  read -s -p "Mật khẩu MongoDB: " MONGODB_PASSWORD
  echo ""
  read -p "Database xác thực [$AUTH_DB]: " USER_AUTH_DB
  AUTH_DB=${USER_AUTH_DB:-$AUTH_DB}
fi

# Lấy thông tin kết nối
echo -e "${YELLOW}THÔNG TIN KẾT NỐI MONGODB${NC}"
read -p "MongoDB host [$MONGODB_HOST]: " USER_HOST
MONGODB_HOST=${USER_HOST:-$MONGODB_HOST}

read -p "MongoDB port [$MONGODB_PORT]: " USER_PORT
MONGODB_PORT=${USER_PORT:-$MONGODB_PORT}

# Lấy thông tin backup
echo -e "${YELLOW}THÔNG TIN BACKUP${NC}"

# Hỏi có muốn chọn database cụ thể không
read -p "Bạn muốn backup tất cả databases hay chỉ một database cụ thể? (all/specific): " BACKUP_TYPE

if [[ "$BACKUP_TYPE" == "specific" ]]; then
  read -p "Tên database cần backup: " SPECIFIC_DB
  
  # Kiểm tra xem database tồn tại không
  if [[ -n "$MONGODB_USER" && -n "$MONGODB_PASSWORD" ]]; then
    DB_EXISTS=$(mongosh --host $MONGODB_HOST --port $MONGODB_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "db.getMongo().getDBNames().includes('$SPECIFIC_DB')")
  else
    DB_EXISTS=$(mongosh --host $MONGODB_HOST --port $MONGODB_PORT --quiet --eval "db.getMongo().getDBNames().includes('$SPECIFIC_DB')")
  fi
  
  if [[ "$DB_EXISTS" != "true" ]]; then
    echo -e "${RED}Database '$SPECIFIC_DB' không tồn tại hoặc không thể truy cập.${NC}"
    read -p "Bạn vẫn muốn tiếp tục? (y/n): " CONTINUE_ANYWAY
    if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
fi

# Thư mục lưu trữ backup
read -p "Thư mục lưu trữ backup [$BACKUP_DIR]: " USER_BACKUP_DIR
BACKUP_DIR=${USER_BACKUP_DIR:-$BACKUP_DIR}

# Tạo thư mục backup nếu chưa tồn tại
mkdir -p $BACKUP_DIR

# Tạo tên thư mục backup với timestamp
if [[ "$BACKUP_TYPE" == "specific" ]]; then
  BACKUP_NAME="${SPECIFIC_DB}_${DATE_FORMAT}"
else
  BACKUP_NAME="mongodb_all_${DATE_FORMAT}"
fi

BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

# Nén backup?
read -p "Bạn có muốn nén backup không? (y/n) [y]: " USER_COMPRESS
if [[ -z "$USER_COMPRESS" || "$USER_COMPRESS" =~ ^[Yy]$ ]]; then
  COMPRESS=true
else
  COMPRESS=false
fi

# Hiển thị thông tin backup
echo -e "${BLUE}\nTHÔNG TIN BACKUP:${NC}"
echo "Host: $MONGODB_HOST:$MONGODB_PORT"
if [[ -n "$MONGODB_USER" ]]; then
  echo "Xác thực: Có (user: $MONGODB_USER, auth DB: $AUTH_DB)"
else
  echo "Xác thực: Không"
fi

if [[ "$BACKUP_TYPE" == "specific" ]]; then
  echo "Database: $SPECIFIC_DB"
else
  echo "Database: Tất cả"
fi

echo "Thư mục backup: $BACKUP_PATH"
echo "Nén backup: $COMPRESS"

# Xác nhận
read -p "Bạn có muốn tiếp tục không? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Hủy thao tác backup.${NC}"
  exit 0
fi

# Bắt đầu backup
echo -e "${GREEN}Bắt đầu tiến trình backup...${NC}"

# Xây dựng command
COMMAND="mongodump --host $MONGODB_HOST --port $MONGODB_PORT --out $BACKUP_PATH"

if [[ -n "$MONGODB_USER" && -n "$MONGODB_PASSWORD" ]]; then
  COMMAND="$COMMAND --username $MONGODB_USER --password $MONGODB_PASSWORD --authenticationDatabase $AUTH_DB"
fi

if [[ "$BACKUP_TYPE" == "specific" ]]; then
  COMMAND="$COMMAND --db $SPECIFIC_DB"
fi

# Thực hiện backup
echo "Đang chạy: $COMMAND"
eval $COMMAND

# Kiểm tra kết quả
if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Backup thành công tại $BACKUP_PATH${NC}"
  
  # Nén nếu yêu cầu
  if [[ "$COMPRESS" == true ]]; then
    echo "Đang nén backup..."
    cd $BACKUP_DIR
    tar -czf "${BACKUP_NAME}.tar.gz" $BACKUP_NAME
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✓ Nén thành công: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz${NC}"
      echo "Xóa thư mục gốc để tiết kiệm dung lượng..."
      rm -rf $BACKUP_PATH
    else
      echo -e "${RED}✗ Lỗi khi nén backup.${NC}"
    fi
  fi
  
  # Hiển thị kích thước
  if [[ "$COMPRESS" == true ]]; then
    du -sh "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
  else
    du -sh $BACKUP_PATH
  fi
  
  echo -e "${GREEN}Backup hoàn tất.${NC}"
else
  echo -e "${RED}✗ Lỗi khi thực hiện backup.${NC}"
  exit 1
fi

# Nhắc nhở lưu trữ ngoài
echo -e "${YELLOW}Lưu ý: Bạn nên sao chép file backup sang vị trí lưu trữ an toàn khác.${NC}"
echo -e "Sử dụng lệnh: scp ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz user@remote_host:/path/to/backup/storage"

exit 0 