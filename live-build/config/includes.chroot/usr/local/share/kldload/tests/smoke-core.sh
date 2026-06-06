#!/bin/bash
# smoke-core.sh — verify a kldloadOS CORE profile install
# Tests: ZFS, boot environments, SSH, networking, stock distro
# Does NOT test: k* tools, webui, sanoid, darksites (not in core)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm
clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — CORE profile                     ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
echo ""

# ── ZFS ──────────────────────────────────────────────────────────────────────
_section "ZFS"

test_cmd "ZFS userspace (zfs)" "zfs"
test_cmd "ZFS pool tools (zpool)" "zpool"
test_output_contains "ZFS module loaded" "lsmod" "zfs"
test_output_contains "Pool rpool exists" "zpool list" "rpool"
test_output_contains "Pool rpool is ONLINE" "zpool list -H -o health rpool" "ONLINE"
test_output_contains "Pool has zero errors" "zpool status rpool" "No known data errors"
test_succeeds "Pool scrub runs" "zpool scrub rpool"

# ── Datasets ─────────────────────────────────────────────────────────────────
_section "ZFS Datasets"

test_dataset "rpool/ROOT exists" "rpool/ROOT"
test_output_contains "Root dataset mounted at /" "zfs get -H -o value mountpoint rpool/ROOT/*" "/"
test_dataset "rpool/home exists" "rpool/home"
test_dataset "rpool/var exists" "rpool/var"
test_dataset "rpool/var/log exists" "rpool/var/log"
test_dataset "rpool/srv exists" "rpool/srv"

DATASET_COUNT=$(zfs list -H -o name 2>/dev/null | wc -l)
if [[ $DATASET_COUNT -ge 10 ]]; then
    _pass "Dataset count ($DATASET_COUNT >= 10)"
else _warn "Dataset count" "only $DATASET_COUNT datasets (expected >= 10)"; fi

test_output_contains "Compression enabled" "zfs get -H -o value compression rpool" "lz4\|zstd\|on"

# ── Boot Environment ─────────────────────────────────────────────────────────
_section "Boot Environment"

test_output_contains "bootfs is set" "zpool get -H -o value bootfs rpool" "rpool/ROOT/"
test_file "Boot environment marker" "/etc/kldload/boot-environment"

# ── EFI / Bootloader ────────────────────────────────────────────────────────
_section "EFI / Bootloader"

# Note: kldload deliberately does NOT keep /boot/efi mounted at runtime —
# the kernel-install hook mounts it on demand during kernel updates and
# unmounts immediately. So checking "is /boot/efi mounted right now" gives
# a false negative on a healthy idle system. We validate the ESP exists
# and contains the expected EFI tree by mounting read-only into a tmp dir
# for the duration of the checks. Caught 2026-05-13 on first clean F44
# install where the old "mountpoint -q /boot/efi" check was the only FAIL
# in an otherwise-green run.
# Wrap in set +e so a quirk of the discovery commands (findmnt return
# codes, pipefail interactions) can't take down the script itself.
(
    set +e
    _esp_dev=$(findmnt -no SOURCE /boot/efi 2>/dev/null)
    if [[ -z "$_esp_dev" ]]; then
        _esp_dev=$(lsblk -lno NAME,PARTTYPE 2>/dev/null |
            awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print "/dev/"$1; exit}')
    fi
    if [[ -n "$_esp_dev" && -b "$_esp_dev" ]]; then
        _pass "ESP partition exists: $_esp_dev"
        _esp_mnt=$(mktemp -d)
        if mount -o ro "$_esp_dev" "$_esp_mnt" 2>/dev/null; then
            if [[ -d "$_esp_mnt/EFI" ]]; then
                _pass "EFI/ tree present on ESP"
            else _fail "EFI/ tree on ESP" "no EFI/ directory found on $_esp_dev"; fi
            if find "$_esp_mnt" -maxdepth 4 \
                \( -name 'zfsbootmenu*' -o -name 'ZFSBootMenu*' -o -name 'vmlinuz*' \) \
                2>/dev/null | grep -q .; then
                _pass "ZFSBootMenu/kernel on ESP"
            else
                _warn "ZFSBootMenu on ESP" "no kernel/ZBM found on $_esp_dev"
            fi
            umount "$_esp_mnt" 2>/dev/null
        else
            _fail "ESP mountable" "could not read-only mount $_esp_dev"
        fi
        rmdir "$_esp_mnt" 2>/dev/null
    else
        _fail "ESP partition exists" "no EFI System Partition found via findmnt or lsblk"
    fi
)

test_file "Hostid configured" "/etc/hostid"

# ── System Identity ──────────────────────────────────────────────────────────
_section "System Identity"

test_file "/etc/os-release exists" "/etc/os-release"
test_file "Build SHA marker" "/etc/kldload-build-sha"
test_file "Edition marker" "/etc/kldload/edition"

# ── SSH ──────────────────────────────────────────────────────────────────────
_section "SSH"

test_service_active "sshd running" "sshd"
test_service_enabled "sshd enabled" "sshd"
test_file "SSH host key exists" "/etc/ssh/ssh_host_ed25519_key.pub"
test_succeeds "SSH port open" "ss -tlnp | grep -q :22"

# ── Networking ───────────────────────────────────────────────────────────────
_section "Networking"

test_succeeds "Has an IP address" "ip -4 addr show | grep -q 'inet '"
test_succeeds "Default route exists" "ip route show default | grep -q 'default'"
test_succeeds "DNS resolves" "getent hosts github.com"

if [[ "$DISTRO" == "deb" ]]; then
    test_service_active "NetworkManager or networkd" "NetworkManager" || test_service_active "systemd-networkd" "systemd-networkd"
else
    test_service_active "NetworkManager running" "NetworkManager"
fi

# ── Core Profile Verification (should NOT have k* tools) ────────────────────
_section "Core Profile Verification"

for tool in kst ksnap kbe kclone kdf kdir kpkg kupgrade kexport krecovery kldload-webui sanoid; do
    if command -v "$tool" >/dev/null 2>&1; then
        _fail "$tool absent (core)" "$tool found — should not be in core profile"
    else
        _pass "$tool absent (core)"
    fi
done

# Webui should not be running
if systemctl is-active kldload-webui >/dev/null 2>&1; then
    _fail "kldload-webui not running (core)" "webui is active — should not be in core"
else
    _pass "kldload-webui not running (core)"
fi

# Sanoid should not be running
if systemctl is-active sanoid.timer >/dev/null 2>&1; then
    _fail "sanoid not running (core)" "sanoid.timer is active — should not be in core"
else
    _pass "sanoid not running (core)"
fi

# ── Snapshot Test ────────────────────────────────────────────────────────────
_section "ZFS Snapshot Test"

SNAP_NAME="smoketest-$(date +%Y%m%d-%H%M%S)"
if zfs snapshot "rpool@${SNAP_NAME}" 2>/dev/null; then
    _pass "Can create snapshot (rpool@${SNAP_NAME})"
    if zfs list -t snapshot "rpool@${SNAP_NAME}" >/dev/null 2>&1; then
        _pass "Snapshot visible in list"
    else
        _fail "Snapshot visible" "snapshot created but not in list"
    fi
    zfs destroy "rpool@${SNAP_NAME}" 2>/dev/null
    _pass "Snapshot destroyed cleanly"
else
    _fail "Can create snapshot" "zfs snapshot failed"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
summary
