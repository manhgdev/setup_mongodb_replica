#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}
============================================================
  BẦU PRIMARY TRONG MONGODB REPLICA SET - MANHG DEV
============================================================${NC}"

# Kiểm tra cài đặt MongoDB client
if ! command -v mongosh &> /dev/null; then
    echo -e "${RED}Lỗi: MongoDB Shell (mongosh) chưa được cài đặt${NC}"
    exit 1
fi

# Thu thập thông tin kết nối
echo -e "${YELLOW}Nhập thông tin kết nối:${NC}"
read -p "Tên người dùng MongoDB [manhg]: " USERNAME
USERNAME=${USERNAME:-manhg}

read -p "Mật khẩu MongoDB [manhnk]: " PASSWORD
PASSWORD=${PASSWORD:-manhnk}

read -p "Database xác thực [admin]: " AUTH_DB
AUTH_DB=${AUTH_DB:-admin}

echo -e "${YELLOW}Thông tin về server hiện tại:${NC}"
read -p "Địa chỉ IP/hostname của server hiện tại: " CURRENT_HOST

read -p "Port của server hiện tại [27017]: " CURRENT_PORT
CURRENT_PORT=${CURRENT_PORT:-27017}

echo -e "${YELLOW}Thông tin về server khác (server sẽ trở thành PRIMARY):${NC}"
read -p "Địa chỉ IP/hostname của server mới: " TARGET_HOST

read -p "Port của server mới [27017]: " TARGET_PORT
TARGET_PORT=${TARGET_PORT:-27017}

# Kiểm tra tên replica set
echo -e "${YELLOW}Kiểm tra thông tin replica set...${NC}"

# Kiểm tra server hiện tại
CURRENT_RS_INFO=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  info = rs.conf();
  print('RS_NAME:' + info._id);
  print('RS_ID:' + info.settings.replicaSetId);
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== THÔNG TIN REPLICA SET (SERVER HIỆN TẠI) =====${NC}"
echo "$CURRENT_RS_INFO"

# Lấy tên replica set từ output
CURRENT_RS_NAME=$(echo "$CURRENT_RS_INFO" | grep RS_NAME | cut -d':' -f2)
if [ -z "$CURRENT_RS_NAME" ]; then
  echo -e "${RED}Không thể xác định tên replica set của server hiện tại${NC}"
  read -p "Nhập tên replica set [rs0]: " CURRENT_RS_NAME
  CURRENT_RS_NAME=${CURRENT_RS_NAME:-rs0}
fi

