# Hướng dẫn xử lý các lỗi phổ biến trong MongoDB Replica Set

## Exit Code 48 - Lỗi Port Conflict

**Nguyên nhân:**
- Port 27017 đã được sử dụng bởi một tiến trình khác
- MongoDB không thể bind vào port đã được cấu hình

**Giải pháp:**
```bash
# Kiểm tra tiến trình nào đang sử dụng port
sudo netstat -tulpn | grep 27017

# Nếu có tiến trình MongoDB khác, dừng nó
sudo systemctl stop mongod
sudo killall mongod
sudo pkill -f mongod

# Xóa các file socket
sudo rm -f /tmp/mongodb-*.sock
```

## Exit Code 14 - Lỗi Quyền Truy Cập

**Nguyên nhân:**
- MongoDB không thể truy cập thư mục dữ liệu
- MongoDB không có quyền ghi vào file log

**Giải pháp:**
```bash
# Khôi phục quyền cho các thư mục
sudo chown -R mongodb:mongodb /var/lib/mongodb
sudo chown -R mongodb:mongodb /var/log/mongodb
sudo chown mongodb:mongodb /etc/mongodb-keyfile
sudo chmod 400 /etc/mongodb-keyfile

# Đảm bảo SELinux không gây trở ngại (nếu có)
sudo setenforce 0  # Chỉ tạm thời vô hiệu hóa
```

## Lỗi Keyfile không đồng bộ

**Nguyên nhân:**
- Keyfile khác nhau giữa các node trong replica set
- Quyền truy cập keyfile không chính xác

**Giải pháp:**
```bash
# Tạo keyfile mới và đồng bộ đến tất cả các node
sudo openssl rand -base64 756 > /tmp/mongodb-keyfile
sudo mv /tmp/mongodb-keyfile /etc/mongodb-keyfile
sudo chmod 400 /etc/mongodb-keyfile
sudo chown mongodb:mongodb /etc/mongodb-keyfile

# Sao chép keyfile đến các máy chủ khác
scp /etc/mongodb-keyfile user@secondary-ip:/tmp/mongodb-keyfile
ssh user@secondary-ip "sudo mv /tmp/mongodb-keyfile /etc/mongodb-keyfile && sudo chmod 400 /etc/mongodb-keyfile && sudo chown mongodb:mongodb /etc/mongodb-keyfile"
```

## Lỗi không thể bầu chọn Primary

**Nguyên nhân:**
- Không đủ số lượng node để bầu chọn
- Các node không thể giao tiếp với nhau
- Cấu hình IP không chính xác

**Giải pháp:**
```bash
# Đảm bảo bind tất cả các IP
sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/g' /etc/mongod.conf

# Kiểm tra tường lửa
sudo ufw status
sudo ufw allow 27017/tcp

# Khởi tạo lại replica set từ đầu
mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:27017', priority: 10}]})"
```

## Reset hoàn toàn MongoDB

Nếu gặp nhiều vấn đề phức tạp và muốn làm lại từ đầu, sử dụng script `reset_mongodb.sh`:

```bash
# Cấp quyền thực thi
chmod +x reset_mongodb.sh

# Chạy script reset
sudo ./reset_mongodb.sh
```

Script này sẽ:
1. Dừng tất cả các tiến trình MongoDB
2. Gỡ cài đặt MongoDB hoàn toàn
3. Xóa sạch dữ liệu và cấu hình
4. Xóa systemd service
5. Tạo lại các thư mục cần thiết
6. Cài đặt lại MongoDB 8.0
7. Tạo keyfile mới
8. Tạo file cấu hình mới
9. Đặt lại quyền thích hợp
10. Khởi động MongoDB và khởi tạo replica set

## Xem log chi tiết

**Xem log MongoDB:**
```bash
sudo tail -f /var/log/mongodb/mongod.log
```

**Xem log systemd:**
```bash
sudo journalctl -u mongod -f
```

## Kiểm tra trạng thái Replica Set

```bash
# Kết nối và kiểm tra trạng thái
mongosh --eval "rs.status()"

# Kiểm tra master
mongosh --eval "rs.isMaster()"

# Kiểm tra cấu hình
mongosh --eval "rs.conf()"
```

## Vấn đề phổ biến khác

### 1. MongoDB khởi động nhưng không phải là replica set

**Giải pháp:**
```bash
# Kết nối và khởi tạo replica set
mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:27017'}]})"
```

### 2. Thông báo "Not primary and secondaryOk=false"

**Giải pháp:**
```bash
# Cho phép đọc dữ liệu từ secondary
mongosh --eval "rs.secondaryOk()"
```

### 3. Lỗi "couldn't connect to server"

**Kiểm tra:**
```bash
# Kiểm tra MongoDB có đang chạy không
sudo systemctl status mongod

# Kiểm tra kết nối
nc -vz localhost 27017
```

### 4. Lỗi "connection accepted from ... but terminated with error 'AuthenticationFailed'"

**Giải pháp:**
```bash
# Đặt lại trạng thái xác thực
sudo sed -i 's/authorization: enabled/authorization: disabled/g' /etc/mongod.conf
sudo systemctl restart mongod
``` 