#!/bin/bash
# MongoDB Replica Set Setup Script
# Script thiết lập Replica Set MongoDB tự động


# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import required configuration files
if [ -f "$SCRIPT_DIR/../config/mongodb_settings.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_settings.sh"
fi

if [ -f "$SCRIPT_DIR/../config/mongodb_functions.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_functions.sh"
fi

# Thiết lập sudo_cmd nếu chưa được định nghĩa
if [ -z "$sudo_cmd" ]; then
    # Kiểm tra quyền root
    has_sudo_rights=true
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            echo -e "${YELLOW}Script sẽ thực hiện một số lệnh cần quyền sudo.${NC}"
            sudo -v || has_sudo_rights=false
        else
            has_sudo_rights=false
        fi
        
        if [ "$has_sudo_rights" = false ]; then
            echo -e "${YELLOW}Cảnh báo: Không chạy với quyền root hoặc sudo.${NC}"
            echo -e "${YELLOW}Một số chức năng có thể không hoạt động, tiếp tục ở chế độ thử nghiệm...${NC}"
        fi
    fi

    # Chuyển đổi lệnh sudo dựa trên quyền
    sudo_cmd=""
    if [ "$(id -u)" -ne 0 ] && [ "$has_sudo_rights" = true ]; then
        sudo_cmd="sudo"
    fi
fi

# Functions
# ---------

# Khởi tạo replica set
init_replica_set() {
    local host_name=$1
    local ip=${2:-$(get_server_ip)}
    
    echo -e "${YELLOW}Khởi tạo replica set $REPLICA_SET_NAME...${NC}"
    echo -e "${YELLOW}Sử dụng IP: $ip cho node đầu tiên${NC}"
    
    # Tạo file khởi tạo replica set
    local init_script=$(mktemp)
    cat > "$init_script" <<EOF
rs.initiate({
  _id: "$REPLICA_SET_NAME",
  members: [
    { _id: 0, host: "$ip:$MONGO_PORT", priority: 10 }
  ]
})
EOF
    
    # Chạy file khởi tạo với IP thực tế thay vì localhost
    mongosh --host "$ip" --port "$MONGO_PORT" < "$init_script"
    
    # Xóa file tạm
    rm -f "$init_script"
    
    # Đợi replica set khởi tạo
    sleep 5
    
    echo -e "${GREEN}Đã khởi tạo replica set $REPLICA_SET_NAME với node đầu tiên là $ip:$MONGO_PORT${NC}"
}

# Thêm node vào replica set
add_replica_node() {
    local secondary_ip=$1
    local primary_ip=${2:-$(get_server_ip)}
    
    # Đảm bảo sử dụng IP thật cho cả primary và secondary
    if [[ "$secondary_ip" == "localhost" || "$secondary_ip" == "127.0.0.1" ]]; then
        secondary_ip=$(get_server_ip)
        echo -e "${YELLOW}Đã chuyển đổi 'localhost' thành IP thật cho secondary: $secondary_ip${NC}"
    fi
    
    if [[ "$primary_ip" == "localhost" || "$primary_ip" == "127.0.0.1" ]]; then
        primary_ip=$(get_server_ip)
        echo -e "${YELLOW}Đã chuyển đổi 'localhost' thành IP thật cho primary: $primary_ip${NC}"
    fi
    
    echo -e "${YELLOW}Thêm node $secondary_ip vào replica set $REPLICA_SET_NAME...${NC}"
    
    # Thực hiện trên primary với IP thực
    mongosh --host "$primary_ip" --port "$MONGO_PORT" --eval "rs.add('$secondary_ip:$MONGO_PORT')"
    
    echo -e "${GREEN}Đã thêm node $secondary_ip:$MONGO_PORT vào replica set${NC}"
}

# Kiểm tra trạng thái replica set
check_replica_status() {
    local host=${1:-$(get_server_ip)}
    
    echo -e "${YELLOW}Kiểm tra trạng thái replica set $REPLICA_SET_NAME...${NC}"
    
    # Kiểm tra xem MongoDB có đang chạy không
    if ! nc -z -w5 $host $MONGO_PORT 2>/dev/null; then
        echo -e "${RED}Không thể kết nối đến MongoDB tại $host:$MONGO_PORT${NC}"
        echo -e "${RED}Đảm bảo MongoDB đang chạy và port $MONGO_PORT đang mở${NC}"
        return 1
    fi
    
    # Yêu cầu thông tin đăng nhập
    read -p "Username (mặc định: $MONGODB_USER): " username
    read -sp "Password (mặc định: $MONGODB_PASSWORD): " password
    echo ""
    
    # Sử dụng giá trị mặc định nếu không nhập
    username=${username:-$MONGODB_USER}
    password=${password:-$MONGODB_PASSWORD}
    
    # Thử ping trước khi lấy thông tin chi tiết
    local ping_result=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "try { db.runCommand({ping: 1}); print('OK'); } catch(e) { print('ERROR: ' + e.message); }" --quiet)
    
    if [[ "$ping_result" != *"OK"* ]]; then
        echo -e "${RED}Không thể xác thực với MongoDB. Chi tiết lỗi:${NC}"
        echo "$ping_result"
        return 1
    fi
    
    echo -e "${GREEN}✅ Kết nối thành công tới MongoDB${NC}"
    
    # Lấy thông tin status với xác thực
    local status=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.status()" --quiet)
    
    # Kiểm tra xem có phải replica set không
    if [[ "$status" == *"not running with --replSet"* ]]; then
        echo -e "${RED}MongoDB chưa được cấu hình là replica set${NC}"
        echo -e "${YELLOW}Bạn cần thiết lập PRIMARY node trước (tùy chọn 1)${NC}"
        return 1
    fi
    
    # Hiển thị thông tin chi tiết hơn về nodes, thay localhost bằng IP thật
    local members=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
    try {
        let result = '';
        const serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];
        rs.status().members.forEach(function(m) {
            // Kiểm tra nếu là localhost thì thay bằng IP thực
            let name = m.name;
            let parts = name.split(':');
            if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
                name = serverIp + ':' + parts[1];
            }
            print(name + ' - ' + m.stateStr + (m.health !== 1 ? ' (not reachable/healthy)' : ''));
        });
    } catch(e) {
        print('ERROR: ' + e.message);
    }
    " --quiet)
    
    echo -e "${GREEN}Thông tin replica set:${NC}"
    echo "$members"
    
    # Kiểm tra node primary, thay localhost bằng IP thật
    local primary=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
    try {
        const serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];
        let primary = rs.isMaster().primary;
        if (primary) {
            let parts = primary.split(':');
            if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
                primary = serverIp + ':' + parts[1];
            }
            print(primary);
        } else {
            print('NONE');
        }
    } catch(e) {
        print('ERROR: ' + e.message);
    }
    " --quiet | grep -v MongoDB)
    
    if [ -n "$primary" ] && [ "$primary" != "ERROR" ] && [ "$primary" != "NONE" ]; then
        echo -e "${GREEN}Primary node: $primary${NC}"
    else
        echo -e "${RED}Không tìm thấy primary node${NC}"
    fi
    
    return 0
}

