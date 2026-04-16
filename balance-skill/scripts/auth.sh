#!/bin/bash

# Awell Balance 多身份认证管理脚本
# 用法：
#   ./auth.sh login <account-id> <email> <password>
#   ./auth.sh relogin [account-id]
#   ./auth.sh switch <account-id>
#   ./auth.sh current [--json]
#   ./auth.sh list [--json]
#   ./auth.sh cookie-path [account-id]
#   ./auth.sh session [account-id]
#   ./auth.sh logout <account-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CRED_DIR="$SKILL_DIR/.credentials"
CURRENT_ACCOUNT_FILE="$CRED_DIR/current_account.txt"
BASE_URL="https://balance.awell.one"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

success() {
    echo -e "${GREEN}OK${NC} $1"
}

warn() {
    echo -e "${YELLOW}WARN${NC} $1"
}

error() {
    echo -e "${RED}ERR${NC} $1" >&2
    exit 1
}

ensure_cred_dir() {
    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"
}

validate_account_id() {
    local account_id="$1"

    if [[ -z "$account_id" ]]; then
        error "account-id 不能为空"
    fi

    if [[ "$account_id" == *"/"* ]] || [[ "$account_id" == "." ]] || [[ "$account_id" == ".." ]]; then
        error "account-id 不能包含斜杠，且不能是 . 或 .."
    fi
}

account_dir() {
    echo "$CRED_DIR/$1"
}

credentials_file() {
    echo "$(account_dir "$1")/credentials.json"
}

profile_file() {
    echo "$(account_dir "$1")/profile.json"
}

cookie_file() {
    echo "$(account_dir "$1")/cookies.txt"
}

read_current_account() {
    if [[ -f "$CURRENT_ACCOUNT_FILE" ]]; then
        cat "$CURRENT_ACCOUNT_FILE"
    fi
}

resolve_account() {
    local account_id="${1:-}"

    if [[ -n "$account_id" ]]; then
        validate_account_id "$account_id"
        echo "$account_id"
        return
    fi

    account_id="$(read_current_account)"
    if [[ -z "$account_id" ]]; then
        error "当前没有激活身份，请先运行: $0 login <account-id> <email> <password> 或 $0 switch <account-id>"
    fi

    echo "$account_id"
}

write_json_file() {
    local path="$1"
    local content="$2"

    umask 077
    printf '%s\n' "$content" > "$path"
    chmod 600 "$path"
}

save_profile() {
    local account_id="$1"
    local email="$2"
    local login_time="$3"

    write_json_file "$(profile_file "$account_id")" \
        "{\"account_id\":\"$account_id\",\"email\":\"$email\",\"login_time\":\"$login_time\"}"
}

save_credentials() {
    local account_id="$1"
    local email="$2"
    local password="$3"

    write_json_file "$(credentials_file "$account_id")" \
        "{\"email\":\"$email\",\"password\":\"$password\"}"
}

set_current_account() {
    local account_id="$1"
    printf '%s\n' "$account_id" > "$CURRENT_ACCOUNT_FILE"
    chmod 600 "$CURRENT_ACCOUNT_FILE"
}

extract_json_value() {
    local path="$1"
    local key="$2"
    sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p" "$path" | head -n1
}

