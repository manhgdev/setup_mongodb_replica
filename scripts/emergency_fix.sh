#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[0;33m'

# Default admin credentials
ADMIN_USER="manhg"
ADMIN_PASS="manhnk"

emergency_fix_replica() {
    echo -e "${RED}===== KHẮC PHỤC KHẨN CẤP REPLICA SET =====${NC}"
    echo -e "${RED}Sử dụng khi không có PRIMARY hoặc có node ở trạng thái OTHER${NC}"
    
    # Nhận thông tin kết nối
    read -p "Nhập IP của node hiện tại: " CURRENT_IP
    read -p "Nhập port của node hiện tại (mặc định 27017): " CURRENT_PORT
    CURRENT_PORT=${CURRENT_PORT:-27017}
    
    # Nhận thông tin xác thực
    read -p "Nhập tên người dùng admin (mặc định $ADMIN_USER): " INPUT_ADMIN_USER
    ADMIN_USER=${INPUT_ADMIN_USER:-$ADMIN_USER}
    read -p "Nhập mật khẩu admin (mặc định $ADMIN_PASS): " INPUT_ADMIN_PASS
    ADMIN_PASS=${INPUT_ADMIN_PASS:-$ADMIN_PASS}
    
    # Bước 1: Kiểm tra trạng thái hiện tại
    echo -e "\n${YELLOW}Bước 1: Kiểm tra trạng thái hiện tại của replica set${NC}"
    echo "Thử kết nối với xác thực..."
    local status_result=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT -u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin --eval "rs.status()" --quiet 2>&1)
    
    if [[ $status_result == *"no primary"* || $status_result == *"connect"* || $status_result == *"auth fail"* ]]; then
        echo -e "${YELLOW}Không thể kết nối với xác thực hoặc không có PRIMARY${NC}"
        echo "Thử kết nối không xác thực..."
        status_result=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT --eval "rs.status()" --quiet 2>&1)
    fi
    
    echo -e "${GREEN}Trạng thái replica set hiện tại:${NC}"
    echo "$status_result"
    
    # Bước 2: Liệt kê tất cả các node
    echo -e "\n${YELLOW}Bước 2: Liệt kê tất cả các node trong replica set${NC}"
    local nodes_info=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT --eval "rs.conf().members.forEach(function(m) { print(m._id + ': ' + m.host + ' (priority: ' + m.priority + ')') })" --quiet 2>&1)
    
    if [[ $nodes_info == *"MongoNetworkError"* || -z "$nodes_info" ]]; then
        echo -e "${RED}Không thể lấy danh sách node. Replica set có thể đã hỏng hoàn toàn.${NC}"
        echo "Thử force reconfigure với config mới..."
        
        # Tìm tất cả các node MongoDB đang chạy
        echo "Tìm các port MongoDB đang hoạt động..."
        local active_ports=$(sudo lsof -i -P -n | grep mongod | grep LISTEN | awk '{print $9}' | cut -d':' -f2 | sort | uniq)
        
        if [ -z "$active_ports" ]; then
            echo -e "${RED}Không tìm thấy port MongoDB nào đang hoạt động${NC}"
            echo "Đang kiểm tra các dịch vụ MongoDB..."
            sudo systemctl list-units | grep mongod
            echo "Bạn cần đảm bảo ít nhất một node MongoDB đang chạy."
            return 1
        fi
        
        echo "Các port MongoDB đang hoạt động: $active_ports"
        echo "Tạo cấu hình mới..."
        
        # Ưu tiên port 27017 cho PRIMARY nếu có
        local primary_port=""
        if [[ $active_ports == *"27017"* ]]; then
            primary_port="27017"
            echo "Port 27017 sẽ được cấu hình làm PRIMARY."
        else
            # Chọn port đầu tiên trong danh sách làm PRIMARY
            primary_port=$(echo $active_ports | awk '{print $1}')
            echo "Port $primary_port sẽ được cấu hình làm PRIMARY (port 27017 không khả dụng)."
        fi
    else
        echo "Các node đã được tìm thấy:"
        echo "$nodes_info"
    fi
    
    # Bước 3: Force reconfigure với node có port 27017 làm PRIMARY
    echo -e "\n${YELLOW}Bước 3: Khởi tạo lại replica set với force config${NC}"
    
    # Tạo force config script
    local force_script="
    // Lấy config hiện tại
    var currentConfig = rs.conf();
    var members = [];
    
    if (currentConfig && currentConfig.members) {
        members = currentConfig.members;
        print('Đang sử dụng cấu hình hiện tại với ' + members.length + ' nodes.');
        
        // Thay đổi priority
        members.forEach(function(member) {
            if (member.host.includes(':27017')) {
                member.priority = 10;
                print('Đặt ' + member.host + ' làm PRIMARY với priority 10');
            } else if (!member.arbiterOnly) {
                member.priority = 1;
                print('Đặt ' + member.host + ' làm SECONDARY với priority 1');
            }
        });
    } else {
        print('Không tìm thấy cấu hình hiện tại, tạo cấu hình mới');
        
        // Sử dụng địa chỉ IP hiện tại
        var currentHost = '$CURRENT_IP:$CURRENT_PORT';
        members = [{ _id: 0, host: currentHost, priority: 10 }];
        print('Tạo replica set mới với node ' + currentHost + ' làm PRIMARY');
    }
    
    // Tạo config mới
    var newConfig = {
        _id: 'rs0',
        members: members
    };
    
    // Force reconfig
    try {
        rs.reconfig(newConfig, { force: true });
        print('Đã force reconfig thành công');
    } catch (e) {
        print('Lỗi khi force reconfig: ' + e);
        
        // Nếu thất bại, thử khởi tạo mới hoàn toàn
        try {
            rs.initiate(newConfig);
            print('Đã khởi tạo mới replica set');
        } catch (e2) {
            print('Lỗi khi khởi tạo mới: ' + e2);
        }
    }
    "
    
    echo "Thực hiện force reconfigure..."
    local force_result=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT --eval "$force_script" --quiet)
    
    echo "$force_result"
    
    # Bước 4: Chờ bầu cử PRIMARY
    echo -e "\n${YELLOW}Bước 4: Chờ bầu cử PRIMARY mới (60 giây)${NC}"
    
    for i in {1..12}; do
        echo "Kiểm tra lần $i..."
        local status_check=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr) })" --quiet)
        
        echo "$status_check"
        
        if [[ $status_check == *"PRIMARY"* ]]; then
            echo -e "${GREEN}✅ Đã tìm thấy PRIMARY!${NC}"
            break
        fi
        
        if [ $i -lt 12 ]; then
            echo "Chờ 5 giây..."
            sleep 5
        fi
    done
    
    # Bước 5: Kiểm tra trạng thái cuối cùng
    echo -e "\n${YELLOW}Bước 5: Kiểm tra trạng thái cuối cùng${NC}"
    
    local final_status=$(mongosh --host $CURRENT_IP --port $CURRENT_PORT --eval "rs.status().members.forEach(function(m) { print(m.name + ' - ' + m.stateStr) })" --quiet 2>&1)
    
    if [[ $final_status == *"PRIMARY"* ]]; then
        echo -e "${GREEN}✅ Replica set đã được khôi phục thành công!${NC}"
        echo "Trạng thái hiện tại:"
        echo "$final_status"
        
        # Kiểm tra xem có node nào ở trạng thái OTHER không
        if [[ $final_status == *"OTHER"* ]]; then
            echo -e "${YELLOW}⚠️ Có node ở trạng thái OTHER. Có thể cần khởi động lại các node này.${NC}"
            echo "Sử dụng lệnh sau trên các node bị ảnh hưởng:"
            echo "sudo systemctl restart mongod_<port>"
        fi
    else
        echo -e "${RED}❌ Không thể khôi phục replica set hoàn toàn${NC}"
        echo "Trạng thái hiện tại:"
        echo "$final_status"
        echo -e "${YELLOW}Hãy thử các bước sau:${NC}"
        echo "1. Kiểm tra log: sudo tail -f /var/log/mongodb/mongod_${CURRENT_PORT}.log"
        echo "2. Kiểm tra firewall và kết nối mạng giữa các node"
        echo "3. Khởi động lại toàn bộ các node: sudo systemctl restart mongod_<port>"
        echo "4. Thử lại process này"
    fi
    
    echo -e "\n${GREEN}Quá trình khắc phục khẩn cấp đã hoàn tất.${NC}"
}

# Chạy hàm khắc phục khẩn cấp
emergency_fix_replica 