# Tạo admin user
create_admin_user() {
    local username=$1
    local password=$2
    local auth_db=$3
    local server_ip=$(get_server_ip)
    
    echo -e "${YELLOW}Tạo user admin...${NC}"
    
    mongosh --host "$server_ip" --port "$MONGO_PORT" --eval "
    db = db.getSiblingDB('$auth_db');
    db.createUser({
        user: '$username',
        pwd: '$password',
        roles: [
            { role: 'root', db: 'admin' },
            { role: 'userAdminAnyDatabase', db: 'admin' },
            { role: 'dbAdminAnyDatabase', db: 'admin' },
            { role: 'readWriteAnyDatabase', db: 'admin' }
        ]
    });
    " --quiet
    
    echo -e "${GREEN}User $username đã được tạo${NC}"
}

# Thiết lập node như primary
setup_primary_node() {
    echo -e "${BLUE}=== THIẾT LẬP PRIMARY NODE ===${NC}"
    
    # Lấy địa chỉ IP thực tế của server
    local server_ip=$(get_server_ip)
    echo -e "${YELLOW}Sử dụng địa chỉ IP: $server_ip${NC}"

    # Tạo keyfile
    create_keyfile true
    
    # Kiểm tra MongoDB đã được cài đặt
    check_mongodb
    
    # Dừng MongoDB hiện tại
    stop_mongodb
    
    # Tạo thư mục cần thiết
    create_dirs
    
    # Tạo file cấu hình
    create_config false false
    
    # Tạo systemd service
    create_systemd_service
    
    # Khởi động MongoDB
    start_mongodb
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Thiết lập replica set
    init_replica_set "primary" "$server_ip"
    
    # Tạo admin user
    create_admin_user "$MONGODB_USER" "$MONGODB_PASSWORD" "$AUTH_DATABASE"
    
    # Dừng MongoDB để cập nhật cấu hình với security
    stop_mongodb
    
    # Cập nhật cấu hình với security và replication
    create_config true true
    
    # Khởi động lại MongoDB
    start_mongodb
    
    # Kiểm tra kết nối
    verify_mongodb_connection "$server_ip" "$MONGO_PORT" "$AUTH_DATABASE" "$MONGODB_USER" "$MONGODB_PASSWORD"
    
    # Kiểm tra trạng thái replica set
    check_replica_status "$server_ip"
    
    echo -e "${GREEN}Thiết lập PRIMARY NODE hoàn tất!${NC}"
    
    # Hiển thị thông tin kết nối
    echo -e "${YELLOW}Thông tin kết nối:${NC}"
    echo -e "  Địa chỉ: ${GREEN}$server_ip:$MONGO_PORT${NC}"
    echo -e "  Tên replica set: ${GREEN}$REPLICA_SET_NAME${NC}"
    echo -e "  Connection string: ${GREEN}mongodb://$MONGODB_USER:$MONGODB_PASSWORD@$server_ip:$MONGO_PORT/$AUTH_DATABASE?replicaSet=$REPLICA_SET_NAME${NC}"
}

