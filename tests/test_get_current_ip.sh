#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/new/lib/get_current_ip.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export CURRENT_IP_CACHE_FILE="$test_dir/cache/ip"
mkdir -p "$(dirname "$CURRENT_IP_CACHE_FILE")"
curl() {
    [[ "$*" == "-q --ipv4 --proxy  --noproxy * --fail --silent --show-error --connect-timeout 5 --max-time 10 https://api.ipify.org" ]] || return 99
    printf '%s' "$mock_ip"
    return "$mock_status"
}
for invalid in 10.1.2.3 172.16.0.1 192.168.1.1 127.0.0.1 169.254.1.2 100.64.1.2 0.0.0.0 224.1.1.1 255.255.255.255 192.0.2.1 198.51.100.1 203.0.113.1 198.18.0.1 256.1.1.1 01.2.3.4 '8.8.8.8 extra' '' ::1; do
    if is_public_ipv4 "$invalid"; then
        echo "Accepted invalid IP: $invalid" >&2
        exit 1
    fi
done
for valid in 8.8.8.8 1.1.1.1 172.32.0.1 100.128.0.1; do
    is_public_ipv4 "$valid"
done
mock_status=0 mock_ip=8.8.8.8
printf '192.168.1.1\n' > "$CURRENT_IP_CACHE_FILE"
[[ "$(get_current_ip)" == 8.8.8.8 ]]
[[ "$(cat "$CURRENT_IP_CACHE_FILE")" == 8.8.8.8 ]]
mock_status=7 mock_ip=''
[[ "$(get_current_ip)" == 8.8.8.8 ]]
mock_status=0 mock_ip=10.0.0.1
[[ "$(get_current_ip)" == 8.8.8.8 ]]
for stale in 192.168.1.1 garbage ''; do
    printf '%s\n' "$stale" > "$CURRENT_IP_CACHE_FILE"
    if get_current_ip > "$test_dir/output" 2>/dev/null; then exit 1; fi
    [[ ! -e "$CURRENT_IP_CACHE_FILE" && ! -s "$test_dir/output" ]]
done
mock_status=7 mock_ip=8.8.4.4
if get_current_ip > "$test_dir/output" 2>/dev/null; then exit 1; fi
[[ ! -s "$test_dir/output" ]]
echo 'PASS: validation, direct curl flags, cache refresh, offline fallback, stale cache removal'
