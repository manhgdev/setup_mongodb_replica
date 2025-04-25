check_status() {
    echo -e "${YELLOW}=== Kiểm tra trạng thái ===${NC}"
    
    # Kiểm tra MongoDB đã cài đặt chưa
    if ! command -v mongod &> /dev/null; then
        echo -e "${RED}❌ MongoDB chưa được cài đặt${NC}"
        read -p "Bạn có muốn cài đặt MongoDB không? (y/n): " install_choice
        if [[ "$install_choice" == "y" ]]; then
            install_mongodb
            echo -e "\n${YELLOW}Đang kiểm tra lại trạng thái sau khi cài đặt...${NC}"
            sleep 2
            check_status
            return 0
        fi
        return 1
    fi
    
    # Kiểm tra MongoDB đang chạy
    if ! mongosh --eval 'db.runCommand({ ping: 1 })' &> /dev/null; then
        echo -e "${RED}❌ MongoDB chưa chạy${NC}"
        read -p "Bạn có muốn khởi động MongoDB không? (y/n): " start_choice
        if [[ "$start_choice" == "y" ]]; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                brew services start mongodb-community
            else
                sudo systemctl start mongod
            fi
            echo -e "${GREEN}✅ Đã khởi động MongoDB${NC}"
            echo -e "\n${YELLOW}Đang kiểm tra lại trạng thái sau khi khởi động...${NC}"
            sleep 2
            check_status
            return 0
        fi
        return 1
    fi
    
    # Hiển thị thông tin
    echo -e "${GREEN}MongoDB Status:${NC}"
    mongod --version
    
    echo -e "\n${GREEN}Service Status:${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        brew services list | grep mongodb
    else
        systemctl status mongod
    fi
    
    echo -e "\n${GREEN}Replica Set Status:${NC}"
    mongosh --eval 'rs.status()'
    
    # Kiểm tra lỗi và đề xuất fix
    local error=$(mongosh --eval 'rs.status()' 2>&1 | grep "not running with --replSet")
    if [ ! -z "$error" ]; then
        echo -e "\n${RED}❌ MongoDB chưa được cấu hình Replica Set${NC}"
        read -p "Bạn có muốn cấu hình Replica Set không? (y/n): " setup_choice
        if [[ "$setup_choice" == "y" ]]; then
            setup_replica
            echo -e "\n${YELLOW}Đang kiểm tra lại trạng thái sau khi cấu hình...${NC}"
            sleep 2
            check_status
            return 0
        fi
    fi
    
    echo -e "\n${GREEN}✅ MongoDB đang hoạt động bình thường${NC}"
}