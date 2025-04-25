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
  THIẾT LẬP VÀ KHẮC PHỤC ARBITER MONGODB - MANHG DEV
============================================================${NC}"

# Kiểm tra quyền sudo
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Script này cần quyền sudo để chạy${NC}"
    read -p "Bạn muốn tiếp tục với sudo không? (y/n): " RUN_SUDO
    if [[ "$RUN_SUDO" =~ ^[Yy]$ ]]; then
        echo "Chạy lại script với sudo..."
        sudo "$0" "$@"
        exit $?
    else
        echo -e "${RED}Thoát script.${NC}"
        exit 1
    fi
fi

# Hỏi người dùng muốn làm gì
echo -e "${YELLOW}=== CHỌN CHỨC NĂNG ===${NC}"
echo "1. Thêm arbiter mới vào replica set"
echo "2. Sửa lỗi arbiter đã tồn tại"
echo "3. Gỡ bỏ arbiter khỏi replica set"
read -p "Chọn chức năng [1]: " FUNCTION_CHOICE
FUNCTION_CHOICE=${FUNCTION_CHOICE:-1}

# Tham số mặc định
MONGODB_PORT="27017"
ARBITER_PORT="27018"
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
REPLICA_SET_NAME="rs0"
MONGODB_KEYFILE="/etc/mongodb-keyfile"

# Thu thập thông tin
echo -e "${YELLOW}=== THÔNG TIN KẾT NỐI ===${NC}"

read -p "Tên người dùng MongoDB [$USERNAME]: " USER_INPUT
USERNAME=${USER_INPUT:-$USERNAME}

read -p "Mật khẩu MongoDB [$PASSWORD]: " USER_INPUT
PASSWORD=${USER_INPUT:-$PASSWORD}

read -p "Port MongoDB chính [$MONGODB_PORT]: " USER_INPUT
MONGODB_PORT=${USER_INPUT:-$MONGODB_PORT}

read -p "Port cho arbiter [$ARBITER_PORT]: " USER_INPUT
ARBITER_PORT=${USER_INPUT:-$ARBITER_PORT}

read -p "Tên replica set [$REPLICA_SET_NAME]: " USER_INPUT
REPLICA_SET_NAME=${USER_INPUT:-$REPLICA_SET_NAME}

read -p "Địa chỉ IP của server này (để trống để tự phát hiện): " SERVER_IP
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Sử dụng địa chỉ IP: $SERVER_IP${NC}"
fi

# Kiểm tra trạng thái replica set trước
echo -e "${YELLOW}Kiểm tra trạng thái replica set...${NC}"
RS_STATUS=$(mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  config = rs.conf();
  print('TOTAL_MEMBERS: ' + config.members.length);
  for (var i = 0; i < status.members.length; i++) {
    print('MEMBER:' + status.members[i].name + ':' + status.members[i].stateStr + ':' + (status.members[i].arbiterOnly || false));
  }
  print('MASTER:' + (rs.isMaster().primary || 'NONE'));
} catch (e) {
  print('ERROR:' + e.message);
}
")

# Kiểm tra xem đã có arbiter chưa
EXISTING_ARBITER=$(echo "$RS_STATUS" | grep "MEMBER:.*:true" | cut -d':' -f2)
if [ -n "$EXISTING_ARBITER" ]; then
    echo -e "${YELLOW}Đã phát hiện arbiter hiện tại: $EXISTING_ARBITER${NC}"
    if [[ "$FUNCTION_CHOICE" == "1" ]]; then
        echo -e "${RED}Không thể thêm arbiter mới khi đã có arbiter tồn tại.${NC}"
        echo -e "${YELLOW}Vui lòng chọn chức năng 2 để sửa lỗi arbiter hiện tại hoặc 3 để gỡ bỏ.${NC}"
        exit 1
    fi
fi

