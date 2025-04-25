#!/bin/bash

echo "====== FIX LỖI MONGODB STARTUP ERROR (CODE 48) ======"

# Kiểm tra port xem có bị chiếm không
echo "Kiểm tra xem port 27017 có đang được sử dụng không..."
sudo lsof -i :27017
sudo netstat -tuln | grep 27017

# Kiểm tra xem có tiến trình mongod nào đang chạy không
echo "Kiểm tra tiến trình MongoDB..."
ps aux | grep mongod

# Kiểm tra log đầy đủ để xem lỗi chi tiết
echo "Kiểm tra log MongoDB để tìm lỗi chính xác..."
sudo cat /var/log/mongodb/mongod.log | tail -n 100 | grep -i error

# Tạo file cấu hình mới với port khác
echo "Tạo file cấu hình mới với port 27018..."
cat > /tmp/mongod.conf << EOF
storage:
  dbPath: /var/lib/mongodb
  
net:
  port: 27018
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

# Hỏi người dùng có muốn dùng port khác không
read -p "Bạn có muốn thử dùng port 27018 thay vì 27017 không? (y/n): " USE_ALT_PORT

if [[ "$USE_ALT_PORT" =~ ^[Yy]$ ]]; then
  sudo mv /tmp/mongod.conf /etc/mongod.conf
  sudo chown mongodb:mongodb /etc/mongod.conf
  echo "Đã đổi sang port 27018"
else
  rm /tmp/mongod.conf
  echo "Giữ nguyên port 27017"
fi

# Dọn sạch
echo "Dọn dẹp các tài nguyên cũ..."
sudo systemctl stop mongod || true
sudo kill $(pgrep mongod) || true
sudo rm -f /tmp/mongodb-*.sock
sudo rm -f /var/lib/mongodb/mongod.lock /var/lib/mongodb/WiredTiger.lock

# Sửa quyền
echo "Sửa quyền truy cập..."
sudo mkdir -p /var/lib/mongodb
sudo chown -R mongodb:mongodb /var/lib/mongodb
sudo chmod -R 750 /var/lib/mongodb

sudo mkdir -p /var/log/mongodb
sudo chown -R mongodb:mongodb /var/log/mongodb
sudo chmod -R 755 /var/log/mongodb

sudo chown mongodb:mongodb /etc/mongodb-keyfile
sudo chmod 400 /etc/mongodb-keyfile

sudo chown mongodb:mongodb /etc/mongod.conf

# Khởi động lại MongoDB
echo "Khởi động lại MongoDB..."
sudo systemctl daemon-reload
sudo systemctl restart mongod

# Kiểm tra trạng thái
echo "Kiểm tra trạng thái..."
sleep 3
sudo systemctl status mongod

# Mở port mới trong tường lửa nếu đã đổi port
if [[ "$USE_ALT_PORT" =~ ^[Yy]$ ]]; then
  echo "Mở port 27018 trong tường lửa..."
  sudo ufw allow 27018/tcp
  sudo ufw status | grep 27018
fi

echo ""
echo "Để kiểm tra log chi tiết:"
echo "sudo cat /var/log/mongodb/mongod.log | tail -n 100"

echo ""
echo "Để sửa đổi thủ công file cấu hình:"
echo "sudo nano /etc/mongod.conf" 