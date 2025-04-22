# Khắc phục lỗi "(not reachable/healthy)" trong MongoDB Replica Set

Khi một node trong MongoDB replica set hiển thị trạng thái "(not reachable/healthy)" với `health: 0`, thực hiện các bước sau để khắc phục.

## Trên node có vấn đề (Secondary)

### 1. Kiểm tra trạng thái MongoDB

```bash
sudo systemctl status mongod
```

Nếu không hoạt động:
```bash
sudo systemctl start mongod
sudo tail -f /var/log/mongodb/mongod.log
```

### 2. Tùy chọn xác thực: Với và Không Với Keyfile

#### Tùy chọn 1: Không sử dụng keyfile (Không xác thực)

Có thể thiết lập replica set mà không cần keyfile, nhưng điều này sẽ tắt xác thực nội bộ:

```bash
# Sửa cấu hình MongoDB trên tất cả các server
sudo vi /etc/mongod.conf

# Thay đổi phần security như sau:
security:
  # Xóa hoặc comment dòng keyFile
  # keyFile: /etc/mongodb-keyfile
  authorization: disabled  # hoặc xóa hoàn toàn phần này
```

**Lưu ý về bảo mật**: 
- Không sử dụng keyfile làm cho MongoDB dễ dàng cài đặt hơn nhưng kém bảo mật
- Chỉ nên dùng trong môi trường phát triển hoặc trong mạng cô lập an toàn
- Không được khuyến nghị cho môi trường sản xuất

#### Tùy chọn 2: Sử dụng keyfile (Được khuyến nghị)

Keyfile là bắt buộc khi bạn cần xác thực giữa các thành viên replica set:

```bash
# Trên primary server, kiểm tra nội dung keyfile
sudo cat /etc/mongodb-keyfile

# Trên secondary server, tạo keyfile với nội dung giống hệt
sudo vi /etc/mongodb-keyfile
# [Dán nội dung từ primary vào đây]

# Đặt quyền chính xác
sudo chmod 400 /etc/mongodb-keyfile
sudo chown mongodb:mongodb /etc/mongodb-keyfile
```

**Ưu điểm của việc sử dụng keyfile**:
- Bảo mật giao tiếp giữa các server trong replica set
- Cho phép xác thực người dùng (user authentication)
- Tuân thủ tiêu chuẩn bảo mật

Sau khi thay đổi cấu hình xác thực, phải khởi động lại MongoDB:
```bash
sudo systemctl restart mongod
```

### 3. Kiểm tra kết nối mạng

```bash
# Thử ping đến primary
ping -c 3 [primary-server-ip]

# Kiểm tra kết nối MongoDB port
nc -zv [primary-server-ip] 27017

# Kiểm tra tường lửa
sudo ufw status
```

### 4. Kiểm tra cấu hình

```bash
sudo cat /etc/mongod.conf
```

Đảm bảo các thiết lập sau:
- `bindIp: 0.0.0.0` (hoặc bao gồm IP của server)
- `replSetName` giống nhau giữa các server
- `keyFile` trỏ đến đường dẫn chính xác

### 5. Làm sạch và tham gia lại Replica Set

Nếu các cách trên không khắc phục được:

```bash
# Dừng MongoDB
sudo systemctl stop mongod

# Xóa dữ liệu
sudo rm -rf /var/lib/mongodb/*

# Khởi động lại MongoDB
sudo systemctl start mongod
```

Trên primary server, xóa và thêm lại node:
```bash
# Đăng nhập vào MongoDB trên Primary
mongosh --host [primary-server-ip] -u admin -p password --authenticationDatabase admin

# Xóa node lỗi
rs.remove("[problem-node-ip]:27017")

# Thêm lại node
rs.add("[problem-node-ip]:27017")

# Kiểm tra trạng thái
rs.status()
```

## Các nguyên nhân và giải pháp phổ biến

1. **Vấn đề về DNS/hostname**:
   - Thêm các mapping vào `/etc/hosts`
   - Sử dụng IP thay vì hostname

2. **SELinux**:
   ```bash
   # Kiểm tra trạng thái SELinux
   getenforce
   
   # Tạm thời vô hiệu hóa
   sudo setenforce 0
   
   # Vô hiệu hóa vĩnh viễn
   sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
   ```

3. **AppArmor**:
   ```bash
   sudo aa-status
   sudo systemctl disable apparmor
   sudo systemctl stop apparmor
   ```

4. **Lỗi đồng bộ hóa**:
   Đặt lại replica set hoàn toàn từ đầu nếu dữ liệu không quan trọng.

5. **Vấn đề về phiên bản MongoDB**:
   Đảm bảo tất cả các node chạy cùng phiên bản MongoDB.
