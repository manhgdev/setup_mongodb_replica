# Hướng dẫn Backup và Khôi phục MongoDB

## I. Backup MongoDB

Script `backup_mongodb.sh` sẽ giúp bạn sao lưu dữ liệu MongoDB trước khi tiến hành cấu hình Replica Set. Điều này đảm bảo an toàn dữ liệu trong quá trình thay đổi cấu hình hệ thống.

### 1. Chuẩn bị

Script sẽ tự động cài đặt MongoDB Database Tools nếu chưa có. Các công cụ này cần thiết để sử dụng `mongodump`.

### 2. Sử dụng script backup

Đăng nhập vào VPS hiện tại và chạy lệnh sau:

```bash
# Copy script sang VPS
scp backup_mongodb.sh user@your_vps_ip:/path/to/destination/

# Đăng nhập vào VPS
ssh user@your_vps_ip

# Cấp quyền thực thi
chmod +x backup_mongodb.sh

# Chạy script
./backup_mongodb.sh
```

### 3. Các tùy chọn backup

Script sẽ hỏi bạn các thông tin sau:

- **Thông tin xác thực MongoDB**: 
  - Nếu MongoDB của bạn yêu cầu xác thực, chọn `y` và nhập username/password
  - Nếu không yêu cầu xác thực, chọn `n`

- **Thông tin kết nối**:
  - Host (mặc định: localhost)
  - Port (mặc định: 27017)

- **Loại backup**:
  - `all`: Backup tất cả databases
  - `specific`: Backup một database cụ thể

- **Nén backup**:
  - Nếu chọn `y`, backup sẽ được nén thành file `.tar.gz`
  - Tiết kiệm không gian lưu trữ

### 4. Vị trí lưu backup

Mặc định, backup sẽ được lưu tại `/root/mongodb_backup` với tên thư mục có cấu trúc:
- `mongodb_all_YYYYMMDD_HHMMSS`: Khi backup tất cả databases
- `database_name_YYYYMMDD_HHMMSS`: Khi backup database cụ thể

### 5. Sao lưu backup về máy local

Sau khi hoàn tất, nên sao chép file backup về máy local để đảm bảo an toàn:

```bash
# Từ máy local
scp user@your_vps_ip:/root/mongodb_backup/your_backup_file.tar.gz /local/path/
```

## II. Khôi phục MongoDB

Nếu cần khôi phục dữ liệu sau này, bạn có thể sử dụng lệnh `mongorestore`.

### 1. Khôi phục dữ liệu

#### A. Nếu backup được nén:

```bash
# Giải nén file backup
tar -xzf your_backup_file.tar.gz -C /tmp

# Khôi phục không xác thực
mongorestore --host localhost --port 27017 /tmp/your_backup_folder/

# Khôi phục có xác thực
mongorestore --host localhost --port 27017 --username your_user --password your_password --authenticationDatabase admin /tmp/your_backup_folder/
```

#### B. Nếu backup không được nén:

```bash
# Khôi phục không xác thực
mongorestore --host localhost --port 27017 /path/to/your_backup_folder/

# Khôi phục có xác thực
mongorestore --host localhost --port 27017 --username your_user --password your_password --authenticationDatabase admin /path/to/your_backup_folder/
```

### 2. Khôi phục một database cụ thể

```bash
# Khôi phục database cụ thể (không xác thực)
mongorestore --host localhost --port 27017 --nsInclude="database_name.*" /path/to/your_backup_folder/

# Khôi phục database cụ thể (có xác thực)
mongorestore --host localhost --port 27017 --username your_user --password your_password --authenticationDatabase admin --nsInclude="database_name.*" /path/to/your_backup_folder/
```

### 3. Khôi phục vào database khác

```bash
# Khôi phục data từ database_old thành database_new
mongorestore --host localhost --port 27017 --nsFrom="database_old.*" --nsTo="database_new.*" /path/to/your_backup_folder/
```

### 4. Khôi phục vào Replica Set

Khi khôi phục dữ liệu vào MongoDB Replica Set, chỉ cần khôi phục vào Primary node:

```bash
# Lấy connection string của Replica Set từ MongoDB
# Ví dụ: mongodb://username:password@primary_ip:27017,secondary_ip:27017/admin?replicaSet=rs0

# Khôi phục vào Replica Set
mongorestore --uri "mongodb://username:password@primary_ip:27017,secondary_ip:27017/admin?replicaSet=rs0" /path/to/your_backup_folder/
```

Dữ liệu sẽ tự động sao chép sang các Secondary nodes thông qua cơ chế replication.

## III. Gỡ lỗi phổ biến

### 1. Lỗi xác thực

Nếu gặp lỗi xác thực khi backup hoặc khôi phục, hãy đảm bảo:
- Username và password chính xác
- User có quyền đọc/ghi trên database cần backup/restore
- Sử dụng đúng authenticationDatabase (thường là `admin`)

### 2. Lỗi quyền truy cập thư mục

Nếu gặp lỗi khi tạo thư mục backup hoặc ghi file:
- Đảm bảo user chạy script có quyền ghi vào thư mục backup
- Sử dụng `sudo` nếu cần

### 3. Lỗi version không tương thích

Khi khôi phục từ phiên bản MongoDB cũ hơn lên phiên bản mới hơn:
- Sử dụng tham số `--convertLegacyIndexes` khi restore
- Đọc tài liệu về sự thay đổi giữa các phiên bản

### 4. Lỗi không đủ dung lượng

Nếu hệ thống báo không đủ dung lượng lưu trữ:
- Kiểm tra không gian đĩa: `df -h`
- Xóa các backup cũ không cần thiết
- Sử dụng nén để giảm kích thước backup 

# Đăng nhập vào server cũ
ssh root@157.66.46.252

# Export database ExpressApiNew
mongodump --host 127.0.0.1 --port 27018 -u manhg -p manhnk --authenticationDatabase admin --db ExpressApiNew --out /root/mongodb_backup

# Nén lại để dễ chuyển
cd /root
tar -czf mongodb_backup.tar.gz mongodb_backup/ 