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
echo -e "${YELLOW}3. Chuyển PRIMARY sang server khác (force)${NC}"
echo -e "${YELLOW}4. Xem trạng thái replica set${NC}"
echo -e "${YELLOW}5. Sửa lỗi node không reachable/healthy${NC}"
echo -e "${YELLOW}6. Thay đổi port của node trong replica set${NC}"
echo -e "${YELLOW}7. Thoát${NC}"

read -p "Chọn thao tác [1-7]: " CHOICE

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
      print('STATE:' + rs.status().myState);
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI HIỆN TẠI =====${NC}"
    echo "$CURRENT_STATUS"
    
    # Kiểm tra xem có phải là PRIMARY không
    CURRENT_STATE=$(echo "$CURRENT_STATUS" | grep "STATE:" | cut -d':' -f2)
    
    if [ "$CURRENT_STATE" != "1" ]; then
      echo -e "${YELLOW}Server hiện tại không phải là PRIMARY. Đang thực hiện step down PRIMARY hiện tại...${NC}"
      
      # Lấy PRIMARY hiện tại
      CURRENT_PRIMARY=$(echo "$CURRENT_STATUS" | grep "MASTER:" | cut -d':' -f2)
      
      if [ "$CURRENT_PRIMARY" = "NONE" ]; then
        echo -e "${RED}Không thể xác định PRIMARY hiện tại.${NC}"
        exit 1
      fi
      
      # Thực hiện step down PRIMARY hiện tại
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
      
      echo -e "${GREEN}Đã thực hiện step down thành công. Chờ bầu PRIMARY mới...${NC}"
      sleep 15
    fi
    
    # Kiểm tra lại trạng thái sau khi step down
    NEW_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      status = rs.status();
      for (var i = 0; i < status.members.length; i++) {
        print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
      }
      print('MASTER:' + (rs.isMaster().primary || 'NONE'));
      print('STATE:' + rs.status().myState);
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI SAU KHI STEP DOWN =====${NC}"
    echo "$NEW_STATUS"
    
    # Kiểm tra xem đã là PRIMARY chưa
    NEW_STATE=$(echo "$NEW_STATUS" | grep "STATE:" | cut -d':' -f2)
    
    if [ "$NEW_STATE" != "1" ]; then
      echo -e "${YELLOW}Server vẫn chưa là PRIMARY. Đang tăng priority...${NC}"
      
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
      
      echo -e "${GREEN}Đã tăng priority của server hiện tại. Chờ bầu PRIMARY mới...${NC}"
      sleep 15
    fi
    
    # Kiểm tra trạng thái cuối cùng
    FINAL_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      status = rs.status();
      for (var i = 0; i < status.members.length; i++) {
        print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
      }
      print('MASTER:' + (rs.isMaster().primary || 'NONE'));
      print('STATE:' + rs.status().myState);
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI CUỐI CÙNG =====${NC}"
    echo "$FINAL_STATUS"
    
    FINAL_STATE=$(echo "$FINAL_STATUS" | grep "STATE:" | cut -d':' -f2)
    if [ "$FINAL_STATE" = "1" ]; then
      echo -e "${GREEN}Server hiện tại đã trở thành PRIMARY!${NC}"
    else
      echo -e "${YELLOW}Server hiện tại vẫn chưa là PRIMARY. Vui lòng thử lại sau.${NC}"
    fi
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
    # Chuyển PRIMARY sang server khác (force)
    echo -e "${BLUE}===== FORCE CHUYỂN PRIMARY SANG SERVER KHÁC =====${NC}"
    
    # Kiểm tra trạng thái hiện tại
    CURRENT_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      status = rs.status();
      for (var i = 0; i < status.members.length; i++) {
        print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr);
      }
      print('MASTER:' + (rs.isMaster().primary || 'NONE'));
      print('STATE:' + rs.status().myState);
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI HIỆN TẠI =====${NC}"
    echo "$CURRENT_STATUS"
    
    # Lấy PRIMARY hiện tại
    CURRENT_PRIMARY=$(echo "$CURRENT_STATUS" | grep "MASTER:" | cut -d':' -f2)
    
    if [ "$CURRENT_PRIMARY" = "NONE" ]; then
      echo -e "${RED}Không thể xác định PRIMARY hiện tại.${NC}"
      exit 1
    fi
    
    # Cập nhật thông tin kết nối
    PRIMARY_HOST=$(echo $CURRENT_PRIMARY | cut -d':' -f1)
    PRIMARY_PORT=$(echo $CURRENT_PRIMARY | cut -d':' -f2)
    
    echo -e "${YELLOW}Thông tin về server sẽ nhận PRIMARY:${NC}"
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
    
    # Force chuyển PRIMARY
    echo -e "${YELLOW}Thực hiện force chuyển PRIMARY...${NC}"
    FORCE_RESULT=$(mongosh "mongodb://$PRIMARY_HOST:$PRIMARY_PORT" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      config = rs.conf();
      for (var i = 0; i < config.members.length; i++) {
        if (config.members[i].host == '$TARGET_HOST:$TARGET_PORT') {
          config.members[i].priority = 10;
          config.members[i].votes = 1;
        } else {
          config.members[i].priority = 1;
          config.members[i].votes = 1;
        }
      }
      result = rs.reconfig(config, {force: true});
      print(JSON.stringify(result));
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$FORCE_RESULT"
    
    if [[ "$FORCE_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi force chuyển PRIMARY.${NC}"
      exit 1
    fi
    
    echo -e "${GREEN}Đã force chuyển PRIMARY thành công. Chờ xác nhận...${NC}"
    sleep 15
    
    # Kiểm tra trạng thái cuối cùng
    FINAL_STATUS=$(mongosh "mongodb://$PRIMARY_HOST:$PRIMARY_PORT" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
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
    
    NEW_PRIMARY=$(echo "$FINAL_STATUS" | grep "MASTER:" | cut -d':' -f2)
    if [ "$NEW_PRIMARY" = "$TARGET_HOST:$TARGET_PORT" ]; then
      echo -e "${GREEN}Server $TARGET_HOST:$TARGET_PORT đã trở thành PRIMARY!${NC}"
    else
      echo -e "${YELLOW}Server $TARGET_HOST:$TARGET_PORT chưa trở thành PRIMARY. Vui lòng thử lại sau.${NC}"
    fi
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
    
    # Hiển thị thêm cấu hình replica set
    CONFIG=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      config = rs.conf();
      print('CONFIG_MEMBERS:' + config.members.length);
      for (var i = 0; i < config.members.length; i++) {
        print('CONFIG_MEMBER_' + i + ':' + config.members[i].host + ':' + 
              'arbiter:' + (config.members[i].arbiterOnly || false) + ':' +
              'priority:' + (config.members[i].priority || 1));
      }
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== CẤU HÌNH REPLICA SET =====${NC}"
    echo "$CONFIG"
    ;;

  5)
    # Sửa lỗi node không reachable/healthy
    echo -e "${BLUE}===== SỬA LỖI NODE KHÔNG REACHABLE/HEALTHY =====${NC}"
    
    # Kiểm tra trạng thái replica set
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
    
    echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET =====${NC}"
    echo "$STATUS"
    
    # Tìm các node không reachable/healthy
    UNREACHABLE_NODES=$(echo "$STATUS" | grep -i "not reachable/healthy" | awk -F':' '{print $2}' | sed 's/ //')
    
    if [ -z "$UNREACHABLE_NODES" ]; then
      echo -e "${GREEN}Không có node nào không reachable/healthy.${NC}"
      exit 0
    fi
    
    echo -e "${YELLOW}Các node không reachable/healthy:${NC}"
    echo "$UNREACHABLE_NODES"
    
    # Chọn node để sửa
    read -p "Nhập node cần sửa (ví dụ: 36.50.134.16:27018): " UNREACHABLE_NODE
    
    # Tách host và port
    UNREACHABLE_HOST=$(echo $UNREACHABLE_NODE | cut -d':' -f1)
    UNREACHABLE_PORT=$(echo $UNREACHABLE_NODE | cut -d':' -f2)
    
    # Xóa node khỏi replica set
    echo -e "${YELLOW}Đang xóa node $UNREACHABLE_NODE khỏi replica set...${NC}"
    REMOVE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      result = rs.remove('$UNREACHABLE_NODE');
      print(JSON.stringify(result));
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$REMOVE_RESULT"
    
    if [[ "$REMOVE_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi xóa node khỏi replica set.${NC}"
      echo -e "${YELLOW}Thử force remove...${NC}"
      
      # Force remove bằng cách reconfigure
      FORCE_REMOVE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
      try {
        config = rs.conf();
        newMembers = [];
        for (var i = 0; i < config.members.length; i++) {
          if (config.members[i].host != '$UNREACHABLE_NODE') {
            newMembers.push(config.members[i]);
          }
        }
        // Reset _id values
        for (var i = 0; i < newMembers.length; i++) {
          newMembers[i]._id = i;
        }
        config.members = newMembers;
        result = rs.reconfig(config, {force: true});
        print(JSON.stringify(result));
      } catch(e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      echo "$FORCE_REMOVE_RESULT"
      
      if [[ "$FORCE_REMOVE_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Không thể xóa node khỏi replica set.${NC}"
        exit 1
      fi
    fi
    
    echo -e "${GREEN}Đã xóa node khỏi replica set.${NC}"
    
    # Hiển thị thông tin để sửa trên server không reachable
    echo -e "${YELLOW}Hướng dẫn sửa lỗi trên server không reachable:${NC}"
    echo -e "${YELLOW}1. Kiểm tra trạng thái MongoDB:${NC}"
    echo "   systemctl status mongod"
    echo -e "${YELLOW}2. Kiểm tra log MongoDB:${NC}"
    echo "   tail -n 50 /var/log/mongodb/mongod.log"
    echo -e "${YELLOW}3. Kiểm tra cấu hình MongoDB:${NC}"
    echo "   cat /etc/mongod.conf"
    echo -e "${YELLOW}4. Kiểm tra keyfile:${NC}"
    echo "   ls -l /etc/mongodb-keyfile"
    echo -e "${YELLOW}5. Kiểm tra quyền truy cập:${NC}"
    echo "   ls -l /var/lib/mongodb"
    echo "   ls -l /var/log/mongodb"
    echo -e "${YELLOW}6. Khởi động lại MongoDB:${NC}"
    echo "   systemctl restart mongod"
    
    # Hỏi xem có muốn thêm lại node không
    read -p "Đã sửa xong lỗi? Thêm lại node vào replica set? [y/N]: " ADD_BACK
    if [[ "$ADD_BACK" =~ ^[Yy]$ ]]; then
      # Có phải là arbiter không?
      read -p "Node này có phải là arbiter không? [y/N]: " IS_ARBITER
      
      if [[ "$IS_ARBITER" =~ ^[Yy]$ ]]; then
        # Thêm lại dưới dạng arbiter
        echo -e "${YELLOW}Thêm lại node dưới dạng arbiter...${NC}"
        ADD_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
        try {
          result = rs.addArb('$UNREACHABLE_HOST:$UNREACHABLE_PORT');
          print(JSON.stringify(result));
        } catch(e) {
          print('ERROR: ' + e.message);
        }
        ")
      else
        # Thêm lại dưới dạng thường
        echo -e "${YELLOW}Thêm lại node dưới dạng thường...${NC}"
        ADD_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
        try {
          result = rs.add('$UNREACHABLE_HOST:$UNREACHABLE_PORT');
          print(JSON.stringify(result));
        } catch(e) {
          print('ERROR: ' + e.message);
        }
        ")
      fi
      
      echo "$ADD_RESULT"
      
      if [[ "$ADD_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Lỗi khi thêm lại node vào replica set.${NC}"
        exit 1
      fi
      
      echo -e "${GREEN}Đã thêm lại node vào replica set.${NC}"
    fi
    ;;
    
  6)
    # Thay đổi port của node trong replica set
    echo -e "${BLUE}===== THAY ĐỔI PORT CỦA NODE TRONG REPLICA SET =====${NC}"
    
    # Kiểm tra trạng thái replica set
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
    
    echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET =====${NC}"
    echo "$STATUS"
    
    # Hiển thị cấu hình replica set
    CONFIG=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      config = rs.conf();
      print('CONFIG_MEMBERS:' + config.members.length);
      for (var i = 0; i < config.members.length; i++) {
        print('CONFIG_MEMBER_' + i + ':' + config.members[i].host + ':' + 
              'arbiter:' + (config.members[i].arbiterOnly || false) + ':' +
              'priority:' + (config.members[i].priority || 1));
      }
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== CẤU HÌNH REPLICA SET =====${NC}"
    echo "$CONFIG"
    
    # Chọn node để thay đổi port
    read -p "Nhập node cần thay đổi port (ví dụ: 36.50.134.16:27018): " OLD_NODE
    
    # Tách host và port
    NODE_HOST=$(echo $OLD_NODE | cut -d':' -f1)
    OLD_PORT=$(echo $OLD_NODE | cut -d':' -f2)
    
    # Nhập port mới
    read -p "Nhập port mới: " NEW_PORT
    
    # Xác định xem node có phải là PRIMARY không
    IS_PRIMARY=$(echo "$STATUS" | grep "$OLD_NODE" | grep -i "PRIMARY")
    
    if [ -n "$IS_PRIMARY" ]; then
      echo -e "${YELLOW}Cảnh báo: Node này là PRIMARY. Cần step down trước khi thay đổi.${NC}"
      read -p "Tiếp tục? [y/N]: " CONTINUE_PRIMARY
      if [[ ! "$CONTINUE_PRIMARY" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Hủy thao tác.${NC}"
        exit 0
      fi
      
      # Step down PRIMARY
      echo -e "${YELLOW}Thực hiện step down...${NC}"
      STEP_DOWN_RESULT=$(mongosh --host $OLD_NODE -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
      try {
        result = db.adminCommand({replSetStepDown: 60, force: true});
        print(JSON.stringify(result));
      } catch(e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      echo "$STEP_DOWN_RESULT"
    fi
    
    # Tìm _id của node
    NODE_ID=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      config = rs.conf();
      for (var i = 0; i < config.members.length; i++) {
        if (config.members[i].host == '$OLD_NODE') {
          print('ID:' + config.members[i]._id);
          break;
        }
      }
    } catch(e) {
      print('ERROR:' + e.message);
    }
    " | grep "ID:" | cut -d':' -f2)
    
    if [ -z "$NODE_ID" ]; then
      echo -e "${RED}Không tìm thấy node trong cấu hình replica set.${NC}"
      exit 1
    fi
    
    # Cập nhật cấu hình replica set
    echo -e "${YELLOW}Cập nhật cấu hình replica set...${NC}"
    UPDATE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      config = rs.conf();
      for (var i = 0; i < config.members.length; i++) {
        if (config.members[i]._id == $NODE_ID) {
          config.members[i].host = '$NODE_HOST:$NEW_PORT';
          break;
        }
      }
      result = rs.reconfig(config);
      print(JSON.stringify(result));
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$UPDATE_RESULT"
    
    if [[ "$UPDATE_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi cập nhật cấu hình replica set.${NC}"
      echo -e "${YELLOW}Thử force update...${NC}"
      
      UPDATE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
      try {
        config = rs.conf();
        for (var i = 0; i < config.members.length; i++) {
          if (config.members[i]._id == $NODE_ID) {
            config.members[i].host = '$NODE_HOST:$NEW_PORT';
            break;
          }
        }
        result = rs.reconfig(config, {force: true});
        print(JSON.stringify(result));
      } catch(e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      echo "$UPDATE_RESULT"
      
      if [[ "$UPDATE_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Không thể cập nhật cấu hình replica set.${NC}"
        exit 1
      fi
    fi
    
    echo -e "${GREEN}Đã thay đổi port của node $OLD_NODE thành $NODE_HOST:$NEW_PORT.${NC}"
    echo -e "${YELLOW}Lưu ý: Cần cập nhật cấu hình MongoDB trên server $NODE_HOST để sử dụng port $NEW_PORT.${NC}"
    ;;
    
  7)
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