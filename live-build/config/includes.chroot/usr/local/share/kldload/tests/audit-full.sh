#!/usr/bin/env bash
# audit-full.sh — comprehensive post-install audit
# Usage: audit-full.sh <ip> <password>
set -uo pipefail

IP="${1:?Usage: audit-full.sh <ip> <password>}"
PW="${2:-Passw0rd}"
SSH="sshpass -p ${PW} ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no admin@${IP}"

pass=0; fail=0; skip=0
ok()   { printf '\e[32m  ✓ %-35s %s\e[0m\n' "$1" "$2"; ((pass++)); }
bad()  { printf '\e[31m  ✗ %-35s %s\e[0m\n' "$1" "$2"; ((fail++)); }
skp()  { printf '\e[33m  ○ %-35s %s\e[0m\n' "$1" "$2"; ((skip++)); }

check() {
  local name="$1" cmd="$2"
  local out rc
  out="$(set +e; $SSH "$cmd" 2>&1; echo "RC:$?")"
  rc="${out##*RC:}"; out="${out%RC:*}"
  out="$(echo "$out" | sed '/^$/d' | head -1)"
  if [[ "$rc" -eq 0 && -n "$out" ]]; then
    ok "$name" "$out"
  elif [[ "$rc" -eq 0 ]]; then
    ok "$name" "(empty output)"
  else
    bad "$name" "${out:-(no output)}"
  fi
}

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  kldloadOS Full Audit — ${IP}"
echo "══════════════════════════════════════════════════════════════"
echo ""

echo "── OS ──────────────────────────────────────────────────────"
check "OS release"          "sed -n '1p' /etc/os-release"
check "Kernel"              "uname -r"
check "Hostname"            "hostname 2>/dev/null || hostnamectl hostname 2>/dev/null || cat /etc/hostname"

echo ""
echo "── ZFS ─────────────────────────────────────────────────────"
check "ZFS module loaded"   "lsmod | grep -q zfs && echo loaded"
check "ZFS version"         "zfs version | head -1"
check "Pool health"         "zpool status -x"
check "Pool list"           "zpool list -H -o name,health | head -1"
check "Dataset hierarchy"   "zfs list -H | wc -l | xargs printf '%s datasets'"
check "Compression"         "zfs get -H -o value compression rpool | head -1"
check "Snapshots"           "zfs list -t snapshot -H 2>/dev/null | wc -l | xargs printf '%s snapshots'"

echo ""
echo "── kldload Tools ───────────────────────────────────────────"
check "kst"                 "kst 2>/dev/null | head -1"
check "kst-dashboard"       "command -v kst-dashboard && echo found"
check "ksnap"               "ksnap list 2>/dev/null | head -1 || ksnap 2>&1 | head -1"
check "kclone"              "command -v kclone && echo found"
check "kdf"                 "kdf 2>/dev/null | head -1"
check "kdir"                "kdir --help 2>&1 | head -1 || command -v kdir"
check "kpkg"                "kpkg help 2>&1 | head -1 || command -v kpkg"
check "kexport"             "kexport 2>&1 | head -1 || command -v kexport"
check "kldload-help"        "kldload-help 2>/dev/null | grep -c 'kldloadOS' | xargs printf '%s lines matched'"
check "kbe"                 "command -v kbe && echo found"
check "krecovery"           "command -v krecovery && echo found"
check "kupgrade"            "command -v kupgrade && echo found"

echo ""
echo "── Modern CLI ──────────────────────────────────────────────"
check "fzf"                 "fzf --version 2>&1 | head -1"
check "btop"                "command -v btop && btop --version 2>&1 | head -1 || echo missing"
check "eza"                 "eza --version 2>&1 | head -1"
check "ripgrep (rg)"        "rg --version 2>&1 | head -1"
check "fd"                  "fd --version 2>&1 | head -1 || fdfind --version 2>&1 | head -1 || echo missing"
check "zoxide"              "zoxide --version 2>&1 | head -1"
check "fastfetch"           "fastfetch --version 2>&1 | head -1"
check "bat"                 "bat --version 2>&1 | head -1 || batcat --version 2>&1 | head -1 || echo 'not in EPEL'"
check "tmux"                "tmux -V 2>&1"

echo ""
echo "── Services ────────────────────────────────────────────────"
check "sshd"                "systemctl is-active sshd"
check "zfs-zed"             "systemctl is-active zfs-zed"
check "sanoid.timer"        "systemctl is-active sanoid.timer"
check "NetworkManager"      "systemctl is-active NetworkManager"

echo ""
echo "── Sanoid ──────────────────────────────────────────────────"
check "sanoid binary"       "sanoid --version 2>&1 | head -1"
check "syncoid binary"      "command -v syncoid && echo found"
check "sanoid config"       "test -f /etc/sanoid/sanoid.conf && echo exists"
check "sanoid timer unit"   "test -f /lib/systemd/system/sanoid.timer && echo exists || test -f /usr/lib/systemd/system/sanoid.timer && echo exists"

echo ""
echo "── Networking ──────────────────────────────────────────────"
check "WireGuard"           "wg --version 2>&1 | head -1 || echo missing"
check "nftables"            "command -v nft && echo found"
check "IP address"          "ip -4 addr show scope global | grep inet | head -1 | awk '{print \$2}'"

echo ""
echo "── eBPF ────────────────────────────────────────────────────"
check "bpftool"             "command -v bpftool && echo found || echo 'not installed (optional)'"
check "bpftrace"            "command -v bpftrace && echo found || echo 'not installed (optional)'"
check "execsnoop"           "command -v execsnoop && echo found || command -v execsnoop-bpfcc && echo found || echo 'not installed (optional)'"

echo ""
echo "── Cloud / Export ──────────────────────────────────────────"
check "cloud-init"          "cloud-init --version 2>&1 | head -1 || echo missing"
check "qemu-img"            "qemu-img --version 2>&1 | head -1 || echo missing"

echo ""
echo "── Desktop ─────────────────────────────────────────────────"
check ".desktop files"      "ls /usr/share/applications/k*.desktop 2>/dev/null | wc -l | xargs printf '%s entries'"
check "tmux config"         "grep -c 'prefix' ~/.tmux.conf 2>/dev/null | xargs printf '%s prefix lines'"
check ".bashrc fzf"         "grep -c fzf ~/.bashrc 2>/dev/null | xargs printf '%s fzf refs'"
check ".bashrc eza"         "grep -c eza ~/.bashrc 2>/dev/null | xargs printf '%s eza refs'"
check ".bashrc fastfetch"   "grep -c fastfetch ~/.bashrc 2>/dev/null | xargs printf '%s fastfetch refs'"
check "vim colorscheme"     "test -f ~/.vim/colors/kldload.vim && echo exists || echo missing"

echo ""
echo "══════════════════════════════════════════════════════════════"
printf "  Results: \e[32m%d passed\e[0m  \e[31m%d failed\e[0m  \e[33m%d skipped\e[0m\n" "$pass" "$fail" "$skip"
echo "══════════════════════════════════════════════════════════════"
echo ""
