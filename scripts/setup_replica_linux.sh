#!/bin/bash
# MongoDB Replica Set Setup Script
# Script thiết lập Replica Set MongoDB tự động

# Đảm bảo terminal hỗ trợ các ký tự ANSI
export TERM=xterm-256color

# Define colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Kiểm tra terminal hỗ trợ màu
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null)
    if [ -n "$ncolors" ] && [ $ncolors -ge 8 ]; then
        echo "Terminal hỗ trợ màu"
    else
        # Nếu terminal không hỗ trợ màu, đặt các biến màu về rỗng
        echo "Terminal không hỗ trợ màu, hiển thị văn bản thường"
        BLUE=''
        GREEN=''
        YELLOW=''
        RED=''
        NC=''
    fi
fi

# Kiểm tra xem script có đang chạy trên macOS hay không
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "${YELLOW}⚠️ Script này dành cho Linux. Đang chạy trên macOS, một số tính năng có thể không hoạt động.${NC}"
    echo
    read -p "Bạn có muốn tiếp tục? (y/n): " continue_mac
    if [[ "$continue_mac" != "y" && "$continue_mac" != "Y" ]]; then
        exit 1
    fi
fi

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
    
    # Chạy file khởi tạo
    mongosh --port "$MONGO_PORT" < "$init_script"
    
    # Xóa file tạm
    rm -f "$init_script"
    
    # Đợi replica set khởi tạo
    sleep 5
    
    echo -e "${GREEN}Đã khởi tạo replica set $REPLICA_SET_NAME với node đầu tiên là $ip:$MONGO_PORT${NC}"
}

# Thêm node vào replica set
add_replica_node() {
    local secondary_ip=$1
    local primary_ip=${2:-"localhost"}
    
    # Đảm bảo sử dụng IP thật
    if [[ "$secondary_ip" == "localhost" || "$secondary_ip" == "127.0.0.1" ]]; then
        secondary_ip=$(get_server_ip)
        echo -e "${YELLOW}Đã chuyển đổi 'localhost' thành IP thật: $secondary_ip${NC}"
    fi
    
    echo -e "${YELLOW}Thêm node $secondary_ip vào replica set $REPLICA_SET_NAME...${NC}"
    
    # Tạo script thêm node
    local add_script=$(mktemp)
    cat > "$add_script" <<EOF
rs.add("$secondary_ip:$MONGO_PORT")
EOF
    
    # Thực hiện trên primary
    mongosh --host "$primary_ip" --port "$MONGO_PORT" --eval "rs.add('$secondary_ip:$MONGO_PORT')"
    
    # Xóa file tạm
    rm -f "$add_script"
    
    echo -e "${GREEN}Đã thêm node $secondary_ip:$MONGO_PORT vào replica set${NC}"
}

# Kiểm tra trạng thái replica set
check_replica_status() {
    local host=${1:-"localhost"}
    
    echo -e "${YELLOW}Kiểm tra trạng thái replica set $REPLICA_SET_NAME...${NC}"
    
    # Yêu cầu thông tin đăng nhập
    read -p "Username (mặc định: $MONGODB_USER): " username
    read -sp "Password (mặc định: $MONGODB_PASSWORD): " password
    echo ""
    
    # Sử dụng giá trị mặc định nếu không nhập
    username=${username:-$MONGODB_USER}
    password=${password:-$MONGODB_PASSWORD}
    
    # Lấy thông tin status với xác thực
    local status=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.status()")
    
    # Hiển thị thông tin cơ bản
    local members=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr); })")
    
    echo -e "${GREEN}Thông tin replica set:${NC}"
    echo "$members"
    
    # Kiểm tra node primary
    local primary=$(mongosh --host "$host" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.isMaster().primary" | grep -v MongoDB)
    if [ -n "$primary" ]; then
        echo -e "${GREEN}Primary node: $primary${NC}"
    else
        echo -e "${RED}Không tìm thấy primary node${NC}"
    fi
}

