#!/bin/bash

#============================================================
# THIẾT LẬP MONGODB REPLICA SET
# Script này tự động thiết lập MongoDB Replica Set với 4 node
# trên một máy duy nhất với các port khác nhau
#============================================================

# URL SETTING: https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/

# Biến cấu hình
SKIP_USER_CREATION=${SKIP_USER_CREATION:-false}  # Đặt thành true nếu đã tạo user từ trước
USE_AUTH_FROM_START=${USE_AUTH_FROM_START:-false}  # Đặt thành true nếu muốn bật xác thực từ đầu
MONGODB_USER="manhgdev"
MONGODB_PASSWORD="manhdepzai"
# Danh sách các port MongoDB
MONGODB_PORTS=(27017 27018 27019 27020)
# Danh sách các đường dẫn dữ liệu tương ứng
MONGODB_PATHS=("/data/rs0" "/data/rs1" "/data/rs2" "/data/rs")
# Danh sách các file log tương ứng
MONGODB_LOGS=("/var/log/mongodb/mongod.log" "/var/log/mongodb/mongod0.log" "/var/log/mongodb/mongod1.log" "/var/log/mongodb/mongod2.log")
# Danh sách các file cấu hình tương ứng
MONGODB_CONFIGS=("/etc/mongod.conf" "/etc/mongod0.conf" "/etc/mongod1.conf" "/etc/mongod2.conf")

# BƯỚC 0: Cài đặt MongoDB nếu chưa có
if ! command -v mongod &> /dev/null; then
  echo "MongoDB chưa được cài đặt. Đang cài đặt MongoDB..."
  sudo apt update && sudo apt install -y curl gnupg netcat-openbsd
  sudo rm -f /usr/share/keyrings/mongodb-server-8.0.gpg
  curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
  sudo apt-get update
  sudo apt-get install -y mongodb-org
  
  # Khởi động dịch vụ MongoDB
  sleep 1
  sudo systemctl daemon-reload
  sudo systemctl start mongod 
  sudo systemctl enable mongod
  
  # Đợi MongoDB khởi động
  echo "Đợi MongoDB khởi động..."
  sleep 2
  
  # Xác nhận MongoDB đã được cài đặt
  if command -v mongod &> /dev/null; then
    echo "✅ MongoDB đã được cài đặt thành công"
    mongod --version
  else
    echo "❌ Có lỗi trong quá trình cài đặt MongoDB"
    echo "Kiểm tra đường dẫn của mongod:"
    sudo find / -name mongod 2>/dev/null || echo "Không tìm thấy mongod"
    
    # Thử thêm đường dẫn vào PATH
    export PATH=$PATH:/usr/bin:/usr/local/bin:/opt/mongodb/bin
    echo "Đã thêm các đường dẫn phổ biến vào PATH"
    
    if command -v mongod &> /dev/null; then
      echo "✅ Đã tìm thấy mongod sau khi cập nhật PATH"
    else
      echo "⚠️ Không thể tìm thấy mongod. Sẽ tiếp tục nhưng có thể gặp lỗi."
    fi
  fi
else
  echo "✅ MongoDB đã được cài đặt"
  mongod --version
fi

# BƯỚC 1: Dọn dẹp môi trường 
echo "Dừng tất cả các instance MongoDB hiện tại..."
sudo systemctl stop mongod 2>/dev/null || true
sudo killall mongod 2>/dev/null || true
sudo pkill -x mongod 2>/dev/null || true
sleep 3
# TODO: Nếu cài đặt lỗi thì mở comment dòng này
# sudo rm -f /tmp/mongodb-*.sock /data/rs*/mongod.lock /data/rs*/WiredTiger.lock

# Tạo KeyFile cho xác thực nếu chưa có
if [ ! -f /etc/mongodb-keyfile ]; then
  echo "Tạo keyfile cho xác thực..."
  sudo openssl rand -base64 756 > /tmp/mongodb-keyfile
  sudo mv /tmp/mongodb-keyfile /etc/mongodb-keyfile
  sudo chmod 400 /etc/mongodb-keyfile
  sudo chown mongodb:mongodb /etc/mongodb-keyfile
