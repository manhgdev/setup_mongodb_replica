#!/usr/bin/env bash
# Authenticate in mongosh before evaluating the caller's script. FD 3 keeps the
# password out of argv and leaves stdin available to the calling script.
mongo_eval() {
    local username=$1 password=$2 auth_db=$3
    shift 3
    local -a command=(mongosh)
    if [[ $1 == --timeout ]]; then
        command=(timeout "$2" mongosh)
        shift 2
    fi
    local -a options=()
    while (( $# )) && [[ $1 != --eval ]]; do
        options+=("$1")
        shift
    done
    [[ $# == 2 && $1 == --eval ]] || return 2
    local authenticate='{ const auth = db.getSiblingDB(process.env.MANAGER_AUTH_DB).auth(process.env.MANAGER_AUTH_USER, require("fs").readFileSync(3,"utf8").slice(0,-1)); if (auth !== 1 && auth?.ok !== 1) { throw new Error("MongoDB authentication failed"); } }'
    MANAGER_AUTH_USER="$username" MANAGER_AUTH_DB="$auth_db" "${command[@]}" "${options[@]}" --eval "$authenticate
$2" 3<<<"$password"
}