# Thiết lập node như secondary
setup_secondary_node() {
    echo -e "${BLUE}=== THIẾT LẬP SECONDARY NODE ===${NC}"
    
    # Lấy địa chỉ IP thực tế của secondary server
    local secondary_ip=$(get_server_ip)
    echo -e "${YELLOW}Địa chỉ IP của SECONDARY node: $secondary_ip${NC}"
    
    # Yêu cầu địa chỉ primary
    read -p "Nhập địa chỉ IP của PRIMARY node: " primary_ip
    
    # Kiểm tra thông tin primary
    if [ -z "$primary_ip" ]; then
        echo -e "${RED}Địa chỉ IP của PRIMARY node không được để trống${NC}"
        return 1
    fi
    
    # Nếu primary_ip là localhost, thì chuyển thành IP thực
    if [[ "$primary_ip" == "localhost" || "$primary_ip" == "127.0.0.1" ]]; then
        primary_ip=$secondary_ip
        echo -e "${YELLOW}Đã chuyển đổi 'localhost' thành IP thực cho primary: $primary_ip${NC}"
    fi
    
    # Kiểm tra kết nối tới primary
    echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
    if ! ping -c 1 "$primary_ip" &>/dev/null; then
        echo -e "${RED}Không thể kết nối tới PRIMARY node $primary_ip${NC}"
        echo -e "${YELLOW}Kiểm tra lại địa chỉ IP và đảm bảo PRIMARY node đang hoạt động${NC}"
        return 1
    fi

    # Tạo keyfile
    create_keyfile false "$primary_ip"
    
    # Kiểm tra MongoDB đã được cài đặt
    check_mongodb
    
    # Dừng MongoDB hiện tại
    stop_mongodb
    
    # Tạo thư mục cần thiết
    create_dirs
    
    # Tạo file cấu hình với security và replication
    create_config true true
    
    # Tạo systemd service
    create_systemd_service
    
    # Khởi động MongoDB
    start_mongodb
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Thông báo cho người dùng
    echo -e "${YELLOW}Hãy thêm node này vào replica set từ PRIMARY node bằng lệnh:${NC}"
    echo -e "${GREEN}mongosh --host $primary_ip --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase $AUTH_DATABASE --eval \"rs.add('$secondary_ip:$MONGO_PORT')\"${NC}"
    
    # Hỏi người dùng có muốn thêm node này vào replica set ngay không
    read -p "Thêm node này vào replica set ngay? (y/n): " add_now
    if [[ "$add_now" == "y" || "$add_now" == "Y" ]]; then
        # Yêu cầu thông tin đăng nhập
        read -p "Username (mặc định: $MONGODB_USER): " username
        read -sp "Password (mặc định: $MONGODB_PASSWORD): " password
        echo ""
        
        # Sử dụng giá trị mặc định nếu không nhập
        username=${username:-$MONGODB_USER}
        password=${password:-$MONGODB_PASSWORD}
        
        # Kiểm tra kết nối đến primary node trước khi thêm
        echo -e "${YELLOW}Kiểm tra kết nối đến PRIMARY node ($primary_ip:$MONGO_PORT)...${NC}"
        if ! nc -z -w5 $primary_ip $MONGO_PORT; then
            echo -e "${RED}❌ Không thể kết nối tới PRIMARY node $primary_ip:$MONGO_PORT${NC}"
            echo -e "${YELLOW}Đảm bảo MongoDB đang chạy trên PRIMARY node và port $MONGO_PORT đang mở${NC}"
            return 1
        fi
        
        # Kiểm tra kết nối đến node hiện tại trước khi thêm
        echo -e "${YELLOW}Kiểm tra kết nối đến node hiện tại ($secondary_ip:$MONGO_PORT)...${NC}"
        if ! nc -z -w5 $secondary_ip $MONGO_PORT; then
            echo -e "${RED}❌ MongoDB không chạy trên node hiện tại hoặc port $MONGO_PORT không mở${NC}"
            echo -e "${YELLOW}Kiểm tra lại trạng thái MongoDB trên node hiện tại${NC}"
            
            # Hiển thị trạng thái MongoDB
            if command -v systemctl &>/dev/null; then
                $sudo_cmd systemctl status mongod || true
            else
                if [ -f "$MONGODB_LOG_PATH" ]; then
                    echo -e "${YELLOW}Xem log MongoDB (10 dòng cuối):${NC}"
                    $sudo_cmd tail -n 10 "$MONGODB_LOG_PATH"
                fi
            fi
            
            # Hỏi người dùng có muốn khởi động lại MongoDB không
            echo -e "${YELLOW}Bạn có muốn khởi động lại MongoDB trên node hiện tại? (y/n)${NC}"
            read -p "> " restart_local
            if [[ "$restart_local" == "y" || "$restart_local" == "Y" ]]; then
                stop_mongodb && sleep 2 && start_mongodb && sleep 5
                if ! nc -z -w5 $secondary_ip $MONGO_PORT; then
                    echo -e "${RED}❌ MongoDB vẫn không chạy sau khi khởi động lại${NC}"
                    return 1
                else
                    echo -e "${GREEN}✅ MongoDB đã khởi động lại thành công${NC}"
                fi
            else
                return 1
            fi
        fi
        
        # Thêm node vào replica set với IP thực
        echo -e "${YELLOW}Đang thêm node $secondary_ip vào replica set...${NC}"
        add_result=$(mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        try {
            rs.add('$secondary_ip:$MONGO_PORT');
            print('SUCCESS');
        } catch(e) {
            print('ERROR: ' + e.message);
        }" --quiet)
        
        # Kiểm tra kết quả
        if [[ "$add_result" == *"SUCCESS"* ]] || [[ "$add_result" == *"\"ok\" : 1"* ]]; then
            echo -e "${GREEN}✅ Đã thêm node vào replica set thành công!${NC}"
        else
            echo -e "${RED}❌ Có lỗi khi thêm node:${NC}"
            echo "$add_result"
            
            # Kiểm tra xem node có thể đã được thêm trước đó
            echo -e "${YELLOW}Kiểm tra xem node có trong replica set không...${NC}"
            check_result=$(mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
            try {
                let config = rs.conf();
                let found = false;
                for (let i=0; i < config.members.length; i++) {
                    if (config.members[i].host === '$secondary_ip:$MONGO_PORT') {
                        found = true;
                        print('NODE_EXISTS: ' + i);
                        break;
                    }
                }
                if (!found) {
                    print('NODE_NOT_FOUND');
                }
            } catch(e) {
                print('ERROR: ' + e.message);
            }" --quiet)
            
            if [[ "$check_result" == *"NODE_EXISTS"* ]]; then
                echo -e "${GREEN}✅ Node đã tồn tại trong replica set${NC}"
            else
                echo -e "${RED}❌ Node không tồn tại trong replica set và không thể thêm${NC}"
                return 1
            fi
        fi
        
        # Đợi node đồng bộ
        echo -e "${YELLOW}Đợi node đồng bộ với replica set (30 giây)...${NC}"
        sleep 30
        
        # Kiểm tra trạng thái
        check_replica_status "$primary_ip"
    fi
    
    echo -e "${GREEN}Thiết lập SECONDARY NODE hoàn tất!${NC}"
}

# Thiết lập node như arbiter
setup_arbiter_node() {
    echo -e "${BLUE}=== THIẾT LẬP ARBITER NODE ===${NC}"
    
    # Lấy địa chỉ IP thực tế của arbiter server
    local arbiter_ip=$(get_server_ip)
    echo -e "${YELLOW}Địa chỉ IP của ARBITER node: $arbiter_ip${NC}"
    
    # Yêu cầu địa chỉ primary
    read -p "Nhập địa chỉ IP của PRIMARY node: " primary_ip
    
    # Kiểm tra thông tin primary
    if [ -z "$primary_ip" ]; then
        echo -e "${RED}Địa chỉ IP của PRIMARY node không được để trống${NC}"
        return 1
    fi
    
    # Nếu primary_ip là localhost, thì chuyển thành IP thực
    if [[ "$primary_ip" == "localhost" || "$primary_ip" == "127.0.0.1" ]]; then
        primary_ip=$arbiter_ip
        echo -e "${YELLOW}Đã chuyển đổi 'localhost' thành IP thực cho primary: $primary_ip${NC}"
    fi
    
    # Kiểm tra kết nối tới primary
    echo -e "${YELLOW}Kiểm tra kết nối tới PRIMARY node...${NC}"
    if ! ping -c 1 "$primary_ip" &>/dev/null; then
        echo -e "${RED}Không thể kết nối tới PRIMARY node $primary_ip${NC}"
        echo -e "${YELLOW}Kiểm tra lại địa chỉ IP và đảm bảo PRIMARY node đang hoạt động${NC}"
        return 1
    fi

    # Tạo keyfile
    create_keyfile false "$primary_ip"
    
    # Kiểm tra MongoDB đã được cài đặt
    check_mongodb
    
    # Dừng MongoDB hiện tại
    stop_mongodb
    
    # Tạo thư mục cần thiết
    create_dirs
    
    # Tạo file cấu hình với security và replication
    create_config true true
    
    # Tạo systemd service
    create_systemd_service
    
    # Khởi động MongoDB
    start_mongodb
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Thông báo cho người dùng
    echo -e "${YELLOW}Hãy thêm node này vào replica set từ PRIMARY node bằng lệnh:${NC}"
    echo -e "${GREEN}mongosh --host $primary_ip --port $MONGO_PORT -u $MONGODB_USER -p $MONGODB_PASSWORD --authenticationDatabase $AUTH_DATABASE --eval \"rs.add('$arbiter_ip:$MONGO_PORT')\"${NC}"
    
    # Hỏi người dùng có muốn thêm node này vào replica set ngay không
    read -p "Thêm arbiter vào replica set ngay? (y/n): " add_now
    if [[ "$add_now" == "y" || "$add_now" == "Y" ]]; then
        # Yêu cầu thông tin đăng nhập
        read -p "Username (mặc định: $MONGODB_USER): " username
        read -sp "Password (mặc định: $MONGODB_PASSWORD): " password
        echo ""
        
        # Sử dụng giá trị mặc định nếu không nhập
        username=${username:-$MONGODB_USER}
        password=${password:-$MONGODB_PASSWORD}
        
        # Kiểm tra kết nối đến primary node trước khi thêm
        echo -e "${YELLOW}Kiểm tra kết nối đến PRIMARY node ($primary_ip:$MONGO_PORT)...${NC}"
        if ! nc -z -w5 $primary_ip $MONGO_PORT; then
            echo -e "${RED}❌ Không thể kết nối tới PRIMARY node $primary_ip:$MONGO_PORT${NC}"
            echo -e "${YELLOW}Đảm bảo MongoDB đang chạy trên PRIMARY node và port $MONGO_PORT đang mở${NC}"
            return 1
        fi
        
        # Kiểm tra kết nối đến arbiter node trước khi thêm
        echo -e "${YELLOW}Kiểm tra kết nối đến ARBITER node ($arbiter_ip:$MONGO_PORT)...${NC}"
        if ! nc -z -w5 $arbiter_ip $MONGO_PORT; then
            echo -e "${RED}❌ MongoDB không chạy trên arbiter node hoặc port $MONGO_PORT không mở${NC}"
            echo -e "${YELLOW}Kiểm tra lại trạng thái MongoDB trên arbiter node${NC}"
            
            # Hiển thị trạng thái MongoDB
            if command -v systemctl &>/dev/null; then
                $sudo_cmd systemctl status mongod || true
            else
                if [ -f "$MONGODB_LOG_PATH" ]; then
                    echo -e "${YELLOW}Xem log MongoDB (10 dòng cuối):${NC}"
                    $sudo_cmd tail -n 10 "$MONGODB_LOG_PATH"
                fi
            fi
            
            # Hỏi người dùng có muốn khởi động lại MongoDB không
            echo -e "${YELLOW}Bạn có muốn khởi động lại MongoDB trên arbiter node? (y/n)${NC}"
            read -p "> " restart_local
            if [[ "$restart_local" == "y" || "$restart_local" == "Y" ]]; then
                stop_mongodb && sleep 2 && start_mongodb && sleep 5
                if ! nc -z -w5 $arbiter_ip $MONGO_PORT; then
                    echo -e "${RED}❌ MongoDB vẫn không chạy sau khi khởi động lại${NC}"
                    return 1
                else
                    echo -e "${GREEN}✅ MongoDB đã khởi động lại thành công${NC}"
                fi
            else
                return 1
            fi
        fi
        
        # Thêm arbiter vào replica set với IP thực
        echo -e "${YELLOW}Đang thêm arbiter $arbiter_ip vào replica set...${NC}"
        add_result=$(mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        try {
            rs.addArb('$arbiter_ip:$MONGO_PORT');
            print('SUCCESS');
        } catch(e) {
            print('ERROR: ' + e.message);
        }" --quiet)
        
        # Kiểm tra kết quả
        if [[ "$add_result" == *"SUCCESS"* ]] || [[ "$add_result" == *"\"ok\" : 1"* ]]; then
            echo -e "${GREEN}✅ Đã thêm arbiter vào replica set thành công!${NC}"
        else
            echo -e "${RED}❌ Có lỗi khi thêm arbiter:${NC}"
            echo "$add_result"
            
            # Kiểm tra xem arbiter có thể đã được thêm trước đó
            echo -e "${YELLOW}Kiểm tra xem arbiter có trong replica set không...${NC}"
            check_result=$(mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
            try {
                let config = rs.conf();
                let found = false;
                for (let i=0; i < config.members.length; i++) {
                    if (config.members[i].host === '$arbiter_ip:$MONGO_PORT') {
                        found = true;
                        print('NODE_EXISTS: ' + i + ', arbiter: ' + (config.members[i].arbiterOnly === true));
                        break;
                    }
                }
                if (!found) {
                    print('NODE_NOT_FOUND');
                }
            } catch(e) {
                print('ERROR: ' + e.message);
            }" --quiet)
            
            if [[ "$check_result" == *"NODE_EXISTS"* ]]; then
                echo -e "${GREEN}✅ Arbiter đã tồn tại trong replica set${NC}"
            else
                echo -e "${RED}❌ Arbiter không tồn tại trong replica set và không thể thêm${NC}"
                return 1
            fi
        fi
        
        # Đợi node đồng bộ
        echo -e "${YELLOW}Đợi arbiter đồng bộ với replica set (15 giây)...${NC}"
        sleep 15
        
        # Kiểm tra trạng thái
        check_replica_status "$primary_ip"
    fi
    
    echo -e "${GREEN}Thiết lập ARBITER NODE hoàn tất!${NC}"
}

# Xem thông tin cấu hình
show_config() {
    echo -e "${BLUE}=== THÔNG TIN CẤU HÌNH ===${NC}"
    echo -e "${YELLOW}MongoDB Version: ${GREEN}$MONGO_VERSION${NC}"
    echo -e "${YELLOW}MongoDB Port: ${GREEN}$MONGO_PORT${NC}"
    echo -e "${YELLOW}Replica Set Name: ${GREEN}$REPLICA_SET_NAME${NC}"
    echo -e "${YELLOW}Admin Database: ${GREEN}$AUTH_DATABASE${NC}"
    echo -e "${YELLOW}Admin Username: ${GREEN}$MONGODB_USER${NC}"
    echo -e "${YELLOW}Admin Password: ${GREEN}$MONGODB_PASSWORD${NC}"
    echo -e "${YELLOW}Data Directory: ${GREEN}$MONGODB_DATA_DIR${NC}"
    echo -e "${YELLOW}Log Path: ${GREEN}$MONGODB_LOG_PATH${NC}"
    echo -e "${YELLOW}Config File: ${GREEN}$MONGODB_CONFIG${NC}"
    echo -e "${YELLOW}Keyfile: ${GREEN}$MONGODB_KEYFILE${NC}"
    echo -e "${YELLOW}Bind IP: ${GREEN}$BIND_IP${NC}"
    echo -e "${YELLOW}Server IP: ${GREEN}$(get_server_ip)${NC}"
    
    # Kiểm tra MongoDB đang chạy không
    if pgrep -x mongod >/dev/null; then
        echo -e "${YELLOW}Status: ${GREEN}Running${NC}"
    else
        echo -e "${YELLOW}Status: ${RED}Stopped${NC}"
    fi
    
    # Kiểm tra cấu hình file
    if [ -f "$MONGODB_CONFIG" ]; then
        echo -e "${YELLOW}Config file content:${NC}"
        cat "$MONGODB_CONFIG"
    fi
}

# Hàm xác minh kết nối MongoDB
verify_mongodb_connection() {
    local host=$1
    local port=$2
    local auth_db=$3
    local user=$4
    local password=$5
    
    echo -e "${YELLOW}Kiểm tra kết nối tới MongoDB...${NC}"
    
    # Chuyển đổi localhost sang IP thực nếu cần
    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
        local real_ip=$(get_server_ip)
        echo -e "${YELLOW}Đang sử dụng IP thực $real_ip thay vì localhost${NC}"
        host=$real_ip
    fi
    
    # Kiểm tra kết nối
    if ! nc -z -w5 $host $port; then
        echo -e "${RED}Không thể kết nối tới MongoDB tại $host:$port${NC}"
        return 1
    fi
    
    # Kiểm tra xác thực
    if [ -n "$user" ] && [ -n "$password" ]; then
        local auth_result=$(mongosh --host "$host" --port "$port" -u "$user" -p "$password" --authenticationDatabase "$auth_db" --eval "db.runCommand({ping:1})" 2>&1)
        
        if echo "$auth_result" | grep -q "Authentication failed"; then
            echo -e "${RED}Xác thực thất bại với user $user${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ Kết nối thành công tới MongoDB tại $host:$port${NC}"
    return 0
}

# Tạo file cấu hình
create_config() {
    local use_auth=$1
    local use_replication=$2
    local server_ip=$(get_server_ip)
    
    echo -e "${YELLOW}Tạo file cấu hình...${NC}"
    
    # Tạo thư mục chứa file cấu hình nếu không tồn tại
    if [ ! -d "$(dirname "$MONGODB_CONFIG")" ]; then
        $sudo_cmd mkdir -p "$(dirname "$MONGODB_CONFIG")"
    fi
    
    # Tạo file cấu hình với các tùy chọn cần thiết
    $sudo_cmd tee "$MONGODB_CONFIG" > /dev/null << EOF
# MongoDB configuration file
# Tự động tạo bởi script thiết lập MongoDB Replica Set

# Các cài đặt lưu trữ
storage:
  dbPath: $MONGODB_DATA_DIR
  journal: true

# Các cài đặt hệ thống
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH

# Các cài đặt mạng
net:
  port: $MONGO_PORT
  bindIp: $server_ip,127.0.0.1,$BIND_IP
EOF
    
    # Thêm cài đặt security nếu cần
    if [ "$use_auth" = true ]; then
        $sudo_cmd tee -a "$MONGODB_CONFIG" > /dev/null << EOF

# Cài đặt bảo mật
security:
  authorization: enabled
  keyFile: $MONGODB_KEYFILE
EOF
    fi
    
    # Thêm cài đặt replication nếu cần
    if [ "$use_replication" = true ]; then
        $sudo_cmd tee -a "$MONGODB_CONFIG" > /dev/null << EOF

# Cài đặt replication
replication:
  replSetName: $REPLICA_SET_NAME
EOF
    fi
    
    # Hiển thị thông báo
    echo -e "${GREEN}✅ Đã tạo file cấu hình tại $MONGODB_CONFIG${NC}"
}

# Tạo keyfile cho xác thực MongoDB
create_keyfile() {
    local is_primary=$1
    local primary_ip=$2
    
    echo -e "${YELLOW}Tạo hoặc lấy keyfile cho xác thực...${NC}"
    
    # Đảm bảo thư mục tồn tại
    local keyfile_dir=$(dirname "$MONGODB_KEYFILE")
    if [ ! -d "$keyfile_dir" ]; then
        $sudo_cmd mkdir -p "$keyfile_dir"
    fi
    
    if [ "$is_primary" = true ]; then
        # Nếu đây là primary node, tạo keyfile mới
        echo -e "${YELLOW}Tạo keyfile mới cho primary node...${NC}"
        $sudo_cmd openssl rand -base64 756 > /tmp/mongodb-keyfile
        $sudo_cmd cp /tmp/mongodb-keyfile "$MONGODB_KEYFILE"
        $sudo_cmd rm -f /tmp/mongodb-keyfile
    else
        # Nếu đây là secondary/arbiter node, sao chép keyfile từ primary
        echo -e "${YELLOW}Lấy keyfile từ primary node ($primary_ip)...${NC}"
        
        # Nếu là local setup, có thể tạo mới
        if [[ "$primary_ip" == "$(get_server_ip)" || "$primary_ip" == "localhost" || "$primary_ip" == "127.0.0.1" ]]; then
            echo -e "${YELLOW}Primary và node hiện tại ở cùng máy, kiểm tra keyfile hiện có...${NC}"
            if [ -f "$MONGODB_KEYFILE" ]; then
                echo -e "${GREEN}✅ Keyfile đã tồn tại${NC}"
            else
                echo -e "${YELLOW}Tạo keyfile mới...${NC}"
                $sudo_cmd openssl rand -base64 756 > /tmp/mongodb-keyfile
                $sudo_cmd cp /tmp/mongodb-keyfile "$MONGODB_KEYFILE"
                $sudo_cmd rm -f /tmp/mongodb-keyfile
            fi
        else
            # Cảnh báo người dùng cần sao chép keyfile thủ công
            echo -e "${YELLOW}Bạn cần sao chép keyfile từ primary node sang node này.${NC}"
            echo -e "${YELLOW}Trên primary node, keyfile được lưu tại:${NC} ${GREEN}$MONGODB_KEYFILE${NC}"
            echo -e "${YELLOW}Bạn có thể sử dụng lệnh sau trên primary node:${NC}"
            echo -e "${GREEN}cat $MONGODB_KEYFILE${NC}"
            echo -e "${YELLOW}Sau đó tạo file keyfile trên node này với nội dung tương tự${NC}"
            
            # Kiểm tra keyfile hiện tại
            if [ -f "$MONGODB_KEYFILE" ]; then
                echo -e "${GREEN}✅ Keyfile đã tồn tại trên node này${NC}"
            else
                # Tạo file trống để người dùng điền vào sau
                touch "$MONGODB_KEYFILE" 2>/dev/null || $sudo_cmd touch "$MONGODB_KEYFILE"
                echo -e "${YELLOW}Đã tạo file keyfile trống, vui lòng điền nội dung vào.${NC}"
                echo -e "${YELLOW}Nhập nội dung keyfile mà bạn đã lấy từ primary node:${NC}"
                read -p "Dán nội dung keyfile và nhấn Enter: " keyfile_content
                if [ -n "$keyfile_content" ]; then
                    echo "$keyfile_content" > /tmp/mongodb-keyfile
                    $sudo_cmd cp /tmp/mongodb-keyfile "$MONGODB_KEYFILE"
                    $sudo_cmd rm -f /tmp/mongodb-keyfile
                else
                    echo -e "${RED}Không nhận được nội dung keyfile, vui lòng cấu hình thủ công.${NC}"
                    $sudo_cmd touch "$MONGODB_KEYFILE"
                fi
            fi
        fi
    fi
    
    # Đặt quyền cho keyfile
    $sudo_cmd chmod 400 "$MONGODB_KEYFILE"
    $sudo_cmd chown mongodb:mongodb "$MONGODB_KEYFILE" 2>/dev/null || true
    
    echo -e "${GREEN}✅ Keyfile đã sẵn sàng tại: $MONGODB_KEYFILE${NC}"
}

# Kiểm tra trạng thái MongoDB
check_mongodb_status() {
    local verbose=${1:-true}

    if [ "$verbose" = true ]; then
        echo -e "${BLUE}=== Kiểm tra trạng thái ===${NC}"
    fi

    # Kiểm tra process
    if pgrep -x mongod >/dev/null; then
        if [ "$verbose" = true ]; then
            echo -e "${GREEN}✅ MongoDB đang chạy (process)${NC}"
        fi
        
        # Kiểm tra port
        local server_ip=$(get_server_ip)
        if nc -z -w5 $server_ip $MONGO_PORT 2>/dev/null; then
            if [ "$verbose" = true ]; then
                echo -e "${GREEN}✅ MongoDB đang lắng nghe trên port $MONGO_PORT${NC}"
            fi
            return 0
        else
            if [ "$verbose" = true ]; then
                echo -e "${RED}❌ MongoDB không lắng nghe trên port $MONGO_PORT${NC}"
                echo -e "${YELLOW}Kiểm tra file cấu hình và log...${NC}"
                
                # Hiển thị cấu hình nếu có
                if [ -f "$MONGODB_CONFIG" ]; then
                    echo -e "${YELLOW}Cấu hình MongoDB:${NC}"
                    grep -A5 "net:" "$MONGODB_CONFIG"
                fi
                
                # Hiển thị log
                if [ -f "$MONGODB_LOG_PATH" ]; then
                    echo -e "${YELLOW}Log MongoDB (10 dòng cuối):${NC}"
                    $sudo_cmd tail -n 10 "$MONGODB_LOG_PATH"
                fi
            fi
            return 1
        fi
    else
        if [ "$verbose" = true ]; then
            echo -e "${RED}❌ MongoDB chưa chạy${NC}"
        fi
        return 1
    fi
}

# Khởi động MongoDB với kiểm tra chi tiết
start_and_verify_mongodb() {
    local max_retries=3
    local retries=0
    
    while [ $retries -lt $max_retries ]; do
        echo -e "${YELLOW}Đang kiểm tra trạng thái trước khi khởi động...${NC}"
        if check_mongodb_status false; then
            echo -e "${GREEN}✅ MongoDB đã chạy, không cần khởi động lại${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}Khởi động MongoDB (lần thử $((retries+1))/${max_retries})...${NC}"
        
        # Dừng MongoDB nếu có lỗi
        stop_mongodb
        
        # Khởi động MongoDB
        if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/mongod.service ]; then
            $sudo_cmd systemctl start mongod
        else
            $sudo_cmd mongod --config "$MONGODB_CONFIG" --fork
        fi
        
        # Đợi MongoDB khởi động
        echo -e "${YELLOW}Đợi MongoDB khởi động...${NC}"
        sleep 5
        
        # Kiểm tra lại
        if check_mongodb_status false; then
            echo -e "${GREEN}✅ Đã khởi động MongoDB ${NC}"
            return 0
        else
            echo -e "${RED}❌ MongoDB không thể khởi động hoặc không lắng nghe trên port ${MONGO_PORT}${NC}"
            
            # Kiểm tra lỗi trong log
            if [ -f "$MONGODB_LOG_PATH" ]; then
                echo -e "${YELLOW}Kiểm tra log lỗi:${NC}"
                $sudo_cmd tail -n 20 "$MONGODB_LOG_PATH" | grep -i "error"
                
                # Kiểm tra lỗi keyfile
                if $sudo_cmd tail -n 20 "$MONGODB_LOG_PATH" | grep -i -q "keyfile"; then
                    echo -e "${RED}❌ Có lỗi liên quan đến keyfile, đang sửa...${NC}"
                    $sudo_cmd chmod 400 "$MONGODB_KEYFILE"
                    $sudo_cmd chown mongodb:mongodb "$MONGODB_KEYFILE" 2>/dev/null || true
                fi
                
                # Kiểm tra lỗi log path
                if $sudo_cmd tail -n 20 "$MONGODB_LOG_PATH" | grep -i -q "log file"; then
                    echo -e "${RED}❌ Có lỗi liên quan đến file log, đang sửa...${NC}"
                    local log_dir=$(dirname "$MONGODB_LOG_PATH")
                    $sudo_cmd mkdir -p "$log_dir"
                    $sudo_cmd touch "$MONGODB_LOG_PATH"
                    $sudo_cmd chmod 644 "$MONGODB_LOG_PATH"
                    $sudo_cmd chown mongodb:mongodb "$MONGODB_LOG_PATH" 2>/dev/null || true
                fi
                
                # Kiểm tra lỗi data path
                if $sudo_cmd tail -n 20 "$MONGODB_LOG_PATH" | grep -i -q "data directory"; then
                    echo -e "${RED}❌ Có lỗi liên quan đến thư mục dữ liệu, đang sửa...${NC}"
                    $sudo_cmd mkdir -p "$MONGODB_DATA_DIR"
                    $sudo_cmd chmod 750 "$MONGODB_DATA_DIR"
                    $sudo_cmd chown -R mongodb:mongodb "$MONGODB_DATA_DIR" 2>/dev/null || true
                fi
            fi
            
            retries=$((retries+1))
            
            if [ $retries -lt $max_retries ]; then
                echo -e "${YELLOW}Thử lại sau 5 giây...${NC}"
                sleep 5
            fi
        fi
    done
    
    # Nếu vẫn không khởi động được sau nhiều lần thử
    echo -e "${RED}❌ Không thể khởi động MongoDB sau ${max_retries} lần thử.${NC}"
    echo -e "${YELLOW}Vui lòng kiểm tra cấu hình và log thủ công. Có thể cần khởi động lại máy chủ.${NC}"
    return 1
}

# Hàm setup_replica để gọi từ main.sh
setup_replica_linux() {
    while true; do
        # Hiển thị menu trực tiếp
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}       ${YELLOW}MONGODB REPLICA SET SETUP${NC}           ${BLUE}║${NC}"
        echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Thiết lập PRIMARY node                  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Thiết lập SECONDARY node                ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Thiết lập ARBITER node                  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Kiểm tra trạng thái replica set         ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}5.${NC} Khởi động lại MongoDB                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}6.${NC} Dừng MongoDB                            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}7.${NC} Xem thông tin cấu hình                  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${RED}0.${NC} Quay lại menu chính                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
        local server_ip=$(get_server_ip true || echo 'không có')
        local port_value=${MONGO_PORT:-$MONGODB_PORT}
        port_value=${port_value:-27017}
        echo "Server IP: $server_ip"
        echo "MongoDB Version: ${MONGO_VERSION:-8.0} | Port: $port_value | Replica: ${REPLICA_SET_NAME:-rs0}"
        
        # Kiểm tra trạng thái MongoDB
        if check_mongodb_status false; then
            echo -e "${GREEN}MongoDB đang chạy trên $server_ip:$port_value${NC}"
        else
            echo -e "${RED}MongoDB không chạy hoặc không hoạt động bình thường${NC}"
        fi
        echo
        
        read -p ">> Chọn chức năng [0-7]: " choice
        
        case $choice in
            1) setup_primary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            2) setup_secondary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            3) setup_arbiter_node; read -p "Nhấn Enter để tiếp tục..." ;;
            4) 
               # Kiểm tra trạng thái MongoDB trước khi chạy check_replica_status
               local server_ip=$(get_server_ip)
               echo -e "${YELLOW}Kiểm tra trạng thái MongoDB tại $server_ip:$port_value...${NC}"
               
               # Kiểm tra port đang mở
               if check_mongodb_status; then
                 echo -e "${GREEN}✅ MongoDB đang chạy và sẵn sàng truy vấn${NC}"
                 check_replica_status
               else
                 echo -e "${RED}❌ MongoDB không chạy hoặc không hoạt động bình thường${NC}"
                 echo -e "${YELLOW}Bạn có muốn khởi động lại MongoDB không? (y/n)${NC}"
                 read -p "> " restart_choice
                 if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
                   echo -e "${YELLOW}Đang khởi động lại MongoDB...${NC}"
                   start_and_verify_mongodb
                   
                   if check_mongodb_status false; then
                     echo -e "${GREEN}✅ MongoDB đã khởi động, đang kiểm tra replica set${NC}"
                     check_replica_status
                   else
                     echo -e "${RED}❌ Không thể khởi động MongoDB, không thể kiểm tra replica set${NC}"
                   fi
                 fi
               fi
               read -p "Nhấn Enter để tiếp tục..." 
               ;;
            5) 
               echo -e "${YELLOW}Đang khởi động lại MongoDB...${NC}"
               stop_mongodb && sleep 2
               start_and_verify_mongodb
               read -p "Nhấn Enter để tiếp tục..." 
               ;;
            6) stop_mongodb; read -p "Nhấn Enter để tiếp tục..." ;;
            7) show_config; read -p "Nhấn Enter để tiếp tục..." ;;
            0) return 0 ;;
            *) echo "❌ Lựa chọn không hợp lệ. Vui lòng chọn lại."; read -p "Nhấn Enter để tiếp tục..." ;;
        esac
    done
}

