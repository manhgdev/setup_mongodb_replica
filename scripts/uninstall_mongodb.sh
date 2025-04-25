#!/bin/bash

detect_mongodb_version() {
    # Kiểm tra phiên bản MongoDB đang cài đặt
    if command -v mongod &> /dev/null; then
        MONGODB_VERSION=$(mongod --version | grep "db version" | awk '{print $3}')
        echo "$MONGODB_VERSION"
        return 0
    fi
    return 1
}

uninstall_mongodb() {
    echo -e "${YELLOW}=== Xóa MongoDB ===${NC}"
    
    # Kiểm tra quyền sudo
    if [[ "$(uname -s)" == "Linux" ]] && [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Cần quyền sudo để xóa MongoDB trên Linux${NC}"
        return 1
    fi
    
    # Dừng MongoDB trước khi xóa
    if [[ "$(uname -s)" == "Darwin" ]]; then
        brew services stop mongodb-community || true
    else
        systemctl stop mongod || true
    fi

    echo "Đang xóa MongoDB..."
    
    # Kiểm tra hệ điều hành
    OS="$(uname -s)"
    case "${OS}" in
        Darwin*)
            # Dừng tất cả các process MongoDB
            pkill -f mongod
            pkill -f mongo
            
            # Phát hiện phiên bản MongoDB
            MONGODB_VERSION=$(detect_mongodb_version)
            if [ $? -eq 0 ]; then
                MAJOR_VERSION=$(echo "$MONGODB_VERSION" | cut -d. -f1)
                echo "Đã phát hiện MongoDB phiên bản $MONGODB_VERSION"
                
                # Dừng service nếu đang chạy
                if brew services list | grep -q "mongodb-community@$MAJOR_VERSION"; then
                    brew services stop "mongodb-community@$MAJOR_VERSION"
                fi
                
                # Xóa MongoDB nếu đã cài đặt
                if brew list | grep -q "mongodb-community@$MAJOR_VERSION"; then
                    brew uninstall "mongodb-community@$MAJOR_VERSION"
                fi
            fi
            
            # Thử xóa tất cả các phiên bản MongoDB có thể
            for version in 8.0 7.0 6.0 5.0 4.4; do
                if brew list | grep -q "mongodb-community@$version"; then
                    brew uninstall "mongodb-community@$version"
                fi
            done
            
            # Xóa các file cấu hình và data nếu tồn tại
            if [[ "$(uname -m)" == "arm64" ]]; then
                # Xóa file cấu hình
                rm -f "/opt/homebrew/etc/mongod.conf"
                rm -f "/opt/homebrew/etc/mongodb.conf"
                
                # Xóa thư mục log
                rm -rf "/opt/homebrew/var/log/mongodb"
                
                # Xóa thư mục data
                rm -rf "/opt/homebrew/var/mongodb"
                rm -rf "/opt/homebrew/var/lib/mongodb"
                
                # Xóa các file trong Cellar
                rm -rf "/opt/homebrew/Cellar/mongodb-community"
            else
                # Xóa file cấu hình
                rm -f "/usr/local/etc/mongod.conf"
                rm -f "/usr/local/etc/mongodb.conf"
                
                # Xóa thư mục log
                rm -rf "/usr/local/var/log/mongodb"
                
                # Xóa thư mục data
                rm -rf "/usr/local/var/mongodb"
                rm -rf "/usr/local/var/lib/mongodb"
                
                # Xóa các file trong Cellar
                rm -rf "/usr/local/Cellar/mongodb-community"
            fi
            ;;
        Linux*)
            # Kiểm tra distro
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                case $ID in
                    ubuntu|debian)
                        # Dừng service MongoDB
                        sudo systemctl stop mongod
                        sudo systemctl disable mongod
                        
                        # Xóa MongoDB và các gói phụ thuộc
                        sudo apt-get purge -y mongodb-org*
                        sudo apt-get autoremove -y
                        
                        # Xóa các file cấu hình và data
                        sudo rm -rf /var/lib/mongodb
                        sudo rm -rf /var/log/mongodb
                        sudo rm -rf /etc/mongodb.conf
                        sudo rm -rf /etc/mongod.conf

                        # Xóa các file replica set
                        sudo rm -rf /var/lib/mongodb_27017/replset.election*
                        sudo rm -rf /var/lib/mongodb_27017/local.*
                        
                        ;;
                    *)
                        echo "❌ Hệ điều hành Linux không được hỗ trợ: $ID"
                        exit 1
                        ;;
                esac
            fi
            ;;
        *)
            echo "❌ Hệ điều hành không được hỗ trợ: ${OS}"
            exit 1
            ;;
    esac
    
    # Xóa các file tạm và file trong thư mục home
    rm -rf /tmp/mongodb-*.sock
    rm -rf ~/.mongodb
    rm -rf ~/.mongorc.js
    
    # Xóa các file trong /var
    sudo rm -rf /var/lib/mongodb
    sudo rm -rf /var/log/mongodb
    sudo rm -rf /var/run/mongodb
    
    echo "✅ Đã xóa MongoDB và các file liên quan"
}

# Chỉ chạy hàm uninstall_mongodb nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    uninstall_mongodb
fi 