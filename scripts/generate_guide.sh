#!/bin/bash

generate_setup_guide() {
    local SERVER_IP=$1
    local PRIMARY_PORT=$2
    local ARBITER1_PORT=$3
    local ARBITER2_PORT=$4
    local ADMIN_USERNAME=$5
    local ADMIN_PASSWORD=$6
    
    local GUIDE_FILE="mongodb_replica_setup_guide.md"
    
    cat > "$GUIDE_FILE" << EOL
# Hướng dẫn cài đặt MongoDB Replica Set - PRIMARY Server

## Thông tin kết nối
- IP: $SERVER_IP
- Ports:
  - PRIMARY: $PRIMARY_PORT
  - ARBITER 1: $ARBITER1_PORT
  - ARBITER 2: $ARBITER2_PORT
- Username: $ADMIN_USERNAME
- Password: $ADMIN_PASSWORD

## Các lệnh hữu ích

1. Kết nối đến MongoDB:
   \`\`\`bash
   mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin
   \`\`\`

2. Kiểm tra trạng thái replica set:
   \`\`\`javascript
   rs.status()
   \`\`\`

3. Xem cấu hình replica set:
   \`\`\`javascript
   rs.conf()
   \`\`\`

4. Thêm node mới:
   \`\`\`javascript
   rs.add("host:port")
   \`\`\`

5. Thêm arbiter:
   \`\`\`javascript
   rs.addArb("host:port")
   \`\`\`

6. Xóa node:
   \`\`\`javascript
   rs.remove("host:port")
   \`\`\`

## Quản lý dữ liệu

1. Backup dữ liệu:
   \`\`\`bash
   mongodump --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin --out /path/to/backup
   \`\`\`

2. Restore dữ liệu:
   \`\`\`bash
   mongorestore --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin /path/to/backup
   \`\`\`

## Lưu ý quan trọng

1. Bảo mật:
   - Giữ keyFile an toàn: /etc/mongodb.key
   - Thay đổi password admin định kỳ
   - Giới hạn IP truy cập

2. Quản lý:
   - Log files: /var/log/mongodb/
   - Data files: /var/lib/mongodb_*
   - Config files: /etc/mongod_*.conf

3. Giám sát:
   - Kiểm tra log file thường xuyên
   - Theo dõi dung lượng ổ đĩa
   - Giám sát hiệu suất

## Xử lý sự cố

1. MongoDB không khởi động:
   - Kiểm tra log file
   - Kiểm tra quyền truy cập
   - Kiểm tra port đã sử dụng

2. Replica set không hoạt động:
   - Kiểm tra kết nối mạng
   - Kiểm tra trạng thái các node
   - Kiểm tra cấu hình replica set

3. Lỗi xác thực:
   - Kiểm tra keyFile
   - Kiểm tra user/password
   - Kiểm tra quyền truy cập

## Liên hệ hỗ trợ

Nếu gặp vấn đề trong quá trình vận hành, vui lòng liên hệ:
- Email: manhg@example.com
- Phone: +84 123 456 789
EOL

    echo -e "${GREEN}✅ Đã tạo file hướng dẫn: $GUIDE_FILE${NC}"
    echo "Bạn có thể sử dụng file này để quản lý MongoDB Replica Set"
} 