#!/bin/bash
# smoke-server.sh — verify a kldloadOS SERVER profile install
# Tests everything in core PLUS: k* tools, webui, sanoid, snapshots, wireguard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — SERVER profile                   ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
echo ""

# ── Run core tests first ─────────────────────────────────────────────────────
# (inline the critical ones, don't recurse to avoid double summary)

_section "ZFS (base)"
test_output_contains "Pool rpool ONLINE" "zpool list -H -o health rpool" "ONLINE"
test_output_contains "Zero errors" "zpool status rpool" "No known data errors"
test_output_contains "bootfs set" "zpool get -H -o value bootfs rpool" "rpool/ROOT/"
test_succeeds "EFI mounted" "mountpoint -q /boot/efi"
test_file "Hostid" "/etc/hostid"

_section "SSH & Network"
test_service_active "sshd" "sshd"
test_succeeds "Has IP" "ip -4 addr show | grep -q 'inet '"
test_succeeds "DNS works" "getent hosts github.com"

# ── k* Tools ─────────────────────────────────────────────────────────────────
_section "kldloadOS Tools"

test_cmd "kst (status)" "kst"
test_cmd "ksnap (snapshots)" "ksnap"
test_cmd "kbe (boot environments)" "kbe"
test_cmd "kclone (CoW cloning)" "kclone"
test_cmd "kdf (disk usage)" "kdf"
test_cmd "kdir (dataset creation)" "kdir"
test_cmd "kpkg (package manager)" "kpkg"
test_cmd "kupgrade (safe upgrade)" "kupgrade"
test_cmd "kexport (image export)" "kexport"
test_cmd "krecovery (disaster recovery)" "krecovery"

# Test kst runs without error
test_succeeds "kst executes" "kst >/dev/null 2>&1"

# Test ksnap list works
test_succeeds "ksnap list runs" "ksnap list >/dev/null 2>&1"

# Test kdf runs
test_succeeds "kdf executes" "kdf >/dev/null 2>&1"

# Test kpkg detects package manager
test_succeeds "kpkg detects pkg manager" "kpkg help >/dev/null 2>&1"

# ── Web UI ───────────────────────────────────────────────────────────────────
_section "Web UI"

test_file "kldload-webui binary" "/usr/local/bin/kldload-webui"
test_service_enabled "kldload-webui enabled" "kldload-webui"

# Check if webui responds (may be inactive on server profile but should be enabled)
if systemctl is-active kldload-webui >/dev/null 2>&1; then
  _pass "kldload-webui running"
  test_succeeds "WebUI responds on :8080" "curl -sf http://localhost:8080 >/dev/null 2>&1"
else
  _warn "kldload-webui running" "service not active (may need manual start)"
fi

# ── Sanoid / Automatic Snapshots ─────────────────────────────────────────────
_section "Automatic Snapshots"

test_cmd "sanoid installed" "sanoid"
test_file "sanoid config" "/etc/sanoid/sanoid.conf"
test_service_enabled "sanoid.timer enabled" "sanoid.timer"

if systemctl is-active sanoid.timer >/dev/null 2>&1; then
  _pass "sanoid.timer running"
else
  _warn "sanoid.timer running" "timer not active"
fi

# ── WireGuard ────────────────────────────────────────────────────────────────
_section "WireGuard"

test_cmd "wg command" "wg"
test_cmd "wg-quick command" "wg-quick"
test_output_contains "WireGuard module available" "modprobe wireguard && lsmod" "wireguard"

# ── Package Snapshot Integration ─────────────────────────────────────────────
_section "Package Snapshot Integration"

SNAP_BEFORE=$(zfs list -t snapshot -H 2>/dev/null | wc -l)

if [[ "$DISTRO" == "deb" ]]; then
  # Install a tiny package to trigger snapshot
  test_succeeds "kpkg install succeeds" "kpkg install -y file >/dev/null 2>&1"
else
  test_succeeds "kpkg install succeeds" "kpkg install -y file >/dev/null 2>&1"
fi

sleep 1
SNAP_AFTER=$(zfs list -t snapshot -H 2>/dev/null | wc -l)

if [[ $SNAP_AFTER -gt $SNAP_BEFORE ]]; then
  _pass "kpkg created snapshot before install ($SNAP_BEFORE → $SNAP_AFTER)"