else
  echo "Keyfile đã tồn tại, sử dụng keyfile hiện có"
fi

# BƯỚC 2: Chuẩn bị thư mục dữ liệu
echo "Kiểm tra thư mục dữ liệu..."
# Tạo thư mục nếu chưa tồn tại
for DIR in "${MONGODB_PATHS[@]}" "/var/log/mongodb"; do
  if [ ! -d "$DIR" ]; then
    echo "Tạo thư mục $DIR"
    sudo mkdir -p "$DIR"
  else
    echo "Thư mục $DIR đã tồn tại"
  fi
done

# Đảm bảo quyền truy cập đúng cho tất cả thư mục
echo "Đảm bảo quyền truy cập cho các thư mục dữ liệu..."
sudo chown -R mongodb:mongodb /data/rs{,0,1,2} /var/log/mongodb
sudo chmod -R 777 /data/rs{,0,1,2} /var/log/mongodb

# BƯỚC 3: Tạo file cấu hình
if [ ! -f /etc/mongod.conf.bak ]; then
  sudo cp /etc/mongod.conf /etc/mongod.conf.bak 2>/dev/null || true
fi

# Hàm tạo file cấu hình
create_config() {
  local port=$1
  local dbpath=$2
  local logpath=$3
  local config_file=$4
  local with_auth=$5  # true/false để bật xác thực
  
  if [ "$with_auth" = true ]; then
    cat << EOF | sudo tee $config_file > /dev/null
storage:
  dbPath: $dbpath
  
net:
  bindIp: 0.0.0.0
  port: $port

replication:
  replSetName: rs0

systemLog:
  destination: file
  path: $logpath
  logAppend: true

security:
  authorization: enabled
  keyFile: /etc/mongodb-keyfile
EOF
  else
    cat << EOF | sudo tee $config_file > /dev/null
storage:
  dbPath: $dbpath
  
net:
  bindIp: 0.0.0.0
  port: $port

replication:
  replSetName: rs0

systemLog:
  destination: file
  path: $logpath
  logAppend: true
EOF
  fi
  echo "✅ Đã tạo file cấu hình cho port $port tại $config_file"
}

# Tạo file cấu hình cho các node
echo "Tạo file cấu hình cho các node..."
for i in "${!MONGODB_PORTS[@]}"; do
  create_config "${MONGODB_PORTS[$i]}" "${MONGODB_PATHS[$i]}" "${MONGODB_LOGS[$i]}" "${MONGODB_CONFIGS[$i]}" "$USE_AUTH_FROM_START"
done

# BƯỚC 4: Kiểm tra liệu các port đã chạy sẵn chưa
check_mongodb_running() {
  local port=$1
  nc -z localhost $port && curl --silent --max-time 3 http://localhost:$port >/dev/null 2>&1
  return $?
}

# Hàm khởi động MongoDB với retry logic và hỗ trợ auth
start_mongodb() {
  local dbpath=$1
  local port=$2
  local logfile=$3
  local max_retries=3
  local retry=0
  local auth_params=""
  
  if [ "$USE_AUTH_FROM_START" = true ]; then
    auth_params="--keyFile=/etc/mongodb-keyfile --auth"
  fi
  
  if check_mongodb_running $port; then
    echo "✅ MongoDB port $port đã đang chạy"
    return 0
  fi
  
  echo "Khởi động MongoDB port $port..."
  while [ $retry -lt $max_retries ]; do
    # Xóa log hiện tại để dễ đọc
    [ -f "$logfile" ] && sudo truncate -s 0 "$logfile"
    
    # Thử phương pháp 1: Khởi động trực tiếp
    sudo mongod --dbpath=$dbpath --port=$port --replSet=rs0 $auth_params --fork --logpath=$logfile
    sleep 8
    
    if check_mongodb_running $port; then
      echo "✅ MongoDB port $port khởi động thành công"
      return 0
    fi
    
    # Đọc log để xem lỗi
    echo "Kiểm tra log lỗi: $(sudo tail -n 5 $logfile)"
    
    # Thử phương pháp 2: Khởi động với user mongodb
    echo "Thử lại với user mongodb..."
    sudo -u mongodb mongod --dbpath=$dbpath --port=$port --replSet=rs0 $auth_params --fork --logpath=$logfile
    sleep 8
    
    if check_mongodb_running $port; then
      echo "✅ MongoDB port $port khởi động thành công (với user mongodb)"
      return 0
    fi
    
    # Xóa lock files nếu có
    sudo rm -f $dbpath/mongod.lock $dbpath/WiredTiger.lock
    sudo rm -f /tmp/mongodb-$port.sock
    
    retry=$((retry+1))
    if [ $retry -lt $max_retries ]; then
      echo "Thử lại lần $((retry+1))..."
      sleep 5
    fi
  done
  
  echo "❌ Không thể khởi động MongoDB port $port sau $max_retries lần thử"
  return 1
}