# Kiểm tra port arbiter
echo -e "${YELLOW}Kiểm tra port $ARBITER_PORT...${NC}"
if lsof -i :$ARBITER_PORT | grep LISTEN; then
    echo -e "${RED}Port $ARBITER_PORT đang được sử dụng.${NC}"
    if [[ "$FUNCTION_CHOICE" == "1" ]]; then
        echo -e "${YELLOW}Đang kiểm tra arbiter hiện tại...${NC}"
        ARBITER_STATUS=$(echo "$RS_STATUS" | grep "MEMBER:.*$ARBITER_PORT")
        if [ -n "$ARBITER_STATUS" ]; then
            echo -e "${YELLOW}Port $ARBITER_PORT đang được sử dụng bởi arbiter hiện tại.${NC}"
            echo -e "${YELLOW}Vui lòng chọn chức năng 2 để sửa lỗi arbiter hiện tại hoặc 3 để gỡ bỏ.${NC}"
            exit 1
        else
            echo -e "${RED}Port $ARBITER_PORT đang được sử dụng bởi một process khác.${NC}"
            echo -e "${YELLOW}Vui lòng dừng process đó hoặc chọn port khác.${NC}"
            exit 1
        fi
    fi
else
    echo -e "${GREEN}✓ Port $ARBITER_PORT khả dụng${NC}"
fi

# 1. Kiểm tra và tạo thư mục log
echo -e "${YELLOW}Kiểm tra thư mục log...${NC}"
if [ ! -d "/var/log/mongodb" ]; then
    echo -e "${RED}Thư mục log không tồn tại. Tạo mới...${NC}"
    mkdir -p /var/log/mongodb
fi
touch /var/log/mongodb/mongod-arbiter.log
chown -R mongodb:mongodb /var/log/mongodb 2>/dev/null || chown -R mongod:mongod /var/log/mongodb 2>/dev/null
chmod 755 /var/log/mongodb
chmod 644 /var/log/mongodb/mongod-arbiter.log
echo -e "${GREEN}✓ Đã thiết lập thư mục log${NC}"

# 2. Kiểm tra thư mục data
echo -e "${YELLOW}Kiểm tra thư mục data...${NC}"
if [ ! -d "/var/lib/mongodb-arbiter" ]; then
    echo -e "${RED}Thư mục data không tồn tại. Tạo mới...${NC}"
    mkdir -p /var/lib/mongodb-arbiter
fi
chown -R mongodb:mongodb /var/lib/mongodb-arbiter 2>/dev/null || chown -R mongod:mongod /var/lib/mongodb-arbiter 2>/dev/null
chmod 755 /var/lib/mongodb-arbiter
echo -e "${GREEN}✓ Đã thiết lập thư mục data${NC}"

# 3. Kiểm tra keyfile
echo -e "${YELLOW}Kiểm tra keyfile...${NC}"
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại. Tạo mới...${NC}"
    openssl rand -base64 756 > "$MONGODB_KEYFILE"
fi
chmod 400 "$MONGODB_KEYFILE"
chown mongodb:mongodb "$MONGODB_KEYFILE" 2>/dev/null || chown mongod:mongod "$MONGODB_KEYFILE" 2>/dev/null
echo -e "${GREEN}✓ Đã thiết lập keyfile${NC}"

# 4. Kiểm tra mongod command
echo -e "${YELLOW}Kiểm tra lệnh mongod...${NC}"
if ! command -v mongod &> /dev/null; then
    echo -e "${RED}mongod không được tìm thấy. Kiểm tra cài đặt MongoDB.${NC}"
    MONGOD_PATH=$(find / -name mongod -type f -executable 2>/dev/null | head -n 1)
    if [ -n "$MONGOD_PATH" ]; then
        echo -e "${GREEN}Tìm thấy mongod tại: $MONGOD_PATH${NC}"
    else
        echo -e "${RED}Không tìm thấy mongod. Vui lòng cài đặt MongoDB trước.${NC}"
        exit 1
    fi
else
    MONGOD_PATH=$(which mongod)
    echo -e "${GREEN}✓ mongod được tìm thấy tại: $MONGOD_PATH${NC}"
fi

# 5. Kiểm tra user mongodb hoặc mongod
echo -e "${YELLOW}Kiểm tra user MongoDB...${NC}"
if id -u mongodb &>/dev/null; then
    MONGO_USER="mongodb"
    echo -e "${GREEN}✓ Sử dụng user mongodb${NC}"
