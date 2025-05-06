# Di chuyển vào thư mục backup
cd /Users/manhg/DEV/#CLOUD/setup_mongodb_replica/mongodb_backup


# Đã xóa database ExpressApiNew
mongosh "mongodb://manhg:manhnk@localhost:27017/admin" --eval "
db = db.getSiblingDB('ExpressApiNew');
db.dropDatabase();
"

# Backup chỉ bảng ExpressApiNew
mongodump --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin --db ExpressApiNew --out ./backup_express_api

# Nén dữ liệu để giảm dung lượng
tar -czf backup_express_api.tar.gz backup_express_api 

# Trong thư mục backup
cd /Users/manhg/DEV/#CLOUD/setup_mongodb_replica/mongodb_backup

# Restore bảng ExpressApiNew sang node localhost
mongorestore --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin ./backup_express_api


# 3. Kiểm tra dữ liệu sau khi restore
// Kết nối tới node localhost
mongosh --host localhost --port 27017 --username manhg --password manhnk --authenticationDatabase admin

// Kiểm tra database ``ExpressApiNew``
use ExpressApiNew
show collections

// Kiểm tra dữ liệu trong bảng
db.collection_name.find().limit(1)