# Kiểm tra server đích
TARGET_RS_INFO=$(mongosh --host $TARGET_HOST --port $TARGET_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  info = rs.conf();
  print('RS_NAME:' + info._id);
  print('RS_ID:' + info.settings.replicaSetId);
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== THÔNG TIN REPLICA SET (SERVER ĐÍCH) =====${NC}"
echo "$TARGET_RS_INFO"

# Lấy tên replica set từ output
TARGET_RS_NAME=$(echo "$TARGET_RS_INFO" | grep RS_NAME | cut -d':' -f2)
if [ -z "$TARGET_RS_NAME" ]; then
  echo -e "${RED}Không thể xác định tên replica set của server đích${NC}"
  read -p "Nhập tên replica set [rs0]: " TARGET_RS_NAME
  TARGET_RS_NAME=${TARGET_RS_NAME:-rs0}
fi

# Kiểm tra xem các server có cùng replica set không
if [ "$CURRENT_RS_NAME" != "$TARGET_RS_NAME" ]; then
  echo -e "${RED}Cảnh báo: Hai server thuộc các replica set khác nhau (${CURRENT_RS_NAME} vs ${TARGET_RS_NAME})!${NC}"
  echo -e "${YELLOW}Để bầu PRIMARY, các server phải thuộc cùng một replica set.${NC}"
  
  read -p "Bạn muốn gộp replica set thành một? Dữ liệu trên server SECONDARY sẽ bị mất [y/N]: " MERGE_RS
  if [[ ! "$MERGE_RS" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Hủy thao tác.${NC}"
    exit 0
  fi
  
  read -p "Server nào sẽ là PRIMARY (giữ nguyên dữ liệu)? [1: $CURRENT_HOST, 2: $TARGET_HOST]: " PRIMARY_CHOICE
  
  if [ "$PRIMARY_CHOICE" = "1" ]; then
    PRIMARY_HOST=$CURRENT_HOST
    PRIMARY_PORT=$CURRENT_PORT
    PRIMARY_RS_NAME=$CURRENT_RS_NAME
    SECONDARY_HOST=$TARGET_HOST
    SECONDARY_PORT=$TARGET_PORT
  elif [ "$PRIMARY_CHOICE" = "2" ]; then
    PRIMARY_HOST=$TARGET_HOST
    PRIMARY_PORT=$TARGET_PORT
    PRIMARY_RS_NAME=$TARGET_RS_NAME
    SECONDARY_HOST=$CURRENT_HOST
    SECONDARY_PORT=$CURRENT_PORT
  else
    echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    exit 1
  fi
  
  echo -e "${BLUE}===== THIẾT LẬP LẠI REPLICA SET =====${NC}"
  echo -e "${YELLOW}PRIMARY: $PRIMARY_HOST:$PRIMARY_PORT (giữ nguyên dữ liệu)${NC}"
  echo -e "${YELLOW}SECONDARY: $SECONDARY_HOST:$SECONDARY_PORT (sẽ xóa dữ liệu và cấu hình)${NC}"
  
  read -p "Tiếp tục? CẢNH BÁO: Thao tác không thể hoàn tác [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Hủy thao tác.${NC}"
    exit 0
  fi
  
  # Dừng MongoDB trên server SECONDARY
  echo -e "${YELLOW}Kết nối SSH đến server SECONDARY ($SECONDARY_HOST) để dừng và xóa dữ liệu...${NC}"
  echo -e "${RED}Đoạn này cần thực hiện thủ công trên server $SECONDARY_HOST:${NC}"
  echo "1. Dừng MongoDB: sudo systemctl stop mongod"
  echo "2. Xóa dữ liệu: sudo rm -rf /var/lib/mongodb/*"
  echo "3. Tạo lại file cấu hình MongoDB với cùng tên replica set \"$PRIMARY_RS_NAME\""
  echo "4. Khởi động lại MongoDB: sudo systemctl start mongod"
  
  read -p "Đã thực hiện các bước trên? [y/N]: " SECONDARY_READY
  if [[ ! "$SECONDARY_READY" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Hãy thực hiện các bước trên trên server SECONDARY trước khi tiếp tục.${NC}"
    exit 0
  fi
  
  # Thêm server SECONDARY vào replica set PRIMARY
  echo -e "${YELLOW}Thêm server SECONDARY vào replica set...${NC}"
  ADD_RESULT=$(mongosh --host $PRIMARY_HOST --port $PRIMARY_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
  try {
    result = rs.add('$SECONDARY_HOST:$SECONDARY_PORT');
    print(JSON.stringify(result));
  } catch(e) {
    print('ERROR: ' + e.message);
  }
  ")
  
  echo "$ADD_RESULT"
  
  if [[ "$ADD_RESULT" == *"ERROR"* ]]; then
    echo -e "${RED}Lỗi khi thêm server SECONDARY vào replica set.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Server SECONDARY đã được thêm vào replica set.${NC}"
  
else
  # Nếu cùng replica set, thực hiện việc bầu PRIMARY
  echo -e "${BLUE}===== BẦU PRIMARY MỚI =====${NC}"
  echo -e "${YELLOW}Thực hiện step down trên PRIMARY hiện tại...${NC}"
  
  # Xác định PRIMARY hiện tại
  CURRENT_PRIMARY=$(echo "$CURRENT_RS_INFO $TARGET_RS_INFO" | grep MASTER | grep -v NONE | cut -d':' -f2- | tr -d '\n')
  
  echo -e "${YELLOW}PRIMARY hiện tại: $CURRENT_PRIMARY${NC}"
  
  if [ -z "$CURRENT_PRIMARY" ]; then
    echo -e "${RED}Không thể xác định PRIMARY hiện tại.${NC}"
    exit 1
  fi
  
  # Thực hiện step down
  STEP_DOWN_RESULT=$(mongosh --host $CURRENT_PRIMARY -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
  try {
    result = db.adminCommand({replSetStepDown: 60, force: true});
    print(JSON.stringify(result));
  } catch(e) {
    print('ERROR: ' + e.message);
  }
  ")
  
  echo "$STEP_DOWN_RESULT"
  
  if [[ "$STEP_DOWN_RESULT" == *"ERROR"* ]]; then
    echo -e "${RED}Lỗi khi thực hiện step down.${NC}"
    echo -e "${YELLOW}Thử force PRIMARY trên server đích...${NC}"
    
    # Tăng priority của server đích để ưu tiên làm PRIMARY
    RECONFIG_RESULT=$(mongosh --host $TARGET_HOST --port $TARGET_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      config = rs.conf();
      for (var i = 0; i < config.members.length; i++) {
        if (config.members[i].host == '$TARGET_HOST:$TARGET_PORT') {
          config.members[i].priority = 10;
        } else {
          config.members[i].priority = 1;
        }
      }
      result = rs.reconfig(config);
      print(JSON.stringify(result));
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$RECONFIG_RESULT"
    
    if [[ "$RECONFIG_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi thay đổi cấu hình replica set.${NC}"
      exit 1
    fi
  fi
fi

# Chờ bầu PRIMARY mới
echo -e "${YELLOW}Chờ bầu PRIMARY mới...${NC}"
sleep 15

# Kiểm tra PRIMARY mới
echo -e "${YELLOW}Kiểm tra PRIMARY mới...${NC}"

# Kiểm tra server hiện tại
FINAL_CURRENT_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET HIỆN TẠI =====${NC}"
echo "$FINAL_CURRENT_STATUS"

# Kiểm tra server đích
FINAL_TARGET_STATUS=$(mongosh --host $TARGET_HOST --port $TARGET_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch(e) {
  print('ERROR:' + e.message);
}
")

echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET ĐÍCH =====${NC}"
echo "$FINAL_TARGET_STATUS"

echo -e "${GREEN}Hoàn thành quá trình bầu PRIMARY!${NC}"

# Tạo chuỗi kết nối cho ứng dụng
CURRENT_MEMBER=$(echo "$FINAL_CURRENT_STATUS" | grep MEMBER | cut -d':' -f2 | cut -d':' -f1)
TARGET_MEMBER=$(echo "$FINAL_TARGET_STATUS" | grep MEMBER | cut -d':' -f2 | cut -d':' -f1)

if [ -n "$CURRENT_MEMBER" ] && [ -n "$TARGET_MEMBER" ]; then
  echo -e "${BLUE}===== CHUỖI KẾT NỐI MONGODB =====${NC}"
  echo -e "${GREEN}mongodb://$USERNAME:$PASSWORD@$CURRENT_MEMBER:$CURRENT_PORT,$TARGET_MEMBER:$TARGET_PORT/admin?replicaSet=$CURRENT_RS_NAME${NC}"
fi 