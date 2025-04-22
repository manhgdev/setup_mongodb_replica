#!/bin/bash

#============================================================
# TRIỂN KHAI TỰ ĐỘNG MONGODB REPLICA SET TRÊN 2 VPS
# Script này tự động triển khai MongoDB Replica Set phân tán
# giữa hai VPS, cấu hình chúng làm việc cùng nhau và tự động
# chuyển đổi khi một server gặp sự cố.
#============================================================

# Thiết lập màu cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Hiển thị banner
echo -e "${BLUE}
============================================================
  TRIỂN KHAI TỰ ĐỘNG MONGODB REPLICA SET TRÊN 2 VPS
============================================================${NC}"

# Thiết lập các biến mặc định
PRIMARY_IP=""
SECONDARY_IP=""
SSH_USER="root"
SSH_PORT="22"
SSH_KEY_PATH=""
SSH_PASSWORD=""
MONGO_PORT="27017"
REPLICA_SET="rs0"
MONGO_USER="manhgdev"
MONGO_PASSWORD="manhdepzai"
USE_PASSWORD_AUTH=false
SCRIPT_PATH="./setup_mongodb_distributed_replica.sh"

# Hàm hiển thị cách sử dụng
show_usage() {
  echo -e "${YELLOW}Cách sử dụng:${NC}"
  echo "  $0 [options]"
  echo
  echo -e "${YELLOW}Tùy chọn bắt buộc:${NC}"
  echo "  -p, --primary-ip IP      Địa chỉ IP của VPS primary"
  echo "  -s, --secondary-ip IP    Địa chỉ IP của VPS secondary"
  echo
  echo -e "${YELLOW}Tùy chọn SSH:${NC}"
  echo "  -u, --user USERNAME      Tên đăng nhập SSH (mặc định: root)"
  echo "  --port PORT              Cổng SSH (mặc định: 22)"
  echo "  -k, --key-path PATH      Đường dẫn đến SSH private key"
  echo "  --password PASSWORD      Mật khẩu SSH (thay cho key authentication)"
  echo
  echo -e "${YELLOW}Tùy chọn MongoDB:${NC}"
  echo "  --mongo-port PORT        Cổng MongoDB (mặc định: 27017)"
  echo "  --replica-set NAME       Tên replica set (mặc định: rs0)"
  echo "  --mongo-user USERNAME    Tên người dùng MongoDB (mặc định: manhgdev)"
  echo "  --mongo-password PASSWD  Mật khẩu MongoDB (mặc định: manhdepzai)"
  echo
  echo -e "${YELLOW}Tùy chọn khác:${NC}"
  echo "  --script-path PATH       Đường dẫn đến script cài đặt MongoDB"
  echo "  -h, --help               Hiển thị trợ giúp này"
  echo
  echo -e "${YELLOW}Ví dụ:${NC}"
  echo "  $0 -p 192.168.1.10 -s 192.168.1.11 -k ~/.ssh/id_rsa"
}

# Xử lý tham số dòng lệnh
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--primary-ip)
      PRIMARY_IP=$2
      shift 2
      ;;
    -s|--secondary-ip)
      SECONDARY_IP=$2
      shift 2
      ;;
    -u|--user)
      SSH_USER=$2
      shift 2
      ;;
    --port)
      SSH_PORT=$2
      shift 2
      ;;
    -k|--key-path)
      SSH_KEY_PATH=$2
      shift 2
      ;;
    --password)
      SSH_PASSWORD=$2
      USE_PASSWORD_AUTH=true
      shift 2
      ;;
    --mongo-port)
      MONGO_PORT=$2
      shift 2
      ;;
    --replica-set)
      REPLICA_SET=$2
      shift 2
      ;;
    --mongo-user)
      MONGO_USER=$2
      shift 2
      ;;
    --mongo-password)
      MONGO_PASSWORD=$2
      shift 2
      ;;
    --script-path)
      SCRIPT_PATH=$2
      shift 2
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Lỗi: Tùy chọn không được hỗ trợ '$1'${NC}" >&2
      show_usage
      exit 1
      ;;
  esac
done

# Kiểm tra các tham số bắt buộc
if [ -z "$PRIMARY_IP" ] || [ -z "$SECONDARY_IP" ]; then
  echo -e "${RED}Lỗi: Phải cung cấp địa chỉ IP cho cả hai VPS${NC}" >&2
  show_usage
  exit 1
fi

