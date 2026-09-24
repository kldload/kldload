#!/bin/bash
# lib-test.sh — shared test functions for kldloadOS smoke tests

# Ensure /usr/local/bin and /usr/local/sbin are in PATH
# (CentOS/RHEL sudo strips them from secure_path)

# This file is SOURCED, and it takes the caller's shell options: it sets none
# of its own. The `set -Eeuo pipefail` that used to sit here re-enabled errexit
# for every suite that had just turned it off -- smoke-features.sh and
# smoke-javaapi-rollback.sh both do `set +e +E` on purpose two lines before
# sourcing this -- so they ran under -e regardless and died on the first probe
# that answered "no", with partial passes and no failures (confirmed
# 2026-09-23). The ERR trap is installed only where errexit is already on, so
# a suite that dies still says where, and a suite that runs failing probes on
# purpose is not spammed with a line per probe.
if [[ $- == *e* ]]; then
    trap 'echo "lib-test.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR
fi

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
# _fail <name> [reason] / _warn <name> [reason] — the reason is optional. Every
# suite runs under `set -u`, and a bare `$2` on a one-argument call killed the
# whole suite with "$2: unbound variable" instead of recording the failure
# (smoke-desktop.sh's launcher check, 2026-09-23; smoke-javaapi-rollback.sh had
# ten of them). The record is made before anything else can go wrong.
_fail() {
    FAIL=$((FAIL + 1))
    TESTS+=("FAIL|$1|${2:-}")
    printf "\e[1;31m  ✗ FAIL\e[0m  %s%s\n" "$1" "${2:+ — $2}"
}
_warn() {
    WARN=$((WARN + 1))
    TESTS+=("WARN|$1|${2:-}")
    printf "\e[1;33m  ⚠ WARN\e[0m  %s%s\n" "$1" "${2:+ — $2}"
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
    # swallow: `systemctl is-active` exits non-zero for a service that is
    # inactive, failed or not-found -- which is precisely the case this helper
    # exists to REPORT. Capturing it bare meant that under the callers' `set -e`
    # the assignment aborted the whole suite before reaching the _fail below, so
    # this function could only ever pass. tests/smoke-desktop.sh died mid-run at
    # "Display Manager" this way on 2026-08-25: no FAIL line, no summary, just a
    # truncated log and a non-zero exit nobody could attribute.
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    if [[ "$state" == "active" ]]; then
        _pass "$name"
    else _fail "$name" "$svc is $state"; fi
}

# Test: systemd service is enabled
test_service_enabled() {
    local name="$1" svc="$2"
    local state
    # swallow: same as test_service_active above -- a disabled or absent unit
    # exits non-zero, and that is the finding, not an error.
    state=$(systemctl is-enabled "$svc" 2>/dev/null || true)
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
    # swallow: the command under test is EXPECTED to fail sometimes; that is
    # what the assertion below decides. Aborting here would turn every failing
    # assertion into a silent death of the whole suite.
    output=$(eval "$cmd" 2>&1 || true)
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

# probe_bounded <seconds> <outfile> <cmd...> — run a probe that may never
# return, without waiting on it.
#
# `timeout` is not enough for this class of command: a wedged NVIDIA driver
# leaves nvidia-smi in uninterruptible sleep, where SIGKILL does nothing and
# timeout waits for ever for a child that will not die. fiend, Fedora AI,
# 2026-09-23: "NVRM: nvAssertFailed ... GPPut < WATCHDOG_GPFIFO_ENTRIES" at
# module load, then every nvidia-smi hung, and one line held the whole smoke
# run for thirty minutes. So the command runs in the background, is polled
# once a second, and is left behind if it never returns -- which is itself
# the finding. Output goes to <outfile>.
# Returns: the command's own status when it finished; 2 when it was still
#          running after <seconds> (disowned, and the caller reports it).
probe_bounded() {
    local secs="$1" out="$2" pid i
    shift 2
    "$@" >"$out" 2>&1 </dev/null &
    pid=$!
    for ((i = 0; i < secs; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        disown "$pid" 2>/dev/null || true # left behind on purpose; a D-state process cannot be reaped
        return 2
    fi
    wait "$pid"
}

# Detect distro family
detect_distro() {
    if command -v dnf >/dev/null 2>&1; then
        echo "rpm"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "deb"
    else echo "unknown"; fi
}

# check_kpkg_snapshot — install a tiny package through kpkg and pass only if a
# pre-install snapshot (dnf-pre-* / apt-pre-*) was CREATED during it. Not "the
# snapshot total grew": snapshot-create.sh keeps ten per prefix and prunes
# after each new one, so at the cap the total never moves. fiend's RHEL 10
# re-run (2026-09-19) failed "no new snapshot (58 -> 58)" while dnf-pre
# snapshots were being taken every run. Creation time comes from ZFS itself.
check_kpkg_snapshot() {
    local t0 new
    t0="$(date +%s)"
    if ! kpkg install -y file >/dev/null 2>&1; then
        _fail "kpkg install" "kpkg install -y file failed"
        return 0
    fi
    new="$(zfs list -Hp -t snapshot -o creation,name 2>/dev/null |
        awk -v t="$t0" '$1 >= t && $2 ~ /@(dnf|apt)-pre-/ {n = $2} END {print n}')"
    if [[ -n "$new" ]]; then
        _pass "kpkg snapshot on install (${new})"
    else
        _fail "kpkg snapshot on install" "no dnf-pre/apt-pre snapshot created since $(date -d "@$t0" +%T)"
    fi
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
