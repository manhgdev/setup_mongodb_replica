#!/bin/bash

# Import required configuration files
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

setup_replica() {
    # Get the absolute path of the script directory
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS detected
        echo -e "${GREEN}✓ macOS detected, using macOS setup...${NC}"
        # Call the main function that shows the menu in setup_replica_macos.sh
        source "$SCRIPT_DIR/setup_replica_macos.sh"
        setup_replica_macos
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux detected
        echo -e "${GREEN}✓ Linux detected, using Linux setup...${NC}"
        # Call the main function that shows the menu in setup_replica_linux.sh
        source "$SCRIPT_DIR/setup_replica_linux.sh"
        setup_replica_linux
    else
        echo -e "${RED}❌ Unsupported operating system: $OSTYPE${NC}"
        read -p "Press Enter to continue..."
        return 1
    fi
}

# Chỉ chạy setup_replica nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica
fi