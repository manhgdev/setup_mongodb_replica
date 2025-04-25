# Quản lý MongoDB PRIMARY trong Replica Set

Thư mục này chứa các tệp cấu hình và công cụ liên quan đến việc quản lý node PRIMARY trong MongoDB Replica Set.

## Giới thiệu

Trong MongoDB Replica Set, node PRIMARY là node duy nhất có thể nhận các thao tác ghi (write) dữ liệu. Khi PRIMARY gặp sự cố, một trong các node SECONDARY sẽ được bầu (election) lên làm PRIMARY mới.

## Các tệp trong thư mục này

- `rs_config_*.json`: Các tệp sao lưu cấu hình replica set (được tạo tự động khi chạy script bầu PRIMARY)
- Các tệp cấu hình và keyfile được tạo trong quá trình thiết lập

## Các tác vụ quản lý PRIMARY

### 1. Bầu/chuyển PRIMARY từ server này sang server khác

Trong một replica set hoạt động bình thường, bạn có thể chuyển vai trò PRIMARY từ server hiện tại sang server khác bằng cách:

```bash
# Khiến PRIMARY hiện tại từ bỏ vai trò (step down)
mongosh -u admin -p password --eval "db.adminCommand({replSetStepDown: 60, force: true})"

# Hoặc tăng priority của một node để nó được ưu tiên làm PRIMARY
mongosh -u admin -p password --eval "
config = rs.conf();
for (var i = 0; i < config.members.length; i++) {
  if (config.members[i].host == 'target-server:27017') {
    config.members[i].priority = 10;
  }
}
rs.reconfig(config);
"
```

### 2. Gộp hai replica set khác nhau

Khi có hai replica set khác nhau (đôi khi do cấu hình sai), bạn cần:
1. Chọn server chứa dữ liệu quan trọng làm PRIMARY
2. Xóa dữ liệu trên server còn lại và cấu hình lại để tham gia vào replica set mới

### 3. Xử lý khi có nhiều PRIMARY cùng lúc (split-brain)

Tình trạng nhiều PRIMARY cùng lúc thường do:
- Network partition (không thể giao tiếp giữa các server)
- Khác replicaSetId (thường do cài đặt riêng biệt)

Cách khắc phục:
1. Dừng MongoDB trên một trong các PRIMARY
2. Xóa dữ liệu trên server đó
3. Cấu hình lại để tham gia vào replica set chính

### 4. Khôi phục khi không có PRIMARY

Khi không thể bầu PRIMARY (thường do không đủ số lượng vote), sử dụng:

```bash
mongosh -u admin -p password --eval "
rs.reconfig(rs.conf(), {force: true})
"
```

## Các thông tin cần sao lưu

1. Cấu hình replica set (`rs.conf()`)
2. Trạng thái replica set (`rs.status()`)
3. Thông tin master (`rs.isMaster()`)

## Tham khảo

- [MongoDB Replica Set Elections](https://www.mongodb.com/docs/manual/core/replica-set-elections/)
- [Force a Member to be Primary](https://www.mongodb.com/docs/manual/tutorial/force-member-to-be-primary/)
- [Reconfigure a Replica Set with Unavailable Members](https://www.mongodb.com/docs/manual/tutorial/reconfigure-replica-set-with-unavailable-members/) 