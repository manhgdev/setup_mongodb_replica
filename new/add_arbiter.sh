#!/bin/bash
# add_arbiter.sh
# Script thêm MongoDB Arbiter Node vào Replica Set

# Thiết lập error handling
# set -e  # Tạm thời disable để tránh script bị terminate
# Disable trap để tránh script bị ngắt khi kill process
# trap 'echo -e "${RED}Script bị ngắt! Đang dọn dẹp...${NC}"; exit 1' INT TERM

# Lấy đường dẫn thư mục chứa script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load các hàm utility từ lib
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/get_current_ip.sh"
source "$LIB_DIR/check_mongodb_connection.sh"
source "$LIB_DIR/check_replica_set_status.sh"
source "$LIB_DIR/remove_duplicate_members.sh"
source "$LIB_DIR/create_keyfile.sh"

# Định nghĩa các biến môi trường
REPLICA_SET_NAME="rs0"
MONGODB_DATA_DIR="/var/lib/mongodb"
MONGODB_LOG_PATH="/var/log/mongodb/mongod.log"
MONGODB_CONFIG="/etc/mongod.conf"
MONGODB_KEYFILE="/etc/mongodb-keyfile"
MONGODB_USER="manhg"
MONGODB_PASS="manhnk"
ARBITER_PORT="27017"  # Sử dụng port mặc định MongoDB

# Hàm tạo cấu hình MongoDB cho Arbiter
create_arbiter_config() {
    local arbiter_ip=$1
    
    echo -e "${YELLOW}Tạo cấu hình MongoDB cho Arbiter...${NC}"
    
    # Tạo cấu hình đặc biệt cho Arbiter
    cat > "/tmp/mongod-arbiter.conf" << EOF
storage:
  dbPath: $MONGODB_DATA_DIR
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH
net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0
security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE
replication:
  replSetName: $REPLICA_SET_NAME
EOF
    
    # Copy cấu hình và set quyền
    sudo cp "/tmp/mongod-arbiter.conf" "$MONGODB_CONFIG"
    sudo mkdir -p "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")"
    sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")" 2>/dev/null || true
    
    echo -e "${GREEN}Đã tạo cấu hình MongoDB cho Arbiter${NC}"
}

# ==================== MAIN SCRIPT ====================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}     THIẾT LẬP MONGODB ARBITER NODE     ${NC}"
echo -e "${BLUE}========================================${NC}"

# Yêu cầu người dùng nhập IP của PRIMARY node
echo -e "${YELLOW}Vui lòng nhập IP của PRIMARY node:${NC}"
read -p "PRIMARY node IP: " PRIMARY_IP

