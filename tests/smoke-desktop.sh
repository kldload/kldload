#!/bin/bash
# smoke-desktop.sh — verify a kldloadOS DESKTOP profile install
# Tests everything in server PLUS: GNOME, GDM, Firefox, graphical target
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — DESKTOP profile                  ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
echo ""

# ── Run server tests (which include core) ────────────────────────────────────
_section "ZFS (base)"
test_output_contains "Pool rpool ONLINE" "zpool list -H -o health rpool" "ONLINE"
test_output_contains "Zero errors" "zpool status rpool" "No known data errors"
test_output_contains "bootfs set" "zpool get -H -o value bootfs rpool" "rpool/ROOT/"
test_succeeds "EFI mounted" "mountpoint -q /boot/efi"

_section "SSH & Network"
test_service_active "sshd" "sshd"
test_succeeds "Has IP" "ip -4 addr show | grep -q 'inet '"
test_succeeds "DNS works" "getent hosts github.com"

_section "kldloadOS Tools"
for tool in kst ksnap kbe kclone kdf kdir kpkg kupgrade kexport krecovery; do
  test_cmd "$tool" "$tool"
done
test_succeeds "kst executes" "kst >/dev/null 2>&1"

_section "Services"
test_service_enabled "kldload-webui" "kldload-webui"
test_cmd "sanoid" "sanoid"
test_service_enabled "sanoid.timer" "sanoid.timer"
test_cmd "wg (WireGuard)" "wg"

# ── GNOME Desktop ────────────────────────────────────────────────────────────
_section "GNOME Desktop"

test_cmd "gnome-shell" "gnome-shell"
test_cmd "gnome-session" "gnome-session"
test_cmd "gnome-terminal" "gnome-terminal"
test_cmd "nautilus (file manager)" "nautilus"

if [[ "$DISTRO" == "deb" ]]; then
  test_cmd "gnome-control-center" "gnome-control-center"
fi

# ── GDM ──────────────────────────────────────────────────────────────────────
_section "Display Manager"

if [[ "$DISTRO" == "deb" ]]; then
  test_service_active "gdm3" "gdm"
  test_service_enabled "gdm3" "gdm"
else
  test_service_active "gdm" "gdm"
  test_service_enabled "gdm" "gdm"
fi

test_output_contains "Graphical target" "systemctl get-default" "graphical"

# ── Firefox ──────────────────────────────────────────────────────────────────
_section "Firefox"

if [[ "$DISTRO" == "deb" ]]; then
  test_cmd "firefox-esr" "firefox-esr"
else
  test_cmd "firefox" "firefox"
fi

# ── Desktop Theme / Config ───────────────────────────────────────────────────
_section "Desktop Configuration"

test_file "dconf profile" "/etc/dconf/profile/user"
test_dir "dconf local.d" "/etc/dconf/db/local.d"

# Check for screensaver disabled
if [[ -f /etc/dconf/db/local.d/00-kldload-desktop ]]; then
  _pass "kldload desktop dconf settings"
  test_output_contains "Idle delay disabled" "cat /etc/dconf/db/local.d/00-kldload-desktop" "idle-delay"
else
  _warn "kldload desktop dconf" "00-kldload-desktop not found"
fi

# ── Wallpaper / Branding ────────────────────────────────────────────────────
_section "Branding"

test_file "OS release" "/etc/os-release"
test_output_contains "OS name is kldload" "cat /etc/os-release" "kldload"

if [[ -d /usr/share/backgrounds/kldload ]]; then
  _pass "kldload wallpaper installed"
else
  _warn "kldload wallpaper" "/usr/share/backgrounds/kldload not found"
fi

# ── Package Snapshot Test ────────────────────────────────────────────────────
_section "Package Snapshot Integration"

SNAP_BEFORE=$(zfs list -t snapshot -H 2>/dev/null | wc -l)
kpkg install -y file >/dev/null 2>&1 || true
sleep 1
SNAP_AFTER=$(zfs list -t snapshot -H 2>/dev/null | wc -l)

if [[ $SNAP_AFTER -gt $SNAP_BEFORE ]]; then
  _pass "kpkg snapshot on install ($SNAP_BEFORE → $SNAP_AFTER)"
else
  _fail "kpkg snapshot on install" "no new snapshot ($SNAP_BEFORE → $SNAP_AFTER)"
fi

# ── Darksite ─────────────────────────────────────────────────────────────────
_section "Darksite"

test_dir "Darksite present" "/root/darksite"
test_file "ZFSBootMenu EFI" "/root/darksite/boot/zfsbootmenu.EFI"

if [[ "$DISTRO" == "deb" ]]; then
  test_dir "APT darksite" "/root/darksite/debian/apt"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
summary