else
  _fail "kpkg snapshot on install" "no new snapshot after kpkg install ($SNAP_BEFORE → $SNAP_AFTER)"
fi

# Check if a kpkg snapshot exists
if zfs list -t snapshot -H -o name 2>/dev/null | grep -q "kpkg-"; then
  _pass "kpkg snapshot naming (kpkg-*)"
else
  _warn "kpkg snapshot naming" "no kpkg-* snapshot found"
fi

# ── Boot Environment Test ────────────────────────────────────────────────────
_section "Boot Environment"

BE_NAME="smoketest-be-$(date +%Y%m%d-%H%M%S)"
if kbe create "$BE_NAME" >/dev/null 2>&1; then
  _pass "kbe create works ($BE_NAME)"
else
  _fail "kbe create" "failed to create boot environment"
fi

if kbe list 2>/dev/null | grep -q "$BE_NAME"; then
  _pass "kbe list shows new BE"
else
  _warn "kbe list" "new BE not visible in kbe list"
fi

# Clean up
kbe delete "$BE_NAME" >/dev/null 2>&1 || true

# ── Darksite ─────────────────────────────────────────────────────────────────
_section "Darksite"

test_dir "Darksite directory" "/root/darksite"

if [[ "$DISTRO" == "deb" ]]; then
  test_dir "APT darksite" "/root/darksite/debian/apt"
  test_file "APT Release file" "/root/darksite/debian/apt/dists/trixie/Release"
fi

test_dir "ZFSBootMenu in darksite" "/root/darksite/boot"
test_file "ZFSBootMenu EFI" "/root/darksite/boot/zfsbootmenu.EFI"

# ── eBPF / Observability ──────────────────────────────────────────────────────
_section "eBPF / Observability"

if [[ "$DISTRO" == "deb" ]]; then
  test_cmd "bpftrace" "bpftrace"
  test_cmd "bpftool" "bpftool"
  if [[ -f /usr/sbin/execsnoop-bpfcc ]] || command -v execsnoop-bpfcc >/dev/null 2>&1; then
    _pass "execsnoop (bpfcc-tools)"
  elif command -v execsnoop >/dev/null 2>&1; then
    _pass "execsnoop"
  else
    _warn "execsnoop" "not found — install bpfcc-tools"
  fi
  test_cmd "perf" "perf"
else
  if [[ -d /usr/share/bcc/tools ]]; then
    _pass "bcc-tools directory"
    test_file "execsnoop (bcc)" "/usr/share/bcc/tools/execsnoop"
    test_file "tcplife (bcc)" "/usr/share/bcc/tools/tcplife"
    test_file "opensnoop (bcc)" "/usr/share/bcc/tools/opensnoop"
  else
    _warn "bcc-tools" "not found — install bcc-tools"
  fi
  test_cmd "bpftrace" "bpftrace"
fi

if [[ -f /sys/kernel/btf/vmlinux ]]; then
  _pass "BTF available (eBPF CO-RE)"
else
  _warn "BTF" "/sys/kernel/btf/vmlinux not found"
fi

if command -v bpftrace >/dev/null 2>&1; then
  if timeout 3 bpftrace -e 'BEGIN { printf("ok\n"); exit(); }' 2>/dev/null | grep -q "ok"; then
    _pass "bpftrace executes"
  else
    _warn "bpftrace execution" "failed — may need root or BTF"
  fi
fi

# ── NVIDIA (optional) ────────────────────────────────────────────────────────
_section "NVIDIA (optional)"

if command -v nvidia-smi >/dev/null 2>&1; then
  _pass "nvidia-smi found"
  if nvidia-smi >/dev/null 2>&1; then
    _pass "nvidia-smi executes (GPU detected)"
  else
    _warn "nvidia-smi" "no GPU detected (expected in VM)"
  fi
else
  _pass "NVIDIA not installed (expected if checkbox not selected)"
fi

# ── System Files ─────────────────────────────────────────────────────────────
_section "System Files"

test_file "Edition marker" "/etc/kldload/edition"
test_file "Build SHA" "/etc/kldload-build-sha"
test_file "Boot environment marker" "/etc/kldload/boot-environment"

# ── Summary ──────────────────────────────────────────────────────────────────
summary