elif id -u mongod &>/dev/null; then
    MONGO_USER="mongod"
    echo -e "${GREEN}✓ Sử dụng user mongod${NC}"
else
    echo -e "${RED}Không tìm thấy user mongodb hoặc mongod. Tạo user mongodb...${NC}"
    useradd -r -d /var/lib/mongodb -s /bin/false mongodb
    MONGO_USER="mongodb"
fi

# 6. Tạo file cấu hình cho arbiter
echo -e "${YELLOW}Tạo file cấu hình cho arbiter...${NC}"
cat > /etc/mongod-arbiter.conf << EOF
# Cấu hình MongoDB Arbiter
storage:
  dbPath: /var/lib/mongodb-arbiter

systemLog:
  destination: file
  path: /var/log/mongodb/mongod-arbiter.log
  logAppend: true

net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0

replication:
  replSetName: $REPLICA_SET_NAME

security:
  keyFile: $MONGODB_KEYFILE
EOF
echo -e "${GREEN}✓ Đã tạo file cấu hình${NC}"

# 7. Tạo service cho arbiter
echo -e "${YELLOW}Tạo service cho arbiter...${NC}"
cat > /etc/systemd/system/mongod-arbiter.service << EOF
[Unit]
Description=MongoDB Arbiter
After=network.target

[Service]
User=$MONGO_USER
Group=$MONGO_USER
ExecStart=$MONGOD_PATH --config /etc/mongod-arbiter.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
echo -e "${GREEN}✓ Đã tạo service${NC}"

# 8. Kiểm tra port
echo -e "${YELLOW}Kiểm tra port $ARBITER_PORT...${NC}"
if lsof -i :$ARBITER_PORT | grep LISTEN; then
    echo -e "${RED}Port $ARBITER_PORT đang được sử dụng. Chọn port khác...${NC}"
    NEW_PORT=$((ARBITER_PORT + 1))
    echo -e "${YELLOW}Thay đổi port arbiter thành $NEW_PORT${NC}"
    sed -i "s/port: $ARBITER_PORT/port: $NEW_PORT/g" /etc/mongod-arbiter.conf
    ARBITER_PORT=$NEW_PORT
else
    echo -e "${GREEN}✓ Port $ARBITER_PORT khả dụng${NC}"
fi

# 9. Kiểm tra và khởi động arbiter
if [[ "$FUNCTION_CHOICE" == "3" ]]; then
    # Bỏ qua khởi động arbiter trong chế độ gỡ bỏ
    echo -e "${YELLOW}Bỏ qua khởi động arbiter trong chế độ gỡ bỏ...${NC}"
else
    echo -e "${YELLOW}Khởi động arbiter...${NC}"
    systemctl daemon-reload
    systemctl stop mongod-arbiter 2>/dev/null
    systemctl start mongod-arbiter
    
    echo -e "${YELLOW}Đợi khởi động (5 giây)...${NC}"
    sleep 5
    
    if systemctl is-active --quiet mongod-arbiter; then
        echo -e "${GREEN}✓ Arbiter đã khởi động thành công!${NC}"
        systemctl enable mongod-arbiter
    else
        echo -e "${RED}Arbiter không thể khởi động.${NC}"
        echo -e "${YELLOW}Kiểm tra log:${NC}"
        journalctl -u mongod-arbiter -n 20 --no-pager
        
        echo -e "${YELLOW}Thử chạy mongod trực tiếp:${NC}"
        sudo -u $MONGO_USER $MONGOD_PATH --config /etc/mongod-arbiter.conf --fork
        
        if ! systemctl is-active --quiet mongod-arbiter; then
            echo -e "${RED}Không thể khởi động arbiter sau nhiều lần thử. Kiểm tra cấu hình.${NC}"
            if [[ "$FUNCTION_CHOICE" != "2" ]]; then
                exit 1
            fi
        fi
    fi
fi