perform_login() {
    local account_id="$1"
    local email="$2"
    local password="$3"

    validate_account_id "$account_id"
    ensure_cred_dir

    local user_dir
    user_dir="$(account_dir "$account_id")"
    mkdir -p "$user_dir"
    chmod 700 "$user_dir"

    local temp_cookies="$user_dir/cookies_temp.txt"
    local temp_headers="$user_dir/headers_temp.txt"
    local final_cookies
    final_cookies="$(cookie_file "$account_id")"
    local final_headers="$user_dir/headers_final.txt"
    local session_body="$user_dir/session_check.json"
    local session_code

    echo "正在登录身份 $account_id ($email)..."

    curl -sS -D "$temp_headers" -c "$temp_cookies" -X POST "$BASE_URL/api/auth/sign-in/email" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" > /dev/null

    if [[ ! -s "$temp_cookies" ]]; then
        rm -f "$temp_cookies" "$temp_headers"
        error "登录失败：未收到临时 cookie"
    fi

    curl -sS -D "$final_headers" -b "$temp_cookies" -c "$final_cookies" \
        "$BASE_URL/auth/callback?locale=zh&returnTo=%2Fdashboard" > /dev/null

    if ! grep -q "balance_session" "$final_cookies"; then
        rm -f "$temp_cookies" "$temp_headers"
        error "登录失败：未获取到 balance_session cookie"
    fi

    session_code=$(curl -sS -o "$session_body" -w "%{http_code}" -b "$final_cookies" \
        "$BASE_URL/api/auth/get-session")
    if [[ "$session_code" != "200" ]] || grep -q '"session":null' "$session_body"; then
        rm -f "$temp_cookies" "$temp_headers"
        error "登录失败：会话校验未通过"
    fi

    save_credentials "$account_id" "$email" "$password"
    save_profile "$account_id" "$email" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set_current_account "$account_id"

    rm -f "$temp_cookies" "$temp_headers"
    success "登录成功，当前身份已设置为: $account_id"
}

login() {
    local account_id="${1:-}"
    local email="${2:-}"
    local password="${3:-}"

    if [[ -z "$account_id" || -z "$email" || -z "$password" ]]; then
        error "用法: $0 login <account-id> <email> <password>"
    fi

    perform_login "$account_id" "$email" "$password"
}

relogin() {
    local account_id
    account_id="$(resolve_account "${1:-}")"
    local creds_path
    creds_path="$(credentials_file "$account_id")"

    if [[ ! -f "$creds_path" ]]; then
        error "身份 $account_id 没有保存登录凭证，请重新执行 login"
    fi

    local email password
    email="$(extract_json_value "$creds_path" "email")"
    password="$(extract_json_value "$creds_path" "password")"

    if [[ -z "$email" || -z "$password" ]]; then
        error "身份 $account_id 的登录凭证不完整，请重新执行 login"
    fi

    perform_login "$account_id" "$email" "$password"
}

switch_user() {
    local account_id="${1:-}"

    if [[ -z "$account_id" ]]; then
        error "用法: $0 switch <account-id>"
    fi

    validate_account_id "$account_id"

    if [[ ! -d "$(account_dir "$account_id")" ]]; then
        error "身份 $account_id 不存在，请先执行 login"
    fi

    if [[ ! -f "$(cookie_file "$account_id")" ]]; then
        error "身份 $account_id 没有 cookie，请先执行 login 或 relogin"
    fi

    set_current_account "$account_id"
    success "已切换到身份: $account_id"
}

show_current() {
    local as_json="${1:-}"
    local account_id
    account_id="$(read_current_account)"

    if [[ -z "$account_id" ]]; then
        if [[ "$as_json" == "--json" ]]; then
            echo '{"current_account":null}'
            return
        fi
        warn "当前没有激活身份"
        echo "请运行: $0 login <account-id> <email> <password>"
        return
    fi

    local path
    path="$(profile_file "$account_id")"
    local email=""
    local login_time=""

    if [[ -f "$path" ]]; then
        email="$(extract_json_value "$path" "email")"
        login_time="$(extract_json_value "$path" "login_time")"
    fi

    if [[ "$as_json" == "--json" ]]; then
        printf '{"current_account":"%s","email":"%s","login_time":"%s","cookie_path":"%s"}\n' \
            "$account_id" "$email" "$login_time" "$(cookie_file "$account_id")"
        return
    fi

    echo -e "${GREEN}ACTIVE${NC} $account_id"
    [[ -n "$email" ]] && echo "email: $email"
    [[ -n "$login_time" ]] && echo "login_time: $login_time"
    echo "cookie_path: $(cookie_file "$account_id")"
}

