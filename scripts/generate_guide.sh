#!/bin/bash

generate_setup_guide() {
    local SERVER_IP=$1
    local PRIMARY_PORT=$2
    local ARBITER1_PORT=$3
    local ARBITER2_PORT=$4
    local ADMIN_USERNAME=$5
    local ADMIN_PASSWORD=$6
    local PRIMARY_SERVER_IP=$7
    
    local GUIDE_FILE="mongodb_replica_setup_guide.md"
    
    cat > "$GUIDE_FILE" << EOL
# Hướng dẫn cài đặt MongoDB Replica Set - SECONDARY Server

## Thông tin kết nối
- IP: $SERVER_IP
- Ports:
  - SECONDARY: $PRIMARY_PORT
  - ARBITER 1: $ARBITER1_PORT
  - ARBITER 2: $ARBITER2_PORT
- PRIMARY Server IP: $PRIMARY_SERVER_IP
- Username: $ADMIN_USERNAME
- Password: $ADMIN_PASSWORD

## Các bước cài đặt

1. Lấy KEY_FILE từ PRIMARY server:
   \`\`\`bash
   # Trên PRIMARY server
   scp /etc/mongodb.key root@$SERVER_IP:/etc/mongodb.key
   
   # Trên SECONDARY server
   chown mongodb:mongodb /etc/mongodb.key
   chmod 600 /etc/mongodb.key
   \`\`\`

2. Kết nối với PRIMARY server:
   \`\`\`bash
   mongosh --host $PRIMARY_SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin
   \`\`\`

3. Thêm node vào replica set:
   \`\`\`javascript
   // Thêm SECONDARY
   rs.add("$SERVER_IP:$PRIMARY_PORT")
   
   // Thêm ARBITER 1
   rs.addArb("$SERVER_IP:$ARBITER1_PORT")
   
   // Thêm ARBITER 2
   rs.addArb("$SERVER_IP:$ARBITER2_PORT")
   \`\`\`

## Các lệnh hữu ích

1. Kiểm tra trạng thái replica set:
   \`\`\`javascript
   rs.status()
   \`\`\`

2. Xem cấu hình replica set:
   \`\`\`javascript
   rs.conf()
   \`\`\`

3. Kết nối đến MongoDB:
   \`\`\`bash
   mongosh --host $SERVER_IP --port $PRIMARY_PORT -u $ADMIN_USERNAME -p $ADMIN_PASSWORD --authenticationDatabase admin
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
   - Kiểm tra kết nối với PRIMARY server
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