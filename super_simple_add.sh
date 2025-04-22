#!/bin/bash

# Màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== THÊM MÁY VÀO REPLICA SET MONGODB ĐƠN GIẢN ===${NC}"

# Lấy thông tin cơ bản
THIS_SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}Địa chỉ IP của server này: $THIS_SERVER_IP${NC}"

read -p "Địa chỉ IP của primary server: " PRIMARY_IP
read -p "Port MongoDB [27017]: " MONGO_PORT
MONGO_PORT=${MONGO_PORT:-27017}
read -p "Tên người dùng MongoDB [manhg]: " MONGO_USER
MONGO_USER=${MONGO_USER:-manhg}
read -p "Mật khẩu MongoDB [manhnk]: " MONGO_PASSWORD
MONGO_PASSWORD=${MONGO_PASSWORD:-manhnk}

# Kiểm tra kết nối tới primary
echo -e "${YELLOW}Kiểm tra kết nối tới $PRIMARY_IP:$MONGO_PORT...${NC}"
if ! nc -z -w5 $PRIMARY_IP $MONGO_PORT; then
  echo -e "${RED}Không thể kết nối tới primary server.${NC}"
  echo -e "${YELLOW}Kiểm tra firewall và đảm bảo MongoDB đang chạy.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Kết nối tới primary server thành công${NC}"

# Thêm server này vào replica set
echo -e "${YELLOW}Thêm server $THIS_SERVER_IP:$MONGO_PORT vào replica set...${NC}"
ADD_RESULT=$(mongosh --host "$PRIMARY_IP:$MONGO_PORT" -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --eval "rs.add('$THIS_SERVER_IP:$MONGO_PORT')")
echo "$ADD_RESULT"

if [[ "$ADD_RESULT" == *"\"ok\" : 1"* || "$ADD_RESULT" == *"ok: 1"* || "$ADD_RESULT" == *"already a member"* ]]; then
  echo -e "${GREEN}✓ Server đã được thêm vào replica set thành công!${NC}"
else
  # Kiểm tra lỗi trùng lặp host
  if [[ "$ADD_RESULT" == *"same host field"* || "$ADD_RESULT" == *"duplicate"* ]]; then
    echo -e "${YELLOW}Phát hiện trùng lặp host. Đang sửa cấu hình...${NC}"
    
    FIX_RESULT=$(mongosh --host "$PRIMARY_IP:$MONGO_PORT" -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --eval "
    try {
      const config = rs.conf();
      const uniqueHosts = {};
      const uniqueMembers = [];
      let id = 0;
      
      for (const member of config.members) {
        if (!uniqueHosts[member.host]) {
          uniqueHosts[member.host] = true;
          member._id = id++;
          uniqueMembers.push(member);
        }
      }
      
      config.members = uniqueMembers;
      
      if (!uniqueHosts['$THIS_SERVER_IP:$MONGO_PORT']) {
        config.members.push({
          _id: id,
          host: '$THIS_SERVER_IP:$MONGO_PORT',
          priority: 1
        });
      }
      
      rs.reconfig(config, {force: true});
      print('SUCCESS');
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    if [[ "$FIX_RESULT" == *"SUCCESS"* ]]; then
      echo -e "${GREEN}✓ Đã sửa cấu hình và thêm server vào replica set${NC}"
    else
      echo -e "${RED}✗ Không thể sửa cấu hình: $FIX_RESULT${NC}"
      exit 1
    fi
  else
    echo -e "${RED}✗ Không thể thêm server vào replica set. Xem lỗi bên trên.${NC}"
    exit 1
  fi
fi

# Kiểm tra trạng thái
echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
sleep 5
STATUS_RESULT=$(mongosh --host "$PRIMARY_IP:$MONGO_PORT" -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --eval "rs.status()")
echo "$STATUS_RESULT" | grep -E "name|stateStr|health" | grep -A 1 "$THIS_SERVER_IP"

# Tạo chuỗi kết nối
RS_NAME=$(mongosh --host "$PRIMARY_IP:$MONGO_PORT" -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --quiet --eval "rs.conf()._id")
echo -e "${BLUE}=== CHUỖI KẾT NỐI CHO ỨNG DỤNG ===${NC}"
echo -e "${GREEN}mongodb://$MONGO_USER:$MONGO_PASSWORD@$PRIMARY_IP:$MONGO_PORT,$THIS_SERVER_IP:$MONGO_PORT/admin?replicaSet=$RS_NAME${NC}"

echo -e "${GREEN}✅ Thêm server vào MongoDB Replica Set hoàn tất!${NC}"
exit 0 