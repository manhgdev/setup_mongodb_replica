#!/bin/bash

# Get the absolute path of the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import required configuration files
if [ -f "$SCRIPT_DIR/../config/mongodb_settings.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_settings.sh"
fi

if [ -f "$SCRIPT_DIR/../config/mongodb_functions.sh" ]; then
    source "$SCRIPT_DIR/../config/mongodb_functions.sh"
fi

# Define colors if not defined
if [ -z "$BLUE" ] || [ -z "$GREEN" ] || [ -z "$YELLOW" ] || [ -z "$RED" ] || [ -z "$NC" ]; then
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    NC='\033[0m'
fi

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}       ${YELLOW}FIX REPLICA SET CONFIGURATION${NC}        ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

# Get the server's real IP
SERVER_IP=$(get_server_ip)
echo -e "${YELLOW}Server IP detected: ${GREEN}$SERVER_IP${NC}"

# Ask for credentials
read -p "MongoDB username [$MONGODB_USER]: " username
username=${username:-$MONGODB_USER}

read -sp "MongoDB password [$MONGODB_PASSWORD]: " password
password=${password:-$MONGODB_PASSWORD}
echo ""

# Get current replica set configuration
echo -e "${YELLOW}Getting current replica set configuration...${NC}"
CONFIG=$(mongosh --quiet --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "JSON.stringify(rs.conf())")

if [ -z "$CONFIG" ]; then
    echo -e "${RED}Failed to get replica set configuration. Check your credentials.${NC}"
    exit 1
fi

# Parse the configuration
echo -e "${YELLOW}Current replica set members:${NC}"
MEMBERS=$(mongosh --quiet --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.conf().members.forEach(m => print(m._id + ': ' + m.host))")
echo "$MEMBERS"

# Check connectivity between nodes
echo -e "${YELLOW}Checking connectivity between nodes...${NC}"
HOSTS=$(mongosh --quiet --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.conf().members.map(m => m.host).join(',')")
IFS=',' read -ra HOST_ARRAY <<< "$HOSTS"

for host in "${HOST_ARRAY[@]}"; do
    # Split host:port
    IFS=':' read -ra HOST_PORT <<< "$host"
    check_host="${HOST_PORT[0]}"
    check_port="${HOST_PORT[1]}"
    
    # Skip localhost/127.0.0.1
    if [[ "$check_host" == "localhost" || "$check_host" == "127.0.0.1" ]]; then
        echo -e "${YELLOW}Skipping localhost check${NC}"
        continue
    fi
    
    # Try to ping the host
    if ping -c 1 -W 2 "$check_host" &>/dev/null; then
        echo -e "${GREEN}✓ Host $check_host is reachable (ping)${NC}"
    else
        echo -e "${RED}✗ Host $check_host is NOT reachable (ping)${NC}"
    fi
    
    # Check MongoDB port using telnet or nc
    if command -v nc &>/dev/null; then
        if nc -z -w 2 "$check_host" "$check_port" &>/dev/null; then
            echo -e "${GREEN}✓ MongoDB on $host is reachable (port check)${NC}"
        else
            echo -e "${RED}✗ MongoDB on $host is NOT reachable (port check)${NC}"
        fi
    elif command -v telnet &>/dev/null; then
        if timeout 2 telnet "$check_host" "$check_port" </dev/null &>/dev/null; then
            echo -e "${GREEN}✓ MongoDB on $host is reachable (port check)${NC}"
        else
            echo -e "${RED}✗ MongoDB on $host is NOT reachable (port check)${NC}"
        fi
    else
        echo -e "${YELLOW}! Cannot check port connectivity. Please install netcat (nc) or telnet${NC}"
    fi
done

# Create menu
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}       ${YELLOW}REPLICA SET OPERATIONS${NC}                ${BLUE}║${NC}"
echo -e "${BLUE}╠════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC} ${GREEN}1.${NC} Update localhost to real IP               ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}2.${NC} Remove unreachable/dead node              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}3.${NC} Show detailed replica status              ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${GREEN}4.${NC} Fix configuration for multi-server setup  ${BLUE}║${NC}"
echo -e "${BLUE}║${NC} ${RED}0.${NC} Exit                                      ${BLUE}║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"

read -p "Choose an option [0-4]: " option

case $option in
    1)
        # Update localhost to real IP
        echo -e "${YELLOW}This will update all 'localhost' hosts to use the server IP: ${GREEN}$SERVER_IP${NC}"
        read -p "Do you want to continue? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 0
        fi
        
        # Create a temporary JavaScript file
        JS_FILE=$(mktemp)
        cat > "$JS_FILE" << EOF