# Kiểm tra nếu script tồn tại
if [ ! -f "$SCRIPT_PATH" ]; then
  echo -e "${RED}Lỗi: Không tìm thấy script cài đặt tại '$SCRIPT_PATH'${NC}" >&2
  echo "Vui lòng chỉ định đường dẫn đúng với tùy chọn --script-path"
  exit 1
fi

# Xây dựng lệnh SSH dựa vào phương thức xác thực
build_ssh_command() {
  local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $SSH_PORT"
  
  if [ "$USE_PASSWORD_AUTH" = true ]; then
    # Sử dụng sshpass nếu xác thực bằng mật khẩu
    which sshpass > /dev/null
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}sshpass chưa được cài đặt. Đang cài đặt...${NC}"
      sudo apt-get update && sudo apt-get install -y sshpass
    fi
    ssh_cmd="sshpass -p \"$SSH_PASSWORD\" $ssh_cmd"
  elif [ -n "$SSH_KEY_PATH" ]; then
    # Sử dụng khóa SSH nếu được cung cấp
    ssh_cmd="$ssh_cmd -i $SSH_KEY_PATH"
  fi
  
  echo "$ssh_cmd"
}

# Xây dựng lệnh SCP dựa vào phương thức xác thực
build_scp_command() {
  local scp_cmd="scp -o StrictHostKeyChecking=no -P $SSH_PORT"
  
  if [ "$USE_PASSWORD_AUTH" = true ]; then
    # Sử dụng sshpass nếu xác thực bằng mật khẩu
    scp_cmd="sshpass -p \"$SSH_PASSWORD\" $scp_cmd"
  elif [ -n "$SSH_KEY_PATH" ]; then
    # Sử dụng khóa SSH nếu được cung cấp
    scp_cmd="$scp_cmd -i $SSH_KEY_PATH"
  fi
  
  echo "$scp_cmd"
}

# Thực thi lệnh SSH và kiểm tra kết quả
run_ssh_command() {
  local server=$1
  local command=$2
  local ssh_cmd=$(build_ssh_command)
  
  echo -e "${YELLOW}Thực thi trên $server: $command${NC}"
  eval "$ssh_cmd $SSH_USER@$server \"$command\""
  
  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${RED}Lệnh thất bại trên $server: $command${NC}" >&2
    return $status
  fi
  
  return 0
}

# Sao chép tệp lên server
copy_file_to_server() {
  local local_file=$1
  local server=$2
  local remote_path=$3
  local scp_cmd=$(build_scp_command)
  
  echo -e "${YELLOW}Sao chép $local_file lên $server:$remote_path${NC}"
  eval "$scp_cmd $local_file $SSH_USER@$server:$remote_path"
  
  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${RED}Sao chép thất bại: $local_file -> $server:$remote_path${NC}" >&2
    return $status
  fi
  
  return 0
}

# Chuẩn bị môi trường trên server
prepare_server() {
  local server=$1
  local remote_script_path="/tmp/setup_mongodb_replica.sh"
  
  echo -e "${BLUE}Chuẩn bị server $server...${NC}"
  
  # Sao chép script lên server
  copy_file_to_server "$SCRIPT_PATH" "$server" "$remote_script_path" || return 1
  
  # Cấp quyền thực thi cho script
  run_ssh_command "$server" "chmod +x $remote_script_path" || return 1
  
  echo -e "${GREEN}✓ Đã chuẩn bị xong server $server${NC}"
  return 0
}

# Chạy cài đặt MongoDB trên VPS Primary
setup_primary() {
  local remote_script="/tmp/setup_mongodb_replica.sh"
  
  echo -e "${BLUE}Thiết lập MongoDB Primary trên $PRIMARY_IP...${NC}"
  
  # Tạo tệp input với các phản hồi tự động cho câu hỏi trong script
  local input_file="/tmp/primary_input.txt"
  cat > $input_file << EOF
y
$SECONDARY_IP
$MONGO_PORT
$REPLICA_SET
$MONGO_USER
$MONGO_PASSWORD
EOF
  
  # Chạy script cài đặt trên primary với dữ liệu nhập tự động
  local ssh_cmd=$(build_ssh_command)
  eval "cat $input_file | $ssh_cmd $SSH_USER@$PRIMARY_IP \"$remote_script\""
  
  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${RED}Cài đặt primary thất bại!${NC}" >&2
    return $status
  fi
  
  echo -e "${GREEN}✓ Đã thiết lập xong MongoDB Primary trên $PRIMARY_IP${NC}"
  return 0
}