# Tạo hàm khởi động mongodb với bảo mật
start_secure_mongodb() {
  local config_file=$1
  local port=$2
  local dbpath=$3
  local logfile=$4
  local max_retries=3
  local retry=0
  
  echo "Khởi động MongoDB port $port với bảo mật..."
  
  while [ $retry -lt $max_retries ]; do
    # Xóa log hiện tại để dễ đọc
    [ -f "$logfile" ] && sudo truncate -s 0 "$logfile"
    
    # Thử phương pháp 1: Sử dụng file cấu hình
    sudo mongod --config $config_file --fork
    sleep 8
    
    if check_mongodb_running $port; then
      echo "✅ MongoDB port $port khởi động thành công với file cấu hình"
      return 0
    fi
    
    # Đọc log để xem lỗi
    echo "Kiểm tra log lỗi: $(sudo tail -n 5 $logfile)"
    
    # Thử phương pháp 2: Khởi động trực tiếp
    sudo mongod --dbpath=$dbpath --port=$port --replSet=rs0 --keyFile=/etc/mongodb-keyfile --auth --fork --logpath=$logfile
    sleep 8
    
    if check_mongodb_running $port; then
      echo "✅ MongoDB port $port khởi động thành công với tham số trực tiếp"
      return 0
    fi
    
    # Thử phương pháp 3: Khởi động với user mongodb
    sudo -u mongodb mongod --dbpath=$dbpath --port=$port --replSet=rs0 --keyFile=/etc/mongodb-keyfile --auth --fork --logpath=$logfile
    sleep 8
    
    if check_mongodb_running $port; then
      echo "✅ MongoDB port $port khởi động thành công với user mongodb"
      return 0
    fi
    
    # Xóa lock files nếu có
    sudo rm -f $dbpath/mongod.lock $dbpath/WiredTiger.lock
    sudo rm -f /tmp/mongodb-$port.sock
    
    retry=$((retry+1))
    if [ $retry -lt $max_retries ]; then
      echo "Thử lại lần $((retry+1))..."
      sleep 5
    fi
  done
  
  echo "❌ Không thể khởi động MongoDB port $port với bảo mật sau $max_retries lần thử"
  return 1
}

# Khởi động và kiểm tra ngay từng node
echo "=== KHỞI ĐỘNG CÁC NODE MONGODB ==="
PORT_STATUS=()

# Khởi động node chính (port đầu tiên) - quan trọng nhất
echo "Khởi động node chính (${MONGODB_PORTS[0]})..."
start_mongodb "${MONGODB_PATHS[0]}" "${MONGODB_PORTS[0]}" "${MONGODB_LOGS[0]}"
if check_mongodb_running "${MONGODB_PORTS[0]}"; then
  PORT_STATUS[0]=1
  echo "✅ Port ${MONGODB_PORTS[0]} hoạt động tốt (NODE CHÍNH)"
else
  PORT_STATUS[0]=0
  echo "❌ Port ${MONGODB_PORTS[0]} KHÔNG HOẠT ĐỘNG - Node chính không khởi động được"
