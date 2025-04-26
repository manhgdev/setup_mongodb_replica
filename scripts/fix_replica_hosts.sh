#!/bin/bash

# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import required configuration files
if [ -f "$SCRIPT_DIR/../config/mongodb_settings.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_settings.sh"
fi

if [ -f "$SCRIPT_DIR/../config/mongodb_functions.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_functions.sh"
fi

# Define colors if not defined
if [ -z "$BLUE" ] || [ -z "$GREEN" ] || [ -z "$YELLOW" ] || [ -z "$RED" ] || [ -z "$NC" ]; then
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    NC='\033[0m'
fi

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}       ${YELLOW}FIX REPLICA SET CONFIGURATION${NC}        ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

# Get the server's real IP
SERVER_IP=$(get_server_ip)
echo -e "${YELLOW}Server IP detected: ${GREEN}$SERVER_IP${NC}"

# Ask for credentials
read -p "MongoDB username [$MONGODB_USER]: " username
username=${username:-$MONGODB_USER}

read -sp "MongoDB password [$MONGODB_PASSWORD]: " password
password=${password:-$MONGODB_PASSWORD}
echo ""

# Get current replica set configuration
echo -e "${YELLOW}Getting current replica set configuration...${NC}"
CONFIG=$(mongosh --quiet --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "JSON.stringify(rs.conf())")

if [ -z "$CONFIG" ]; then
    echo -e "${RED}Failed to get replica set configuration. Check your credentials.${NC}"
    exit 1
fi

# Parse the configuration
echo -e "${YELLOW}Current replica set members:${NC}"
MEMBERS=$(mongosh --quiet --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
// Lấy danh sách thành viên với IP thật thay vì localhost
let members = rs.conf().members;
let serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];

for (let i = 0; i < members.length; i++) {
  let host = members[i].host;
  let parts = host.split(':');
  
  // Thay thế localhost bằng địa chỉ IP thực
  if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
    host = serverIp + ':' + parts[1];
  }
  
  print(members[i]._id + ': ' + host);
}
")
echo "$MEMBERS"

# Check connectivity between nodes
echo -e "${YELLOW}Checking connectivity between nodes...${NC}"
HOSTS=$(mongosh --quiet --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
let results = [];
let members = rs.conf().members;
let serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];

for (let i = 0; i < members.length; i++) {
  let host = members[i].host;
  let parts = host.split(':');
  
  // Thay thế localhost bằng địa chỉ IP thực
  if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
    host = serverIp + ':' + parts[1];
  }
  
  results.push(host);
}

results.join(',');
")
IFS=',' read -ra HOST_ARRAY <<< "$HOSTS"

for host in "${HOST_ARRAY[@]}"; do
    # Split host:port
    IFS=':' read -ra HOST_PORT <<< "$host"
    check_host="${HOST_PORT[0]}"
    check_port="${HOST_PORT[1]}"
    
    # Skip localhost/127.0.0.1
    if [[ "$check_host" == "localhost" || "$check_host" == "127.0.0.1" ]]; then
        echo -e "${YELLOW}Skipping localhost check${NC}"
        continue
    fi
    
    # Try to ping the host
    if ping -c 1 -W 2 "$check_host" &>/dev/null; then
        echo -e "${GREEN}✓ Host $check_host is reachable (ping)${NC}"
    else
        echo -e "${RED}✗ Host $check_host is NOT reachable (ping)${NC}"
    fi
    
    # Check MongoDB port using telnet or nc
    if command -v nc &>/dev/null; then
        if nc -z -w 2 "$check_host" "$check_port" &>/dev/null; then
            echo -e "${GREEN}✓ MongoDB on $host is reachable (port check)${NC}"
        else
            echo -e "${RED}✗ MongoDB on $host is NOT reachable (port check)${NC}"
        fi
    elif command -v telnet &>/dev/null; then
        if timeout 2 telnet "$check_host" "$check_port" </dev/null &>/dev/null; then
            echo -e "${GREEN}✓ MongoDB on $host is reachable (port check)${NC}"
        else
            echo -e "${RED}✗ MongoDB on $host is NOT reachable (port check)${NC}"
        fi
    else
        echo -e "${YELLOW}! Cannot check port connectivity. Please install netcat (nc) or telnet${NC}"
    fi
done

# Create menu
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}       ${YELLOW}REPLICA SET OPERATIONS${NC}                ${BLUE}║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Update localhost to real IP               ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Remove unreachable/dead node              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Show detailed replica status              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Fix configuration for multi-server setup  ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${RED}0.${NC} Exit                                      ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

