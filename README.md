# MongoDB Replica Set Setup Script for Ubuntu

Đây là script tự động cài đặt và cấu hình MongoDB Replica Set trên máy chủ Ubuntu. Phù hợp cho môi trường phát triển, kiểm thử hoặc demo nhanh hệ thống phân tán MongoDB.

---

## 🧾 Nội dung script

Script bao gồm:

1. Cài đặt MongoDB từ kho chính thức của MongoDB
2. Tạo các thư mục dữ liệu cho các node trong Replica Set
3. Cấu hình các instance MongoDB chạy trên các cổng khác nhau
4. Khởi tạo Replica Set với 4 thành viên
5. Tạo người dùng có quyền `root`
6. Bật xác thực (authentication)
7. Thiết lập keyFile để các node xác thực lẫn nhau
8. Cập nhật lại các file cấu hình
9. Khởi động lại MongoDB
10. Kiểm tra trạng thái Replica Set
11. Ép bầu chọn lại Primary nếu cần

---

## 💾 Cách sử dụng

### Bước 1: Tạo file script

Tạo file có tên `setup_mongodb_replica.sh`:

```bash
vi setup_mongodb_replica.sh
```
Sau đó dán toàn bộ nội dung script vào.

### Bước 2: Cấp quyền thực thi cho file

```bash
chmod +x setup_mongodb_replica.sh
```

### Bước 3: Chạy script với quyền root

```bash
sudo ./setup_mongodb_replica.sh
```