# Chạy cài đặt MongoDB trên VPS Secondary
setup_secondary() {
  local remote_script="/tmp/setup_mongodb_replica.sh"
  
  echo -e "${BLUE}Thiết lập MongoDB Secondary trên $SECONDARY_IP...${NC}"
  
  # Tạo tệp input với các phản hồi tự động cho câu hỏi trong script
  local input_file="/tmp/secondary_input.txt"
  cat > $input_file << EOF
n
$PRIMARY_IP
$MONGO_PORT
$REPLICA_SET
$MONGO_USER
$MONGO_PASSWORD
y
EOF
  
  # Chạy script cài đặt trên secondary với dữ liệu nhập tự động
  local ssh_cmd=$(build_ssh_command)
  eval "cat $input_file | $ssh_cmd $SSH_USER@$SECONDARY_IP \"$remote_script\""
  
  local status=$?
  if [ $status -ne 0 ]; then
    echo -e "${RED}Cài đặt secondary thất bại!${NC}" >&2
    return $status
  fi
  
  echo -e "${GREEN}✓ Đã thiết lập xong MongoDB Secondary trên $SECONDARY_IP${NC}"
  return 0
}

# Kiểm tra trạng thái replica set
check_replica_status() {
  local server=$1
  local command="mongosh --port $MONGO_PORT -u $MONGO_USER -p $MONGO_PASSWORD --authenticationDatabase admin --eval \"rs.status(); rs.isMaster();\""
  
  echo -e "${BLUE}Kiểm tra trạng thái replica set trên $server...${NC}"
  run_ssh_command "$server" "$command"
  
  echo -e "${GREEN}✓ Đã kiểm tra trạng thái replica set${NC}"
}

# Tạo chuỗi kết nối cho ứng dụng
generate_connection_string() {
  local conn_string="mongodb://$MONGO_USER:$MONGO_PASSWORD@$PRIMARY_IP:$MONGO_PORT,$SECONDARY_IP:$MONGO_PORT/admin?replicaSet=$REPLICA_SET"
  
  echo -e "${BLUE}
============================================================
  THÔNG TIN KẾT NỐI MONGODB REPLICA SET
============================================================${NC}"
  
  echo -e "${YELLOW}Chuỗi kết nối MongoDB:${NC}"
  echo -e "${GREEN}$conn_string${NC}"
  echo
  echo -e "${YELLOW}Kết nối bằng mongosh:${NC}"
  echo -e "${GREEN}mongosh \"$conn_string\"${NC}"
  echo
  echo -e "${YELLOW}Các server trong replica set:${NC}"
  echo -e "${GREEN}Primary (mặc định): $PRIMARY_IP:$MONGO_PORT${NC}"
  echo -e "${GREEN}Secondary: $SECONDARY_IP:$MONGO_PORT${NC}"
}

# Thực hiện các bước triển khai
deploy() {
  # 1. Chuẩn bị các server
  echo -e "${BLUE}[1/5] Chuẩn bị môi trường trên các server...${NC}"
  prepare_server "$PRIMARY_IP" || exit 1
  prepare_server "$SECONDARY_IP" || exit 1
  
  # 2. Thiết lập MongoDB trên primary
  echo -e "${BLUE}[2/5] Thiết lập MongoDB trên server primary...${NC}"
  setup_primary || exit 1
  
  # 3. Đợi primary khởi động và ổn định
  echo -e "${BLUE}[3/5] Đợi primary ổn định (30 giây)...${NC}"
  sleep 30
  
  # 4. Thiết lập MongoDB trên secondary
  echo -e "${BLUE}[4/5] Thiết lập MongoDB trên server secondary...${NC}"
  setup_secondary || exit 1
  
  # 5. Kiểm tra trạng thái replica set và xuất chuỗi kết nối
  echo -e "${BLUE}[5/5] Kiểm tra trạng thái replica set...${NC}"
  sleep 10  # Đợi secondary kết nối
  check_replica_status "$PRIMARY_IP"
  
  # Hiển thị thông tin kết nối
  generate_connection_string
  
  echo -e "${GREEN}
============================================================
  TRIỂN KHAI MONGODB REPLICA SET HOÀN TẤT!
============================================================${NC}"
  echo -e "${YELLOW}✓ Primary: $PRIMARY_IP:$MONGO_PORT${NC}"
  echo -e "${YELLOW}✓ Secondary: $SECONDARY_IP:$MONGO_PORT${NC}"
  echo -e "${YELLOW}✓ Replica Set: $REPLICA_SET${NC}"
  echo -e "${YELLOW}✓ Tài khoản: $MONGO_USER / $MONGO_PASSWORD${NC}"
}

# Bắt đầu triển khai
deploy 