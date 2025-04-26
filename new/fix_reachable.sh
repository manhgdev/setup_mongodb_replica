#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Thông tin kết nối
host="localhost"
port="27017"
username="manhg"
password="manhnk"
auth_db="admin"

# Hàm kiểm tra kết nối MongoDB
check_mongodb_connection() {
    if mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Kết nối thành công đến $host:$port"
        return 0
    else
        echo -e "${RED}✗${NC} Không thể kết nối đến $host:$port"
        return 1
    fi
}

# Hàm kiểm tra node có đang chạy không
check_node_running() {
    local node_host=$1
    local node_port=$2
    if mongosh --host $node_host --port $node_port --username $username --password $password --authenticationDatabase $auth_db --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Node $node_host:$node_port đang chạy"
        return 0
    else
        echo -e "${RED}✗${NC} Node $node_host:$node_port không chạy"
        return 1
    fi
}

# Hàm kiểm tra kết nối mạng
check_network_connection() {
    local node_host=$1
    local node_port=$2
    if nc -z $node_host $node_port >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Có thể kết nối đến $node_host:$node_port"
        return 0
    else
        echo -e "${RED}✗${NC} Không thể kết nối đến $node_host:$node_port"
        return 1
    fi
}

# Hàm kiểm tra cấu hình replica set
check_replica_set_config() {
    local node_host=$1
    local node_port=$2
    echo -e "\n${BLUE}Kiểm tra cấu hình replica set trên $node_host:$node_port:${NC}"
    mongosh --host $node_host --port $node_port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.conf()"
}

# Hàm kiểm tra quyền truy cập
check_access_rights() {
    local node_host=$1
    local node_port=$2
    echo -e "\n${BLUE}Kiểm tra quyền truy cập trên $node_host:$node_port:${NC}"
    mongosh --host $node_host --port $node_port --username $username --password $password --authenticationDatabase $auth_db --eval "db.runCommand({connectionStatus: 1})"
}

# Hàm lấy danh sách các node không reachable
get_unreachable_nodes() {
    echo -e "\n${BLUE}Danh sách các node không reachable:${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.status().members.forEach(function(member) { if (member.stateStr === '(not reachable/healthy)') { print(member.name) } })"
}

# Hàm xóa node không reachable
remove_unreachable_node() {
    local node_name=$1
    echo -e "\n${YELLOW}Đang xóa node $node_name...${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.remove('$node_name')"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Đã xóa node $node_name thành công"
    else
        echo -e "${RED}✗${NC} Không thể xóa node $node_name"
    fi
}

# Hàm kiểm tra và khởi động lại node
restart_node() {
    local node_name=$1
    local node_host=$(echo $node_name | cut -d':' -f1)
    local node_port=$(echo $node_name | cut -d':' -f2)
    
    echo -e "\n${YELLOW}Kiểm tra node $node_name...${NC}"
    
    # Kiểm tra kết nối mạng
    if ! check_network_connection $node_host $node_port; then
        echo -e "${RED}Không thể kết nối đến node. Vui lòng kiểm tra mạng.${NC}"
        return 1
    fi
    
    # Kiểm tra node có đang chạy không
    if ! check_node_running $node_host $node_port; then
        echo -e "${YELLOW}Node không chạy. Đang thử khởi động lại...${NC}"
        # Thử khởi động lại MongoDB trên node
        ssh $node_host "sudo systemctl restart mongod"
        sleep 5
        
        # Kiểm tra lại sau khi khởi động
        if check_node_running $node_host $node_port; then
            echo -e "${GREEN}✓${NC} Đã khởi động lại node thành công"
        else
            echo -e "${RED}✗${NC} Không thể khởi động lại node"
            return 1
        fi
    fi
    
    # Kiểm tra cấu hình replica set
    check_replica_set_config $node_host $node_port
    
    # Kiểm tra quyền truy cập
    check_access_rights $node_host $node_port
    
    return 0
}

# Hàm thêm lại node
add_node_back() {
    local node_name=$1
    echo -e "\n${YELLOW}Đang thêm lại node $node_name...${NC}"
    mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.add('$node_name')"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Đã thêm lại node $node_name thành công"
    else
        echo -e "${RED}✗${NC} Không thể thêm lại node $node_name"
    fi
}

# Main
echo -e "${YELLOW}Fix lỗi node không reachable/healthy${NC}"
echo -e "${YELLOW}===============================${NC}"

# Kiểm tra kết nối
if check_mongodb_connection; then
    # Lấy danh sách các node không reachable
    get_unreachable_nodes
    
    # Hỏi người dùng có muốn xử lý các node không reachable không
    read -p "Bạn có muốn xử lý các node không reachable không? (y/n): " choice
    if [[ $choice == "y" || $choice == "Y" ]]; then
        # Lấy danh sách các node không reachable và xử lý từng node
        mongosh --host $host --port $port --username $username --password $password --authenticationDatabase $auth_db --eval "rs.status().members.forEach(function(member) { if (member.stateStr === '(not reachable/healthy)') { print(member.name) } })" | while read -r node_name; do
            if [ ! -z "$node_name" ]; then
                # Kiểm tra và khởi động lại node nếu cần
                if restart_node "$node_name"; then
                    # Xóa node cũ
                    remove_unreachable_node "$node_name"
                    sleep 2
                    # Thêm lại node
                    add_node_back "$node_name"
                    sleep 5
                else
                    echo -e "${RED}Không thể xử lý node $node_name. Vui lòng kiểm tra thủ công.${NC}"
                fi
            fi
        done
        
        echo -e "\n${GREEN}Đã hoàn thành việc xử lý các node không reachable${NC}"
    else
        echo -e "\n${YELLOW}Đã hủy thao tác${NC}"
    fi
else
    echo -e "${RED}Không thể kết nối đến MongoDB. Vui lòng kiểm tra lại thông tin kết nối.${NC}"
fi 