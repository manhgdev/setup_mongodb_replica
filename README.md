# MongoDB Replica Set Setup Scripts

Bộ script này giúp bạn thiết lập và triển khai MongoDB Replica Set trong nhiều môi trường khác nhau.

## Cấu trúc thư mục

```
setup_mongodb_replica/
├── one_server/               # Thiết lập trên một server
│   └── setup_mongodb_replica.sh
├── multil_server/            # Thiết lập phân tán trên nhiều server
│   └── setup_mongodb_distributed_replica.sh
├── ssh/                      # Triển khai từ xa
│   └── deploy_mongodb_replica.sh
├── fixup/                    # Sửa lỗi
│   ├── mongodb_fixup_code14.sh
│   ├── mongodb_fixup_code48.sh
│   ├── mongodb_fixup_keyfile.sh
│   ├── mongodb_fixup_primaryfailure.sh
│   └── mongodb_reset.sh
├── run_setup_mongodb.sh      # Script khởi chạy chính
├── run_fix_all_configs.sh    # Script sửa lỗi
└── README.md
```

## Cách sử dụng

Sử dụng script chính để chọn loại thiết lập MongoDB Replica Set:

```bash
chmod +x run_setup_mongodb.sh
./run_setup_mongodb.sh
```

Bạn sẽ được hỏi loại thiết lập:

1. **Single Server** - Thiết lập trên một server
2. **Multiple Servers** - Thiết lập phân tán
3. **Remote Deployment** - Triển khai từ xa
4. **Fix Issues** - Sửa lỗi MongoDB
5. **Exit** - Thoát

---

## 1️⃣ MongoDB Replica Set trên một server

Script `one_server/setup_mongodb_replica.sh` giúp thiết lập MongoDB Replica Set trên một máy chủ Ubuntu duy nhất, sử dụng nhiều port khác nhau. Phù hợp cho môi trường phát triển, kiểm thử hoặc demo nhanh.

### Tính năng

1. Cài đặt MongoDB từ kho chính thức của MongoDB
2. Tạo các thư mục dữ liệu cho các node trong Replica Set
3. Cấu hình các instance MongoDB chạy trên các cổng khác nhau
4. Khởi tạo Replica Set với 4 thành viên
5. Tạo người dùng có quyền `root`
6. Bật xác thực (authentication)
7. Thiết lập keyFile để các node xác thực lẫn nhau

---

## 2️⃣ MongoDB Replica Set phân tán trên hai VPS

Script `multil_server/setup_mongodb_distributed_replica.sh` thiết lập MongoDB Replica Set phân tán trên hai VPS riêng biệt, cung cấp khả năng failover tự động khi một server gặp sự cố.

### Tính năng

1. Thiết lập tự động MongoDB Replica Set trên 2 server vật lý riêng biệt
2. Tự động bầu chọn primary node khi xảy ra sự cố
3. Cấu hình xác thực bảo mật giữa các node
4. Mở firewall cho phép kết nối giữa các node
5. Tạo chuỗi kết nối cho ứng dụng hỗ trợ tự động chuyển đổi

### Các bước khi chạy script

1. Script sẽ hỏi server này là primary hay secondary
2. Nhập IP của server đối tác (server còn lại)
3. Chọn port, tên replica set, username và password
4. Script tự động cài đặt và cấu hình MongoDB
5. Khởi tạo replica set hoặc thêm server vào replica set hiện có

---

## 3️⃣ Triển khai tự động từ xa

Script `ssh/deploy_mongodb_replica.sh` cho phép triển khai MongoDB Replica Set từ máy local lên hai VPS từ xa, tự động hóa toàn bộ quá trình cài đặt.

### Tính năng

1. Tự động triển khai MongoDB Replica Set lên hai VPS từ máy local
2. Hỗ trợ xác thực qua SSH key hoặc mật khẩu
3. Tự động cấu hình replica set trên cả hai server
4. Kiểm tra trạng thái và hiển thị thông tin kết nối sau khi hoàn tất

---

## 4️⃣ Khắc phục sự cố

Nếu bạn gặp vấn đề trong quá trình cài đặt, sử dụng script sửa lỗi:

```bash
./run_fix_all_configs.sh
```

Các tùy chọn sửa lỗi:

1. **Sửa lỗi quyền truy cập (exit code 14)** - Khắc phục lỗi về quyền thư mục
2. **Sửa lỗi port (exit code 48)** - Khắc phục lỗi xung đột port
3. **Sửa lỗi keyfile không đồng bộ** - Đồng bộ keyfile giữa các server
4. **Sửa lỗi không thể bầu chọn primary** - Khắc phục vấn đề bầu chọn
5. **Reset hoàn toàn MongoDB** - Xóa và thiết lập lại từ đầu

Chi tiết về các lỗi và cách khắc phục có trong tài liệu `troubleshoot.md`.

---

## Yêu cầu hệ thống

- Ubuntu 20.04 LTS trở lên
- Quyền sudo để cài đặt MongoDB
- Tường lửa cho phép kết nối TCP qua port MongoDB (mặc định 27017)
- Với thiết lập phân tán: Hai server có thể kết nối với nhau qua mạng

## Biến đổi

Các script có thể tùy chỉnh qua các biến cấu hình ở đầu mỗi file, bao gồm:
- Port MongoDB
- Tên replica set
- Tên người dùng và mật khẩu
- Đường dẫn lưu trữ dữ liệu
- Phiên bản MongoDB cài đặt