#!/bin/bash

generate_setup_guide() {
    local PRIMARY_IP=$1
    local PRIMARY_PORT=$2
    local ARBITER1_PORT=$3
    local ARBITER2_PORT=$4
    local ADMIN_USERNAME=$5
    local ADMIN_PASSWORD=$6
    
    local GUIDE_FILE="mongodb_replica_setup_guide.md"
    
    cat > "$GUIDE_FILE" << EOL
# Hướng dẫn cài đặt MongoDB Replica Set - SECONDARY Server

## Thông tin PRIMARY Server
- IP: $PRIMARY_IP
- Ports:
  - PRIMARY: $PRIMARY_PORT
  - ARBITER 1: $ARBITER1_PORT
  - ARBITER 2: $ARBITER2_PORT
- Username: $ADMIN_USERNAME
- Password: $ADMIN_PASSWORD

## Các bước cài đặt

1. Cài đặt MongoDB trên server mới:
   \`\`\`bash
   # Ubuntu/Debian
   sudo apt-get update
   sudo apt-get install -y mongodb-org

   # CentOS/RHEL
   sudo yum install -y mongodb-org
   \`\`\`

2. Tải script cài đặt:
   \`\`\`bash
   wget https://raw.githubusercontent.com/manhg/setup_mongodb_replica/main/scripts/setup_replica_linux.sh
   chmod +x setup_replica_linux.sh
   \`\`\`

3. Chạy script cài đặt:
   \`\`\`bash
   sudo ./setup_replica_linux.sh
   \`\`\`

4. Chọn tùy chọn 2 (SECONDARY) khi được hỏi

5. Nhập thông tin:
   - IP của PRIMARY server: $PRIMARY_IP
   - Username admin: $ADMIN_USERNAME
   - Password admin: $ADMIN_PASSWORD

## Kiểm tra kết nối

1. Kết nối đến PRIMARY server:
   \`\`\`bash
   mongosh --host $PRIMARY_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin
   \`\`\`

2. Kiểm tra trạng thái replica set:
   \`\`\`javascript
   rs.status()
   \`\`\`

## Xử lý lỗi thường gặp

1. Không thể kết nối đến PRIMARY server:
   - Kiểm tra firewall
   - Kiểm tra kết nối mạng
   - Kiểm tra port đã mở

2. Lỗi xác thực:
   - Kiểm tra lại username/password
   - Kiểm tra quyền truy cập của user

3. Lỗi replica set:
   - Kiểm tra log file
   - Kiểm tra trạng thái các node
   - Kiểm tra kết nối giữa các node

## Liên hệ hỗ trợ

Nếu gặp vấn đề trong quá trình cài đặt, vui lòng liên hệ:
- Email: manhg@example.com
- Phone: +84 123 456 789
EOL

    echo -e "${GREEN}✅ Đã tạo file hướng dẫn: $GUIDE_FILE${NC}"
    echo "Bạn có thể chia sẻ file này cho người cài đặt server tiếp theo"
} 