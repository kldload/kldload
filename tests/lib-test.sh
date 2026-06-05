#!/bin/bash
# lib-test.sh — shared test functions for kldloadOS smoke tests

# Ensure /usr/local/bin and /usr/local/sbin are in PATH
# (CentOS/RHEL sudo strips them from secure_path)
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

PASS=0
FAIL=0
WARN=0
TESTS=()

_pass() {
    PASS=$((PASS + 1))
    TESTS+=("PASS|$1")
    printf "\e[1;32m  ✓ PASS\e[0m  %s\n" "$1"
}
_fail() {
    FAIL=$((FAIL + 1))
    TESTS+=("FAIL|$1|$2")
    printf "\e[1;31m  ✗ FAIL\e[0m  %s — %s\n" "$1" "$2"
}
_warn() {
    WARN=$((WARN + 1))
    TESTS+=("WARN|$1|$2")
    printf "\e[1;33m  ⚠ WARN\e[0m  %s — %s\n" "$1" "$2"
}
_section() { printf "\n\e[1;36m  ── %s ──────────────────────────────────────────\e[0m\n" "$1"; }

# Test: command exists
test_cmd() {
    local name="$1" cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        _pass "$name"
    else _fail "$name" "$cmd not found"; fi
}

# Test: file exists
test_file() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        _pass "$name"
    else _fail "$name" "$path not found"; fi
}

# Test: directory exists
test_dir() {
    local name="$1" path="$2"
    if [[ -d "$path" ]]; then
        _pass "$name"
    else _fail "$name" "$path not found"; fi
}

# Test: systemd service is active
test_service_active() {
    local name="$1" svc="$2"
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        _pass "$name"
    else _fail "$name" "$svc is $state"; fi
}

# Test: systemd service is enabled
test_service_enabled() {
    local name="$1" svc="$2"
    local state
    state=$(systemctl is-enabled "$svc" 2>/dev/null)
    if [[ "$state" == "enabled" ]]; then
        _pass "$name"
    else _warn "$name" "$svc is $state"; fi
}

# Test: ZFS dataset exists
test_dataset() {
    local name="$1" ds="$2"
    if zfs list "$ds" >/dev/null 2>&1; then
        _pass "$name"
    else _fail "$name" "dataset $ds not found"; fi
}

# Test: command output contains string
test_output_contains() {
    local name="$1" cmd="$2" expected="$3"
    local output
    output=$(eval "$cmd" 2>&1)
    if echo "$output" | grep -qi "$expected"; then
        _pass "$name"
    else _fail "$name" "expected '$expected' in output of: $cmd"; fi
}

# Test: command succeeds (exit 0)
test_succeeds() {
    local name="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        _pass "$name"
    else _fail "$name" "command failed: $cmd"; fi
}

# Detect distro family
detect_distro() {
    if command -v dnf >/dev/null 2>&1; then
        echo "rpm"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "deb"
    else echo "unknown"; fi
}

# Print summary
summary() {
    local total=$((PASS + FAIL + WARN))
    printf "\n\e[1;36m  ══════════════════════════════════════════════════\e[0m\n"
    printf "  \e[1mResults:\e[0m  %d passed  " "$PASS"
    [[ $FAIL -gt 0 ]] && printf "\e[1;31m%d failed\e[0m  " "$FAIL"
    [[ $WARN -gt 0 ]] && printf "\e[1;33m%d warnings\e[0m  " "$WARN"
    printf "(%d total)\n" "$total"
    printf "\e[1;36m  ══════════════════════════════════════════════════\e[0m\n\n"

    if [[ $FAIL -gt 0 ]]; then
        printf "\e[1;31m  Failed tests:\e[0m\n"
        for t in "${TESTS[@]}"; do
            IFS='|' read -r status name reason <<<"$t"
            [[ "$status" == "FAIL" ]] && printf "    ✗ %s — %s\n" "$name" "$reason"
        done
        echo ""
    fi

    [[ $FAIL -eq 0 ]]
}