read -p "Choose an option [0-4]: " option

case $option in
    1)
        # Update localhost to real IP
        echo -e "${YELLOW}This will update all 'localhost' hosts to use the server IP: ${GREEN}$SERVER_IP${NC}"
        read -p "Do you want to continue? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 0
        fi
        
        # Apply the configuration directly
        echo -e "${YELLOW}Applying new configuration...${NC}"
        mongosh --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        try {
          // Get current configuration
          var cfg = rs.conf();
          
          // Track if any changes were made
          var changed = false;
          
          // Update member hostnames
          for (var i = 0; i < cfg.members.length; i++) {
            var host = cfg.members[i].host;
            var port = host.split(':')[1];
            
            if (host.includes('localhost') || host.includes('127.0.0.1')) {
              cfg.members[i].host = '$SERVER_IP:' + port;
              print('Updating member ' + i + ' from ' + host + ' to ' + cfg.members[i].host);
              changed = true;
            }
          }
          
          // Apply the new configuration if changed
          if (changed) {
            var result = rs.reconfig(cfg, {force: true});
            printjson(result);
          } else {
            print('No changes needed. All members already using correct IP.');
          }
        } catch (e) {
          print('ERROR: ' + e.message);
        }
        "
        ;;
    2)
        # Remove unreachable/dead node
        echo -e "${YELLOW}Removing unreachable/dead node...${NC}"
        
        # Lấy danh sách các node từ replica set
        NODE_LIST=$(mongosh --quiet --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        let members = rs.conf().members;
        let serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];
        let result = [];
        
        for (let i = 0; i < members.length; i++) {
          let host = members[i].host;
          let parts = host.split(':');
          
          // Thay thế localhost bằng địa chỉ IP thực
          if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
            host = serverIp + ':' + parts[1];
          }
          
          result.push({
            id: members[i]._id,
            host: host,
            origHost: members[i].host
          });
        }
        
        // Xuất danh sách dạng JSON
        JSON.stringify(result);
        ")
        
        # Hiển thị danh sách để người dùng chọn
        echo -e "${YELLOW}Chọn node muốn xóa:${NC}"
        IFS=$'\n' read -d '' -ra NODE_ARRAY < <(echo "$NODE_LIST" | jq -r '.[] | "\(.id): \(.host)"')
        
        for node_entry in "${NODE_ARRAY[@]}"; do
            echo "$node_entry"
        done
        
        read -p "Nhập ID của node (hoặc nhập địa chỉ host:port): " remove_choice
        
        # Xác định xem người dùng đã nhập ID hay địa chỉ
        if [[ "$remove_choice" =~ ^[0-9]+$ ]]; then
            # Người dùng đã nhập ID
            NODE_ID=$remove_choice
            ORIG_HOST=$(echo "$NODE_LIST" | jq -r ".[] | select(.id == $NODE_ID) | .origHost")
            DISPLAY_HOST=$(echo "$NODE_LIST" | jq -r ".[] | select(.id == $NODE_ID) | .host")
            
            if [ -z "$ORIG_HOST" ]; then
                echo -e "${RED}Không tìm thấy node với ID $NODE_ID${NC}"
                exit 1
            fi
            
            remove_host=$ORIG_HOST
            display_host=$DISPLAY_HOST
        else
            # Người dùng đã nhập địa chỉ host:port
            remove_host=$remove_choice
            display_host=$remove_choice
        fi
        
        if [ -z "$remove_host" ]; then
            echo -e "${RED}Không có node nào được chọn. Hủy thao tác.${NC}"
            exit 0
        fi
        
        # Xác nhận xóa
        echo -e "${YELLOW}Bạn sắp xóa node ${RED}$display_host${YELLOW} khỏi replica set.${NC}"
        read -p "Bạn có chắc chắn? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Đã hủy thao tác${NC}"
            exit 0
        fi
        
        # Áp dụng cấu hình trực tiếp
        echo -e "${YELLOW}Đang xóa node khỏi replica set...${NC}"
        mongosh --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        try {
          var result = rs.remove('$remove_host', {force: true});
          printjson(result);
        } catch (e) {
          print('ERROR: ' + e.message);
          
          // Thử phương pháp khác nếu cách thông thường thất bại
          try {
            print('Đang thử phương pháp thay thế...');
            var cfg = rs.conf();
            var newMembers = [];
            
            for (var i = 0; i < cfg.members.length; i++) {
              if (cfg.members[i].host !== '$remove_host') {
                newMembers.push(cfg.members[i]);
              } else {
                print('Đã tìm thấy node cần xóa: ' + cfg.members[i].host);
              }
            }
            
            if (newMembers.length === cfg.members.length) {
              print('Không tìm thấy node $remove_host trong cấu hình');
            } else {
              cfg.members = newMembers;
              var reconfigResult = rs.reconfig(cfg, {force: true});
              printjson(reconfigResult);
            }
          } catch (e2) {
            print('LỖI NGHIÊM TRỌNG: ' + e2.message);
          }
        }
        "
        ;;
    3)
        # Show detailed replica status
        echo -e "${YELLOW}Showing detailed replica set status...${NC}"
        mongosh --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.status()"
        ;;
    4)
        # Fix configuration for multi-server setup
        echo -e "${YELLOW}Fixing configuration for multi-server setup...${NC}"
        read -p "Enter the primary node host:port: " primary_host
        
        if [ -z "$primary_host" ]; then
            echo -e "${RED}No primary host specified. Operation cancelled.${NC}"
            exit 0
        fi
        
        # Confirm changes
        echo -e "${YELLOW}This will update the configuration to use the proper hostnames/IPs.${NC}"
        read -p "Do you want to continue? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 0
        fi
        
        # Apply the configuration directly
        echo -e "${YELLOW}Applying new configuration...${NC}"
        mongosh --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
        try {
          var primary = '$primary_host';
          var serverHosts = [];
          
          // Add current server if not already a member
          serverHosts.push('$SERVER_IP:$MONGO_PORT');
          
          // Get current configuration
          var cfg = rs.conf();
          
          // Check if any members need updating
          var changed = false;
          
          // First pass: update any localhost references to real IPs
          for (var i = 0; i < cfg.members.length; i++) {
            var host = cfg.members[i].host;
            
            if (host.includes('localhost') || host.includes('127.0.0.1')) {
              // This is a local reference, update it
              var port = host.split(':')[1];
              cfg.members[i].host = '$SERVER_IP:' + port;
              print('Updating local member ' + i + ' from ' + host + ' to ' + cfg.members[i].host);
              changed = true;
            }
          }
          
          // Apply the new configuration if changed
          if (changed) {
            print('Applying configuration updates...');
            var result = rs.reconfig(cfg, {force: true});
            printjson(result);
            print('Replica set configuration updated successfully');
          } else {
            print('No changes needed for local references.');
          }
          
          // Create simplified connection string for reference
          var connString = 'mongodb://$username:$password@';
          var hosts = [];
          
          for (var i = 0; i < cfg.members.length; i++) {
            hosts.push(cfg.members[i].host);
          }
          
          connString += hosts.join(',') + '/$AUTH_DATABASE?replicaSet=' + cfg._id;
          print('Connection string: ' + connString);
          
        } catch (e) {
          print('ERROR: ' + e.message);
        }
        "
        ;;
    0|*)
        echo -e "${GREEN}Exiting...${NC}"
        exit 0
        ;;
esac

# Check the new configuration
echo -e "${YELLOW}Verifying new configuration...${NC}"
sleep 3
NEW_MEMBERS=$(mongosh --quiet --host $SERVER_IP --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "
// Lấy và hiển thị cấu hình với IP thật thay vì localhost
let members = rs.conf().members;
let serverIp = db.adminCommand({ whatsmyuri: 1 }).you.split(':')[0];

for (let i = 0; i < members.length; i++) {
  let host = members[i].host;
  let parts = host.split(':');
  
  // Thay thế localhost bằng địa chỉ IP thực
  if (parts[0] === 'localhost' || parts[0] === '127.0.0.1') {
    host = serverIp + ':' + parts[1];
  }
  
  print(members[i]._id + ': ' + host);
}
")
echo "$NEW_MEMBERS"

echo -e "${GREEN}✓ Replica set configuration update completed!${NC}"
echo -e "${YELLOW}Note: It might take some time for all nodes to reconnect.${NC}"
echo -e "${YELLOW}Check status with: mongosh -u $username -p $password --authenticationDatabase $AUTH_DATABASE --eval \"rs.status()\"${NC}"

# Nếu script được gọi từ UI, cho phép trở về
read -p "[*] Nhấn Enter để tiếp tục..." enter 