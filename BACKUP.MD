# Di chuyển vào thư mục backup
cd /Users/manhg/DEV/#CLOUD/setup_mongodb_replica/mongodb_backup

# Backup chỉ bảng ExpressApiNew
mongodump --host 157.66.46.252 --port 27017 --username manhg --password manhnk --authenticationDatabase admin --db ExpressApiNew --out ./backup_express_api

# Nén dữ liệu để giảm dung lượng
tar -czf backup_express_api.tar.gz backup_express_api 

# Trong thư mục backup
cd /Users/manhg/DEV/#CLOUD/setup_mongodb_replica/mongodb_backup

# Restore bảng ExpressApiNew sang node 171.244.21.188
mongorestore --host 171.244.21.188 --port 27017 --username manhg --password manhnk --authenticationDatabase admin ./backup_express_api


# 3. Kiểm tra dữ liệu sau khi restore
// Kết nối tới node 171.244.21.188
mongosh --host 171.244.21.188 --port 27017 --username manhg --password manhnk --authenticationDatabase admin

// Kiểm tra database ExpressApiNew
use ExpressApiNew
show collections

// Kiểm tra dữ liệu trong bảng
db.collection_name.find().limit(1)