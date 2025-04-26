#!/bin/bash
# File chứa các hàm chức năng dùng chung cho MongoDB

# Đọc các biến cấu hình
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/mongodb_settings.sh"

# Dừng MongoDB
stop_mongodb() {
    echo -e "${YELLOW}Dừng MongoDB...${NC}"
    
    # Dừng dịch vụ nếu đang chạy
    if command -v systemctl &>/dev/null; then
        $sudo_cmd systemctl stop mongod 2>/dev/null
    elif command -v service &>/dev/null; then
        $sudo_cmd service mongod stop 2>/dev/null
    fi
    
    # Tìm và kill các tiến trình MongoDB đang chạy
    if pgrep -x "mongod" >/dev/null; then
        echo -e "${YELLOW}Kill các tiến trình MongoDB đang chạy...${NC}"
        $sudo_cmd pkill -f mongod
        sleep 2
        if pgrep -x "mongod" >/dev/null; then
            echo -e "${YELLOW}Kill cưỡng bức các tiến trình MongoDB...${NC}"
            $sudo_cmd pkill -9 -f mongod
        fi
    fi
    
    # Đảm bảo port MongoDB không còn được sử dụng
    if lsof -Pi :${MONGO_PORT} -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${YELLOW}Kill tiến trình sử dụng port ${MONGO_PORT}...${NC}"
        lsof -Pi :${MONGO_PORT} -sTCP:LISTEN -t | xargs $sudo_cmd kill -9
    fi
    
    # Đợi port được giải phóng
    echo -e "${YELLOW}Đợi port ${MONGO_PORT} được giải phóng...${NC}"
    while lsof -Pi :${MONGO_PORT} -sTCP:LISTEN -t >/dev/null; do
        sleep 1
    done
    
    echo -e "${GREEN}MongoDB đã dừng thành công${NC}"
}

# Tạo thư mục cần thiết
create_dirs() {
    echo -e "${YELLOW}Tạo các thư mục cần thiết...${NC}"
    
    # Tạo thư mục dữ liệu
    if [ ! -d "$MONGODB_DATA_DIR" ]; then
        mkdir -p "$MONGODB_DATA_DIR"
        echo -e "${GREEN}Đã tạo thư mục dữ liệu: $MONGODB_DATA_DIR${NC}"
    else
        echo -e "${BLUE}Thư mục dữ liệu đã tồn tại: $MONGODB_DATA_DIR${NC}"
    fi
    
    # Tạo thư mục log
    local log_dir=$(dirname "$MONGODB_LOG_PATH")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 
        echo -e "${GREEN}Đã tạo thư mục log: $log_dir${NC}"
    else
        echo -e "${BLUE}Thư mục log đã tồn tại: $log_dir${NC}"
    fi
    
    # Tạo thư mục chứa keyfile
    local keyfile_dir=$(dirname "$MONGODB_KEYFILE")
    if [ ! -d "$keyfile_dir" ]; then
        mkdir -p "$keyfile_dir"
        echo -e "${GREEN}Đã tạo thư mục keyfile: $keyfile_dir${NC}"
    else
        echo -e "${BLUE}Thư mục keyfile đã tồn tại: $keyfile_dir${NC}"
    fi
    
    # Thiết lập quyền nếu chạy với quyền root
    if [ "$(id -u)" -eq 0 ] || [ -n "$sudo_cmd" ]; then
        if getent passwd mongodb >/dev/null; then
            $sudo_cmd chown -R mongodb:mongodb "$MONGODB_DATA_DIR" "$log_dir" "$keyfile_dir"
            echo -e "${GREEN}Đã thiết lập quyền thư mục cho mongodb${NC}"
        else
            echo -e "${YELLOW}Không tìm thấy người dùng mongodb, đặt quyền cho người dùng hiện tại${NC}"
            $sudo_cmd chown -R $(id -u):$(id -g) "$MONGODB_DATA_DIR" "$log_dir" "$keyfile_dir"
        fi
    else
        echo -e "${YELLOW}Chạy không có quyền sudo, bỏ qua việc thiết lập quyền${NC}"
    fi
    
    touch "$MONGODB_LOG_PATH" 2>/dev/null
    if [ -f "$MONGODB_LOG_PATH" ]; then
        chmod 644 "$MONGODB_LOG_PATH"
        echo -e "${GREEN}Đã thiết lập quyền cho file log${NC}"
    fi
    
    echo -e "${GREEN}Tạo thư mục thành công${NC}"
}

