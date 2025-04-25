#!/bin/bash

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Thông tin kết nối
USERNAME="manhg"
PASSWORD="manhnk"
AUTH_DB="admin"
TARGET_HOST="157.66.46.252"
TARGET_PORT="27017"

echo -e "${YELLOW}=== CHUYỂN PRIMARY SANG SERVER MỚI ===${NC}"

# 1. Kiểm tra kết nối đến server mới
echo -e "${YELLOW}Kiểm tra kết nối đến server mới...${NC}"
if ! mongosh "mongodb://$USERNAME:$PASSWORD@$TARGET_HOST:$TARGET_PORT/admin" --eval "db.runCommand({ping: 1})" --quiet | grep -q "ok.*1"; then
    echo -e "${RED}Không thể kết nối đến server mới.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Kết nối thành công đến server mới${NC}"

# 2. Force reconfig để đặt server mới làm PRIMARY
echo -e "${YELLOW}Force reconfig để đặt server mới làm PRIMARY...${NC}"
mongosh "mongodb://$USERNAME:$PASSWORD@$TARGET_HOST:$TARGET_PORT/admin" --quiet --eval "
try {
    cfg = rs.conf();
    for (var i = 0; i < cfg.members.length; i++) {
        if (cfg.members[i].host == '$TARGET_HOST:$TARGET_PORT') {
            cfg.members[i].priority = 10;
            cfg.members[i].votes = 1;
        } else {
            cfg.members[i].priority = 0;
            cfg.members[i].votes = 0;
        }
    }
    db.adminCommand({replSetReconfig: cfg, force: true});
    print('✓ Đã cập nhật cấu hình replica set');
} catch (e) {
    print('Lỗi: ' + e.message);
}"

# 3. Đợi 15 giây để hệ thống bầu PRIMARY mới
echo -e "${YELLOW}Đợi 15 giây để hệ thống bầu PRIMARY mới...${NC}"
sleep 15

# 4. Kiểm tra trạng thái mới
echo -e "${YELLOW}Kiểm tra trạng thái mới...${NC}"
mongosh "mongodb://$USERNAME:$PASSWORD@$TARGET_HOST:$TARGET_PORT/admin" --eval "rs.status()" --quiet | grep -E "name|stateStr"

echo -e "${GREEN}✓ Hoàn thành chuyển PRIMARY${NC}" 