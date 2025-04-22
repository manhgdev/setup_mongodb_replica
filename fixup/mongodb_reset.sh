#!/bin/bash

echo "====== RESET HOÀN TOÀN MONGODB ======"
echo "CẢNH BÁO: Script này sẽ xóa hoàn toàn dữ liệu MongoDB."
echo "        Đảm bảo bạn đã sao lưu dữ liệu quan trọng trước khi tiếp tục."
read -p "Bạn chắc chắn muốn tiếp tục? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Đã hủy thao tác."
    exit 0
fi

# Dừng MongoDB
echo "Dừng MongoDB..."
sudo systemctl stop mongod

# Xóa tất cả dữ liệu MongoDB
echo "Xóa dữ liệu MongoDB..."
sudo rm -rf /var/lib/mongodb/*

# Xóa log
echo "Xóa log MongoDB..."
sudo rm -f /var/log/mongodb/mongod.log*

# Xóa các file socket
echo "Xóa các file socket..."
sudo rm -f /tmp/mongodb-*.sock

# Tạo lại các thư mục với quyền phù hợp
echo "Tạo lại các thư mục dữ liệu..."
sudo mkdir -p /var/lib/mongodb
sudo chown -R mongodb:mongodb /var/lib/mongodb
sudo chmod -R 750 /var/lib/mongodb

echo "Tạo lại thư mục log..."
sudo mkdir -p /var/log/mongodb
sudo chown -R mongodb:mongodb /var/log/mongodb
sudo chmod -R 755 /var/log/mongodb

# Tùy chọn để xóa keyfile
read -p "Bạn muốn tạo keyfile mới không? (y/n): " NEW_KEYFILE
if [[ "$NEW_KEYFILE" =~ ^[Yy]$ ]]; then
    echo "Tạo keyfile mới..."
    sudo rm -f /etc/mongodb-keyfile
    openssl rand -base64 756 | sudo tee /etc/mongodb-keyfile > /dev/null
    sudo chmod 400 /etc/mongodb-keyfile
    sudo chown mongodb:mongodb /etc/mongodb-keyfile
fi

# Tùy chọn đặt lại file cấu hình
read -p "Bạn muốn tạo file cấu hình mới không? (y/n): " NEW_CONFIG
if [[ "$NEW_CONFIG" =~ ^[Yy]$ ]]; then
    echo "Tạo file cấu hình mới..."
    
    # Lưu file cấu hình cũ
    if [ -f /etc/mongod.conf ]; then
        sudo cp /etc/mongod.conf /etc/mongod.conf.bak
    fi
    
    # Tạo file cấu hình mới
    cat > /tmp/mongod.conf << EOF
# MongoDB configuration file
storage:
  dbPath: /var/lib/mongodb
  
net:
  port: 27017
  bindIp: 0.0.0.0

replication:
  replSetName: rs0

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true

security:
  keyFile: /etc/mongodb-keyfile
  authorization: enabled
EOF

    sudo mv /tmp/mongod.conf /etc/mongod.conf
    sudo chown mongodb:mongodb /etc/mongod.conf
fi

# Khởi động lại MongoDB
echo "Khởi động lại MongoDB..."
sudo systemctl daemon-reload
sudo systemctl restart mongod

# Kiểm tra trạng thái
echo "Kiểm tra trạng thái..."
sleep 5
sudo systemctl status mongod

echo ""
echo "MongoDB đã được reset hoàn toàn."
echo "Chạy lại script thiết lập để cấu hình replica set: ./setup_mongodb_distributed_replica.sh" 