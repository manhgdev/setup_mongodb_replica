#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Cài đặt mặc định
MAX_RETRIES=5
RETRY_INTERVAL=5
CURRENT_IP=$(hostname -I | awk '{print $1}')
CURRENT_PORT=27017
MONGO_USERNAME=""
MONGO_PASSWORD=""
detected_nodes=""
unreachable_nodes=""
connected_primary=""

# Hàm kiểm tra kết nối tới MongoDB
check_connection() {
    local host=$1
    local retries=$2
    local interval=$3
    local auth_params=""
    
    if [ ! -z "$MONGO_USERNAME" ] && [ ! -z "$MONGO_PASSWORD" ]; then
        auth_params="--username $MONGO_USERNAME --password $MONGO_PASSWORD --authenticationDatabase admin"
    fi
    
    echo -e "${YELLOW}Đang kiểm tra kết nối tới $host...${NC}"
    
    for ((i=1; i<=$retries; i++)); do
        if timeout 5 mongosh --quiet --eval "db.runCommand({ ping: 1 })" "$host" $auth_params &>/dev/null; then
            echo -e "${GREEN}Kết nối thành công tới $host${NC}"
            return 0
        else
            echo -e "${YELLOW}Lần thử $i: Không thể kết nối tới $host, thử lại sau $interval giây...${NC}"
            sleep $interval
        fi
    done
    
    echo -e "${RED}Không thể kết nối tới $host sau $retries lần thử${NC}"
    return 1
}

# Hàm tìm host hiện tại
find_current_host() {
    local reachable_host=""
    
    # Thử kết nối tới các port MongoDB mặc định
    for port in 27017 27018 27019; do
        local host="$CURRENT_IP:$port"
        if check_connection "$host" 1 1; then
            CURRENT_IP=$CURRENT_IP
            CURRENT_PORT=$port
            reachable_host=$host
            break
        fi
    done
    
    # Nếu không tìm thấy kết nối
    if [ -z "$reachable_host" ]; then
        echo -e "${RED}Không thể kết nối tới bất kỳ node MongoDB nào trên máy hiện tại${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Sử dụng node $reachable_host cho thao tác${NC}"
}

