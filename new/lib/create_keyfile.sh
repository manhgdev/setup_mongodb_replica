#!/bin/bash
# create_keyfile.sh
# Hàm tạo keyfile cho xác thực MongoDB

# Load colors
source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"

# Hàm tạo keyfile
create_keyfile() {
    local PRIMARY_IP=$1
    local MONGODB_KEYFILE=$2
    
    echo -e "${YELLOW}Thiết lập keyfile cho xác thực...${NC}"
    
    # Kiểm tra xem keyfile đã tồn tại chưa
    if [ -f "$MONGODB_KEYFILE" ]; then
        echo -e "${GREEN}Keyfile đã tồn tại tại: $MONGODB_KEYFILE${NC}"
        echo -e "${YELLOW}Bạn có muốn sử dụng keyfile hiện có không?${NC}"
        echo "1) Sử dụng keyfile hiện có"
        echo "2) Tải keyfile mới từ PRIMARY server"
        echo "3) Nhập keyfile thủ công"
        read -p "Lựa chọn của bạn (1-3): " keyfile_choice
        
        case $keyfile_choice in
            1)
                echo -e "${GREEN}Sử dụng keyfile hiện có.${NC}"
                # Kiểm tra quyền keyfile
                echo -e "${YELLOW}Kiểm tra quyền keyfile...${NC}"
                sudo chmod 400 "$MONGODB_KEYFILE"
                if getent passwd mongodb >/dev/null 2>&1; then
                    sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
                fi
                echo -e "${GREEN}Keyfile đã được thiết lập với quyền phù hợp${NC}"
                return 0
                ;;
            2)
                echo -e "${YELLOW}Tải keyfile mới từ PRIMARY server...${NC}"
                # Backup keyfile hiện tại
                sudo cp "$MONGODB_KEYFILE" "${MONGODB_KEYFILE}.bak.$(date +%Y%m%d%H%M%S)"
                echo -e "${GREEN}Đã backup keyfile hiện tại${NC}"
                ;;
            3)
                echo -e "${YELLOW}Nhập keyfile thủ công...${NC}"
                # Backup keyfile hiện tại
                sudo cp "$MONGODB_KEYFILE" "${MONGODB_KEYFILE}.bak.$(date +%Y%m%d%H%M%S)"
                echo -e "${GREEN}Đã backup keyfile hiện tại${NC}"
                echo "Vui lòng cung cấp nội dung keyfile từ server primary:"
                echo "Để lấy nội dung keyfile từ server primary, hãy chạy lệnh: sudo cat $MONGODB_KEYFILE"
                echo "Sau đó copy toàn bộ nội dung vào đây và nhấn CTRL+D khi hoàn tất:"
                sudo bash -c "cat > $MONGODB_KEYFILE"
                echo "Đã nhập keyfile mới"
                # Thiết lập quyền và kết thúc
                sudo chmod 400 "$MONGODB_KEYFILE"
                if getent passwd mongodb >/dev/null 2>&1; then
                    sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
                fi
                echo -e "${GREEN}Keyfile đã được thiết lập${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ. Sử dụng keyfile hiện có.${NC}"
                sudo chmod 400 "$MONGODB_KEYFILE"
                if getent passwd mongodb >/dev/null 2>&1; then
                    sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
                fi
                return 0
                ;;
        esac
    else
        echo -e "${YELLOW}Keyfile chưa tồn tại. Sẽ tải từ PRIMARY server.${NC}"
    fi
    
    # Yêu cầu thông tin đăng nhập SSH cho việc copy keyfile từ PRIMARY
    read -p "Nhập username SSH cho máy chủ primary: " ssh_user
    
    # Thử copy keyfile từ primary
    echo -e "${YELLOW}Copy keyfile từ máy chủ primary $PRIMARY_IP...${NC}"
    if scp -o StrictHostKeyChecking=no ${ssh_user}@${PRIMARY_IP}:${MONGODB_KEYFILE} ${MONGODB_KEYFILE}; then
        echo -e "${GREEN}Đã copy keyfile từ primary thành công${NC}"
    else
        echo -e "${RED}Không thể copy keyfile từ primary.${NC}"
        echo "====== FIX LỖI MONGODB KEYFILE KHÔNG ĐỒNG BỘ ======"
        
        # Lưu lại keyfile hiện tại nếu có
        if [ -f "$MONGODB_KEYFILE" ]; then
            echo "Lưu lại keyfile hiện tại..."
            sudo cp "$MONGODB_KEYFILE" "${MONGODB_KEYFILE}.bak"
        fi
        
        # Yêu cầu người dùng nhập nội dung keyfile từ server primary
        echo "Vui lòng cung cấp nội dung keyfile từ server primary:"
        echo "Để lấy nội dung keyfile từ server primary, hãy chạy lệnh: sudo cat $MONGODB_KEYFILE"
        echo "Sau đó copy toàn bộ nội dung vào đây và nhấn CTRL+D khi hoàn tất:"
        
        sudo bash -c "cat > $MONGODB_KEYFILE"
        echo "Đã nhập keyfile mới"
    fi
    
    # Thiết lập quyền
    echo -e "${YELLOW}Thiết lập quyền cho keyfile...${NC}"
    sudo chmod 400 "$MONGODB_KEYFILE"
    if getent passwd mongodb >/dev/null 2>&1; then
        sudo chown mongodb:mongodb "$MONGODB_KEYFILE"
    fi
    
    echo -e "${GREEN}Keyfile đã được thiết lập${NC}"
}