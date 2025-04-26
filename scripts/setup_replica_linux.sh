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
        
        # Thêm node vào replica set với IP thực
        echo -e "${YELLOW}Đang thêm node $secondary_ip vào replica set...${NC}"
        add_result=$(mongosh --host "$primary_ip" --port "$MONGO_PORT" -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.add('$secondary_ip:$MONGO_PORT')" --quiet)
        
        # Kiểm tra kết quả
        if echo "$add_result" | grep -q "\"ok\" : 1"; then
            echo -e "${GREEN}✅ Đã thêm node vào replica set thành công!${NC}"
        else
            echo -e "${RED}❌ Có lỗi khi thêm node:${NC}"
            echo "$add_result"
        fi
        
        # Đợi node đồng bộ
        echo -e "${YELLOW}Đợi node đồng bộ với replica set (30 giây)...${NC}"
        sleep 30
        
        # Kiểm tra trạng thái
        check_replica_status "$primary_ip"
    fi
    
    echo -e "${GREEN}Thiết lập SECONDARY NODE hoàn tất!${NC}"
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
        local server_ip=$(get_server_ip true || echo 'không có')
        local port_value=${MONGO_PORT:-$MONGODB_PORT}
        echo "Server IP: $server_ip"
        echo "MongoDB Version: ${MONGO_VERSION:-8.0} | Port: ${port_value:-27017} | Replica: ${REPLICA_SET_NAME:-rs0}"
        echo
        
        read -p ">> Chọn chức năng [0-6]: " choice
        
        case $choice in
            1) setup_primary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            2) setup_secondary_node; read -p "Nhấn Enter để tiếp tục..." ;;
            3) 
               # Kiểm tra trạng thái MongoDB trước khi chạy check_replica_status
               local server_ip=$(get_server_ip)
               echo -e "${YELLOW}Kiểm tra trạng thái MongoDB tại $server_ip:$MONGO_PORT...${NC}"
               
               # Kiểm tra port đang mở
               if nc -z -w5 $server_ip $MONGO_PORT 2>/dev/null; then
                 echo -e "${GREEN}✅ MongoDB đang chạy và port $MONGO_PORT đang mở${NC}"
                 check_replica_status
               else
                 echo -e "${RED}❌ MongoDB không chạy hoặc port $MONGO_PORT không mở${NC}"
                 echo -e "${YELLOW}Kiểm tra trạng thái service:${NC}"
                 $sudo_cmd systemctl status mongod || true
                 echo -e "${YELLOW}Bạn có muốn khởi động lại MongoDB không? (y/n)${NC}"
                 read -p "> " restart_choice
                 if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
                   stop_mongodb && start_mongodb && sleep 5
                   echo -e "${YELLOW}Đang kiểm tra lại trạng thái...${NC}"
                   check_replica_status
                 fi
               fi
               read -p "Nhấn Enter để tiếp tục..." 
               ;;
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