fi

# Khởi động các node thứ cấp
for i in $(seq 1 $((${#MONGODB_PORTS[@]}-1))); do
  start_mongodb "${MONGODB_PATHS[$i]}" "${MONGODB_PORTS[$i]}" "${MONGODB_LOGS[$i]}"
  if check_mongodb_running "${MONGODB_PORTS[$i]}"; then
    PORT_STATUS[$i]=1
    echo "✅ Port ${MONGODB_PORTS[$i]} hoạt động tốt"
  else
    PORT_STATUS[$i]=0
    echo "❌ Port ${MONGODB_PORTS[$i]} KHÔNG HOẠT ĐỘNG"
  fi
done

# BƯỚC 5: Đếm số node đang chạy
NODE_COUNT=0
PRIMARY_PORT=""
for i in {0..3}; do
  if [ "${PORT_STATUS[$i]}" -eq 1 ]; then
    NODE_COUNT=$((NODE_COUNT+1))
    # Lưu lại port đầu tiên tìm thấy để khởi tạo replica set
    if [ -z "$PRIMARY_PORT" ]; then
      case $i in
        0) PRIMARY_PORT="${MONGODB_PORTS[0]}" ;;
        1) PRIMARY_PORT="${MONGODB_PORTS[1]}" ;;
        2) PRIMARY_PORT="${MONGODB_PORTS[2]}" ;;
        3) PRIMARY_PORT="${MONGODB_PORTS[3]}" ;;
      esac
    fi
  fi
done

# Nếu không có node nào hoạt động, thoát script
if [ $NODE_COUNT -lt 1 ]; then
  echo "❌ Lỗi nghiêm trọng: Không có node nào hoạt động. Kiểm tra logs:"
  sudo tail -n 20 /var/log/mongodb/mongod*.log
  exit 1
fi

if [ $NODE_COUNT -lt 3 ]; then
  echo "⚠️ Cảnh báo: Chỉ có $NODE_COUNT node đang chạy. Replica set cần ít nhất 3 node để đảm bảo tính sẵn sàng cao."
else
  echo "✅ Có $NODE_COUNT MongoDB instances đang chạy"
fi

echo "Đợi 5 giây để các instance ổn định..."
sleep 5

# BƯỚC 6: Khởi tạo replica set
echo "=== THIẾT LẬP REPLICA SET ==="
echo "Sử dụng port $PRIMARY_PORT để khởi tạo replica set"

# Tạo danh sách thành viên
INIT_MEMBERS="["
MEMBER_ID=0
for i in "${!MONGODB_PORTS[@]}"; do
  PORT="${MONGODB_PORTS[$i]}"
  if check_mongodb_running "$PORT"; then
    PRIORITY="1"
    if [ "$PORT" = "${MONGODB_PORTS[0]}" ]; then
      PRIORITY="10"  # Ưu tiên port đầu tiên làm primary
    fi
    if [ $MEMBER_ID -gt 0 ]; then
      INIT_MEMBERS="$INIT_MEMBERS,"
    fi
    INIT_MEMBERS="$INIT_MEMBERS { _id: $MEMBER_ID, host: 'localhost:$PORT', priority: $PRIORITY }"
    MEMBER_ID=$((MEMBER_ID+1))
  fi
done
INIT_MEMBERS="$INIT_MEMBERS ]"

