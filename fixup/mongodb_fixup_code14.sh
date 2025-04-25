#!/bin/bash

echo "====== FIX LỖI MONGODB STARTUP ERROR (CODE 14) ======"

# Kiểm tra log đầy đủ
echo "Kiểm tra log MongoDB..."
sudo cat /var/log/mongodb/mongod.log | tail -n 50

# Fix quyền sở hữu thư mục dữ liệu
echo "Fix quyền sở hữu thư mục dữ liệu..."
sudo mkdir -p /var/lib/mongodb
sudo chown -R mongodb:mongodb /var/lib/mongodb
sudo chmod -R 750 /var/lib/mongodb

# Fix quyền keyfile
echo "Fix quyền keyfile..."
sudo chown mongodb:mongodb /etc/mongodb-keyfile
sudo chmod 400 /etc/mongodb-keyfile

# Fix thư mục log
echo "Fix thư mục log..."
sudo mkdir -p /var/log/mongodb
sudo chown -R mongodb:mongodb /var/log/mongodb
sudo chmod -R 755 /var/log/mongodb

# Xóa các file lock
echo "Xóa file lock nếu có..."
sudo rm -f /var/lib/mongodb/mongod.lock /var/lib/mongodb/WiredTiger.lock
sudo rm -f /tmp/mongodb-*.sock

# Sửa file cấu hình
echo "Kiểm tra file cấu hình..."
grep -i dbPath /etc/mongod.conf

# Khởi động lại MongoDB
echo "Khởi động lại MongoDB..."
sudo systemctl restart mongod

# Kiểm tra trạng thái
echo "Kiểm tra trạng thái..."
sleep 3
sudo systemctl status mongod

# Hướng dẫn kiểm tra log chi tiết
echo "Để xem log chi tiết, chạy lệnh: sudo cat /var/log/mongodb/mongod.log | tail -n 50" 