# Tạo file cấu hình
create_config() {
    local security_enabled=$1
    local replication_enabled=$2
    
    echo -e "${YELLOW}Tạo file cấu hình MongoDB...${NC}"
    
    # Tạo cấu hình cơ bản
    cat > "$MONGODB_CONFIG" <<EOF
# mongod.conf

# Lưu trữ
storage:
  dbPath: $MONGODB_DATA_DIR
  journal:
    enabled: true

# Log
systemLog:
  destination: file
  logAppend: true
  path: $MONGODB_LOG_PATH

# Network
net:
  port: $MONGO_PORT
  bindIp: $BIND_IP

# Process Management
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  fork: true
EOF

    # Thêm cấu hình security nếu được yêu cầu
    if [ "$security_enabled" = true ]; then
        cat >> "$MONGODB_CONFIG" <<EOF

# Security
security:
  authorization: enabled
EOF
        
        # Thêm cấu hình keyFile nếu file tồn tại
        if [ -f "$MONGODB_KEYFILE" ]; then
            cat >> "$MONGODB_CONFIG" <<EOF
  keyFile: $MONGODB_KEYFILE
EOF
        fi
    fi
    
    # Thêm cấu hình replication nếu được yêu cầu
    if [ "$replication_enabled" = true ]; then
        cat >> "$MONGODB_CONFIG" <<EOF

# Replication
replication:
  replSetName: $REPLICA_SET_NAME
EOF
    fi
    
    # Thiết lập quyền
    chmod 644 "$MONGODB_CONFIG"
    
    echo -e "${GREEN}Đã tạo file cấu hình MongoDB tại $MONGODB_CONFIG${NC}"
}

# Tạo keyfile
create_keyfile() {
    local is_primary=$1
    local primary_host=$2
    
    echo -e "${YELLOW}Tạo keyfile cho xác thực...${NC}"
    
    if [ "$is_primary" = true ] || [ -z "$primary_host" ]; then
        # Tạo keyfile mới cho primary hoặc nếu không có thông tin primary
        openssl rand -base64 756 > "$MONGODB_KEYFILE"
        echo -e "${GREEN}Đã tạo keyfile mới tại $MONGODB_KEYFILE${NC}"
    else
        # Copy keyfile từ máy chủ primary
        echo -e "${YELLOW}Copy keyfile từ máy chủ primary $primary_host...${NC}"
        
        # Yêu cầu thông tin đăng nhập SSH
        read -p "Nhập username SSH cho máy chủ primary: " ssh_user
        
        # Thử copy keyfile từ primary
        if scp -o StrictHostKeyChecking=no ${ssh_user}@${primary_host}:${MONGODB_KEYFILE} ${MONGODB_KEYFILE}; then
            echo -e "${GREEN}Đã copy keyfile từ primary thành công${NC}"
        else
            echo -e "${RED}Không thể copy keyfile từ primary. Tạo keyfile mới...${NC}"
            openssl rand -base64 756 > "$MONGODB_KEYFILE"
            echo -e "${YELLOW}Cảnh báo: Sử dụng keyfile mới có thể gây ra vấn đề với xác thực replica set${NC}"
            echo -e "${YELLOW}Nên copy keyfile từ primary node thủ công để đảm bảo tính nhất quán${NC}"
        fi
    fi
    
    # Thiết lập quyền
    chmod 400 "$MONGODB_KEYFILE"
    if [ "$(id -u)" -eq 0 ] || [ -n "$sudo_cmd" ]; then
        if getent passwd mongodb >/dev/null; then
            $sudo_cmd chown mongodb:mongodb "$MONGODB_KEYFILE"
        fi
    fi
    
    echo -e "${GREEN}Keyfile đã được thiết lập${NC}"
}