# Chỉ chạy setup_replica_linux nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica_linux
fi

# Dừng MongoDB
stop_mongodb() {
    echo -e "${YELLOW}Dừng MongoDB...${NC}"
    
    # Kiểm tra MongoDB có đang chạy không
    if ! pgrep -x mongod >/dev/null; then
        echo -e "${YELLOW}MongoDB không chạy${NC}"
        return 0
    fi
    
    # Dừng bằng systemd nếu có
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/mongod.service ]; then
        $sudo_cmd systemctl stop mongod
        sleep 2
        
        # Kiểm tra đã dừng chưa
        if ! pgrep -x mongod >/dev/null; then
            echo -e "${GREEN}MongoDB đã dừng thành công (systemd)${NC}"
            return 0
        else
            echo -e "${YELLOW}Không thể dừng MongoDB bằng systemd, đang thử phương pháp khác...${NC}"
        fi
    fi
    
    # Nếu không có systemd hoặc systemd không thành công, thử dừng bằng kill
    local pid=$(pgrep -x mongod)
    if [ -n "$pid" ]; then
        echo -e "${YELLOW}Dừng MongoDB process (PID: $pid)...${NC}"
        $sudo_cmd kill $pid
        sleep 3
        
        # Kiểm tra đã dừng chưa
        if ! pgrep -x mongod >/dev/null; then
            echo -e "${GREEN}MongoDB đã dừng thành công (kill)${NC}"
        else
            # Dùng kill -9 nếu cần
            echo -e "${YELLOW}Buộc dừng MongoDB...${NC}"
            $sudo_cmd kill -9 $pid
            sleep 2
            
            if ! pgrep -x mongod >/dev/null; then
                echo -e "${GREEN}MongoDB đã buộc dừng thành công (kill -9)${NC}"
            else
                echo -e "${RED}Không thể dừng MongoDB${NC}"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Khởi động MongoDB
