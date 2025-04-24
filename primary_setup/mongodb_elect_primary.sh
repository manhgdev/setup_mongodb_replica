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
    echo -e "${YELLOW}Danh sách các server hiện có trong replica set:${NC}"
    echo "$CURRENT_STATUS" | grep "MEMBER:" | cut -d':' -f2,3 | sed 's/^/  /'
    
    read -p "Nhập tên server (IP hoặc hostname) sẽ nhận PRIMARY: " TARGET_HOST
    
    # Kiểm tra xem server có tồn tại trong replica set không
    if ! echo "$CURRENT_STATUS" | grep -q "MEMBER:.*$TARGET_HOST"; then
      echo -e "${RED}Server $TARGET_HOST không tồn tại trong replica set.${NC}"
      exit 1
    fi
    
    # Lấy port của server đích từ trạng thái hiện tại
    TARGET_PORT=$(echo "$CURRENT_STATUS" | grep "MEMBER:.*$TARGET_HOST" | cut -d':' -f3 | cut -d' ' -f1)
    
    if [ -z "$TARGET_PORT" ]; then
      read -p "Port của server mới [27017]: " TARGET_PORT
      TARGET_PORT=${TARGET_PORT:-27017}
    fi
    
    # Kiểm tra xem server đích có phải là arbiter không
    IS_ARBITER=$(echo "$CURRENT_STATUS" | grep "MEMBER:.*$TARGET_HOST:.*ARBITER")
    if [ -n "$IS_ARBITER" ]; then
      echo -e "${RED}Không thể chuyển PRIMARY sang arbiter node.${NC}"
      exit 1
    fi
    
    # Force chuyển PRIMARY
    echo -e "${YELLOW}Thực hiện force chuyển PRIMARY...${NC}"
    
    # Bước 1: Step down PRIMARY hiện tại
    echo -e "${YELLOW}Bước 1: Step down PRIMARY hiện tại...${NC}"
    
    # Kiểm tra PRIMARY hiện tại
    PRIMARY_STATUS=$(mongosh "mongodb://$USERNAME:$PASSWORD@$PRIMARY_HOST:$PRIMARY_PORT/admin" --quiet --eval "
    try {
      status = rs.status();
      for (var i = 0; i < status.members.length; i++) {
        if (status.members[i].stateStr == 'PRIMARY') {
          print('PRIMARY:' + status.members[i].name);
          break;
        }
      }
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    if [[ "$PRIMARY_STATUS" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi kiểm tra PRIMARY:${NC}"
      echo "$PRIMARY_STATUS"
      exit 1
    fi
    
    CURRENT_PRIMARY=$(echo "$PRIMARY_STATUS" | grep "PRIMARY:" | cut -d':' -f2)
    if [ -z "$CURRENT_PRIMARY" ]; then
      echo -e "${RED}Không tìm thấy PRIMARY hiện tại.${NC}"
      exit 1
    fi
    
    # Step down PRIMARY
    STEP_DOWN_RESULT=$(mongosh "mongodb://$USERNAME:$PASSWORD@$CURRENT_PRIMARY/admin" --eval "
    try {
      result = db.adminCommand({replSetStepDown: 60, force: true});
      print(JSON.stringify(result));
    } catch(e) {
      if (e.message.includes('not primary')) {
        print('OK: Node đã không còn là PRIMARY');
      } else {
        print('ERROR: ' + e.message);
      }
    }
    ")
    
    if [[ "$STEP_DOWN_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi step down PRIMARY hiện tại:${NC}"
      echo "$STEP_DOWN_RESULT"
      exit 1
    fi
    
    echo -e "${GREEN}✓ Đã step down PRIMARY hiện tại${NC}"
    
    # Bước 2: Chờ bầu PRIMARY mới
    echo -e "${YELLOW}Bước 2: Chờ bầu PRIMARY mới...${NC}"
    sleep 15
    
    # Bước 3: Kiểm tra trạng thái cuối cùng
    echo -e "${YELLOW}Bước 3: Kiểm tra trạng thái cuối cùng...${NC}"
    FINAL_STATUS=$(mongosh "mongodb://$USERNAME:$PASSWORD@$TARGET_HOST:$TARGET_PORT/admin" --quiet --eval "
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
      echo -e "${GREEN}✓ Server $TARGET_HOST:$TARGET_PORT đã trở thành PRIMARY!${NC}"
    else
      echo -e "${YELLOW}⚠️ Server $TARGET_HOST:$TARGET_PORT chưa trở thành PRIMARY.${NC}"
      echo -e "${YELLOW}Có thể cần thêm thời gian để hoàn tất quá trình bầu cử.${NC}"
      echo -e "${YELLOW}Vui lòng kiểm tra lại sau vài phút.${NC}"
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
      config = rs.conf();
      print('CONFIG:' + JSON.stringify(config));
      for (var i = 0; i < status.members.length; i++) {
        print('MEMBER:' + status.members[i].name + ':' + 
              status.members[i].stateStr + ':' +
              'health:' + status.members[i].health + ':' +
              'uptime:' + status.members[i].uptime + ':' +
              'ping:' + (status.members[i].pingMs || 'N/A'));
      }
      print('MASTER:' + (rs.isMaster().primary || 'NONE'));
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET =====${NC}"
    echo "$STATUS"
    
    # Tìm các node không reachable/healthy
    UNHEALTHY_NODES=$(echo "$STATUS" | grep "MEMBER:" | grep -E ":(DOWN|UNKNOWN|REMOVED|ROLLBACK|STARTUP|RECOVERING):" | awk -F':' '{print $2 ":" $3}')
    UNREACHABLE_NODES=$(echo "$STATUS" | grep "MEMBER:" | grep ":0:" | awk -F':' '{print $2}')
    
    if [ -z "$UNHEALTHY_NODES" ] && [ -z "$UNREACHABLE_NODES" ]; then
      echo -e "${GREEN}✓ Tất cả các node đều healthy và reachable.${NC}"
      exit 0
    fi
    
    if [ -n "$UNHEALTHY_NODES" ]; then
      echo -e "${YELLOW}Các node không healthy:${NC}"
      echo "$UNHEALTHY_NODES" | sed 's/^/  /'
    fi
    
    if [ -n "$UNREACHABLE_NODES" ]; then
      echo -e "${YELLOW}Các node không reachable:${NC}"
      echo "$UNREACHABLE_NODES" | sed 's/^/  /'
    fi
    
    # Chọn node để sửa
    read -p "Nhập node cần sửa (ví dụ: 36.50.134.16:27018): " PROBLEM_NODE
    
    # Tách host và port
    PROBLEM_HOST=$(echo $PROBLEM_NODE | cut -d':' -f1)
    PROBLEM_PORT=$(echo $PROBLEM_NODE | cut -d':' -f2)
    
    # Lấy thông tin cấu hình của node
    NODE_CONFIG=$(echo "$STATUS" | grep "CONFIG:" | grep -o "{.*}" | jq -r ".members[] | select(.host==\"$PROBLEM_NODE\")")
    IS_ARBITER=$(echo "$NODE_CONFIG" | jq -r '.arbiterOnly // false')
    NODE_PRIORITY=$(echo "$NODE_CONFIG" | jq -r '.priority // 1')
    NODE_VOTES=$(echo "$NODE_CONFIG" | jq -r '.votes // 1')
    NODE_ID=$(echo "$NODE_CONFIG" | jq -r '._id')
    
    echo -e "${BLUE}===== THÔNG TIN NODE =====${NC}"
    echo "Host: $PROBLEM_HOST"
    echo "Port: $PROBLEM_PORT"
    echo "ID: $NODE_ID"
    echo "Arbiter: $IS_ARBITER"
    echo "Priority: $NODE_PRIORITY"
    echo "Votes: $NODE_VOTES"
    
    # Xóa node khỏi replica set
    echo -e "${YELLOW}Bước 1: Xóa node khỏi replica set...${NC}"
    REMOVE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
    try {
      result = rs.remove('$PROBLEM_NODE');
      print(JSON.stringify(result));
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    if [[ "$REMOVE_RESULT" == *"ERROR"* ]]; then
      echo -e "${YELLOW}Thử force remove...${NC}"
      
      # Force remove bằng cách reconfigure
      FORCE_REMOVE_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
      try {
        config = rs.conf();
        newMembers = [];
        for (var i = 0; i < config.members.length; i++) {
          if (config.members[i].host != '$PROBLEM_NODE') {
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
      
      if [[ "$FORCE_REMOVE_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Không thể xóa node khỏi replica set.${NC}"
        exit 1
      fi
    fi
    
    echo -e "${GREEN}✓ Đã xóa node khỏi replica set${NC}"
    
    # Hiển thị thông tin để sửa trên server không reachable
    echo -e "${BLUE}===== HƯỚNG DẪN SỬA LỖI =====${NC}"
    echo -e "${YELLOW}1. Kiểm tra kết nối mạng:${NC}"
    echo "   ping $PROBLEM_HOST"
    echo "   telnet $PROBLEM_HOST $PROBLEM_PORT"
    
    echo -e "${YELLOW}2. Kiểm tra trạng thái MongoDB:${NC}"
    echo "   systemctl status mongod"
    
    echo -e "${YELLOW}3. Kiểm tra log MongoDB:${NC}"
    echo "   tail -n 50 /var/log/mongodb/mongod.log"
    
    echo -e "${YELLOW}4. Kiểm tra cấu hình MongoDB:${NC}"
    echo "   cat /etc/mongod.conf"
    echo "   - Xác nhận bindIp và port"
    echo "   - Kiểm tra replication.replSetName"
    
    echo -e "${YELLOW}5. Kiểm tra keyfile:${NC}"
    echo "   ls -l /etc/mongodb-keyfile"
    echo "   - Quyền phải là 400"
    echo "   - Owner phải là mongodb:mongodb"
    
    echo -e "${YELLOW}6. Kiểm tra quyền truy cập:${NC}"
    echo "   ls -l /var/lib/mongodb"
    echo "   ls -l /var/log/mongodb"
    echo "   - Owner phải là mongodb:mongodb"
    
    echo -e "${YELLOW}7. Khởi động lại MongoDB:${NC}"
    echo "   systemctl restart mongod"
    echo "   systemctl status mongod"
    
    # Hỏi xem có muốn thêm lại node không
    read -p "Đã sửa xong lỗi? Thêm lại node vào replica set? [y/N]: " ADD_BACK
    if [[ "$ADD_BACK" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Bước 2: Thêm lại node vào replica set...${NC}"
      
      if [ "$IS_ARBITER" = "true" ]; then
        # Thêm lại dưới dạng arbiter
        echo -e "${YELLOW}Thêm lại node dưới dạng arbiter...${NC}"
        ADD_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
        try {
          result = rs.addArb('$PROBLEM_HOST:$PROBLEM_PORT');
          print(JSON.stringify(result));
        } catch(e) {
          print('ERROR: ' + e.message);
        }
        ")
      else
        # Thêm lại dưới dạng thường với priority và votes ban đầu
        echo -e "${YELLOW}Thêm lại node dưới dạng thường...${NC}"
        ADD_RESULT=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
        try {
          config = rs.conf();
          member = {
            _id: $NODE_ID,
            host: '$PROBLEM_HOST:$PROBLEM_PORT',
            priority: $NODE_PRIORITY,
            votes: $NODE_VOTES
          };
          result = rs.add(member);
          print(JSON.stringify(result));
        } catch(e) {
          print('ERROR: ' + e.message);
        }
        ")
      fi
      
      if [[ "$ADD_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Lỗi khi thêm lại node vào replica set.${NC}"
        exit 1
      fi
      
      echo -e "${GREEN}✓ Đã thêm lại node vào replica set${NC}"
      
      # Kiểm tra trạng thái cuối cùng
      echo -e "${YELLOW}Bước 3: Kiểm tra trạng thái cuối cùng...${NC}"
      sleep 5
      
      FINAL_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
      try {
        status = rs.status();
        for (var i = 0; i < status.members.length; i++) {
          if (status.members[i].name == '$PROBLEM_NODE') {
            print('NODE_STATUS:' + status.members[i].stateStr);
            print('NODE_HEALTH:' + status.members[i].health);
            break;
          }
        }
      } catch(e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      NODE_STATUS=$(echo "$FINAL_STATUS" | grep "NODE_STATUS:" | cut -d':' -f2)
      NODE_HEALTH=$(echo "$FINAL_STATUS" | grep "NODE_HEALTH:" | cut -d':' -f2)
      
      if [ "$NODE_HEALTH" = "1" ]; then
        echo -e "${GREEN}✓ Node đã hoạt động bình thường (health=1)${NC}"
        echo -e "${GREEN}✓ Trạng thái hiện tại: $NODE_STATUS${NC}"
      else
        echo -e "${YELLOW}⚠️ Node vẫn chưa healthy (health=$NODE_HEALTH)${NC}"
        echo -e "${YELLOW}⚠️ Trạng thái hiện tại: $NODE_STATUS${NC}"
        echo -e "${YELLOW}Vui lòng kiểm tra lại các bước sửa lỗi.${NC}"
      fi
    fi
    ;;
    
  6)
    # Thay đổi port của node trong replica set
    echo -e "${BLUE}===== THAY ĐỔI PORT CỦA NODE TRONG REPLICA SET =====${NC}"
    
    # Kiểm tra trạng thái replica set
    STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      status = rs.status();
      config = rs.conf();
      print('CONFIG:' + JSON.stringify(config));
      for (var i = 0; i < status.members.length; i++) {
        print('MEMBER:' + status.members[i].name + ':' + 
              status.members[i].stateStr + ':' +
              'health:' + status.members[i].health);
      }
      print('MASTER:' + (rs.isMaster().primary || 'NONE'));
    } catch(e) {
      print('ERROR:' + e.message);
    }
    ")
    
    echo -e "${BLUE}===== TRẠNG THÁI REPLICA SET =====${NC}"
    echo "$STATUS" | grep -v "CONFIG:"
    
    # Hiển thị cấu hình replica set
    CONFIG=$(echo "$STATUS" | grep "CONFIG:" | grep -o "{.*}")
    echo -e "${BLUE}===== CẤU HÌNH REPLICA SET =====${NC}"
    echo "$CONFIG" | jq -r '.members[] | "  " + .host + 
                          " (ID:" + (._id | tostring) + 
                          ", Priority:" + (.priority | tostring) + 
                          ", Votes:" + (.votes | tostring) + 
                          ", Arbiter:" + (.arbiterOnly | tostring) + ")"'
    
    # Chọn node để thay đổi port
    echo -e "${YELLOW}Chọn node để thay đổi port:${NC}"
    read -p "Nhập node cần thay đổi port (ví dụ: 36.50.134.16:27018): " OLD_NODE
    
    # Kiểm tra node có tồn tại không
    if ! echo "$STATUS" | grep -q "MEMBER:.*$OLD_NODE"; then
      echo -e "${RED}Node $OLD_NODE không tồn tại trong replica set.${NC}"
      exit 1
    fi
    
    # Tách host và port
    NODE_HOST=$(echo $OLD_NODE | cut -d':' -f1)
    OLD_PORT=$(echo $OLD_NODE | cut -d':' -f2)
    
    # Lấy thông tin cấu hình của node
    NODE_CONFIG=$(echo "$CONFIG" | jq -r ".members[] | select(.host==\"$OLD_NODE\")")
    IS_ARBITER=$(echo "$NODE_CONFIG" | jq -r '.arbiterOnly // false')
    NODE_PRIORITY=$(echo "$NODE_CONFIG" | jq -r '.priority // 1')
    NODE_VOTES=$(echo "$NODE_CONFIG" | jq -r '.votes // 1')
    NODE_ID=$(echo "$NODE_CONFIG" | jq -r '._id')
    
    # Kiểm tra port mới
    while true; do
      read -p "Nhập port mới: " NEW_PORT
      
      # Kiểm tra port có hợp lệ không
      if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Port phải là số.${NC}"
        continue
      fi
      
      if [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}Port phải từ 1024 đến 65535.${NC}"
        continue
      fi
      
      # Kiểm tra port có đang được sử dụng không
      if lsof -i :$NEW_PORT > /dev/null 2>&1; then
        echo -e "${RED}Port $NEW_PORT đang được sử dụng.${NC}"
        continue
      fi
      
      break
    done
    
    # Xác định xem node có phải là PRIMARY không
    IS_PRIMARY=$(echo "$STATUS" | grep "$OLD_NODE" | grep -i "PRIMARY")
    
    if [ -n "$IS_PRIMARY" ]; then
      echo -e "${YELLOW}⚠️ Cảnh báo: Node này là PRIMARY.${NC}"
      echo -e "${YELLOW}Cần step down trước khi thay đổi port.${NC}"
      read -p "Tiếp tục? [y/N]: " CONTINUE_PRIMARY
      if [[ ! "$CONTINUE_PRIMARY" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Hủy thao tác.${NC}"
        exit 0
      fi
      
      # Step down PRIMARY
      echo -e "${YELLOW}Bước 1: Step down PRIMARY...${NC}"
      STEP_DOWN_RESULT=$(mongosh --host $OLD_NODE -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "
      try {
        result = db.adminCommand({replSetStepDown: 60, force: true});
        print(JSON.stringify(result));
      } catch(e) {
        if (e.message.includes('not primary')) {
          print('OK: Node đã không còn là PRIMARY');
        } else {
          print('ERROR: ' + e.message);
        }
      }
      ")
      
      if [[ "$STEP_DOWN_RESULT" == *"ERROR"* ]]; then
        echo -e "${RED}Lỗi khi step down PRIMARY.${NC}"
        exit 1
      fi
      
      echo -e "${GREEN}✓ Đã step down PRIMARY${NC}"
      echo -e "${YELLOW}Chờ bầu PRIMARY mới...${NC}"
      sleep 15
    fi
    
    # Cập nhật cấu hình replica set
    echo -e "${YELLOW}Bước 2: Cập nhật cấu hình replica set...${NC}"
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
    
    if [[ "$UPDATE_RESULT" == *"ERROR"* ]]; then
      echo -e "${RED}Lỗi khi cập nhật cấu hình replica set.${NC}"
      exit 1
    fi
    
    echo -e "${GREEN}✓ Đã cập nhật cấu hình replica set${NC}"
    
    # Kiểm tra trạng thái cuối cùng
    echo -e "${YELLOW}Bước 3: Kiểm tra trạng thái cuối cùng...${NC}"
    sleep 5
    
    FINAL_STATUS=$(mongosh --host $CURRENT_HOST --port $CURRENT_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      status = rs.status();
      for (var i = 0; i < status.members.length; i++) {
        if (status.members[i].name == '$NODE_HOST:$NEW_PORT') {
          print('NODE_STATUS:' + status.members[i].stateStr);
          print('NODE_HEALTH:' + status.members[i].health);
          break;
        }
      }
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    NODE_STATUS=$(echo "$FINAL_STATUS" | grep "NODE_STATUS:" | cut -d':' -f2)
    NODE_HEALTH=$(echo "$FINAL_STATUS" | grep "NODE_HEALTH:" | cut -d':' -f2)
    
    echo -e "${GREEN}✓ Đã thay đổi port của node $OLD_NODE thành $NODE_HOST:$NEW_PORT${NC}"
    
    if [ "$NODE_HEALTH" = "1" ]; then
      echo -e "${GREEN}✓ Node đang hoạt động bình thường (health=1)${NC}"
      echo -e "${GREEN}✓ Trạng thái hiện tại: $NODE_STATUS${NC}"
    else
      echo -e "${YELLOW}⚠️ Node chưa healthy (health=$NODE_HEALTH)${NC}"
      echo -e "${YELLOW}⚠️ Trạng thái hiện tại: $NODE_STATUS${NC}"
    fi
    
    echo -e "${BLUE}===== HƯỚNG DẪN TIẾP THEO =====${NC}"
    echo -e "${YELLOW}1. Cập nhật cấu hình MongoDB trên server $NODE_HOST:${NC}"
    echo "   - Chỉnh sửa /etc/mongod.conf"
    echo "   - Thay đổi port thành $NEW_PORT"
    echo -e "${YELLOW}2. Khởi động lại MongoDB:${NC}"
    echo "   systemctl restart mongod"
    echo "   systemctl status mongod"
    echo -e "${YELLOW}3. Kiểm tra kết nối:${NC}"
    echo "   mongosh --host $NODE_HOST --port $NEW_PORT"
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