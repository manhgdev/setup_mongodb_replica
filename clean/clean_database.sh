#!/bin/bash

echo "Đang xóa database ExpressApiNew trên node 171.xxx..."

read -r -p "User MongoDB: " username || exit 1
[[ -n "$username" ]] || exit 1
mongosh --host 127.0.0.1 --port 27017 --username "$username" --authenticationDatabase admin \
    --eval "db.getSiblingDB('ExpressApiNew').dropDatabase()" || exit 1

echo "Đã xóa database ExpressApiNew thành công!" 