# Kiểm tra IP PRIMARY hợp lệ
if [[ ! $PRIMARY_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}IP PRIMARY không hợp lệ. Vui lòng nhập lại.${NC}"
    exit 1
fi

# Tự động lấy IP của ARBITER node (node hiện tại)
ARBITER_IP=$(get_current_ip)
echo "ARBITER IP: $ARBITER_IP"

# Nếu không lấy được IP tự động, yêu cầu nhập
if [ -z "$ARBITER_IP" ] || [[ ! $ARBITER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}Không thể tự động lấy IP của node hiện tại.${NC}"
    echo -e "${YELLOW}Vui lòng nhập IP của ARBITER node (node hiện tại):${NC}"
    read -p "ARBITER node IP: " ARBITER_IP
    
    # Kiểm tra IP ARBITER hợp lệ
    if [[ ! $ARBITER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}IP ARBITER không hợp lệ. Vui lòng nhập lại.${NC}"
        exit 1
    fi
fi

PRIMARY_HOST="${PRIMARY_IP}:27017"
ARBITER_HOST="${ARBITER_IP}:${ARBITER_PORT}"

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB Arbiter Node...${NC}"
echo -e "${YELLOW}PRIMARY node: $PRIMARY_HOST${NC}"
echo -e "${YELLOW}ARBITER node: $ARBITER_HOST${NC}"

# Kiểm tra kết nối tới PRIMARY node
echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin"; then
    echo -e "${RED}Không thể kết nối tới PRIMARY node. Vui lòng kiểm tra lại.${NC}"
    echo -e "${YELLOW}Đảm bảo rằng:${NC}"
    echo -e "${YELLOW}1. PRIMARY node đang chạy${NC}"
    echo -e "${YELLOW}2. Thông tin xác thực ($MONGODB_USER/$MONGODB_PASS) chính xác${NC}"
    echo -e "${YELLOW}3. Firewall cho phép kết nối MongoDB${NC}"
    exit 1
fi

# Kiểm tra trạng thái replica set trên PRIMARY
echo -e "${YELLOW}Kiểm tra trạng thái replica set trên PRIMARY...${NC}"
RS_STATUS=$(check_replica_set_status "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin")
if [ "$RS_STATUS" != "1" ]; then
    echo -e "${RED}Replica Set chưa được cấu hình đúng trên PRIMARY node.${NC}"
    echo -e "${YELLOW}Vui lòng chạy setup_primary.sh trước khi thêm arbiter.${NC}"
    exit 1
fi

# Tạo keyfile từ PRIMARY node
create_keyfile "$PRIMARY_IP" "$MONGODB_KEYFILE"

# Kiểm tra keyfile
if [ ! -f "$MONGODB_KEYFILE" ]; then
    echo -e "${RED}Keyfile không tồn tại tại $MONGODB_KEYFILE${NC}"
    echo -e "${YELLOW}Vui lòng đảm bảo keyfile đã được tạo thành công.${NC}"
    exit 1
fi

# Tạo thư mục dữ liệu MongoDB cho Arbiter (nhỏ và không quan trọng)
echo -e "${YELLOW}Tạo thư mục dữ liệu MongoDB cho Arbiter...${NC}"
if [ ! -d "$MONGODB_DATA_DIR" ]; then
    sudo mkdir -p "$MONGODB_DATA_DIR"
    if getent passwd mongodb >/dev/null 2>&1; then
        sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR"
    fi
    echo -e "${GREEN}Đã tạo thư mục dữ liệu: $MONGODB_DATA_DIR${NC}"
else
    echo -e "${GREEN}Thư mục dữ liệu MongoDB đã tồn tại.${NC}"
fi

# Tạo thư mục log nếu chưa tồn tại
sudo mkdir -p "$(dirname "$MONGODB_LOG_PATH")"
if getent passwd mongodb >/dev/null 2>&1; then
    sudo chown -R mongodb:mongodb "$(dirname "$MONGODB_LOG_PATH")"
fi

# Tạo cấu hình MongoDB cho Arbiter
create_arbiter_config "$ARBITER_IP"

# Dừng MongoDB hiện tại nếu đang chạy
echo -e "${YELLOW}Dừng MongoDB hiện tại (nếu có)...${NC}"
sudo systemctl stop mongod 2>/dev/null || true
sleep 2

# Kiểm tra và dừng process mongod còn lại một cách an toàn
echo -e "${YELLOW}Kiểm tra process mongod còn lại...${NC}"

# Lấy danh sách process mongod (trừ script này)
MONGOD_PIDS=$(pgrep -f "mongod" 2>/dev/null | grep -v $$ | head -10 || true)

if [ ! -z "$MONGOD_PIDS" ]; then
    echo -e "${YELLOW}Tìm thấy process mongod đang chạy, đang dừng từng process...${NC}"
    
    # Dừng từng process một cách cẩn thận
    for pid in $MONGOD_PIDS; do
        if [ ! -z "$pid" ] && [ "$pid" != "$$" ]; then
            # Kiểm tra process có tồn tại không
            if kill -0 "$pid" 2>/dev/null; then
                echo "Đang dừng process mongod với PID: $pid"
                # Sử dụng SIGTERM trước
                sudo kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                
                # Kiểm tra process đã dừng chưa
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process $pid vẫn chạy, đợi thêm..."
                    sleep 2
                    
                    # Nếu vẫn chạy thì force kill
                    if kill -0 "$pid" 2>/dev/null; then
                        echo "Force kill process $pid"
                        sudo kill -9 "$pid" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
    
    # Đợi một chút để các process dừng hoàn toàn
    sleep 3
    
    # Kiểm tra lại có process nào còn lại không
    REMAINING_PIDS=$(pgrep -f "mongod" 2>/dev/null | grep -v $$ || true)
    if [ ! -z "$REMAINING_PIDS" ]; then
        echo -e "${YELLOW}Vẫn còn một số process mongod, thử dừng bằng pkill...${NC}"
        # Chỉ sử dụng pkill cho những process cụ thể
        sudo pkill -f "mongod --config" 2>/dev/null || true
        sudo pkill -f "mongod.conf" 2>/dev/null || true
        sleep 2
    fi
else
    echo -e "${GREEN}Không có process mongod nào đang chạy${NC}"
fi

# Xóa lock file nếu có
if [ -f "/var/lib/mongodb/mongod.lock" ]; then
    echo -e "${YELLOW}Xóa lock file...${NC}"
    sudo rm -f /var/lib/mongodb/mongod.lock
fi

# Xóa các lock file khác nếu có
if [ -f "$MONGODB_DATA_DIR/mongod.lock" ]; then
    echo -e "${YELLOW}Xóa lock file trong data directory...${NC}"
    sudo rm -f "$MONGODB_DATA_DIR/mongod.lock"
fi

# Kiểm tra và tạo thư mục pid nếu cần
echo -e "${YELLOW}Tạo thư mục pid...${NC}"
sudo mkdir -p /var/run/mongodb
if getent passwd mongodb >/dev/null 2>&1; then
    sudo chown mongodb:mongodb /var/run/mongodb
fi

echo -e "${GREEN}Hoàn thành việc dọn dẹp và chuẩn bị. Tiếp tục khởi động MongoDB...${NC}"

# Khởi động MongoDB với cấu hình Arbiter
echo -e "${YELLOW}Khởi động MongoDB Arbiter...${NC}"

# Dừng MongoDB hiện tại
sudo systemctl stop mongod 2>/dev/null || true
sudo pkill -f mongod 2>/dev/null || true
sleep 2

# Khởi động MongoDB
if sudo systemctl start mongod; then
    echo -e "${GREEN}MongoDB đã khởi động${NC}"
else
    nohup sudo -u mongodb mongod --config "$MONGODB_CONFIG" > /tmp/mongod.log 2>&1 &
    echo -e "${GREEN}MongoDB đã khởi động (direct)${NC}"
fi

sleep 5

# Kiểm tra MongoDB đã khởi động thành công
if ! pgrep -f mongod >/dev/null; then
    echo -e "${RED}MongoDB không khởi động được${NC}"
    exit 1
fi

echo -e "${GREEN}MongoDB Arbiter đã khởi động thành công!${NC}"

# Kiểm tra kết nối local
echo -e "${YELLOW}Kiểm tra kết nối local tới Arbiter...${NC}"
sleep 5

# Thử kết nối nhiều lần nếu cần
for i in {1..5}; do
    echo -e "${YELLOW}Thử kết nối lần $i...${NC}"
    if mongosh --port "$ARBITER_PORT" --quiet --eval "db.runCommand({ping: 1}).ok" 2>/dev/null; then
        echo -e "${GREEN}Kết nối thành công tới MongoDB Arbiter trên port $ARBITER_PORT${NC}"
        break
    else
        if [ $i -eq 5 ]; then
            echo -e "${RED}Không thể kết nối tới MongoDB Arbiter trên port $ARBITER_PORT${NC}"
            echo -e "${YELLOW}Kiểm tra port có đang được sử dụng:${NC}"
            sudo netstat -tlnp | grep ":$ARBITER_PORT " || echo "Port $ARBITER_PORT không được sử dụng"
            echo -e "${YELLOW}Kiểm tra process MongoDB:${NC}"
            ps aux | grep mongod | grep -v grep || echo "Không tìm thấy process mongod"
            exit 1
        else
            echo -e "${YELLOW}Kết nối thất bại, đợi 3 giây và thử lại...${NC}"
            sleep 3
        fi
    fi
done

# Xóa các member trùng lặp trước khi thêm arbiter
remove_duplicate_members "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin" "$ARBITER_HOST"

# Thêm Arbiter vào Replica Set từ PRIMARY
echo -e "${YELLOW}Đang thêm Arbiter vào Replica Set từ PRIMARY...${NC}"

# Kiểm tra lại kết nối PRIMARY trước khi thêm
echo -e "${YELLOW}Kiểm tra lại kết nối tới PRIMARY...${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin"; then
    echo -e "${RED}Mất kết nối tới PRIMARY node. Kiểm tra lại network.${NC}"
    exit 1
fi

ADD_RESULT=$(mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "
try {
    print('Trying rs.addArb...');
    rs.addArb('$ARBITER_HOST');
    print('SUCCESS');
} catch(e) {
    print('ERROR: ' + e.message);
}" 2>&1)

echo -e "${BLUE}Kết quả thêm Arbiter: $ADD_RESULT${NC}"

if [[ "$ADD_RESULT" == *"SUCCESS"* ]]; then
    echo -e "${GREEN}Đã thêm Arbiter vào Replica Set thành công!${NC}"
else
    echo -e "${YELLOW}Thử phương pháp thay thế để thêm Arbiter...${NC}"
    
    # Phương pháp thay thế: sử dụng rs.add với cấu hình đặc biệt
    ALT_RESULT=$(mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "
    try {
        print('Getting current config...');
        var cfg = rs.conf();
        var maxId = 0;
        for (var i = 0; i < cfg.members.length; i++) {
            if (cfg.members[i]._id > maxId) {
                maxId = cfg.members[i]._id;
            }
        }
        
        print('Adding arbiter with ID: ' + (maxId + 1));
        cfg.members.push({
            _id: maxId + 1,
            host: '$ARBITER_HOST',
            arbiterOnly: true,
            priority: 0,
            votes: 1
        });
        
        cfg.version += 1;
        print('Reconfiguring replica set...');
        rs.reconfig(cfg);
        print('SUCCESS');
    } catch(e) {
        print('ERROR: ' + e.message);
    }" 2>&1)
    
    echo -e "${BLUE}Kết quả phương pháp thay thế: $ALT_RESULT${NC}"
    
    if [[ "$ALT_RESULT" == *"SUCCESS"* ]]; then
        echo -e "${GREEN}Đã thêm Arbiter bằng phương pháp thay thế!${NC}"
    else
        echo -e "${RED}Không thể thêm Arbiter vào Replica Set.${NC}"
        echo -e "${RED}Lỗi chi tiết:${NC}"
        echo -e "${RED}$ALT_RESULT${NC}"
        
        echo -e "${YELLOW}Kiểm tra cấu hình replica set hiện tại:${NC}"
        mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "rs.conf()" 2>/dev/null || echo "Không thể lấy cấu hình"
        
        exit 1
    fi
fi

# Đợi một chút để Replica Set cập nhật
sleep 5

# Kiểm tra trạng thái Replica Set
echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --eval "
printjson(rs.status());
print('\\n=== REPLICA SET CONFIGURATION ===');
printjson(rs.conf());
"

# Kiểm tra đặc biệt xem arbiter có hoạt động không
echo -e "${YELLOW}Kiểm tra trạng thái Arbiter...${NC}"
ARBITER_STATUS=$(mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "
var status = rs.status();
for (var i = 0; i < status.members.length; i++) {
    if (status.members[i].name === '$ARBITER_HOST') {
        print('Arbiter State: ' + status.members[i].stateStr);
        print('Arbiter Health: ' + status.members[i].health);
        break;
    }
}
" 2>/dev/null)

echo "$ARBITER_STATUS"

# Hoàn thành
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}        MongoDB Arbiter Node đã được thiết lập thành công!      ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Thông tin Arbiter:${NC}"
echo -e "${BLUE}  - Host: $ARBITER_HOST${NC}"
echo -e "${BLUE}  - Role: Arbiter (chỉ tham gia voting, không lưu trữ data)${NC}"
echo -e "${BLUE}  - Priority: 0 (không thể trở thành Primary)${NC}"
echo -e "${BLUE}  - Votes: 1 (tham gia bầu chọn Primary)${NC}"
echo ""
echo -e "${GREEN}Bạn có thể kiểm tra trạng thái replica set với lệnh:${NC}"
echo -e "${GREEN}mongosh $PRIMARY_HOST -u $MONGODB_USER -p $MONGODB_PASS --authenticationDatabase admin --eval 'rs.status()'${NC}"
echo ""
echo -e "${YELLOW}Lưu ý: Arbiter không lưu trữ dữ liệu, chỉ tham gia bầu chọn để đảm bảo tính khả dụng cao của Replica Set.${NC}"
