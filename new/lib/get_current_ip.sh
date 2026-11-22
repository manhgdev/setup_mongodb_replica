#!/bin/bash
# Chỉ chấp nhận IPv4 public có thể định tuyến trên Internet.
is_public_ipv4() {
    local value="$1" a b c d octet
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$value"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    # Private, loopback, link-local, shared, documentation và reserved.
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 192 && b == 88 && c == 99 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
}

get_current_ip() {
    local cache_file="${CURRENT_IP_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/setup_mongodb_replica/public_ipv4}"
    local ip cached_ip="" cache_dir temp_file

    if [[ -f "$cache_file" ]]; then
        cached_ip=$(cat -- "$cache_file" 2>/dev/null)
        if ! is_public_ipv4 "$cached_ip"; then
            cached_ip=""
            rm -f -- "$cache_file"
        fi
    fi

    # -q phải đứng đầu: bỏ ~/.curlrc; vô hiệu hóa proxy từ cả cấu hình và môi trường.
    if ip=$(curl -q --ipv4 --proxy '' --noproxy '*' --fail --silent --show-error \
        --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null) && is_public_ipv4 "$ip"; then
        cache_dir=$(dirname -- "$cache_file")
        if mkdir -p -- "$cache_dir" && temp_file=$(mktemp "$cache_file.XXXXXX"); then
            if printf '%s\n' "$ip" > "$temp_file"; then
                mv -f -- "$temp_file" "$cache_file" || rm -f -- "$temp_file"
            else
                rm -f -- "$temp_file"
            fi
        fi
        printf '%s\n' "$ip"
        return 0
    fi

    if [[ -n "$cached_ip" ]]; then
        printf '%s\n' "$cached_ip"
        return 0
    fi
    echo 'Không lấy được IPv4 public từ ipify và không có cache public hợp lệ.' >&2
    return 1
}