# Tạo hoặc cập nhật admin user
create_admin_user() {
    local username=$1
    local password=$2
    local database=$3
    
    if [ -z "$username" ]; then username="$MONGODB_USER"; fi
    if [ -z "$password" ]; then password="$MONGODB_PASSWORD"; fi
    if [ -z "$database" ]; then database="$AUTH_DATABASE"; fi
    
    echo -e "${YELLOW}Tạo/cập nhật user admin...${NC}"
    
    # Kiểm tra kết nối MongoDB
    if ! mongosh --port "$MONGO_PORT" --eval "db.version()" >/dev/null 2>&1; then
        echo -e "${RED}Không thể kết nối đến MongoDB, đảm bảo dịch vụ đang chạy${NC}"
        return 1
    fi
    
    # Kiểm tra xem user đã tồn tại chưa
    local user_exists=$(mongosh --port "$MONGO_PORT" "$database" --eval "db.getUser('$username')" 2>/dev/null | grep -c "null")
    
    if [ "$user_exists" -eq 0 ]; then
        # Cập nhật mật khẩu nếu user đã tồn tại
        mongosh --port "$MONGO_PORT" "$database" --eval "db.changeUserPassword('$username', '$password')" 2>/dev/null
        echo -e "${GREEN}Đã cập nhật mật khẩu cho user $username${NC}"
    else
        # Tạo user mới
        mongosh --port "$MONGO_PORT" "$database" --eval "
            db.createUser({
                user: '$username',
                pwd: '$password',
                roles: [
                    { role: 'userAdminAnyDatabase', db: 'admin' },
                    { role: 'dbAdminAnyDatabase', db: 'admin' },
                    { role: 'readWriteAnyDatabase', db: 'admin' },
                    { role: 'clusterAdmin', db: 'admin' }
                ]
            })
        " 2>/dev/null
        echo -e "${GREEN}Đã tạo user admin $username${NC}"
    fi
}

# Tạo systemd service
create_systemd_service() {
    echo -e "${YELLOW}Tạo MongoDB systemd service...${NC}"
    
    if [ ! -d /etc/systemd/system ]; then
        echo -e "${RED}Không tìm thấy thư mục systemd, có thể hệ thống không sử dụng systemd${NC}"
        return 1
    fi
    
    if [ "$(id -u)" -eq 0 ] || [ -n "$sudo_cmd" ]; then
        $sudo_cmd cat > /etc/systemd/system/mongod.service <<EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
Environment="OPTIONS=-f $MONGODB_CONFIG"
ExecStart=/usr/bin/mongod \$OPTIONS
ExecStartPre=-/usr/bin/mkdir -p /var/run/mongodb
ExecStartPre=/usr/bin/chown mongodb:mongodb /var/run/mongodb
ExecStartPre=/usr/bin/chmod 0755 /var/run/mongodb
PermissionsStartOnly=true
PIDFile=/var/run/mongodb/mongod.pid
Type=forking
# File size
LimitFSIZE=infinity
# CPU time
LimitCPU=infinity
# Virtual memory size
LimitAS=infinity
# Open files
LimitNOFILE=64000
# Processes/threads
LimitNPROC=64000
# Locked memory
LimitMEMLOCK=infinity
# Total threads (user+kernel)
TasksMax=infinity
TasksAccounting=false
# Restart service after 10 seconds if mongod crashes
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        $sudo_cmd systemctl daemon-reload
        echo -e "${GREEN}Đã tạo và cập nhật MongoDB systemd service${NC}"
    else
        echo -e "${YELLOW}Không có quyền tạo systemd service, bỏ qua bước này${NC}"
    fi
}

# Khởi động MongoDB
start_mongodb() {
    echo -e "${YELLOW}Khởi động MongoDB...${NC}"
    
    # Sử dụng systemd nếu có
    if command -v systemctl &>/dev/null && [ -n "$sudo_cmd" ]; then
        $sudo_cmd systemctl enable mongod
        $sudo_cmd systemctl start mongod
        sleep 5
        
        if $sudo_cmd systemctl is-active mongod >/dev/null; then
            echo -e "${GREEN}MongoDB đã khởi động thành công (systemd)${NC}"
            return 0
        else
            echo -e "${RED}Không thể khởi động MongoDB với systemd, thử phương thức khác...${NC}"
        fi
    fi
    
    # Sử dụng service nếu có
    if command -v service &>/dev/null && [ -n "$sudo_cmd" ]; then
        $sudo_cmd service mongod start
        sleep 5
        
        if pgrep -x mongod >/dev/null; then
            echo -e "${GREEN}MongoDB đã khởi động thành công (service)${NC}"
            return 0
        else
            echo -e "${RED}Không thể khởi động MongoDB với service, thử phương thức khác...${NC}"
        fi
    fi
    
    # Khởi động trực tiếp không cần quyền root
    echo -e "${YELLOW}Khởi động MongoDB trực tiếp...${NC}"
    mongod --config "$MONGODB_CONFIG" &
    sleep 5
    
    if pgrep -x mongod >/dev/null; then
        echo -e "${GREEN}MongoDB đã khởi động thành công (direct)${NC}"
        return 0
    else
        echo -e "${RED}Không thể khởi động MongoDB. Kiểm tra logs tại $MONGODB_LOG_PATH${NC}"
        return 1
    fi
}