# Thiết lập node như primary
setup_primary_node() {
    echo -e "${BLUE}=== THIẾT LẬP PRIMARY NODE ===${NC}"
    
    # Kiểm tra MongoDB đã được cài đặt
    check_mongodb
    
    # Dừng MongoDB hiện tại
    stop_mongodb
    
    # Tạo thư mục cần thiết
    create_dirs
    
    # Tạo keyfile
    create_keyfile true
    
    # Tạo file cấu hình
    create_config false false
    
    # Tạo systemd service
    create_systemd_service
    
    # Khởi động MongoDB
    start_mongodb
    
    # Cấu hình tường lửa
    configure_firewall
    
    # Thiết lập replica set
    init_replica_set "primary" $(get_server_ip)
    
    # Tạo admin user
    create_admin_user "$MONGODB_USER" "$MONGODB_PASSWORD" "$AUTH_DATABASE"
    
    # Dừng MongoDB để cập nhật cấu hình với security
    stop_mongodb
    
    # Cập nhật cấu hình với security và replication
    create_config true true
    
    # Khởi động lại MongoDB
    start_mongodb
    
    # Kiểm tra kết nối
    verify_mongodb_connection "localhost" "$MONGO_PORT" "$AUTH_DATABASE" "$MONGODB_USER" "$MONGODB_PASSWORD"
    
    # Kiểm tra trạng thái replica set
    check_replica_status
    
    echo -e "${GREEN}Thiết lập PRIMARY NODE hoàn tất!${NC}"
    
    # Hiển thị thông tin kết nối
    local server_ip=$(get_server_ip)
    echo -e "${YELLOW}Thông tin kết nối:${NC}"
    echo -e "  Địa chỉ: ${GREEN}$server_ip:$MONGO_PORT${NC}"
    echo -e "  Tên replica set: ${GREEN}$REPLICA_SET_NAME${NC}"
    echo -e "  Connection string: ${GREEN}mongodb://$MONGODB_USER:$MONGODB_PASSWORD@$server_ip:$MONGO_PORT/$AUTH_DATABASE?replicaSet=$REPLICA_SET_NAME${NC}"
}

# Thiết lập node như secondary
setup_secondary_node() {
    echo -e "${BLUE}=== THIẾT LẬP SECONDARY NODE ===${NC}"
    
    # Yêu cầu địa chỉ primary
    read -p "Nhập địa chỉ IP của PRIMARY node: " primary_ip
    
    # Kiểm tra thông tin primary
    if [ -z "$primary_ip" ]; then
        echo -e "${RED}Địa chỉ IP của PRIMARY node không được để trống${NC}"
        return 1
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
    
    # Lấy địa chỉ IP của secondary node
    local secondary_ip=$(get_server_ip)
    
    # Thông báo cho người dùng
    echo -e "${YELLOW}Địa chỉ IP của SECONDARY node: $secondary_ip${NC}"
    echo -e "${YELLOW}Hãy thêm node này vào replica set từ PRIMARY node bằng lệnh:${NC}"
    echo -e "${GREEN}mongosh --host $primary_ip --port $MONGO_PORT --eval \"rs.add('$secondary_ip:$MONGO_PORT')\"${NC}"
    
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
        
        # Thêm node vào replica set
        mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.add('$secondary_ip:$MONGO_PORT')"
    fi
    
    echo -e "${GREEN}Thiết lập SECONDARY NODE hoàn tất!${NC}"
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
        echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Kiểm tra trạng thái replica set         ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Khởi động lại MongoDB                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}5.${NC} Dừng MongoDB                            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${GREEN}6.${NC} Xem thông tin cấu hình                  ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC} ${RED}0.${NC} Quay lại menu chính                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
        echo "Server IP: $(get_server_ip true || echo 'không có')"
        echo "MongoDB Version: ${MONGO_VERSION} | Port: ${MONGODB_PORT} | Replica: ${REPLICA_SET_NAME}"
        echo
        
        read -p ">> Chọn chức năng [0-6]: " choice
        
        case $choice in
            1) setup_primary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            2) setup_secondary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            3) check_replica_status; read -p "Nhấn Enter để tiếp tục..." ;;
            4) stop_mongodb && start_mongodb; read -p "Nhấn Enter để tiếp tục..." ;;
            5) stop_mongodb; read -p "Nhấn Enter để tiếp tục..." ;;
            6) show_config; read -p "Nhấn Enter để tiếp tục..." ;;
            0) return 0 ;;
            *) echo "❌ Lựa chọn không hợp lệ. Vui lòng chọn lại."; read -p "Nhấn Enter để tiếp tục..." ;;
        esac
    done
}

# Chỉ chạy setup_replica_linux nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica_linux
fi