#!/bin/bash

echo "====== FIX LỖI MONGODB KEYFILE KHÔNG ĐỒNG BỘ ======"

# Lưu lại keyfile hiện tại
echo "Lưu lại keyfile hiện tại..."
sudo cp /etc/mongodb-keyfile /etc/mongodb-keyfile.bak

# Yêu cầu người dùng nhập nội dung keyfile từ server primary
echo "Vui lòng cung cấp nội dung keyfile từ server primary:"
echo "Để lấy nội dung keyfile từ server primary, hãy chạy lệnh: sudo cat /etc/mongodb-keyfile"
echo "Sau đó copy toàn bộ nội dung vào đây và nhấn CTRL+D khi hoàn tất:"

sudo bash -c 'cat > /etc/mongodb-keyfile'
echo "Đã nhập keyfile mới"

# Sửa quyền cho keyfile
echo "Sửa quyền cho keyfile..."
sudo chmod 400 /etc/mongodb-keyfile
sudo chown mongodb:mongodb /etc/mongodb-keyfile

# Kiểm tra quyền
echo "Kiểm tra quyền của keyfile..."
ls -la /etc/mongodb-keyfile

# Khởi động lại MongoDB
echo "Khởi động lại MongoDB..."
sudo systemctl restart mongod

# Kiểm tra trạng thái
echo "Kiểm tra trạng thái MongoDB..."
sleep 3
sudo systemctl status mongod

echo ""
echo "Nếu MongoDB đã khởi động thành công, bạn có thể thử kết nối lại với replica set."
echo "Chạy lại script chính để tiếp tục thiết lập: ./setup_mongodb_distributed_replica.sh" 