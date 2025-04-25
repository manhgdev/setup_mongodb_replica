#!/bin/bash

setup_replica() {
    echo -e "${YELLOW}=== MongoDB Replica Set Configuration ===${NC}"
    
    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS detected
        echo "macOS detected, using macOS setup..."
        # Call the specific function from setup_replica_macos.sh
        setup_replica_primary_macos $(hostname -I | awk '{print $1}')
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux detected
        echo "Linux detected, using Linux setup..."
        # Call the main function that shows the menu in setup_replica_linux.sh
        setup_replica_linux
    else
        echo -e "${RED}❌ Unsupported operating system: $OSTYPE${NC}"
        return 1
    fi
}

# Chỉ chạy setup_replica nếu script được gọi trực tiếp
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_replica
fi