# Hàm lấy thông tin replica set
get_replica_info() {
    local host="$CURRENT_IP:$CURRENT_PORT"
    local auth_params=""
    
    if [ ! -z "$MONGO_USERNAME" ] && [ ! -z "$MONGO_PASSWORD" ]; then
        auth_params="--username $MONGO_USERNAME --password $MONGO_PASSWORD --authenticationDatabase admin"
    fi
    
    echo -e "${YELLOW}Đang lấy thông tin replica set từ $host...${NC}"
    
    # Lấy thông tin tất cả các nodes trong replica set
    local all_nodes=$(mongosh --quiet --eval "
        const status = rs.status();
        if (!status || !status.members) {
            print('NOT_IN_REPLSET');
        } else {
            status.members.forEach(m => print(m.name + ' ' + m.stateStr));
        }
    " "$host" $auth_params)
    
    # Kiểm tra xem có trong replica set không
    if [ "$all_nodes" == "NOT_IN_REPLSET" ]; then
        echo -e "${RED}Node $host không nằm trong replica set nào${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Thông tin replica set:${NC}"
    echo "$all_nodes"
    
    # Lấy danh sách tất cả các nodes từ rs.conf()
    local all_config_nodes=$(mongosh --quiet --eval "
        const conf = rs.conf();
        if (!conf || !conf.members) {
            print('NO_CONFIG');
        } else {
            conf.members.forEach(m => print(m.host));
        }
    " "$host" $auth_params)
    
    if [ "$all_config_nodes" == "NO_CONFIG" ]; then
        echo -e "${RED}Không thể lấy cấu hình replica set${NC}"
        return 1
    fi
    
    # Kiểm tra kết nối tới tất cả các nodes
    detected_nodes=""
    unreachable_nodes=""
    echo -e "${YELLOW}Kiểm tra kết nối tới tất cả các nodes trong replica set...${NC}"
    
    while read -r node; do
        if check_connection "$node" 2 2; then
            if [ -z "$detected_nodes" ]; then
                detected_nodes="$node"
            else
                detected_nodes="$detected_nodes $node"
            fi
            
            # Lưu lại node đầu tiên trên port 27017 nếu nó kết nối được
            if [[ "$node" == *":27017" ]] && [ -z "$connected_primary" ]; then
                connected_primary="$node"
            fi
        else
            if [ -z "$unreachable_nodes" ]; then
                unreachable_nodes="$node"
            else
                unreachable_nodes="$unreachable_nodes $node"
            fi
        fi
    done <<< "$all_config_nodes"
    
    # Nếu không có node nào trên port 27017 kết nối được, thì dùng node đầu tiên trong danh sách có thể kết nối được làm PRIMARY
    if [ -z "$connected_primary" ] && [ ! -z "$detected_nodes" ]; then
        connected_primary=$(echo $detected_nodes | cut -d ' ' -f1)
        echo -e "${YELLOW}Không tìm thấy node port 27017, sử dụng $connected_primary làm PRIMARY${NC}"
    fi
    
    echo -e "${GREEN}Các node kết nối được: $detected_nodes${NC}"
    echo -e "${YELLOW}Các node không kết nối được: $unreachable_nodes${NC}"
    
    # Kiểm tra xem có đủ node và không có node nào là PRIMARY không
    local primary_count=$(echo "$all_nodes" | grep "PRIMARY" | wc -l)
    if [ $primary_count -eq 0 ]; then
        echo -e "${RED}Cảnh báo: Không có node PRIMARY trong replica set${NC}"
    elif [ $primary_count -gt 1 ]; then
        echo -e "${RED}Cảnh báo: Có $primary_count node PRIMARY trong replica set${NC}"
    fi
}

# Hàm sửa replica set
fix_replica_set() {
    local host="$CURRENT_IP:$CURRENT_PORT"
    local auth_params=""
    
    if [ ! -z "$MONGO_USERNAME" ] && [ ! -z "$MONGO_PASSWORD" ]; then
        auth_params="--username $MONGO_USERNAME --password $MONGO_PASSWORD --authenticationDatabase admin"
    fi
    
    # Luôn loại bỏ các node không kết nối được
    REMOVE_NODES="y"
    if [ ! -z "$unreachable_nodes" ]; then
        echo -e "${YELLOW}Phát hiện các node không kết nối được: $unreachable_nodes${NC}"
        echo -e "${YELLOW}Các node này sẽ tự động bị loại bỏ khỏi replica set${NC}"
    fi
    
    # Tạo force config script
    local force_script="
    // Lấy config hiện tại
    var currentConfig = rs.conf();
    var members = [];
    
    if (currentConfig && currentConfig.members) {
        members = currentConfig.members;
        print('Đang sử dụng cấu hình hiện tại với ' + members.length + ' nodes.');
        
        // Thay đổi priority và loại bỏ node không kết nối nếu cần
        var keepMembers = [];
        var nextId = 0;
        
        for (var i = 0; i < members.length; i++) {
            var member = members[i];
            var keep = true;
            
            // Kiểm tra có loại bỏ node không kết nối không
            if ('$REMOVE_NODES' === 'y') {
                var unreachableNodes = '$unreachable_nodes'.trim().split(' ');
                for (var j = 0; j < unreachableNodes.length; j++) {
                    if (unreachableNodes[j] && member.host === unreachableNodes[j]) {
                        print('Loại bỏ node không kết nối được: ' + member.host);
                        keep = false;
                        break;
                    }
                }
            }
            
            if (keep) {
                // Đặt priority
                if (member.host === '$connected_primary') {
                    member.priority = 10;
                    print('Đặt ' + member.host + ' làm PRIMARY với priority 10');
                } else if (!member.arbiterOnly) {
                    member.priority = 1;
                    print('Đặt ' + member.host + ' làm SECONDARY với priority 1');
                }
                
                // Cập nhật ID
                member._id = nextId++;
                keepMembers.push(member);
            }
        }
        
        members = keepMembers;
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
    
    // Kiểm tra xác nhận số lượng thành viên 
    print('Cấu hình mới có ' + members.length + ' nodes');
    
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
    
    echo -e "${YELLOW}Đang chuẩn bị force reconfiguration...${NC}"
    echo -e "${YELLOW}Connected PRIMARY node sẽ là: $connected_primary${NC}"
    
    # Thực hiện force reconfiguration
    local result=$(mongosh --quiet --eval "$force_script" "$host" $auth_params)
    echo -e "${GREEN}Kết quả:${NC}"
    echo "$result"
    
    # Kiểm tra kết quả
    if echo "$result" | grep -q "force reconfig thành công\|khởi tạo mới replica set"; then
        echo -e "${GREEN}Đã sửa thành công replica set${NC}"
        
        # Kiểm tra lại trạng thái của replica set
        echo -e "${YELLOW}Đang kiểm tra lại trạng thái replica set...${NC}"
        sleep 10
        
        local status=$(mongosh --quiet --eval "rs.status()" "$host" $auth_params)
        if echo "$status" | grep -q "PRIMARY"; then
            echo -e "${GREEN}Replica set đã có PRIMARY node${NC}"
            return 0
        else
            echo -e "${YELLOW}Replica set vẫn chưa có PRIMARY node, bạn cần đợi thêm...${NC}"
            return 1
        fi
    else
        echo -e "${RED}Không thể sửa replica set${NC}"
        return 1
    fi
}

# Chức năng chính
main() {
    echo -e "${GREEN}MongoDB Replica Set Emergency Fix Tool${NC}"
    
    # Tìm host hiện tại
    find_current_host
    
    # Lấy thông tin replica set
    get_replica_info
    
    # Hỏi người dùng có muốn sửa replica set không
    read -p "Bạn có muốn sửa replica set không? (y/n): " CONFIRM_FIX
    if [ "$CONFIRM_FIX" == "y" ]; then
        # Sửa replica set
        fix_replica_set
    else
        echo -e "${YELLOW}Đã hủy thao tác sửa replica set${NC}"
    fi
    
    echo -e "${GREEN}Hoàn thành!${NC}"
}

# Thực thi chương trình
main 