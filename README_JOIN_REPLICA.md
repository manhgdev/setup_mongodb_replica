# Hướng dẫn Join Node vào MongoDB Replica Set

## 1. Kiểm tra trạng thái hiện tại

### Trên node PRIMARY:
```js
rs.status()
```

### Trên node muốn join:
```js
rs.status()
```

## 2. Chuẩn bị

### 2.1. Kiểm tra kết nối mạng
```bash
# Trên node PRIMARY
ping IP_NODE_MOI
telnet IP_NODE_MOI 27017

# Trên node muốn join
ping IP_PRIMARY
telnet IP_PRIMARY 27017
```

### 2.2. Kiểm tra cấu hình mongod.conf
```bash
# Trên cả 2 node, kiểm tra file /etc/mongod.conf
sudo nano /etc/mongod.conf

# Đảm bảo các cấu hình sau:
net:
  bindIp: 0.0.0.0
  port: 27017

replication:
  replSetName: rs0

security:
  keyFile: /etc/mongo-keyfile
```

### 2.3. Kiểm tra keyFile
```bash
# Trên cả 2 node
sudo ls -l /etc/mongo-keyfile
# Phải có quyền 400 và thuộc về user mongodb
sudo chmod 400 /etc/mongo-keyfile
sudo chown mongodb:mongodb /etc/mongo-keyfile
```

## 3. Backup dữ liệu từ node khác

### 3.1. Backup toàn bộ dữ liệu
```bash
# Trên node có dữ liệu cần backup
mongodump --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin --out /tmp/mongodb_backup

# Copy dữ liệu sang node mới
scp -r /tmp/mongodb_backup user@IP_NODE_MOI:/tmp/
```

### 3.2. Backup từng database cụ thể
```bash
# Backup database cụ thể
mongodump --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin --db database_name --out /tmp/mongodb_backup

# Copy dữ liệu sang node mới
scp -r /tmp/mongodb_backup user@IP_NODE_MOI:/tmp/
```

### 3.3. Restore dữ liệu trên node mới
```bash
# Trên node mới
mongorestore --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin /tmp/mongodb_backup
```

## 4. Quy trình join node

### 4.1. Trên node muốn join
```bash
# 1. Dừng mongod
sudo systemctl stop mongod

# 2. Xóa toàn bộ dữ liệu (KHÔNG xóa nếu node có dữ liệu quan trọng)
sudo rm -rf /var/lib/mongodb/*
# hoặc: sudo rm -rf /data/db/*

# 3. Khởi động lại mongod
sudo systemctl start mongod
```

### 4.2. Trên node PRIMARY
```js
// 1. Kiểm tra trạng thái
rs.status()

// 2. Remove node cũ nếu còn trong config
rs.remove("IP_NODE_MOI:27017")

// 3. Add node mới
rs.add("IP_NODE_MOI:27017")

// 4. Kiểm tra lại trạng thái
rs.status()
```

## 5. Kiểm tra sau khi join

### 5.1. Trên node PRIMARY
```js
rs.status()
// Node mới sẽ ở trạng thái STARTUP2 -> RECOVERING -> SECONDARY
```

### 5.2. Trên node mới join
```js
rs.status()
// Node sẽ tự động đồng bộ dữ liệu từ PRIMARY
```

## 6. Xử lý lỗi

### 6.1. Lỗi Authentication Failed
- Kiểm tra keyFile giống nhau trên cả 2 node
- Kiểm tra quyền file (400) và chủ sở hữu (mongodb)
- Kiểm tra user có quyền root trên cả 2 node

### 6.2. Lỗi Node không reachable
- Kiểm tra network (ping, telnet)
- Kiểm tra firewall
- Kiểm tra bindIp trong mongod.conf

### 6.3. Lỗi Config Version khác nhau
- Force reconfig trên PRIMARY:
  ```js
  cfg = rs.conf()
  cfg.version = cfg.version + 1
  rs.reconfig(cfg, {force: true})
  ```

### 6.4. Lỗi Node không join được
- Xóa sạch dữ liệu trên node muốn join
- Remove và add lại node từ PRIMARY
- Kiểm tra log mongod trên cả 2 node

## 7. Kiểm tra log

### 7.1. Trên node PRIMARY
```bash
tail -f /var/log/mongodb/mongod.log
```

### 7.2. Trên node muốn join
```bash
tail -f /var/log/mongodb/mongod.log
```

## 8. Lưu ý quan trọng

1. **KHÔNG xóa dữ liệu** nếu node có dữ liệu quan trọng
2. **Đảm bảo backup** trước khi thực hiện
3. **Kiểm tra kỹ network** giữa các node
4. **Đảm bảo keyFile giống nhau** trên cả 2 node
5. **Kiểm tra quyền user** trên cả 2 node
6. **Đảm bảo cấu hình mongod.conf** đúng trên cả 2 node
7. **Kiểm tra phiên bản MongoDB** giống nhau trên cả 2 node
8. **Backup dữ liệu** trước khi xóa hoặc reset node
9. **Kiểm tra dung lượng ổ đĩa** trước khi restore dữ liệu
10. **Đảm bảo user có quyền backup/restore** trên cả 2 node

## 9. Tham khảo

- [MongoDB Replica Set Configuration](https://www.mongodb.com/docs/manual/reference/replica-configuration/)
- [MongoDB Replica Set Deployment](https://www.mongodb.com/docs/manual/administration/replica-set-deployment/)
- [MongoDB Replica Set Troubleshooting](https://www.mongodb.com/docs/manual/administration/replica-set-troubleshooting/)
- [MongoDB Backup and Restore](https://www.mongodb.com/docs/manual/core/backup-restore/) 