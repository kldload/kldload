#!/bin/bash
# smoke-server.sh — verify a kldloadOS SERVER profile install
# Tests everything in core PLUS: k* tools, webui, sanoid, snapshots, wireguard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm; clear
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
test_cmd "kldload-help" "kldload-help"
test_cmd "kldload-overview" "kldload-overview"
test_cmd "kube-demo" "kube-demo"

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
# Darksite is intentionally REMOVED on first boot by kldload-firstboot
# (lines 2052-2068 in /usr/sbin/kldload-firstboot) to reclaim ~1.8G —
# only the install phase needs it. ZFSBootMenu binary lives at
# /boot/efi/EFI/zbm/ (signed, MOK-verified), NOT inside the darksite
# tree (that was an old layout). So presence here is a regression.
_section "Darksite (post-firstboot cleanup)"
test_succeeds "darksite removed from /root (firstboot reclaim)" \
  "[[ ! -d /root/darksite ]]"
test_succeeds "darksite repo file removed" \
  "[[ ! -f /etc/yum.repos.d/kldload-darksite.repo ]]"
# LAN mirror opt-in: when /etc/kldload/keep-darksite exists, the admin
# kept darksite at install time as a network-accessible package mirror
# for other machines. In that case it SHOULD still be there and the
# service active.
if [[ -f /etc/kldload/keep-darksite ]]; then
  test_dir "LAN mirror mode: darksite kept" "/root/darksite"
  test_service_active "LAN mirror service" "kldload-apt-mirror"
  if [[ "$DISTRO" == "deb" ]]; then
    test_dir "APT darksite" "/root/darksite/debian/apt"
    test_file "APT Release file" "/root/darksite/debian/apt/dists/trixie/Release"
  fi
fi
# ZBM EFI lives at the canonical EFI System Partition path, not inside
# /root/darksite (old layout). Verify it's where the bootloader actually
# expects to find it.
test_file "ZFSBootMenu EFI on ESP" "/boot/efi/EFI/zbm/BOOTX64.EFI"

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

# ── Bob + RAG ────────────────────────────────────────────────────────────────
# Verifies the Bob CLI + the RAG service stack added in commit ec5bd90:
# previous builds shipped the RAG code but it never worked because deps
# weren't installed, units weren't enabled, and Bob didn't call it.
_section "Bob + RAG"

# CLI presence
test_file "Bob CLI"                 "/usr/local/bin/bob"
test_file "RAG service code"        "/usr/local/lib/kldload-rag/kldload_rag.py"
test_file "RAG indexer code"        "/usr/local/lib/kldload-rag/kldload_rag_index.py"
test_file "RAG indexer CLI"         "/usr/local/bin/kldload-rag-index"
test_file "kai-rag CLI"             "/usr/local/bin/kai-rag"

# Bob CLI was actually patched (not the 3-line stub from older builds)
if [[ -f /usr/local/bin/bob ]] && grep -q 'BOB_RAG\b' /usr/local/bin/bob 2>/dev/null; then
  _pass "Bob CLI has RAG bridge"
else
  _fail "Bob CLI has RAG bridge" "no BOB_RAG reference -- stub installed instead of full bob"
fi

# Systemd unit files installed
test_file "RAG service unit"        "/usr/lib/systemd/system/kldload-rag.service"
test_file "RAG firstboot unit"      "/usr/lib/systemd/system/kldload-rag-firstboot.service"
test_file "RAG index timer"         "/usr/lib/systemd/system/kldload-rag-index.timer"
test_file "RAG index service"       "/usr/lib/systemd/system/kldload-rag-index.service"

# Symlinks created by profiles.sh (units enabled to start at boot)
test_file "RAG service enabled (symlink)"     \
  "/etc/systemd/system/multi-user.target.wants/kldload-rag.service"
test_file "RAG firstboot enabled (symlink)"   \
  "/etc/systemd/system/multi-user.target.wants/kldload-rag-firstboot.service"
test_file "RAG index timer enabled (symlink)" \
  "/etc/systemd/system/timers.target.wants/kldload-rag-index.timer"

# ChromaDB data dir
test_dir "RAG ChromaDB data dir" "/var/lib/kldload-rag"

# Python imports succeed (the actual reason RAG used to never start)
if python3 -c "import chromadb, bs4" 2>/dev/null; then
  _pass "Python deps importable (chromadb, bs4)"
else
  _fail "Python deps importable" "chromadb or beautifulsoup4 missing -- RAG service can't start"
fi

# RAG service is actually running and responding
if curl -sf --max-time 3 http://localhost:8400/health >/dev/null 2>&1; then
  _pass "RAG service responds on :8400"
  # And ChromaDB has some chunks indexed (first-boot indexer ran successfully)
  chunks=$(curl -sf --max-time 3 http://localhost:8400/health | grep -oE '"chunks":\s*[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [[ -n "$chunks" && "$chunks" -gt 0 ]]; then
    _pass "RAG corpus indexed ($chunks chunks)"
  else
    _warn "RAG corpus indexed" "0 chunks -- first-boot indexer may still be running"
  fi
else
  _fail "RAG service responds on :8400" "no response from /health -- service down"
fi

# Ollama (RAG and Bob both depend on this)
if command -v ollama >/dev/null 2>&1; then
  _pass "Ollama CLI"
  if curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    _pass "Ollama API responds"
  else
    _warn "Ollama API responds" "ollama service may not be running yet"
  fi
else
  _warn "Ollama CLI" "not installed -- Bob/RAG will not work"
fi

# Indexer is callable
if [[ -x /usr/local/bin/kldload-rag-index ]]; then
  _pass "kldload-rag-index is executable"
else
  _fail "kldload-rag-index is executable" "not executable -- nightly re-index will fail"
fi

# ── System Files ─────────────────────────────────────────────────────────────
_section "System Files"

test_file "Edition marker" "/etc/kldload/edition"
test_file "Profile marker" "/etc/kldload/profile"
test_file "Build ID" "/etc/kldload-build-id"
test_file "Build SHA" "/etc/kldload-build-sha"
test_file "Boot environment marker" "/etc/kldload/boot-environment"

# ── Summary ──────────────────────────────────────────────────────────────────
summary