# Kiểm tra và khởi tạo replica set
echo "Kiểm tra trạng thái replica set hiện tại..."
RS_STATUS=$(mongosh --port $PRIMARY_PORT --quiet --norc --eval "
try {
  rs.status();
  print('EXISTS');
} catch (e) {
  print('NOT_INITIALIZED');
}
" 2>&1) || echo "ERROR"

if [[ "$RS_STATUS" == *"NOT_INITIALIZED"* ]]; then
  echo "Khởi tạo replica set..."
  INIT_RESULT=$(mongosh --port $PRIMARY_PORT --eval "
  try {
    const result = rs.initiate({
      _id: 'rs0',
      members: $INIT_MEMBERS
    });
    if (result.ok) {
      print('SUCCESS');
    } else {
      print('FAILED: ' + JSON.stringify(result));
    }
  } catch (e) {
    print('ERROR: ' + e.message);
  }
  " 2>&1)
  
  if [[ "$INIT_RESULT" == *"SUCCESS"* ]]; then
    echo "✅ Replica set khởi tạo thành công"
  else
    echo "⚠️ Có vấn đề khi khởi tạo replica set: $INIT_RESULT"
    echo "Thử lại với cấu hình đơn giản hơn..."
    mongosh --port $PRIMARY_PORT --eval "rs.initiate()" 2>&1
  fi
else
  echo "Replica set đã được khởi tạo từ trước"
fi

# Đợi replica set ổn định
echo "Đợi 5 giây để replica set ổn định..."
sleep 5

# BƯỚC 7: Chờ cho node primary sẵn sàng và tìm node primary
echo "Xác định node primary..."
PRIMARY_INFO=$(mongosh --port $PRIMARY_PORT --quiet --norc --eval "
try {
  for(let i=0; i<10; i++) {
    const status = rs.status();
    for(const member of status.members) {
      if(member.stateStr === 'PRIMARY') {
        print(member.name);
        quit();
      }
    }
    sleep(1000);
  }
  print('NOT_FOUND');
} catch(e) {
  print('ERROR: ' + e.message);
}
" 2>&1)

# Flag để kiểm tra xem có lỗi khi tìm primary node không
PRIMARY_ERROR=false

# Kiểm tra kết quả và xử lý lỗi
if [[ "$PRIMARY_INFO" == *":"* ]] && [[ "$PRIMARY_INFO" != *"ERROR"* ]] && [[ "$PRIMARY_INFO" != *"ECONNREFUSED"* ]]; then
  PRIMARY_PORT=$(echo "$PRIMARY_INFO" | cut -d':' -f2)
  echo "✅ Node primary tìm thấy: $PRIMARY_INFO (port $PRIMARY_PORT)"
else
  echo "⚠️ Không tìm được hoặc có lỗi khi xác định node primary: $PRIMARY_INFO"
  echo "Thử sử dụng port khởi tạo ban đầu: $PRIMARY_PORT"
  
  # Kiểm tra xem port này có hoạt động không
  if ! check_mongodb_running $PRIMARY_PORT; then
    echo "⚠️ Port $PRIMARY_PORT không hoạt động. Tìm port thay thế..."
    
    # Tìm port khác đang hoạt động
    for PORT in "${MONGODB_PORTS[@]}"; do
      if check_mongodb_running $PORT; then
        PRIMARY_PORT=$PORT
        echo "✅ Đã tìm thấy port thay thế: $PRIMARY_PORT"
        break
      fi
    done
    
    if ! check_mongodb_running $PRIMARY_PORT; then
      echo "❌ Không tìm thấy PRIMARY_PORT MongoDB nào đang hoạt động."
      PRIMARY_ERROR=true
    fi
  fi
fi

# BƯỚC 8: Tạo user quản trị
echo "=== TẠO USER QUẢN TRỊ ==="

# Bỏ qua bước tạo user nếu có chỉ định hoặc nếu có lỗi khi tìm primary node
if [ "$SKIP_USER_CREATION" = true ]; then
  echo "Bỏ qua bước tạo user vì đã được chỉ định (SKIP_USER_CREATION=true)"
  echo "Sử dụng thông tin user đã có:"
  echo "- User: $MONGODB_USER"
  echo "- Password: $MONGODB_PASSWORD" 
elif [ "$PRIMARY_ERROR" = true ]; then
  echo "Bỏ qua bước tạo user vì không thể xác định được primary node"
  echo "Tiếp tục với khởi động lại với bảo mật"
else
  echo "Tạo user quản trị trên port $PRIMARY_PORT..."

  # Kiểm tra kết nối trước khi thử tạo user
  if ! check_mongodb_running $PRIMARY_PORT; then
    echo "❌ Không thể kết nối tới MongoDB qua port $PRIMARY_PORT để tạo user"
    echo "Cố gắng tìm port khác đang hoạt động..."
    
    for PORT in "${MONGODB_PORTS[@]}"; do
      if check_mongodb_running $PORT; then
        PRIMARY_PORT=$PORT
        echo "✅ Đã tìm thấy port thay thế: $PRIMARY_PORT"
        break
      fi
    done
    
    if ! check_mongodb_running $PRIMARY_PORT; then
      echo "❌ Không tìm thấy port MongoDB nào đang hoạt động. Không thể tạo user."
      echo "Tiếp tục với khởi động lại với bảo mật"
    fi
  fi

  # Tiếp tục tạo user nếu có kết nối MongoDB
  if check_mongodb_running $PRIMARY_PORT; then
    # Kiểm tra xem user có tồn tại không
    USER_CHECK=$(mongosh --port $PRIMARY_PORT --eval "
    try {
      const adminDB = db.getSiblingDB('admin');
      const user = adminDB.getUser('$MONGODB_USER');
      if (user) {
        print('USER_EXISTS');
      } else {
        print('USER_NOT_FOUND');
      }
    } catch(e) {
      print('ERROR: ' + e.message);
    }
    " 2>&1)
    
    if [[ "$USER_CHECK" == *"USER_EXISTS"* ]]; then
      echo "✅ User $MONGODB_USER đã tồn tại, bỏ qua bước tạo user"
      SKIP_USER_CREATION=true
    else
      # Thử tạo user vài lần
      for attempt in {1..3}; do
        USER_RESULT=$(mongosh --port $PRIMARY_PORT --eval "
        try {
          db.getSiblingDB('admin').createUser({
            user: '$MONGODB_USER',
            pwd: '$MONGODB_PASSWORD',
            roles: [{ role: 'root', db: 'admin' }]
          });
          print('SUCCESS');
        } catch(e) {
          if(e.message.includes('already exists')) {
            print('EXISTS');
          } else {
            print('ERROR: ' + e.message);
          }
        }
        " 2>&1)
        
        if [[ "$USER_RESULT" == *"SUCCESS"* ]] || [[ "$USER_RESULT" == *"EXISTS"* ]]; then
          echo "✅ User quản trị đã được tạo hoặc đã tồn tại"
          break
        else
          echo "⚠️ Lần $attempt: Không thể tạo user: $USER_RESULT"
          if [ $attempt -lt 3 ]; then
            echo "Đợi 5 giây trước khi thử lại..."
            sleep 5
          fi
        fi
      done
    fi
    
    # Kiểm tra xác thực
    echo "Kiểm tra xác thực với user quản trị..."
    AUTH_TEST=$(mongosh --port $PRIMARY_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin --eval "
    try {
      print('Xác thực thành công!');
    } catch(e) {
      print('Lỗi xác thực: ' + e.message);
    }
    " 2>&1)
    
    if [[ "$AUTH_TEST" == *"Xác thực thành công"* ]]; then
      echo "✅ Xác thực với user quản trị thành công"
    else
      echo "⚠️ Xác thực thất bại: $AUTH_TEST"
      echo "Có thể tiếp tục với cấu hình không xác thực trước"
    fi
  else
    echo "❌ Không thể kết nối tới MongoDB. Bỏ qua bước tạo user."
  fi
fi

# BƯỚC 9: Dừng tất cả instances để chuẩn bị khởi động lại với bảo mật
echo "=== KHỞI ĐỘNG LẠI VỚI BẢO MẬT ==="

# Nếu đã bật xác thực từ đầu thì không cần khởi động lại
if [ "$USE_AUTH_FROM_START" = true ]; then
  echo "Đã khởi động với xác thực từ đầu, không cần khởi động lại"
else
  # Dừng tất cả các instances
  echo "Dừng tất cả các MongoDB instances..."
  sudo systemctl stop mongod 2>/dev/null || true
  sudo killall mongod 2>/dev/null || true
  sudo pkill -x mongod 2>/dev/null || true
  sleep 5

  # Đảm bảo không còn tiến trình MongoDB nào chạy
  if pgrep -x "mongod" > /dev/null; then
    echo "⚠️ Vẫn còn tiến trình MongoDB đang chạy. Cố gắng buộc dừng..."
    sudo pkill -9 -x mongod
    sleep 3
  fi

  # Cập nhật cấu hình với bảo mật
  echo "Cập nhật file cấu hình với bảo mật..."
  for i in "${!MONGODB_PORTS[@]}"; do
    create_config "${MONGODB_PORTS[$i]}" "${MONGODB_PATHS[$i]}" "${MONGODB_LOGS[$i]}" "${MONGODB_CONFIGS[$i]}" true
  done

  # Đảm bảo quyền truy cập đúng
  echo "Đảm bảo quyền truy cập đúng..."
  sudo chown -R mongodb:mongodb /etc/mongodb-keyfile
  sudo chmod 400 /etc/mongodb-keyfile
  sudo chown -R mongodb:mongodb /data/rs{,0,1,2} /var/log/mongodb
  sudo chmod -R 777 /data/rs{,0,1,2} /var/log/mongodb

  # Khởi động lại với bảo mật
  echo "Khởi động lại các MongoDB instances với bảo mật..."
  for i in "${!MONGODB_PORTS[@]}"; do
    start_secure_mongodb "${MONGODB_CONFIGS[$i]}" "${MONGODB_PORTS[$i]}" "${MONGODB_PATHS[$i]}" "${MONGODB_LOGS[$i]}"
  done
fi

# Kiểm tra các node sau khi khởi động lại
ACTIVE_COUNT=0
PRIMARY_PORT_SECURE=""
for PORT in "${MONGODB_PORTS[@]}"; do
  if check_mongodb_running $PORT; then
    echo "✅ Port $PORT: OK"
    ACTIVE_COUNT=$((ACTIVE_COUNT+1))
    if [ -z "$PRIMARY_PORT_SECURE" ]; then
      PRIMARY_PORT_SECURE=$PORT
    fi
  else
    echo "❌ Port $PORT: KHÔNG HOẠT ĐỘNG"
  fi
done

if [ $ACTIVE_COUNT -lt 1 ]; then
  echo "❌ Lỗi nghiêm trọng: Không thể khởi động MongoDB với xác thực."
  echo "Kiểm tra log: sudo tail -n 50 /var/log/mongodb/mongod*.log"
  exit 1
else
  echo "✅ Đã khởi động thành công $ACTIVE_COUNT MongoDB instances với bảo mật!"
fi

# BƯỚC 10: Hoàn tất và thông tin kết nối
echo "=== THIẾT LẬP MONGODB REPLICA SET HOÀN TẤT ==="
echo "Tóm tắt cấu hình:"
echo "- Số lượng node đang chạy: $ACTIVE_COUNT"
echo "- Port hoạt động: $(for PORT in "${MONGODB_PORTS[@]}"; do check_mongodb_running $PORT && echo -n "$PORT "; done)"
echo "- Primary node: $PRIMARY_PORT_SECURE (hoặc được chọn tự động trong replica set)"
echo "- Kết nối: mongosh --port 27017 --username $MONGODB_USER --password $MONGODB_PASSWORD --authenticationDatabase admin"
echo "- Kết nối: mongosh --host 'rs0/localhost:$PRIMARY_PORT_SECURE' -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin"

# Tạo chuỗi kết nối replica set với tất cả các port
RS_CONNECTION="rs0/"
first=true
for PORT in "${MONGODB_PORTS[@]}"; do
  if check_mongodb_running $PORT; then
    if [ "$first" = true ]; then
      RS_CONNECTION="${RS_CONNECTION}localhost:$PORT"
      first=false
    else
      RS_CONNECTION="${RS_CONNECTION},localhost:$PORT"
    fi
  fi
done

echo "- Kết nối với tất cả nodes: mongosh --host '$RS_CONNECTION' -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase admin"
echo "- Trạng thái replica set: rs.status()"
echo "- Kiểm tra primary: rs.isMaster()"
