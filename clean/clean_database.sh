#!/bin/bash

echo "Đang xóa database ExpressApiNew trên node 171.xxx..."

mongosh --host 127.0.0.1 --port 27017 --username user --password pass --authenticationDatabase admin <<EOF
use ExpressApiNew
db.dropDatabase()
exit
EOF

echo "Đã xóa database ExpressApiNew thành công!" 