list_users() {
    local as_json="${1:-}"
    ensure_cred_dir

    local current_account=""
    current_account="$(read_current_account)"

    if [[ ! -d "$CRED_DIR" ]] || [[ -z "$(find "$CRED_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]]; then
        if [[ "$as_json" == "--json" ]]; then
            echo '{"accounts":[]}'
            return
        fi
        warn "没有已保存的身份"
        return
    fi

    if [[ "$as_json" == "--json" ]]; then
        local first=1
        printf '{"accounts":['
        for user_dir in "$CRED_DIR"/*; do
            [[ -d "$user_dir" ]] || continue
            local account_id email login_time active
            account_id="$(basename "$user_dir")"
            email="$(extract_json_value "$user_dir/profile.json" "email")"
            login_time="$(extract_json_value "$user_dir/profile.json" "login_time")"
            if [[ "$account_id" == "$current_account" ]]; then
                active="true"
            else
                active="false"
            fi

            if [[ $first -eq 0 ]]; then
                printf ','
            fi
            first=0
            printf '{"account_id":"%s","email":"%s","login_time":"%s","active":%s,"cookie_path":"%s"}' \
                "$account_id" "$email" "$login_time" "$active" "$(cookie_file "$account_id")"
        done
        printf ']}\n'
        return
    fi

    echo "已保存的身份："
    for user_dir in "$CRED_DIR"/*; do
        [[ -d "$user_dir" ]] || continue
        local account_id email login_time prefix
        account_id="$(basename "$user_dir")"
        email="$(extract_json_value "$user_dir/profile.json" "email")"
        login_time="$(extract_json_value "$user_dir/profile.json" "login_time")"
        prefix="-"
        if [[ "$account_id" == "$current_account" ]]; then
            prefix="*"
        fi
        echo "$prefix $account_id (${email:-unknown}) ${login_time:+login_time=$login_time}"
    done
}

show_cookie_path() {
    local account_id
    account_id="$(resolve_account "${1:-}")"
    local path
    path="$(cookie_file "$account_id")"

    if [[ ! -f "$path" ]]; then
        error "身份 $account_id 没有 cookie，请先执行 login 或 relogin"
    fi

    echo "$path"
}

show_session() {
    local account_id
    account_id="$(resolve_account "${1:-}")"
    local path
    path="$(cookie_file "$account_id")"

    if [[ ! -f "$path" ]]; then
        error "身份 $account_id 没有 cookie，请先执行 login 或 relogin"
    fi

    curl -sS -b "$path" "$BASE_URL/api/auth/get-session"
}

logout_user() {
    local account_id="${1:-}"

    if [[ -z "$account_id" ]]; then
        error "用法: $0 logout <account-id>"
    fi

    validate_account_id "$account_id"

    if [[ ! -d "$(account_dir "$account_id")" ]]; then
        error "身份 $account_id 不存在"
    fi

    if [[ "$(read_current_account)" == "$account_id" ]]; then
        rm -f "$CURRENT_ACCOUNT_FILE"
        warn "已清除当前激活身份"
    fi

    rm -rf "$(account_dir "$account_id")"
    success "已删除身份 $account_id 的本地凭证"
}

usage() {
    cat <<EOF
Awell Balance 多身份认证管理

用法:
  $0 login <account-id> <email> <password>
  $0 relogin [account-id]
  $0 switch <account-id>
  $0 current [--json]
  $0 list [--json]
  $0 cookie-path [account-id]
  $0 session [account-id]
  $0 logout <account-id>
EOF
}

main() {
    local command="${1:-}"

    case "$command" in
        login)
            login "${2:-}" "${3:-}" "${4:-}"
            ;;
        relogin)
            relogin "${2:-}"
            ;;
        switch)
            switch_user "${2:-}"
            ;;
        current)
            show_current "${2:-}"
            ;;
        list)
            list_users "${2:-}"
            ;;
        cookie-path)
            show_cookie_path "${2:-}"
            ;;
        session)
            show_session "${2:-}"
            ;;
        logout)
            logout_user "${2:-}"
            ;;
        *)
            usage
            [[ -n "$command" ]] && exit 1
            ;;
    esac
}

main "$@"