start_mongodb() {
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Kiểm tra file cấu hình
    if [ ! -f "$MONGODB_CONFIG" ]; then
        echo -e "${RED}❌ Không tìm thấy file cấu hình tại $MONGODB_CONFIG${NC}"
        echo -e "${YELLOW}Đang tạo file cấu hình mặc định...${NC}"
        create_config true true
    fi
    
    # Kiểm tra syntax của file cấu hình MongoDB
    echo -e "${YELLOW}Kiểm tra cấu hình MongoDB...${NC}"
    if [ -x "$(command -v mongod)" ]; then
        # Kiểm tra cấu hình bằng mongod
        local check_result=$(mongod --config "$MONGODB_CONFIG" --validate 2>&1 || echo "ERROR")
        if [[ "$check_result" == *"ERROR"* ]]; then
            echo -e "${RED}❌ File cấu hình MongoDB không hợp lệ:${NC}"
            echo "$check_result"
            echo -e "${YELLOW}Đang sửa chữa file cấu hình...${NC}"
            # Sửa chữa file cấu hình bằng cách tạo lại
            create_config true true
        else
            echo -e "${GREEN}✅ File cấu hình hợp lệ${NC}"
        fi
    fi
    
    # Đảm bảo thư mục dữ liệu tồn tại và có quyền truy cập
    if [ ! -d "$MONGODB_DATA_DIR" ]; then
        echo -e "${YELLOW}Thư mục dữ liệu không tồn tại, đang tạo...${NC}"
        $sudo_cmd mkdir -p "$MONGODB_DATA_DIR"
    fi
    
    # Đảm bảo thư mục log tồn tại
    local log_dir=$(dirname "$MONGODB_LOG_PATH")
    if [ ! -d "$log_dir" ]; then
        echo -e "${YELLOW}Thư mục log không tồn tại, đang tạo...${NC}"
        $sudo_cmd mkdir -p "$log_dir"
        $sudo_cmd chown -R mongodb:mongodb "$log_dir" 2>/dev/null || true
    fi
    
    # Đảm bảo file log có thể ghi được
    $sudo_cmd touch "$MONGODB_LOG_PATH" 2>/dev/null || true
    $sudo_cmd chmod 644 "$MONGODB_LOG_PATH" 2>/dev/null || true
    $sudo_cmd chown mongodb:mongodb "$MONGODB_LOG_PATH" 2>/dev/null || true
    
    # Khởi động MongoDB bằng systemd nếu có
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/mongod.service ]; then
        echo -e "${YELLOW}Khởi động MongoDB bằng systemd...${NC}"
        $sudo_cmd systemctl start mongod
        sleep 3
        
        # Kiểm tra trạng thái
        if systemctl is-active --quiet mongod; then
            echo -e "${GREEN}MongoDB đã khởi động thành công (systemd)${NC}"
            return 0
        else
            echo -e "${RED}MongoDB không khởi động được bằng systemd, đang thử phương pháp khác...${NC}"
        fi
    fi
    
    # Nếu không có systemd hoặc systemd không thành công, thử khởi động trực tiếp
    echo -e "${YELLOW}Khởi động MongoDB trực tiếp...${NC}"
    $sudo_cmd mongod --config "$MONGODB_CONFIG" --fork
    
    # Kiểm tra MongoDB đã khởi động chưa
    sleep 3
    if pgrep -x mongod >/dev/null; then
        echo -e "${GREEN}MongoDB đã khởi động thành công (direct)${NC}"
        sleep 2
        # Kiểm tra xem có thể kết nối được không
        check_mongodb_status false
        return 0
    else
        echo -e "${RED}Không thể khởi động MongoDB${NC}"
        
        # Xem log lỗi
        if [ -f "$MONGODB_LOG_PATH" ]; then
            echo -e "${YELLOW}Xem log lỗi (10 dòng cuối):${NC}"
            $sudo_cmd tail -n 10 "$MONGODB_LOG_PATH"
        fi
        
        # Kiểm tra quyền truy cập
        echo -e "${YELLOW}Kiểm tra quyền truy cập:${NC}"
        ls -la "$MONGODB_DATA_DIR"
        ls -la "$log_dir"
        
        # Thử sửa quyền cho keyfile nếu có
        if [ -f "$MONGODB_KEYFILE" ]; then
            echo -e "${YELLOW}Sửa quyền cho keyfile...${NC}"
            $sudo_cmd chmod 400 "$MONGODB_KEYFILE"
            $sudo_cmd chown mongodb:mongodb "$MONGODB_KEYFILE" 2>/dev/null || true
        fi
        
        # Thử sửa quyền và khởi động lại
        echo -e "${YELLOW}Đang sửa quyền và thử lại...${NC}"
        $sudo_cmd chown -R mongodb:mongodb "$MONGODB_DATA_DIR" 2>/dev/null || true
        $sudo_cmd chown -R mongodb:mongodb "$log_dir" 2>/dev/null || true
        $sudo_cmd chmod -R 750 "$MONGODB_DATA_DIR" 2>/dev/null || true
        $sudo_cmd chmod -R 750 "$log_dir" 2>/dev/null || true
        
        # Thử lại một lần nữa
        $sudo_cmd mongod --config "$MONGODB_CONFIG" --fork
        sleep 3
        
        if pgrep -x mongod >/dev/null; then
            echo -e "${GREEN}MongoDB đã khởi động thành công (sau khi sửa quyền)${NC}"
            return 0
        else
            echo -e "${RED}Vẫn không thể khởi động MongoDB. Vui lòng kiểm tra cấu hình và log.${NC}"
            return 1
        fi
    fi
}

