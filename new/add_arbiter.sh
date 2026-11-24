#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/mongo_auth.sh" || exit 1
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
IFS= read -rs -p "Mật khẩu MongoDB: " MONGODB_PASS || exit 1
echo >&2
[[ -n "$MONGODB_PASS" ]] || exit 1
ARBITER_PORT="27017"  # Sử dụng port mặc định MongoDB

# Hàm tạo cấu hình MongoDB cho Arbiter
create_arbiter_config() {
    local arbiter_ip=$1
    
    echo -e "${YELLOW}Tạo cấu hình MongoDB cho Arbiter...${NC}"
    
    # Tạo cấu hình đặc biệt cho Arbiter
    cat > "/tmp/mongod-arbiter.conf" << EOF
# mongod.conf for Arbiter Node

# Where and how to store data - Arbiter không cần lưu trữ data
storage:
  dbPath: $MONGODB_DATA_DIR
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.25  # Cache nhỏ cho arbiter

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH

# network interfaces
net:
  port: $ARBITER_PORT
  bindIp: 0.0.0.0

# security
security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE

# replication
replication:
  replSetName: "$REPLICA_SET_NAME"
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

# Sanity check: không được dùng cùng một IP cho PRIMARY và ARBITER
if [ "$PRIMARY_IP" = "$ARBITER_IP" ]; then
    echo -e "${RED}PRIMARY_IP và ARBITER_IP đang trùng nhau (${PRIMARY_IP}). Điều này sẽ gây xung đột mạng/ARP và lỗi kết nối.${NC}"
    echo -e "${YELLOW}Hãy đảm bảo bạn đang chạy arbiter trên máy khác hoặc dùng IP khác, sau đó chạy lại script.${NC}"
    exit 1
fi

echo -e "${YELLOW}Bắt đầu thiết lập MongoDB Arbiter Node...${NC}"
echo -e "${YELLOW}PRIMARY node: $PRIMARY_HOST${NC}"
echo -e "${YELLOW}ARBITER node: $ARBITER_HOST${NC}"

# Kiểm tra kết nối tới PRIMARY node
echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
if ! check_mongodb_connection "$PRIMARY_HOST" "$MONGODB_USER" "$MONGODB_PASS" "admin"; then
    echo -e "${RED}Không thể kết nối tới PRIMARY node. Vui lòng kiểm tra lại.${NC}"
    echo -e "${YELLOW}Đảm bảo rằng:${NC}"
    echo -e "${YELLOW}1. PRIMARY node đang chạy${NC}"
    echo -e "${YELLOW}2. Thông tin xác thực ($MONGODB_USER) chính xác${NC}"
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

# Dừng MongoDB hiện tại nếu có
sudo systemctl stop mongod 2>/dev/null || true
sleep 2

# Khởi động MongoDB với cấu hình mới
if sudo systemctl start mongod; then
    echo -e "${GREEN}MongoDB đã khởi động trên port 27017${NC}"
    sleep 5
else
    echo -e "${RED}Không thể khởi động MongoDB bằng systemctl${NC}"
    exit 1
fi

# Kiểm tra MongoDB đã khởi động thành công
if ! systemctl is-active --quiet mongod; then
    echo -e "${RED}MongoDB không khởi động được. Kiểm tra logs tại $MONGODB_LOG_PATH${NC}"
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
WRITE_CONCERN_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
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

# Kiểm tra xem đã có arbiter nào chưa
echo -e "${YELLOW}Kiểm tra arbiter hiện có trong replica set...${NC}"
EXISTING_ARBITERS=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
var cfg = rs.conf();
var arbiters = [];
for (var i = 0; i < cfg.members.length; i++) {
    if (cfg.members[i].arbiterOnly === true) {
        arbiters.push(cfg.members[i].host);
    }
}
print(arbiters.join(','));
" 2>/dev/null)

echo "Arbiters hiện có: $EXISTING_ARBITERS"

if [ ! -z "$EXISTING_ARBITERS" ] && [ "$EXISTING_ARBITERS" != "" ]; then
    echo -e "${YELLOW}Đã có arbiter trong replica set: $EXISTING_ARBITERS${NC}"
    
    # Kiểm tra xem arbiter hiện tại có phải là node này không
    if [[ "$EXISTING_ARBITERS" == *"$ARBITER_HOST"* ]]; then
        echo -e "${GREEN}Node này đã là arbiter trong replica set rồi!${NC}"
        echo -e "${GREEN}Không cần thêm lại.${NC}"
    else
        echo -e "${YELLOW}Có arbiter khác trong replica set.${NC}"
        echo -e "${YELLOW}MongoDB chỉ cho phép 1 arbiter per replica set.${NC}"
        echo -e "${YELLOW}Bạn có muốn thay thế arbiter hiện tại không? (y/n)${NC}"
        read -p "Thay thế arbiter hiện tại? " replace_choice
        
        if [[ "$replace_choice" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Đang xóa arbiter cũ và thêm arbiter mới...${NC}"
            
            # Xóa arbiter cũ
            REMOVE_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
            try {
                var cfg = rs.conf();
                var newMembers = [];
                
                for (var i = 0; i < cfg.members.length; i++) {
                    if (cfg.members[i].arbiterOnly !== true) {
                        newMembers.push(cfg.members[i]);
                    } else {
                        print('Removing arbiter: ' + cfg.members[i].host);
                    }
                }
                
                cfg.members = newMembers;
                cfg.version += 1;
                rs.reconfig(cfg);
                print('SUCCESS: Removed old arbiter');
            } catch(e) {
                print('ERROR: ' + e.message);
            }" 2>&1)
            
            echo "Kết quả xóa arbiter cũ: $REMOVE_RESULT"
            
            if [[ "$REMOVE_RESULT" == *"SUCCESS"* ]]; then
                echo -e "${GREEN}Đã xóa arbiter cũ thành công${NC}"
                sleep 3
            else
                echo -e "${RED}Không thể xóa arbiter cũ: $REMOVE_RESULT${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}Không thay thế arbiter. Thoát script.${NC}"
            exit 0
        fi
    fi
fi

# Preflight: kiểm tra kết nối mạng 2 chiều trước khi thêm arbiter
echo -e "${YELLOW}Preflight: Kiểm tra kết nối mạng giữa PRIMARY và ARBITER (TCP 27017)...${NC}"

# 1) Từ ARBITER (máy đang chạy script) tới PRIMARY
PRIMARY_IP_ONLY=$(echo "$PRIMARY_HOST" | cut -d: -f1)
if nc -z -w 3 "$PRIMARY_IP_ONLY" 27017 2>/dev/null; then
    echo -e "${GREEN}✓${NC} ARBITER -> PRIMARY: TCP 27017 OK"
else
    echo -e "${RED}✗${NC} ARBITER -> PRIMARY: TCP 27017 FAIL"
    echo -e "${YELLOW}Hãy đảm bảo trên PRIMARY:${NC}"
    echo -e "  - Mở cổng 27017 (ufw/firewalld/security group/NACL)"
    echo -e "  - mongod bind 0.0.0.0 (mongod.conf: net.bindIp: 0.0.0.0) và đã restart"
    echo -e "  - Đường mạng giữa hai server thông suốt (ICMP có thể bị chặn, nhưng TCP 27017 phải thông)"
    echo -e "${YELLOW}Dừng lại để tránh thêm member unreachable. Thử lại sau khi mở kết nối.${NC}"
    exit 1
fi

# 2) Listener trên ARBITER (đảm bảo mongod đang nghe trên 0.0.0.0:27017)
if command -v ss >/dev/null 2>&1; then
    if ss -tln | grep -E "LISTEN\s+.*:27017\s" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} ARBITER listener: 27017 đang LISTEN"
    else
        echo -e "${RED}✗${NC} ARBITER listener: không thấy LISTEN 27017"
        echo -e "${YELLOW}Kiểm tra mongod và cấu hình bindIp, sau đó restart mongod.${NC}"
        exit 1
    fi
else
    if netstat -tln 2>/dev/null | grep ":27017" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} ARBITER listener: 27017 đang LISTEN"
    else
        echo -e "${RED}✗${NC} ARBITER listener: không thấy LISTEN 27017"
        echo -e "${YELLOW}Kiểm tra mongod và cấu hình bindIp, sau đó restart mongod.${NC}"
        exit 1
    fi
fi

# Chỉ thêm arbiter nếu chưa có hoặc đã xóa arbiter cũ
if [ -z "$EXISTING_ARBITERS" ] || [ "$EXISTING_ARBITERS" == "" ] || [[ "$replace_choice" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Đang thêm arbiter mới vào replica set...${NC}"
    
    ADD_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
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
        ALT_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
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
    
    # Ngay sau khi thêm thành công, kiểm tra và fix lỗi "not reachable"
    echo -e "${YELLOW}Kiểm tra và sửa lỗi kết nối arbiter ngay sau khi thêm...${NC}"
    sleep 3
    
    # Kiểm tra trạng thái arbiter ngay lập tức
    IMMEDIATE_STATUS=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
    var status = rs.status();
    for (var i = 0; i < status.members.length; i++) {
        if (status.members[i].name === '$ARBITER_HOST') {
            print(status.members[i].stateStr);
            break;
        }
    }
    " 2>/dev/null)
    
    echo "Trạng thái arbiter ngay sau khi thêm: $IMMEDIATE_STATUS"
    
    if [[ "$IMMEDIATE_STATUS" == *"not reachable"* ]] || [[ "$IMMEDIATE_STATUS" == *"(not reachable/healthy)"* ]]; then
        echo -e "${YELLOW}Arbiter bị 'not reachable' ngay sau khi thêm. Đang sửa...${NC}"
        
        # 1. Đảm bảo MongoDB đang chạy và bind đúng
        echo -e "${YELLOW}1. Kiểm tra MongoDB local...${NC}"
        if ! pgrep -f mongod >/dev/null; then
            echo "MongoDB không chạy, khởi động lại..."
            sudo systemctl restart mongod
            sleep 5
        fi
        
        # 2. Kiểm tra port binding
        if ! netstat -tlnp 2>/dev/null | grep ":27017.*0.0.0.0:" >/dev/null; then
            echo "MongoDB không bind 0.0.0.0:27017, restart để fix..."
            sudo systemctl restart mongod
            sleep 5
        fi
        
        # 3. Mở firewall
        echo -e "${YELLOW}2. Mở firewall ports...${NC}"
        sudo ufw allow 27017/tcp 2>/dev/null || echo "UFW không khả dụng"
        sudo firewall-cmd --permanent --add-port=27017/tcp 2>/dev/null && sudo firewall-cmd --reload 2>/dev/null || echo "firewall-cmd không khả dụng"
        
        # 4. Lấy IP chính xác và cập nhật config
        echo -e "${YELLOW}3. Cập nhật IP chính xác trong replica set...${NC}"
        CORRECT_IP=$(get_current_ip)
        CORRECT_ARBITER_HOST="${CORRECT_IP}:27017"
        
        if [ "$CORRECT_ARBITER_HOST" != "$ARBITER_HOST" ]; then
            echo "IP thực tế: $CORRECT_IP, IP trong config: $ARBITER_IP"
            echo "Cập nhật từ $ARBITER_HOST thành $CORRECT_ARBITER_HOST"
            
            UPDATE_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
            try {
                var cfg = rs.conf();
                for (var i = 0; i < cfg.members.length; i++) {
                    if (cfg.members[i].arbiterOnly === true && cfg.members[i].host === '$ARBITER_HOST') {
                        print('Updating arbiter IP from ' + cfg.members[i].host + ' to $CORRECT_ARBITER_HOST');
                        cfg.members[i].host = '$CORRECT_ARBITER_HOST';
                        break;
                    }
                }
                cfg.version += 1;
                rs.reconfig(cfg, {force: false});
                print('SUCCESS: Updated arbiter IP');
            } catch(e) {
                print('ERROR: ' + e.message);
            }" 2>&1)
            
            echo "Kết quả cập nhật IP: $UPDATE_RESULT"
            ARBITER_HOST="$CORRECT_ARBITER_HOST"
        fi
        
        # 5. Đợi và kiểm tra lại
        echo -e "${YELLOW}4. Đợi replica set cập nhật...${NC}"
        sleep 10
        
        FIXED_STATUS=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
        var status = rs.status();
        for (var i = 0; i < status.members.length; i++) {
            if (status.members[i].name === '$ARBITER_HOST' || status.members[i].name === '$CORRECT_ARBITER_HOST') {
                print('State: ' + status.members[i].stateStr + ', Health: ' + status.members[i].health);
                break;
            }
        }
        " 2>/dev/null)
        
        echo "Trạng thái sau khi fix: $FIXED_STATUS"
    fi
else
    echo -e "${GREEN}Arbiter đã được cấu hình trong replica set.${NC}"
fi

# Đợi một chút để Replica Set cập nhật
sleep 5

# Kiểm tra trạng thái Replica Set
echo -e "${YELLOW}Kiểm tra trạng thái Replica Set...${NC}"
mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --eval "
printjson(rs.status());
print('\\n=== REPLICA SET CONFIGURATION ===');
printjson(rs.conf());
"

# Kiểm tra đặc biệt xem arbiter có hoạt động không
echo -e "${YELLOW}Kiểm tra trạng thái Arbiter...${NC}"
ARBITER_STATUS=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
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

# Nếu arbiter bị "not reachable", thử sửa tự động
if [[ "$ARBITER_STATUS" == *"not reachable"* ]] || [[ "$ARBITER_STATUS" == *"(not reachable/healthy)"* ]]; then
    echo -e "${YELLOW}Phát hiện arbiter 'not reachable', đang thử sửa...${NC}"
    
    # 1. Kiểm tra firewall và network
    echo -e "${YELLOW}1. Kiểm tra network và firewall...${NC}"
    
    # Mở port 27017 trên firewall
    echo "Mở port 27017 trên firewall..."
    sudo ufw allow 27017/tcp 2>/dev/null || echo "UFW không khả dụng hoặc đã mở port"
    sudo firewall-cmd --permanent --add-port=27017/tcp 2>/dev/null && sudo firewall-cmd --reload 2>/dev/null || echo "firewall-cmd không khả dụng"
    
    # 2. Kiểm tra MongoDB binding
    echo -e "${YELLOW}2. Kiểm tra MongoDB binding...${NC}"
    if ! netstat -tlnp 2>/dev/null | grep ":27017.*0.0.0.0:" >/dev/null; then
        echo "MongoDB không bind trên 0.0.0.0, thử restart..."
        sudo systemctl restart mongod || sudo mongod --config "$MONGODB_CONFIG" --fork
        sleep 5
    fi
    
    # 3. Cập nhật IP arbiter trong replica set config
    echo -e "${YELLOW}3. Cập nhật cấu hình arbiter với IP chính xác...${NC}"
    
    # Lấy IP chính xác của arbiter
    CORRECT_IP=$(get_current_ip)
    CORRECT_ARBITER_HOST="${CORRECT_IP}:27017"
    
    if [ "$CORRECT_ARBITER_HOST" != "$ARBITER_HOST" ]; then
        echo "Cập nhật IP arbiter từ $ARBITER_HOST thành $CORRECT_ARBITER_HOST"
        
        UPDATE_RESULT=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
        try {
            var cfg = rs.conf();
            var updated = false;
            
            // Tìm và cập nhật arbiter host
            for (var i = 0; i < cfg.members.length; i++) {
                if (cfg.members[i].arbiterOnly === true) {
                    print('Cập nhật arbiter host từ: ' + cfg.members[i].host + ' thành: $CORRECT_ARBITER_HOST');
                    cfg.members[i].host = '$CORRECT_ARBITER_HOST';
                    updated = true;
                    break;
                }
            }
            
            if (updated) {
                cfg.version += 1;
                rs.reconfig(cfg, {force: false});
                print('SUCCESS: Đã cập nhật cấu hình arbiter');
            } else {
                print('ERROR: Không tìm thấy arbiter trong cấu hình');
            }
        } catch(e) {
            print('ERROR: ' + e.message);
        }" 2>&1)
        
        echo "Kết quả cập nhật: $UPDATE_RESULT"
        ARBITER_HOST="$CORRECT_ARBITER_HOST"
    fi
    
    # 4. Đợi và kiểm tra lại
    echo -e "${YELLOW}4. Đợi replica set cập nhật...${NC}"
    sleep 10
    
    # Kiểm tra lại trạng thái
    ARBITER_STATUS_FIXED=$(mongo_eval "$MONGODB_USER" "$MONGODB_PASS" "admin" --host "$PRIMARY_HOST" --quiet --eval "
    var status = rs.status();
    for (var i = 0; i < status.members.length; i++) {
        if (status.members[i].name === '$ARBITER_HOST' || status.members[i].name === '$CORRECT_ARBITER_HOST') {
            print('Arbiter State: ' + status.members[i].stateStr);
            print('Arbiter Health: ' + status.members[i].health);
            if (status.members[i].stateStr === 'ARBITER') {
                print('STATUS: FIXED');
            }
            break;
        }
    }
    " 2>/dev/null)
    
    echo "Trạng thái arbiter sau khi sửa: $ARBITER_STATUS_FIXED"
    
    if [[ "$ARBITER_STATUS_FIXED" == *"ARBITER"* ]]; then
        echo -e "${GREEN}✓ Đã sửa thành công lỗi 'not reachable'${NC}"
    else
        echo -e "${RED}✗ Vẫn chưa sửa được lỗi 'not reachable'${NC}"
        echo -e "${YELLOW}Các bước kiểm tra thủ công:${NC}"
        echo "1. Kiểm tra firewall: sudo ufw status"
        echo "2. Kiểm tra network: ping $CORRECT_IP"
        echo "3. Kiểm tra MongoDB binding: netstat -tlnp | grep 27017"
        echo "4. Kiểm tra logs: tail -f $MONGODB_LOG_PATH"
    fi
fi

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
echo -e "${GREEN}mongosh $PRIMARY_HOST -u $MONGODB_USER --authenticationDatabase admin --eval 'rs.status()'${NC}"
echo ""
echo -e "${YELLOW}Lưu ý: Arbiter không lưu trữ dữ liệu, chỉ tham gia bầu chọn để đảm bảo tính khả dụng cao của Replica Set.${NC}"