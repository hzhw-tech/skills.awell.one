#!/bin/bash

# Balance Skill 本地脚本测试

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
AUTH_SCRIPT="$SCRIPT_DIR/auth.sh"
CRED_DIR="$SKILL_DIR/.credentials"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

success() {
    echo -e "${GREEN}OK${NC} $1"
}

info() {
    echo -e "${YELLOW}INFO${NC} $1"
}

error() {
    echo -e "${RED}ERR${NC} $1"
    exit 1
}

cleanup() {
    rm -rf "$CRED_DIR"
}

assert_file() {
    local path="$1"
    [[ -f "$path" ]] || error "缺少文件: $path"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || error "输出未包含: $needle"
}

prepare_account() {
    local account_id="$1"
    local email="$2"

    mkdir -p "$CRED_DIR/$account_id"
    cat > "$CRED_DIR/$account_id/profile.json" <<EOF
{"account_id":"$account_id","email":"$email","login_time":"2026-04-16T00:00:00Z"}
EOF
    cat > "$CRED_DIR/$account_id/credentials.json" <<EOF
{"email":"$email","password":"secret"}
EOF
    touch "$CRED_DIR/$account_id/cookies.txt"
}

test_help() {
    info "测试帮助输出"
    local output
    output="$("$AUTH_SCRIPT" || true)"
    assert_contains "$output" "login <account-id> <email> <password>"
    success "帮助输出正常"
}

test_empty_state() {
    info "测试空状态"
    local current_output list_output
    current_output="$("$AUTH_SCRIPT" current || true)"
    list_output="$("$AUTH_SCRIPT" list || true)"
    assert_contains "$current_output" "当前没有激活身份"
    assert_contains "$list_output" "没有已保存的身份"
    success "空状态正常"
}

test_switch_and_current() {
    info "测试身份切换与 current"
    prepare_account "personal" "personal@example.com"
    prepare_account "work" "work@example.com"

    "$AUTH_SCRIPT" switch personal >/dev/null

    assert_file "$CRED_DIR/current_account.txt"
    [[ "$(cat "$CRED_DIR/current_account.txt")" == "personal" ]] || error "当前身份写入失败"

    local current_json
    current_json="$("$AUTH_SCRIPT" current --json)"
    assert_contains "$current_json" '"current_account":"personal"'
    assert_contains "$current_json" '"cookie_path":"'
    success "current 与 switch 正常"
}

test_list_json() {
    info "测试 list --json"
    local output
    output="$("$AUTH_SCRIPT" list --json)"
    assert_contains "$output" '"account_id":"personal"'
    assert_contains "$output" '"account_id":"work"'
    assert_contains "$output" '"active":true'
    success "list --json 正常"
}

test_cookie_path() {
    info "测试 cookie-path"
    local cookie_path
    cookie_path="$("$AUTH_SCRIPT" cookie-path personal)"
    [[ "$cookie_path" == "$CRED_DIR/personal/cookies.txt" ]] || error "cookie-path 输出错误"
    success "cookie-path 正常"
}

test_logout() {
    info "测试 logout"
    "$AUTH_SCRIPT" logout personal >/dev/null
    [[ ! -d "$CRED_DIR/personal" ]] || error "logout 未删除身份目录"
    [[ ! -f "$CRED_DIR/current_account.txt" ]] || error "logout 未清空当前身份"
    success "logout 正常"
}

main() {
    cleanup

    test_help
    test_empty_state
    test_switch_and_current
    test_list_json
    test_cookie_path
    test_logout

    cleanup
    success "所有本地测试通过"
}

main
