#!/bin/bash

# Màu cho đầu ra
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== THÊM MÁY VÀO REPLICA SET CHỈ DÙNG USERNAME/PASSWORD ===${NC}"

# Lấy IP hiện tại
THIS_IP=$(hostname -I | awk '{print $1}')
echo -e "IP máy này: $THIS_IP"

# Nhập thông tin
read -p "IP máy PRIMARY: " PRIMARY_IP
read -p "Port [27017]: " PORT
PORT=${PORT:-27017}
read -p "Username [manhg]: " USERNAME
USERNAME=${USERNAME:-manhg}
read -p "Password [manhnk]: " PASSWORD
PASSWORD=${PASSWORD:-manhnk}

echo -e "${YELLOW}1. Xóa máy này khỏi replica set (nếu đã tồn tại)${NC}"
mongosh --host $PRIMARY_IP:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "try { rs.remove('$THIS_IP:$PORT') } catch(e) { print(e.message) }"

echo -e "${YELLOW}2. Sửa các cấu hình trùng lặp${NC}"
mongosh --host $PRIMARY_IP:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "
try {
  const config = rs.conf();
  let hasChanges = false;
  
  // Lọc bỏ các host trùng lặp
  const uniqueHosts = new Set();
  const newMembers = [];
  
  for (let i = 0; i < config.members.length; i++) {
    if (!uniqueHosts.has(config.members[i].host)) {
      uniqueHosts.add(config.members[i].host);
      newMembers.push(config.members[i]);
    } else {
      print('Xóa host trùng lặp: ' + config.members[i].host);
      hasChanges = true;
    }
  }
  
  if (hasChanges) {
    // Đặt lại ID
    for (let i = 0; i < newMembers.length; i++) {
      newMembers[i]._id = i;
    }
    
    config.members = newMembers;
    rs.reconfig(config, {force: true});
    print('Đã sửa cấu hình replica set');
  } else {
    print('Không có host trùng lặp cần sửa');
  }
} catch(e) {
  print('Lỗi khi sửa cấu hình: ' + e.message);
}
"

echo -e "${YELLOW}3. Thêm máy hiện tại vào replica set${NC}"
ADD_RESULT=$(mongosh --host $PRIMARY_IP:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "rs.add('$THIS_IP:$PORT')")
echo "$ADD_RESULT"

if [[ "$ADD_RESULT" == *"\"ok\" : 1"* || "$ADD_RESULT" == *"ok: 1"* ]]; then
  echo -e "${GREEN}✓ Đã thêm thành công máy $THIS_IP vào replica set${NC}"
else
  echo -e "${RED}✗ Không thể thêm máy vào replica set. Xem lỗi ở trên.${NC}"
fi

echo -e "${YELLOW}4. Kiểm tra trạng thái replica set${NC}"
mongosh --host $PRIMARY_IP:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"

echo -e "${YELLOW}5. Hiển thị chuỗi kết nối cho ứng dụng${NC}"
RS_NAME=$(mongosh --host $PRIMARY_IP:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase admin --quiet --eval "rs.conf()._id")
echo -e "${GREEN}mongodb://$USERNAME:$PASSWORD@$PRIMARY_IP:$PORT,$THIS_IP:$PORT/admin?replicaSet=$RS_NAME${NC}"

echo -e "${GREEN}Hoàn tất!${NC}" 