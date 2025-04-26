#!/bin/bash

setup_replica() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}       ${YELLOW}MONGODB REPLICA SET CONFIG${NC}           ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    
    # Get the absolute path of the script directory
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS detected
        echo -e "${GREEN}✓ macOS detected, using macOS setup...${NC}"
        # Call the specific function from setup_replica_macos.sh
        if type setup_replica_macos >/dev/null 2>&1; then
            setup_replica_macos
        else
            # Try to source the macOS setup script directly
            if [ -f "$SCRIPT_DIR/setup_replica_macos.sh" ]; then
                echo -e "${YELLOW}Importing macOS setup script...${NC}"
                source "$SCRIPT_DIR/setup_replica_macos.sh"
                if type setup_replica_macos >/dev/null 2>&1; then
                    setup_replica_macos
                else
                    echo -e "${RED}❌ Error: setup_replica_macos function not found after importing${NC}"
                    read -p "Press Enter to continue..."
                    return 1
                fi
            else
                echo -e "${RED}❌ Error: setup_replica_macos.sh file not found${NC}"
                echo -e "${YELLOW}Please create macOS setup script at: $SCRIPT_DIR/setup_replica_macos.sh${NC}"
                read -p "Press Enter to continue..."
                return 1
            fi
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux detected
        echo -e "${GREEN}✓ Linux detected, using Linux setup...${NC}"
        # Call the main function that shows the menu in setup_replica_linux.sh
        if type setup_replica_linux >/dev/null 2>&1; then
            setup_replica_linux
        else
            # Try to source the Linux setup script directly as a fallback
            echo -e "${YELLOW}setup_replica_linux function not found, importing Linux setup script...${NC}"
            if [ -f "$SCRIPT_DIR/setup_replica_linux.sh" ]; then
                source "$SCRIPT_DIR/setup_replica_linux.sh"
                if type setup_replica_linux >/dev/null 2>&1; then
                    setup_replica_linux
                else
                    echo -e "${RED}❌ Error: setup_replica_linux function not found after importing${NC}"
                    read -p "Press Enter to continue..."
                    return 1
                fi
            else
                echo -e "${RED}❌ Error: setup_replica_linux.sh file not found at $SCRIPT_DIR/setup_replica_linux.sh${NC}"
                read -p "Press Enter to continue..."
                return 1
            fi
        fi
    else
        echo -e "${RED}❌ Unsupported operating system: $OSTYPE${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi
}

# Chỉ chạy setup_replica nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Đảm bảo các biến màu sắc tồn tại
    if [ -z "$BLUE" ] || [ -z "$GREEN" ] || [ -z "$YELLOW" ] || [ -z "$RED" ] || [ -z "$NC" ]; then
        # Define colors if not defined
        BLUE='\033[0;34m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        RED='\033[0;31m'
        NC='\033[0m'
    fi
    
    # Thực thi chức năng replica
    setup_replica
fi