# Cấu hình tường lửa
configure_firewall() {
    echo -e "${YELLOW}Cấu hình tường lửa cho MongoDB...${NC}"
    
    # Kiểm tra quyền
    if [ "$(id -u)" -ne 0 ] && [ -z "$sudo_cmd" ]; then
        echo -e "${YELLOW}Không có quyền cấu hình tường lửa, bỏ qua bước này${NC}"
        return 1
    fi
    
    # Kiểm tra UFW
    if command -v ufw &>/dev/null && $sudo_cmd ufw status | grep -q "active"; then
        echo -e "${YELLOW}Phát hiện UFW đang hoạt động, cấu hình UFW...${NC}"
        $sudo_cmd ufw allow "$MONGO_PORT/tcp" comment "MongoDB"
        echo -e "${GREEN}Đã cấu hình UFW cho MongoDB port $MONGO_PORT${NC}"
        return 0
    fi
    
    # Kiểm tra firewalld
    if command -v firewall-cmd &>/dev/null && $sudo_cmd systemctl is-active firewalld >/dev/null 2>&1; then
        echo -e "${YELLOW}Phát hiện firewalld đang hoạt động, cấu hình firewalld...${NC}"
        $sudo_cmd firewall-cmd --permanent --add-port="$MONGO_PORT/tcp"
        $sudo_cmd firewall-cmd --reload
        echo -e "${GREEN}Đã cấu hình firewalld cho MongoDB port $MONGO_PORT${NC}"
        return 0
    fi
    
    # Kiểm tra iptables
    if command -v iptables &>/dev/null; then
        echo -e "${YELLOW}Cấu hình iptables...${NC}"
        $sudo_cmd iptables -A INPUT -p tcp --dport "$MONGO_PORT" -j ACCEPT
        
        # Lưu cấu hình iptables nếu có công cụ phù hợp
        if command -v iptables-save &>/dev/null; then
            if [ -d /etc/iptables ]; then
                $sudo_cmd iptables-save > /etc/iptables/rules.v4
            elif [ -f /etc/sysconfig/iptables ]; then
                $sudo_cmd iptables-save > /etc/sysconfig/iptables
            fi
        fi
        
        echo -e "${GREEN}Đã cấu hình iptables cho MongoDB port $MONGO_PORT${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Không phát hiện tường lửa nào đang hoạt động${NC}"
    return 0
}

# Kiểm tra kết nối MongoDB
verify_mongodb_connection() {
    local host=$1
    local port=$2
    local auth_db=$3
    local username=$4
    local password=$5
    
    # Sử dụng giá trị mặc định nếu không được cung cấp
    if [ -z "$host" ]; then host="localhost"; fi
    if [ -z "$port" ]; then port="$MONGO_PORT"; fi
    
    echo -e "${YELLOW}Kiểm tra kết nối MongoDB tại $host:$port...${NC}"
    
    # Kiểm tra kết nối không xác thực
    if mongosh --host "$host" --port "$port" --eval "db.version()" >/dev/null 2>&1; then
        echo -e "${GREEN}Kết nối đến MongoDB thành công (không xác thực)${NC}"
        
        # Nếu có thông tin xác thực, kiểm tra kết nối có xác thực
        if [ -n "$auth_db" ] && [ -n "$username" ] && [ -n "$password" ]; then
            if mongosh --host "$host" --port "$port" --authenticationDatabase "$auth_db" -u "$username" -p "$password" --eval "db.version()" >/dev/null 2>&1; then
                echo -e "${GREEN}Kết nối đến MongoDB với xác thực thành công${NC}"
            else
                echo -e "${RED}Kết nối đến MongoDB với xác thực thất bại${NC}"
                return 1
            fi
        fi
        
        return 0
    else
        echo -e "${RED}Không thể kết nối đến MongoDB tại $host:$port${NC}"
        return 1
    fi
}

