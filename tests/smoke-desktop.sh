#!/bin/bash
# smoke-desktop.sh — verify a kldloadOS DESKTOP profile install
# Tests everything in server PLUS: GNOME, GDM, Firefox, graphical target
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm
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

# ── ZFS Console (zxplore) ─────────────────────────────────────────────────────
# Desktop ships BOTH zxplore variants: the Fyne GUI (with launcher/icon) and
# the static TUI. Baked at ISO build from github.com/zxplore/zxplore.
_section "ZFS Console"
test_cmd "zxplore (GUI)" "zxplore"
test_cmd "zxplore-tui" "zxplore-tui"
if zxplore-tui --version 2>/dev/null | grep -q '^zxplore'; then
    _pass "zxplore-tui --version reports"
else
    _fail "zxplore-tui --version" "no version output"
fi
test_file "zxplore launcher" "/usr/share/applications/zxplore.desktop"
test_file "zxplore icon (dark, launcher face)" "/usr/share/icons/hicolor/scalable/apps/zxplore-tui.svg"
test_file "zxplore commit breadcrumb" "/etc/kldload/zxplore-commit"

_section "Services"
test_service_enabled "kldload-webui" "kldload-webui"
test_cmd "sanoid" "sanoid"
test_service_enabled "sanoid.timer" "sanoid.timer"
test_cmd "wg (WireGuard)" "wg"

# ── GNOME Desktop ────────────────────────────────────────────────────────────
_section "Launchers point at binaries that exist"

# Every .desktop that runs something out of /usr/local/bin must have that
# binary present. The installer copies launchers, icons and binaries from
# THREE separate curated lists, so adding a tool to one and not the others
# ships an app-grid tile that opens onto nothing — and nothing logs a thing.
#
# HISTORY: three times now. vmxplore (1.4.0-rc2) shipped both launchers, the
# icon and the commit stamp with no binaries. ollama.svg matched no icon
# pattern and rendered a blank square. ztx (rc8) shipped the launcher, the
# icon and the System-folder entry with no binary. Each fix added one more
# name to one more list; this checks the result instead.
_broken_launchers=0
for _d in /usr/share/applications/*.desktop; do
    [[ -f "$_d" ]] || continue
    _exec=$(awk -F= '/^Exec=/{print $2; exit}' "$_d" 2>/dev/null | awk '{print $1}')
    case "$_exec" in
    /usr/local/bin/*) ;;
    *) continue ;;
    esac
    if [[ -x "$_exec" ]]; then
        _pass "$(basename "$_d") → $(basename "$_exec")"
    else
        _fail "$(basename "$_d") points at $_exec which is NOT installed"
        _broken_launchers=$((_broken_launchers + 1))
    fi
done
[[ "$_broken_launchers" -eq 0 ]] && _pass "every launcher resolves to an installed binary"

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

# ── Browser ──────────────────────────────────────────────────────────────────
# Installed targets ship Chrome (webui app windows, Web Speech API for Bob);
# firefox is LIVE-ISO-only by design — the old firefox assertion here failed
# every correctly-built desktop install.
_section "Browser"

test_cmd "google-chrome" "google-chrome-stable"

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
# Darksite is intentionally REMOVED on first boot by kldload-firstboot
# (lines 2052-2068 in /usr/sbin/kldload-firstboot) to reclaim ~1.8G —
# it's only needed during the install. So presence at smoke-time would
# actually be a regression (firstboot didn't run, or something kept
# the dir alive). Two markers we DO want post-install:
#   - /etc/yum.repos.d/kldload-darksite.repo is gone (cleaned up too)
#   - If admin opted into LAN mirror mode, kldload-apt-mirror.service
#     is enabled and /root/darksite/<distro>/apt persists.
# For default installs, just verify the rehydrated outputs landed.
_section "Darksite (post-firstboot cleanup)"
test_succeeds "darksite removed from /root (firstboot reclaim)" \
    "[[ ! -d /root/darksite ]]"
test_succeeds "darksite repo file removed" \
    "[[ ! -f /etc/yum.repos.d/kldload-darksite.repo ]]"
# When KLDLOAD_KEEP_DARKSITE=1 was set at install (LAN mirror mode),
# the dir SHOULD persist. Check that case explicitly so an admin who
# enabled it doesn't get a false PASS from the cleanup check above.
if [[ -f /etc/kldload/keep-darksite ]]; then
    test_dir "LAN mirror mode: darksite kept" "/root/darksite"
    test_service_active "LAN mirror service" "kldload-apt-mirror"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
summary
