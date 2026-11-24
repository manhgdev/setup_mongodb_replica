#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/mongo_auth.sh" || exit 1
# remove_duplicate_members.sh
# Hàm kiểm tra và xóa member trùng lặp

# Load colors
source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"

# Hàm kiểm tra và xóa member trùng lặp
remove_duplicate_members() {
    local host=$1
    local user=$2
    local pass=$3
    local auth_db=$4
    local current_host=$5
    
    echo -e "${YELLOW}Kiểm tra và xóa member trùng lặp trong replica set...${NC}"
    mongo_eval "$user" "$pass" "$auth_db" --host "$host" --quiet --eval "
        var cfg = rs.conf();
        var members = cfg.members;
        var seen = {};
        var newMembers = [];
        
        for (var i = 0; i < members.length; i++) {
            var member = members[i];
            if (!seen[member.host]) {
                seen[member.host] = true;
                newMembers.push(member);
            }
        }
        
        if (newMembers.length !== members.length) {
            cfg.members = newMembers;
            cfg.version += 1;
            rs.reconfig(cfg);
            print('Removed duplicate members');
        } else {
            print('No duplicate members found');
        }
    "
}