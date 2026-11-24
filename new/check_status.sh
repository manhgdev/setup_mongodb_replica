#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/mongo_auth.sh" || exit 1

# Lấy đường dẫn thư mục chứa script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load các hàm utility từ lib
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/check_mongodb_connection.sh"

# Hàm kiểm tra kết nối MongoDB với format riêng cho check_status
check_mongodb_connection_status() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    if mongo_eval "$username" "$password" "$auth_db" --host $host --port $port --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Kết nối thành công đến $host:$port"
        return 0
    else
        echo -e "${RED}✗${NC} Không thể kết nối đến $host:$port"
        return 1
    fi
}

# Hàm lấy thông tin replica set
get_replica_set_info() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}📊 Thông tin Replica Set${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    
    RS_INFO=$(mongo_eval "$username" "$password" "$auth_db" --host $host --port $port --quiet --eval "
    const status = rs.status();
    print('SET:' + status.set);
    print('DATE:' + status.date);
    print('STATE:' + status.myState);
    status.members.forEach(m => {
        print('MEMBER:' + m.name + '|' + m.stateStr + '|' + m.health + '|' + (m.uptime || 0) + '|' + (m.lastHeartbeat || 'N/A') + '|' + (m.optimeDate || 'N/A'));
    });
    ")
    
    echo "$RS_INFO" | while IFS=: read -r key value; do
        case $key in
            SET) echo -e "${YELLOW}Replica Set:${NC} ${GREEN}$value${NC}" ;;
            DATE) echo -e "${YELLOW}Date:${NC} $value" ;;
            STATE) echo -e "${YELLOW}My State:${NC} ${CYAN}$value${NC}" ;;
            MEMBER)
                IFS='|' read -r name state health uptime heartbeat optime <<< "$value"
                echo -e "\n${YELLOW}  ▶ Node:${NC} ${CYAN}$name${NC}"
                if [ "$state" = "PRIMARY" ]; then
                    echo -e "    ${YELLOW}State:${NC} ${GREEN}$state${NC}"
                elif [ "$state" = "SECONDARY" ]; then
                    echo -e "    ${YELLOW}State:${NC} ${BLUE}$state${NC}"
                else
                    echo -e "    ${YELLOW}State:${NC} ${RED}$state${NC}"
                fi
                if [ "$health" = "1" ]; then
                    echo -e "    ${YELLOW}Health:${NC} ${GREEN}✓ $health${NC}"
                else
                    echo -e "    ${YELLOW}Health:${NC} ${RED}✗ $health${NC}"
                fi
                echo -e "    ${YELLOW}Uptime:${NC} ${CYAN}${uptime}s${NC}"
                [ "$heartbeat" != "N/A" ] && echo -e "    ${YELLOW}Last Heartbeat:${NC} $heartbeat"
                [ "$optime" != "N/A" ] && echo -e "    ${YELLOW}Optime:${NC} $optime"
                ;;
        esac
    done
}

# Hàm kiểm tra replication lag
check_replication_lag() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}⏱️  Replication Lag${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    mongo_eval "$username" "$password" "$auth_db" --host $host --port $port --quiet --eval "db.printSlaveReplicationInfo()"
}

# Hàm kiểm tra trạng thái các node
check_nodes_status() {
    local host=$1
    local port=$2
    local username=$3
    local password=$4
    local auth_db=$5
    
    echo -e "\n${MAGENTA}═══════════════════════════════════════${NC}"
    echo -e "${MAGENTA}🖥️  Trạng thái các Node${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════${NC}"
    
    NODES_INFO=$(mongo_eval "$username" "$password" "$auth_db" --host $host --port $port --quiet --eval "
    rs.status().members.forEach(function(member) { 
        print(member.name + '|' + member.stateStr + '|' + member.health);
    })")
    
    echo "$NODES_INFO" | while IFS='|' read -r name state health; do
        if [ "$health" = "1" ]; then
            HEALTH_ICON="${GREEN}✓${NC}"
        else
            HEALTH_ICON="${RED}✗${NC}"
        fi
        
        if [ "$state" = "PRIMARY" ]; then
            echo -e "$HEALTH_ICON ${GREEN}[PRIMARY]${NC} ${CYAN}$name${NC} ${GREEN}→ $state${NC}"
        elif [ "$state" = "SECONDARY" ]; then
            echo -e "$HEALTH_ICON ${BLUE}[SECONDARY]${NC} ${CYAN}$name${NC} ${BLUE}→ $state${NC}"
        else
            echo -e "$HEALTH_ICON ${YELLOW}[OTHER]${NC} ${CYAN}$name${NC} ${RED}→ $state${NC}"
        fi
    done
}

# Main
echo -e "${YELLOW}Kiểm tra trạng thái MongoDB Replica Set${NC}"
echo -e "${YELLOW}========================================${NC}"

# Nhập thông tin kết nối
read -p "Nhập host (mặc định: localhost): " host
host=${host:-localhost}

read -p "Nhập port (mặc định: 27017): " port
port=${port:-27017}

read -p "Nhập username: " username
username="manhg"
IFS= read -rs -p "Nhập password: " password || exit 1
echo
read -p "Nhập authentication database (mặc định: admin): " auth_db
auth_db=${auth_db:-admin}

# Kiểm tra kết nối
if check_mongodb_connection_status $host $port $username "$password" "$auth_db"; then
    # Lấy thông tin replica set
    get_replica_set_info $host $port $username "$password" "$auth_db"
    
    # Kiểm tra trạng thái các node
    check_nodes_status $host $port $username "$password" "$auth_db"
    
    # Kiểm tra replication lag
    check_replication_lag $host $port $username "$password" "$auth_db"
else
    echo -e "${RED}Không thể kết nối đến MongoDB. Vui lòng kiểm tra lại thông tin kết nối.${NC}"
fi 