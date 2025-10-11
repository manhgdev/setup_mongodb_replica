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
MONGODB_DATA_DIR="/data/rs0-arbiter"
MONGODB_LOG_PATH="/var/log/mongodb/mongod-arbiter.log"
MONGODB_CONFIG="/etc/mongod-arbiter.conf"
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
echo "ARBITER_IP IP: $ARBITER_IP"

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
    # Tạo thư mục dữ liệu MongoDB cho Arbiter
echo -e "${YELLOW}Tạo thư mục dữ liệu MongoDB cho Arbiter...${NC}"
sudo mkdir -p "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")"
sudo chown -R mongodb:mongodb "$MONGODB_DATA_DIR" "$(dirname "$MONGODB_LOG_PATH")" 2>/dev/null || true

# Tạo cấu hình MongoDB cho Arbiter
create_arbiter_config "$ARBITER_IP"

# Khởi động MongoDB Arbiter trên port 27017
echo -e "${YELLOW}Khởi động MongoDB Arbiter trên port 27017...${NC}"

# Chỉ cần khởi động đơn giản
if sudo systemctl restart mongod; then
    echo -e "${GREEN}MongoDB đã khởi động trên port 27017${NC}"
else
    sudo mongod --config "$MONGODB_CONFIG" --fork
    echo -e "${GREEN}MongoDB đã khởi động trực tiếp trên port 27017${NC}"
fi

sleep 3

# Kiểm tra MongoDB đã khởi động thành công
if ! pgrep -f mongod >/dev/null; then
    echo -e "${RED}MongoDB không khởi động được${NC}"
    exit 1
fi

echo -e "${GREEN}MongoDB Arbiter đã khởi động thành công!${NC}"

# Kiểm tra kết nối local tới Arbiter
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
            exit 1
        else
            echo -e "${YELLOW}Kết nối thất bại, đợi 3 giây và thử lại...${NC}"
            sleep 3
        fi
    fi
done

# Xóa các member trùng lặp trước khi thêm arbiter
remove_duplicate_members "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin" "$ARBITER_HOST"

# Thiết lập write concern trước khi thêm arbiter (bắt buộc)
echo -e "${YELLOW}Thiết lập write concern cho replica set...${NC}"
WRITE_CONCERN_RESULT=$(mongosh --host "$PRIMARY_HOST" -u "$MONGODB_USER" -p "$MONGODB_PASS" --authenticationDatabase "admin" --quiet --eval "
try {
    // Kiểm tra write concern hiện tại
    var currentConcern = db.adminCommand({getDefaultRWConcern: 1});
    print('Current write concern: ' + JSON.stringify(currentConcern));
    
    // Thiết lập write concern mới nếu chưa có
    if (!currentConcern.defaultWriteConcern || !currentConcern.defaultWriteConcern.w) {
        print('Setting default write concern...');
        var result = db.adminCommand({
            setDefaultRWConcern: 1,
            defaultWriteConcern: {
                w: 'majority',
                wtimeout: 10000
            }
        });
        print('Write concern set successfully: ' + JSON.stringify(result));
    } else {
        print('Write concern already configured');
    }
    print('SUCCESS');
} catch(e) {
    print('ERROR: ' + e.message);
}" 2>&1)

echo -e "${BLUE}Kết quả thiết lập write concern: $WRITE_CONCERN_RESULT${NC}"

if [[ "$WRITE_CONCERN_RESULT" != *"SUCCESS"* ]]; then
    echo -e "${RED}Không thể thiết lập write concern. Tiếp tục nhưng có thể gặp vấn đề.${NC}"
fi

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