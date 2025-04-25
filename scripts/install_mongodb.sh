#!/bin/bash

install_mongodb() {
    if ! command -v mongod &> /dev/null; then
        echo "MongoDB chưa được cài đặt. Đang cài đặt MongoDB..."
        
        # Kiểm tra hệ điều hành
        OS="$(uname -s)"
        case "${OS}" in
            Linux*)
                # Cài đặt cho Ubuntu/Debian
                sudo apt update && sudo apt install -y curl gnupg netcat-openbsd
                sudo rm -f /usr/share/keyrings/mongodb-server-8.0.gpg
                curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
                echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
                sudo apt-get update
                sudo apt-get install -y mongodb-org
                
                sleep 1
                sudo systemctl daemon-reload
                sudo systemctl start mongod 
                sudo systemctl enable mongod
                ;;
            Darwin*)
                # Cài đặt cho macOS
                if ! command -v brew &> /dev/null; then
                    echo "Homebrew chưa được cài đặt. Đang cài đặt Homebrew..."
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                fi
                
                brew tap mongodb/brew
                brew install mongodb-community@8.0
                ;;
            *)
                echo "❌ Hệ điều hành không được hỗ trợ: ${OS}"
                exit 1
                ;;
        esac
        
        echo "Đợi MongoDB khởi động..."
        sleep 2
        
        if command -v mongod &> /dev/null; then
            echo "✅ MongoDB đã được cài đặt thành công"
            mongod --version
        else
            echo "❌ Có lỗi trong quá trình cài đặt MongoDB"
            echo "Kiểm tra đường dẫn của mongod:"
            
            case "${OS}" in
                Linux*)
                    sudo find / -name mongod 2>/dev/null || echo "Không tìm thấy mongod"
                    export PATH=$PATH:/usr/bin:/usr/local/bin:/opt/mongodb/bin
                    ;;
                Darwin*)
                    which mongod || echo "Không tìm thấy mongod"
                    export PATH="/usr/local/bin:$PATH"
                    ;;
            esac
            
            echo "Đã thêm các đường dẫn phổ biến vào PATH"
            
            if command -v mongod &> /dev/null; then
                echo "✅ Đã tìm thấy mongod sau khi cập nhật PATH"
            else
                echo "⚠️ Không thể tìm thấy mongod. Sẽ tiếp tục nhưng có thể gặp lỗi."
            fi
        fi
    else
        echo "✅ MongoDB đã được cài đặt"
        mongod --version
        
        # Kiểm tra và khởi động service nếu cần
        OS="$(uname -s)"
        case "${OS}" in
            Linux*)
                if ! systemctl is-active --quiet mongod; then
                    echo "Khởi động lại MongoDB service..."
                    sudo systemctl restart mongod
                fi
                ;;
            Darwin*)
                if ! brew services list | grep mongodb-community | grep started > /dev/null; then
                    echo "Khởi động lại MongoDB service..."
                    brew services restart mongodb-community@7.0
                fi
                ;;
        esac
    fi
}

# Chỉ chạy hàm install_mongodb nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_mongodb
fi 