try {
  // Get current configuration
  var cfg = rs.conf();
  
  // Track if any changes were made
  var changed = false;
  
  // Update member hostnames
  for (var i = 0; i < cfg.members.length; i++) {
    var host = cfg.members[i].host;
    var port = host.split(':')[1];
    
    if (host.includes('localhost') || host.includes('127.0.0.1')) {
      cfg.members[i].host = "$SERVER_IP:" + port;
      print("Updating member " + i + " from " + host + " to " + cfg.members[i].host);
      changed = true;
    }
  }
  
  // Apply the new configuration if changed
  if (changed) {
    var result = rs.reconfig(cfg, {force: true});
    printjson(result);
  } else {
    print("No changes needed. All members already using correct IP.");
  }
} catch (e) {
  print("ERROR: " + e.message);
}
EOF
        
        # Apply the configuration
        echo -e "${YELLOW}Applying new configuration...${NC}"
        mongosh --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" "$JS_FILE"
        
        # Cleanup
        rm -f "$JS_FILE"
        ;;
    2)
        # Remove unreachable/dead node
        echo -e "${YELLOW}Removing unreachable/dead node...${NC}"
        read -p "Enter the host:port of the node to remove: " remove_host
        
        if [ -z "$remove_host" ]; then
            echo -e "${RED}No host specified. Operation cancelled.${NC}"
            exit 0
        fi
        
        # Confirm removal
        echo -e "${YELLOW}You are about to remove ${RED}$remove_host${YELLOW} from the replica set.${NC}"
        read -p "Are you sure? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 0
        fi
        
        # Create removal script
        JS_FILE=$(mktemp)
        cat > "$JS_FILE" << EOF
try {
  var result = rs.remove("$remove_host", {force: true});
  printjson(result);
} catch (e) {
  print("ERROR: " + e.message);
  
  // Try more aggressive method if standard approach fails
  try {
    print("Trying alternative method...");
    var cfg = rs.conf();
    var newMembers = [];
    
    for (var i = 0; i < cfg.members.length; i++) {
      if (cfg.members[i].host !== "$remove_host") {
        newMembers.push(cfg.members[i]);
      } else {
        print("Found member to remove: " + cfg.members[i].host);
      }
    }
    
    if (newMembers.length === cfg.members.length) {
      print("Node $remove_host was not found in the configuration");
    } else {
      cfg.members = newMembers;
      var reconfigResult = rs.reconfig(cfg, {force: true});
      printjson(reconfigResult);
    }
  } catch (e2) {
    print("FATAL ERROR: " + e2.message);
  }
}
EOF
        
        # Apply the configuration
        echo -e "${YELLOW}Removing node from replica set...${NC}"
        mongosh --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" "$JS_FILE"
        
        # Cleanup
        rm -f "$JS_FILE"
        ;;
    3)
        # Show detailed replica status
        echo -e "${YELLOW}Showing detailed replica set status...${NC}"
        mongosh --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.status()"
        ;;
    4)
        # Fix configuration for multi-server setup
        echo -e "${YELLOW}Fixing configuration for multi-server setup...${NC}"
        read -p "Enter the primary node host:port: " primary_host
        
        if [ -z "$primary_host" ]; then
            echo -e "${RED}No primary host specified. Operation cancelled.${NC}"
            exit 0
        fi
        
        # Confirm changes
        echo -e "${YELLOW}This will update the configuration to use the proper hostnames/IPs.${NC}"
        read -p "Do you want to continue? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Operation cancelled${NC}"
            exit 0
        fi
        
        # Create a temporary JavaScript file
        JS_FILE=$(mktemp)
        cat > "$JS_FILE" << EOF
try {
  var primary = "$primary_host";
  var serverHosts = [];
  
  // Add current server if not already a member
  serverHosts.push("$SERVER_IP:$MONGO_PORT");
  
  // Get current configuration
  var cfg = rs.conf();
  
  // Check if any members need updating
  var changed = false;
  
  // First pass: update any localhost references to real IPs
  for (var i = 0; i < cfg.members.length; i++) {
    var host = cfg.members[i].host;
    
    if (host.includes('localhost') || host.includes('127.0.0.1')) {
      // This is a local reference, update it
      var port = host.split(':')[1];
      cfg.members[i].host = "$SERVER_IP:" + port;
      print("Updating local member " + i + " from " + host + " to " + cfg.members[i].host);
      changed = true;
    }
  }
  
  // Apply the new configuration if changed
  if (changed) {
    print("Applying configuration updates...");
    var result = rs.reconfig(cfg, {force: true});
    printjson(result);
    print("Replica set configuration updated successfully");
  } else {
    print("No changes needed for local references.");
  }
  
  // Create simplified connection string for reference
  var connString = "mongodb://$username:$password@";
  var hosts = [];
  
  for (var i = 0; i < cfg.members.length; i++) {
    hosts.push(cfg.members[i].host);
  }
  
  connString += hosts.join(',') + "/$AUTH_DATABASE?replicaSet=" + cfg._id;
  print("Connection string: " + connString);
  
} catch (e) {
  print("ERROR: " + e.message);
}
EOF
        
        # Apply the configuration
        echo -e "${YELLOW}Applying new configuration...${NC}"
        mongosh --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" "$JS_FILE"
        
        # Cleanup
        rm -f "$JS_FILE"
        ;;
    0|*)
        echo -e "${GREEN}Exiting...${NC}"
        exit 0
        ;;
esac

# Check the new configuration
echo -e "${YELLOW}Verifying new configuration...${NC}"
sleep 3
NEW_MEMBERS=$(mongosh --quiet --host localhost --port $MONGO_PORT -u "$username" -p "$password" --authenticationDatabase "$AUTH_DATABASE" --eval "rs.conf().members.forEach(m => print(m._id + ': ' + m.host))")
echo "$NEW_MEMBERS"

echo -e "${GREEN}✓ Replica set configuration update completed!${NC}"
echo -e "${YELLOW}Note: It might take some time for all nodes to reconnect.${NC}"
echo -e "${YELLOW}Check status with: mongosh --eval \"rs.status()\"${NC}" 