# Kiểm tra MongoDB đã được cài đặt
check_mongodb() {
    echo -e "${YELLOW}Kiểm tra cài đặt MongoDB...${NC}"
    
    if command -v mongod &>/dev/null; then
        local version=$(mongod --version | grep -oP "db version v\K[0-9]+\.[0-9]+")
        echo -e "${GREEN}MongoDB phiên bản $version đã được cài đặt${NC}"
        return 0
    else
        echo -e "${RED}MongoDB chưa được cài đặt. Tiến hành cài đặt...${NC}"
        
        # Kiểm tra hệ điều hành
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
            VERSION=$VERSION_ID
        elif type lsb_release >/dev/null 2>&1; then
            OS=$(lsb_release -si)
            VERSION=$(lsb_release -sr)
        else
            OS=$(uname -s)
            VERSION=$(uname -r)
        fi
        
        OS=$(echo $OS | tr '[:upper:]' '[:lower:]')
        
        # Cài đặt MongoDB dựa trên hệ điều hành
        case $OS in
            ubuntu|debian)
                echo -e "${YELLOW}Cài đặt MongoDB trên $OS $VERSION...${NC}"
                apt-get update
                apt-get install -y gnupg curl
                curl -fsSL https://pgp.mongodb.com/server-$MONGO_VERSION.asc | gpg -o /usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg --dearmor
                echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] http://repo.mongodb.org/apt/$OS $(lsb_release -cs)/mongodb-org/$MONGO_VERSION multiverse" | tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
                apt-get update
                apt-get install -y mongodb-org
                ;;
            centos|redhat|fedora|rhel)
                echo -e "${YELLOW}Cài đặt MongoDB trên $OS $VERSION...${NC}"
                cat > /etc/yum.repos.d/mongodb-org-$MONGO_VERSION.repo <<EOF
[mongodb-org-$MONGO_VERSION]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/$MONGO_VERSION/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc
EOF
                yum install -y mongodb-org
                ;;
            *)
                echo -e "${RED}Không hỗ trợ cài đặt tự động trên $OS. Vui lòng cài đặt MongoDB thủ công.${NC}"
                return 1
                ;;
        esac
        
        # Kiểm tra lại việc cài đặt
        if command -v mongod &>/dev/null; then
            local version=$(mongod --version | grep -oP "db version v\K[0-9]+\.[0-9]+")
            echo -e "${GREEN}MongoDB phiên bản $version đã được cài đặt thành công${NC}"
            return 0
        else
            echo -e "${RED}Cài đặt MongoDB thất bại${NC}"
            return 1
        fi
    fi
}

# Lấy IP của máy chủ
get_server_ip() {
    local external_ip=""
    local quiet=${1:-false}
    
    # Thử lấy IP public
    if command -v curl &>/dev/null; then
        external_ip=$(curl -s -4 ifconfig.co 2>/dev/null)
    elif command -v wget &>/dev/null; then
        external_ip=$(wget -qO- ifconfig.co 2>/dev/null)
    fi
    
    # Nếu không lấy được IP public, thử lấy IP private
    if [ -z "$external_ip" ] || [[ "$external_ip" =~ ^127\.|^10\.|^172\.16\.|^192\.168\. ]]; then
        # Lấy IP dựa trên giao diện mạng chính
        if command -v ip &>/dev/null; then
            # Lấy IP từ giao diện mạng chính (không phải lo/loopback)
            local default_iface=$(ip route | grep default | awk '{print $5}' | head -n1)
            if [ -n "$default_iface" ]; then
                local ip_addr=$(ip -4 addr show $default_iface | grep -oP "(?<=inet )([0-9]{1,3}\.){3}[0-9]{1,3}")
                if [ -n "$ip_addr" ]; then
                    external_ip=$ip_addr
                fi
            fi
        elif command -v ifconfig &>/dev/null; then
            # Backup nếu không có ip command
            local ip_addr=$(ifconfig | grep -A1 'eth0\|en0\|ens3' | grep -oP "(?<=inet )([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n1)
            if [ -n "$ip_addr" ]; then
                external_ip=$ip_addr
            fi
        fi
    fi
    
    # Nếu vẫn không lấy được IP, sử dụng localhost
    if [ -z "$external_ip" ]; then
        external_ip="127.0.0.1"
        if [ "$quiet" = false ]; then
            echo -e "${YELLOW}Không thể xác định IP, sử dụng localhost: $external_ip${NC}"
        fi
    else
        if [ "$quiet" = false ]; then
            echo -e "${GREEN}IP máy chủ: $external_ip${NC}"
        fi
    fi
    
    echo "$external_ip"
} 