# 10. Tìm PRIMARY trong replica set
echo -e "${YELLOW}Tìm PRIMARY trong replica set...${NC}"
RS_STATUS=$(mongosh --host 127.0.0.1:$MONGODB_PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  status = rs.status();
  for (var i = 0; i < status.members.length; i++) {
    if (status.members[i].stateStr === 'PRIMARY') {
      print('PRIMARY:' + status.members[i].name);
      quit();
    }
  }
  print('PRIMARY_NOT_FOUND');
} catch (e) {
  print('ERROR:' + e.message);
}
")

if [[ "$RS_STATUS" == PRIMARY:* ]]; then
  PRIMARY_HOST=$(echo "$RS_STATUS" | cut -d':' -f2-)
  echo -e "${GREEN}✓ Tìm thấy PRIMARY tại: $PRIMARY_HOST${NC}"
else
  echo -e "${RED}Không tìm thấy PRIMARY trong replica set${NC}"
  echo -e "${YELLOW}Vui lòng cung cấp địa chỉ của PRIMARY:${NC}"
  read -p "IP:Port của PRIMARY (ví dụ: 157.66.46.252:27017): " PRIMARY_HOST
  
  if [ -z "$PRIMARY_HOST" ]; then
    echo -e "${RED}Không có thông tin PRIMARY, không thể tiếp tục${NC}"
    exit 1
  fi
fi

