# MongoDB Replica Set Setup

Script này giúp thiết lập MongoDB Replica Set với 2 server, mỗi server có 3 node:

## Cấu trúc thư mục
```
.
├── main.sh              # Script chính
├── scripts/             # Thư mục chứa các script con
│   ├── install_mongodb.sh  # Script cài đặt MongoDB
│   ├── data_manager.sh     # Script quản lý thư mục data
│   └── mongodb_manager.sh  # Script quản lý MongoDB instances
└── config/              # Thư mục chứa các file cấu hình
```

## Cấu hình

### Server 1
- Node 27017: PRIMARY (priority: 2)
- Node 27018: ARBITER
- Node 27019: ARBITER

### Server 2
- Node 27017: SECONDARY (priority: 1)
- Node 27018: ARBITER
- Node 27019: ARBITER

## Cách sử dụng

1. Cấp quyền thực thi cho các script:
```bash
chmod +x main.sh scripts/*.sh
```

2. Chạy script chính:
```bash
./main.sh
```

3. Chọn các tùy chọn:
- 0: Cài đặt MongoDB (nếu chưa có)
- 1: Setup và khởi động Replica Set
- 2: Dừng Replica Set
- 3: Dọn dẹp và thoát

## Lưu ý
- Script sẽ tự động kiểm tra và cài đặt MongoDB nếu chưa có
- Các thư mục data sẽ được tạo tự động
- Log file sẽ được lưu trong thư mục data tương ứng
- Đảm bảo có quyền sudo để cài đặt MongoDB 