fix_unreachable_node_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}      ${YELLOW}FIX UNREACHABLE NODE WIZARD${NC}          ${BLUE}║${NC}"
        echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Kiểm tra và sửa lỗi node không kết nối  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Khôi phục node bằng cách xóa và thêm lại ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Cấu hình lại node không kết nối được    ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${RED}0.${NC} Quay lại                                  ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
        
        # Hiển thị trạng thái hiện tại
        local node_ip
        read -p "Nhập IP của node cần sửa (mặc định: $(get_server_ip)): " node_ip
        node_ip=${node_ip:-$(get_server_ip)}
        
        # Kiểm tra trạng thái MongoDB trên node đó
        echo -e "${YELLOW}Kiểm tra trạng thái node $node_ip...${NC}"
        
        # Hiển thị các thông tin quan trọng
        if ping -c 1 -W 2 $node_ip &>/dev/null; then
            echo -e "${GREEN}✅ Node $node_ip có thể ping được${NC}"
        else
            echo -e "${RED}❌ Node $node_ip không thể ping được${NC}"
        fi
        
        if check_mongodb_status false $node_ip; then
            echo -e "${GREEN}✅ MongoDB đang chạy trên $node_ip${NC}"
        else
            echo -e "${RED}❌ MongoDB không chạy hoặc không hoạt động bình thường trên $node_ip${NC}"
        fi
        
        read -p ">> Chọn chức năng [0-3]: " choice
        
        case $choice in
            1)
                echo -e "${YELLOW}Đang chạy kiểm tra và sửa lỗi node không kết nối...${NC}"
                check_and_fix_unreachable $node_ip
                read -p "Nhấn Enter để tiếp tục..." 
                ;;
            2) 
                echo -e "${YELLOW}Đang khôi phục node bằng cách xóa và thêm lại...${NC}"
                force_recover_node $node_ip
                read -p "Nhấn Enter để tiếp tục..." 
                ;;
            3)
                echo -e "${YELLOW}Đang cấu hình lại node không kết nối được...${NC}"
                force_reconfigure_node $node_ip
                read -p "Nhấn Enter để tiếp tục..." 
                ;;
            0) return 0 ;;
            *) echo "❌ Lựa chọn không hợp lệ. Vui lòng chọn lại."; read -p "Nhấn Enter để tiếp tục..." ;;
        esac
    done
}