# 11. Xử lý theo chức năng
case $FUNCTION_CHOICE in
  1)
    # Thêm arbiter mới
    echo -e "${YELLOW}=== THÊM ARBITER MỚI ===${NC}"
    
    # Thiết lập write concern mặc định
    echo -e "${YELLOW}Thiết lập write concern mặc định...${NC}"
    SET_DEFAULT_WRITE_CONCERN=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = db.adminCommand({
        setDefaultRWConcern: 1,
        defaultWriteConcern: { w: 'majority' }
      });
      if (result.ok) {
        print('SUCCESS: Đã thiết lập write concern mặc định');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$SET_DEFAULT_WRITE_CONCERN"
    
    echo -e "${YELLOW}Thêm arbiter từ PRIMARY ($PRIMARY_HOST)...${NC}"
    ADD_ARBITER_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = rs.addArb('$SERVER_IP:$ARBITER_PORT');
      if (result.ok) {
        print('SUCCESS: Arbiter đã được thêm thành công');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$ADD_ARBITER_RESULT"
    
    if [[ "$ADD_ARBITER_RESULT" == *"SUCCESS"* ]]; then
        echo -e "${GREEN}✓ Arbiter đã được thêm vào replica set!${NC}"
    elif [[ "$ADD_ARBITER_RESULT" == *"already exists"* ]]; then
        echo -e "${YELLOW}⚠️ Arbiter đã tồn tại trong replica set.${NC}"
    else
        echo -e "${RED}⚠️ Có vấn đề khi thêm arbiter.${NC}"
    fi
    ;;
    
  2)
    # Sửa lỗi arbiter
    echo -e "${YELLOW}=== SỬA LỖI ARBITER ===${NC}"
    echo -e "${YELLOW}Kiểm tra xem arbiter đã có trong replica set chưa...${NC}"
    
    # Thiết lập write concern mặc định
    echo -e "${YELLOW}Thiết lập write concern mặc định...${NC}"
    SET_DEFAULT_WRITE_CONCERN=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = db.adminCommand({
        setDefaultRWConcern: 1,
        defaultWriteConcern: { w: 'majority' }
      });
      if (result.ok) {
        print('SUCCESS: Đã thiết lập write concern mặc định');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$SET_DEFAULT_WRITE_CONCERN"
    
    CHECK_ARBITER=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      const config = rs.conf();
      let arbiterFound = false;
      let arbiterHost = '$SERVER_IP:$ARBITER_PORT';
      
      for (let i = 0; i < config.members.length; i++) {
        if (config.members[i].host === arbiterHost) {
          if (config.members[i].arbiterOnly) {
            print('ARBITER_EXISTS');
          } else {
            print('HOST_EXISTS_NOT_ARBITER');
          }
          arbiterFound = true;
          break;
        }
      }
      
      if (!arbiterFound) {
        print('ARBITER_NOT_FOUND');
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    if [[ "$CHECK_ARBITER" == "ARBITER_EXISTS" ]]; then
      echo -e "${GREEN}✓ Arbiter đã tồn tại trong replica set${NC}"
      echo -e "${YELLOW}Gỡ bỏ arbiter hiện tại và thêm lại...${NC}"
      
      REMOVE_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
      try {
        result = rs.remove('$SERVER_IP:$ARBITER_PORT');
        if (result.ok) {
          print('SUCCESS');
        } else {
          print('ERROR: ' + result.errmsg);
        }
      } catch (e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      if [[ "$REMOVE_RESULT" == "SUCCESS" ]]; then
        echo -e "${GREEN}✓ Đã gỡ bỏ arbiter${NC}"
      else
        echo -e "${RED}Lỗi khi gỡ bỏ arbiter: $REMOVE_RESULT${NC}"
      fi
      
      echo -e "${YELLOW}Đợi 5 giây trước khi thêm lại...${NC}"
      sleep 5
    elif [[ "$CHECK_ARBITER" == "HOST_EXISTS_NOT_ARBITER" ]]; then
      echo -e "${RED}Host đã tồn tại nhưng không phải là arbiter${NC}"
      echo -e "${YELLOW}Gỡ bỏ host hiện tại và thêm lại dưới dạng arbiter...${NC}"
      
      REMOVE_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
      try {
        result = rs.remove('$SERVER_IP:$ARBITER_PORT');
        if (result.ok) {
          print('SUCCESS');
        } else {
          print('ERROR: ' + result.errmsg);
        }
      } catch (e) {
        print('ERROR: ' + e.message);
      }
      ")
      
      if [[ "$REMOVE_RESULT" == "SUCCESS" ]]; then
        echo -e "${GREEN}✓ Đã gỡ bỏ host${NC}"
      else
        echo -e "${RED}Lỗi khi gỡ bỏ host: $REMOVE_RESULT${NC}"
      fi
      
      echo -e "${YELLOW}Đợi 5 giây trước khi thêm lại...${NC}"
      sleep 5
    elif [[ "$CHECK_ARBITER" == "ARBITER_NOT_FOUND" ]]; then
      echo -e "${YELLOW}Arbiter chưa có trong replica set. Sẽ thêm mới...${NC}"
    else
      echo -e "${RED}Lỗi khi kiểm tra: $CHECK_ARBITER${NC}"
    fi
    
    # Thêm arbiter vào replica set
    echo -e "${YELLOW}Thêm arbiter vào replica set...${NC}"
    ADD_ARBITER_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = rs.addArb('$SERVER_IP:$ARBITER_PORT');
      if (result.ok) {
        print('SUCCESS: Arbiter đã được thêm thành công');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$ADD_ARBITER_RESULT"
    
    if [[ "$ADD_ARBITER_RESULT" == *"SUCCESS"* ]]; then
        echo -e "${GREEN}✓ Arbiter đã được thêm vào replica set!${NC}"
    elif [[ "$ADD_ARBITER_RESULT" == *"already exists"* ]]; then
        echo -e "${YELLOW}⚠️ Arbiter đã tồn tại trong replica set.${NC}"
    else
        echo -e "${RED}⚠️ Có vấn đề khi thêm arbiter.${NC}"
    fi
    ;;
    
  3)
    # Gỡ bỏ arbiter
    echo -e "${YELLOW}=== GỠ BỎ ARBITER ===${NC}"
    echo -e "${RED}Cảnh báo: Bạn sắp gỡ bỏ arbiter khỏi replica set.${NC}"
    read -p "Bạn có chắc chắn muốn tiếp tục? (y/n): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Đã hủy thao tác gỡ bỏ.${NC}"
      exit 0
    fi
    
    # Thiết lập write concern mặc định
    echo -e "${YELLOW}Thiết lập write concern mặc định...${NC}"
    SET_DEFAULT_WRITE_CONCERN=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = db.adminCommand({
        setDefaultRWConcern: 1,
        defaultWriteConcern: { w: 'majority' }
      });
      if (result.ok) {
        print('SUCCESS: Đã thiết lập write concern mặc định');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$SET_DEFAULT_WRITE_CONCERN"
    
    echo -e "${YELLOW}Gỡ bỏ arbiter từ PRIMARY ($PRIMARY_HOST)...${NC}"
    REMOVE_RESULT=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
    try {
      result = rs.remove('$SERVER_IP:$ARBITER_PORT');
      if (result.ok) {
        print('SUCCESS: Arbiter đã được gỡ bỏ thành công');
      } else {
        print('ERROR: ' + result.errmsg);
      }
    } catch (e) {
      print('ERROR: ' + e.message);
    }
    ")
    
    echo "$REMOVE_RESULT"
    
    if [[ "$REMOVE_RESULT" == *"SUCCESS"* ]]; then
        echo -e "${GREEN}✓ Arbiter đã được gỡ bỏ khỏi replica set!${NC}"
        
        echo -e "${YELLOW}Dừng và vô hiệu hóa service arbiter...${NC}"
        systemctl stop mongod-arbiter
        systemctl disable mongod-arbiter
        echo -e "${GREEN}✓ Đã dừng service arbiter${NC}"
        
        read -p "Bạn có muốn xóa dữ liệu arbiter không? (y/n): " DELETE_DATA
        if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
          echo -e "${YELLOW}Xóa thư mục dữ liệu arbiter...${NC}"
          rm -rf /var/lib/mongodb-arbiter/*
          echo -e "${GREEN}✓ Đã xóa dữ liệu arbiter${NC}"
        fi
    else
        echo -e "${RED}⚠️ Có vấn đề khi gỡ bỏ arbiter.${NC}"
    fi
    ;;
    
  *)
    echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    exit 1
    ;;
esac

# 12. Hiển thị trạng thái replica set
echo -e "${YELLOW}=== TRẠNG THÁI REPLICA SET ===${NC}"
mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "rs.status()" | grep -E "name|stateStr"

# 13. Hiển thị cấu hình replica set
echo -e "${YELLOW}=== CẤU HÌNH REPLICA SET ===${NC}"
REPLICA_CONFIG=$(mongosh --host "$PRIMARY_HOST" -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --quiet --eval "
try {
  config = rs.conf();
  print('TOTAL_MEMBERS: ' + config.members.length);
  for (let i = 0; i < config.members.length; i++) {
    let member = config.members[i];
    print('MEMBER_' + i + ': ' + member.host + ' (arbiterOnly: ' + member.arbiterOnly + ', priority: ' + (member.priority || 1) + ')');
  }
} catch (e) {
  print('ERROR: ' + e.message);
}
")
echo "$REPLICA_CONFIG"

echo -e "${BLUE}
============================================================
  HOÀN THÀNH THIẾT LẬP/KHẮC PHỤC ARBITER
============================================================${NC}"

if [[ "$FUNCTION_CHOICE" != "3" ]]; then
  echo -e "${GREEN}Arbiter đã được cấu hình tại: $SERVER_IP:$ARBITER_PORT${NC}"
  echo -e "${YELLOW}Lệnh để kiểm tra trạng thái replica set:${NC}"
  echo -e "  mongosh --host \"$PRIMARY_HOST\" -u \"$USERNAME\" -p \"$PASSWORD\" --authenticationDatabase \"$AUTH_DB\" --eval \"rs.status()\""
  
  # Kiểm tra số thành viên trong replica set
  if [[ "$REPLICA_CONFIG" == *"TOTAL_MEMBERS: 3"* || "$REPLICA_CONFIG" == *"TOTAL_MEMBERS: 4"* || "$REPLICA_CONFIG" == *"TOTAL_MEMBERS: 5"* ]]; then
    echo -e "${GREEN}✓ Replica set có đủ thành viên (3+) để đạt majority và có thể thực hiện bầu PRIMARY khi cần.${NC}"
  else
    echo -e "${YELLOW}⚠️ Replica set chỉ có 2 thành viên. Bạn vẫn có thể gặp vấn đề khi bầu PRIMARY.${NC}"
    echo -e "${YELLOW}   Xem xét thêm thêm một arbiter hoặc node dữ liệu khác.${NC}"
  fi
fi 