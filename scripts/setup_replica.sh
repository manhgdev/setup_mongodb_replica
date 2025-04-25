#!/bin/bash

setup_replica() {
    echo -e "${YELLOW}=== MongoDB Replica Set Configuration ===${NC}"
    
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS detected
        echo "macOS detected, using macOS setup..."
        # Call the specific function from setup_replica_macos.sh
        if type setup_replica_macos >/dev/null 2>&1; then
            setup_replica_macos
        else
            echo -e "${RED}❌ Error: setup_replica_macos function not found${NC}"
            echo "Make sure scripts/setup_replica_macos.sh is properly sourced in main.sh"
            return 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux detected
        echo "Linux detected, using Linux setup..."
        # Call the main function that shows the menu in setup_replica_linux.sh
        if type setup_replica_linux >/dev/null 2>&1; then
            setup_replica_linux
        else
            # Try to source the Linux setup script directly as a fallback
            echo "setup_replica_linux function not found, trying to source it directly..."
            if [ -f "$(dirname "$0")/setup_replica_linux.sh" ]; then
                source "$(dirname "$0")/setup_replica_linux.sh"
                setup_replica_linux
            else
                echo -e "${RED}❌ Error: setup_replica_linux function not found and setup_replica_linux.sh file not found${NC}"
                echo "Make sure scripts/setup_replica_linux.sh is properly sourced in main.sh"
                return 1
            fi
        fi
    else
        echo -e "${RED}❌ Unsupported operating system: $OSTYPE${NC}"
        return 1
    fi
}

# Chỉ chạy setup_replica nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica
fi