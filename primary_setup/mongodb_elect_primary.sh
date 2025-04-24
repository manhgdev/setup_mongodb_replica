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
  QUẢN LÝ PRIMARY TRONG MONGODB REPLICA SET - MANHG DEV
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

# Thử nhiều cách để lấy IP
CURRENT_IP=""

# Phương pháp 1: hostname -I
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Phương pháp 2: ip addr
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Phương pháp 3: ifconfig
if [ -z "$CURRENT_IP" ]; then
  IP_RESULT=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
  if [ -n "$IP_RESULT" ]; then
    CURRENT_IP=$IP_RESULT
  fi
fi

# Thông báo nếu phát hiện được IP
if [ -n "$CURRENT_IP" ]; then
  echo -e "${GREEN}✓ Đã phát hiện IP: $CURRENT_IP${NC}"
else
  echo -e "${YELLOW}⚠️ Không thể tự động phát hiện IP${NC}"
  CURRENT_IP="127.0.0.1"
fi

read -p "Địa chỉ IP/hostname của server hiện tại [$CURRENT_IP]: " USER_CURRENT_HOST
CURRENT_HOST=${USER_CURRENT_HOST:-$CURRENT_IP}

read -p "Port của server hiện tại [27017]: " CURRENT_PORT
CURRENT_PORT=${CURRENT_PORT:-27017}

# Hiển thị menu lựa chọn
echo -e "${BLUE}
============================================================
  LỰA CHỌN THAO TÁC
============================================================${NC}"
echo -e "${YELLOW}1. Bầu bản thân làm PRIMARY${NC}"
echo -e "${YELLOW}2. Bầu server khác làm PRIMARY${NC}"
echo -e "${YELLOW}3. Chuyển PRIMARY sang server khác (không bầu)${NC}"
echo -e "${YELLOW}4. Xem trạng thái replica set${NC}"
echo -e "${YELLOW}5. Thoát${NC}"

read -p "Chọn thao tác [1-5]: " CHOICE

case $CHOICE in
  1)
    # Bầu bản thân làm PRIMARY
    echo -e "${BLUE}===== BẦU BẢN THÂN LÀM PRIMARY =====${NC}"
    
    # Kiểm tra trạng thái hiện tại
    CURRENT_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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
    
    echo -e "${BLUE}===== TRẠNG THÁI HIỆN TẠI =====${NC}"
    echo "$CURRENT_STATUS"
    
    # Tăng priority của bản thân
    RECONFIG_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      config = rs.conf();
      for (var i = 0; i < config.members.length; i++) {
        if (config.members[i].host == '$CURRENT_HOST:$CURRENT_PORT') {
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
    
    echo -e "${GREEN}Đã tăng priority của server hiện tại.${NC}"
    ;;
    
  2)
    # Bầu server khác làm PRIMARY
    echo -e "${YELLOW}Thông tin về server sẽ làm PRIMARY:${NC}"
    read -p "Địa chỉ IP/hostname của server mới: " TARGET_HOST
    
    read -p "Port của server mới [27017]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-27017}
    
    # Kiểm tra server đích
    TARGET_STATUS=$(mongosh --host $TARGET_HOST --port $TARGET_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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
    
    echo -e "${BLUE}===== TRẠNG THÁI SERVER ĐÍCH =====${NC}"
    echo "$TARGET_STATUS"
    
    # Tăng priority của server đích
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
    
    echo -e "${GREEN}Đã tăng priority của server đích.${NC}"
    ;;
    
  3)
    # Chuyển PRIMARY sang server khác (không bầu)
    echo -e "${YELLOW}Thông tin về server sẽ nhận PRIMARY:${NC}"
    read -p "Địa chỉ IP/hostname của server mới: " TARGET_HOST
    
    read -p "Port của server mới [27017]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-27017}
    
    # Kiểm tra PRIMARY hiện tại
    CURRENT_PRIMARY=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      print(rs.isMaster().primary || 'NONE');
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    if [ "$CURRENT_PRIMARY" = "NONE" ]; then
      echo -e "${RED}Không thể xác định PRIMARY hiện tại.${NC}"
      exit 1
    fi
    
    echo -e "${YELLOW}PRIMARY hiện tại: $CURRENT_PRIMARY${NC}"
    
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
      exit 1
    fi
    
    echo -e "${GREEN}Đã thực hiện step down thành công.${NC}"
    ;;
    
  4)
    # Xem trạng thái replica set
    echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET =====${NC}"
    
    STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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
    
    echo "$STATUS"
    ;;
    
  5)
    echo -e "${YELLOW}Thoát chương trình.${NC}"
    exit 0
    ;;
    
  *)
    echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    exit 1
    ;;
esac

# Chờ bầu PRIMARY mới (nếu có)
if [ "$CHOICE" = "1" ] || [ "$CHOICE" = "2" ] || [ "$CHOICE" = "3" ]; then
  echo -e "${YELLOW}Chờ bầu PRIMARY mới...${NC}"
  sleep 15
  
  # Kiểm tra PRIMARY mới
  FINAL_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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
  
  echo -e "${BLUE}===== TRẠNG THÁI CUỐI CÙNG =====${NC}"
  echo "$FINAL_STATUS"
fi

echo -e "${GREEN}Hoàn thành thao tác!${NC}" 