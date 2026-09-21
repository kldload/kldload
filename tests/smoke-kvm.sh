#!/bin/bash
# smoke-kvm.sh — verify a kldloadOS KVM profile install
# Tests everything in server PLUS: KVM, libvirt, kube-*, kzfs-lab, virbr0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm
clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — KVM profile                      ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
printf "  Build:         %s\n" "$(cat /etc/kldload-build-id 2>/dev/null || echo unknown)"
echo ""

# ── ZFS ──────────────────────────────────────────────────────────────────────
_section "ZFS (base)"
test_output_contains "Pool rpool ONLINE" "zpool list -H -o health rpool" "ONLINE"
test_output_contains "Zero errors" "zpool status rpool" "No known data errors"
test_output_contains "bootfs set" "zpool get -H -o value bootfs rpool" "rpool/ROOT/"
test_succeeds "EFI mounted" "mountpoint -q /boot/efi"

# ── SSH & Network ────────────────────────────────────────────────────────────
_section "SSH & Network"
test_service_active "sshd" "sshd"
# Captured, not piped: `| grep -q` under pipefail is rc=141 when grep
# exits first (see the SSH check in smoke-core.sh).
test_succeeds "Has IP" '[[ "$(ip -4 addr show 2>/dev/null)" == *"inet "* ]]'

# ── Secure Boot ──────────────────────────────────────────────────────────────
_section "Secure Boot"
if command -v mokutil >/dev/null 2>&1; then
    _pass "mokutil installed"
    _sb_state="$(mokutil --sb-state 2>/dev/null || echo 'unknown')"
    if echo "$_sb_state" | grep -q "enabled"; then
        _pass "Secure Boot: ENABLED"
        # Check MOK enrolled
        if mokutil --list-enrolled 2>/dev/null | grep -q "kldload"; then
            _pass "MOK key enrolled (kldload Secure Boot MOK)"
        else
            _warn "MOK key" "not enrolled — run mokutil --import /var/lib/dkms/mok.der"
        fi
        # Check lockdown
        _lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'unknown')"
        _pass "Kernel lockdown: ${_lockdown}"
    else
        _pass "Secure Boot: disabled (optional)"
    fi
else
    _warn "mokutil" "not installed"
fi
# The MOK pair and the shim chain on the ESP exist only when the install asked for
# Secure Boot. Checked unconditionally, six FAILs landed on every Secure-Boot-off kvm
# install (4-k8s, fiend 2026-09-14: 235 passed, 7 failed, six of them these).
_sb_requested=0
grep -qE '^KLDLOAD_ENABLE_SECURE_BOOT="?1"?$' /etc/kldload/install-manifest.env 2>/dev/null && _sb_requested=1
if ((_sb_requested)); then
    test_file "MOK key (DER)" "/var/lib/dkms/mok.der"
    test_file "MOK key (private)" "/var/lib/dkms/mok.key"
    test_file "MOK key (public)" "/var/lib/dkms/mok.pub"
else
    _pass "MOK keys not expected: this install did not request Secure Boot"
fi
if command -v sbsign >/dev/null 2>&1; then
    _pass "sbsigntool installed"
else
    _warn "sbsigntool" "not installed — modules can't be signed locally"
fi
# Check shim on EFI partition
if [[ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
    _boot_hash="$(sha256sum /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null | awk '{print $1}')"
    _zbm_hash="$(sha256sum /boot/efi/EFI/zbm/BOOTX64.EFI 2>/dev/null | awk '{print $1}')"
    if [[ "$_boot_hash" != "$_zbm_hash" ]]; then
        _pass "Shim installed as UEFI fallback (different from ZFSBootMenu)"
    else
        _warn "BOOT/BOOTX64.EFI" "same as ZFSBootMenu — shim may not be installed"
    fi
fi
if ((_sb_requested)); then
    test_file "MokManager" "/boot/efi/EFI/BOOT/mmx64.efi"
    test_file "MOK cert on EFI" "/boot/efi/EFI/BOOT/mok.der"
    test_file "grubx64.efi (ZBM for shim)" "/boot/efi/EFI/BOOT/grubx64.efi"
fi

# ── Profile & Edition ────────────────────────────────────────────────────────
_section "Profile Markers"
test_file "Edition marker" "/etc/kldload/edition"
test_file "Build ID" "/etc/kldload-build-id"
test_file "Build SHA" "/etc/kldload-build-sha"
if [[ -f /etc/kldload/profile ]]; then
    _pass "Profile marker: $(cat /etc/kldload/profile)"
else
    _fail "Profile marker" "/etc/kldload/profile missing"
fi

# ── kldloadOS Tools ──────────────────────────────────────────────────────────
_section "kldloadOS Tools"
for tool in kst ksnap kbe kclone kdf kdir kpkg kupgrade kexport krecovery kldload-help kldload-overview kube-demo; do
    test_cmd "$tool" "$tool"
done

# ── KVM / Libvirt ────────────────────────────────────────────────────────────
_section "KVM / Libvirt"
test_cmd "virsh" "virsh"
test_cmd "virt-install" "virt-install"
test_cmd "qemu-img" "qemu-img"
# libvirtd is SOCKET-ACTIVATED and shipped DISABLED: it starts when something
# connects and idles out when nothing does. Asserting the service is resident
# therefore fails on a correctly configured host that has simply not been asked
# anything lately, and passes on a busy one — so this check was really testing
# how recently someone used libvirt.
#
# HISTORY: fiend, 2026-09-21, 5-desktop. The report said "libvirtd is inactive"
# while the machine's own journal showed libvirtd.service "Deactivated
# successfully" at 15:35:25 and "Started" again at 15:36:29, on demand, with
# libvirtd.socket active throughout and libvirtd.service `disabled`. Every kvm
# and k8s edition in the same sweep passed it, because they had VMs running.
#
# What matters is that libvirt ANSWERS. The daemon behind the socket is an
# implementation detail — on the modular split it is virtqemud and there may be
# no libvirtd at all — so ask the tool instead of the unit.
test_succeeds "libvirt responds" "virsh --connect qemu:///system list --all"

# virbr0 / default NAT network. In NESTED installs (this guest's uplink is
# itself on a host's 192.168.122.0/24 libvirt NAT) the default network can
# never start — libvirt refuses "network already in use by interface X".
# That is an environmental impossibility, not an install defect: WARN with
# the reason (visible + counted) instead of a false FAIL. Real hardware
# installs have no collision and still hard-fail here. Subnet-aware lab
# tooling (klab/kube hardcode 192.168.122.0/24) is the tracked real fix.
_nested_collision=0
if ip -4 addr show 2>/dev/null | grep -v 'virbr0' | grep -q 'inet 192\.168\.122\.'; then
    _nested_collision=1
fi

if ip addr show virbr0 >/dev/null 2>&1; then
    _pass "virbr0 interface up"
elif ((_nested_collision)); then
    _warn "virbr0" "absent — nested install, uplink already owns 192.168.122.0/24 (subnet collision)"
else
    _fail "virbr0" "interface not found"
fi

if virsh net-list 2>/dev/null | grep -q "active"; then
    _pass "default network active"
elif ((_nested_collision)); then
    _warn "default network" "inactive — nested 192.168.122.0/24 collision (see virbr0)"
else
    _fail "default network" "not active"
fi

if virsh net-info default 2>/dev/null | grep -q "Autostart.*yes"; then
    _pass "default network autostart"
else
    _warn "default network autostart" "not set to yes"
fi

# KVM tools
for tool in kvm-create kvm-clone kvm-snap kvm-delete kvm-list kvm-demo; do
    test_cmd "$tool" "$tool"
done

# ── Kubernetes Tools ─────────────────────────────────────────────────────────
_section "Kubernetes Tools"
for tool in kube-cluster kube-init kube-join kube-network kube-setup kube-status kube-reset kube-smoke-test kube-load-images; do
    test_cmd "$tool" "$tool"
done

# ── kzfs-lab ─────────────────────────────────────────────────────────────────
_section "ZFS Dev Lab"
test_cmd "kzfs-lab" "kzfs-lab"

# ── Sanoid ───────────────────────────────────────────────────────────────────
_section "Sanoid"
test_cmd "sanoid" "sanoid"
test_file "sanoid config" "/etc/sanoid/sanoid.conf"
test_file "sanoid defaults" "/etc/sanoid/sanoid.defaults.conf"
test_service_enabled "sanoid.timer" "sanoid.timer"
if sanoid --cron >/dev/null 2>&1; then
    _pass "sanoid --cron runs clean"
else
    _fail "sanoid --cron" "exits with error"
fi

# ── sshpass ──────────────────────────────────────────────────────────────────
_section "SSH Automation"
test_cmd "sshpass" "sshpass"

# ── WireGuard ────────────────────────────────────────────────────────────────
_section "WireGuard"
test_cmd "wg" "wg"
test_output_contains "WireGuard module" "modprobe wireguard && lsmod" "wireguard"

# ── eBPF ─────────────────────────────────────────────────────────────────────
# ── ZFS Console (zxplore) ─────────────────────────────────────────────────────
# zxplore-tui is part of the OS on every tool-bearing profile (static binary,
# baked at ISO build from github.com/zxplore/zxplore, copied to the target by
# the zxplore* glob in profiles.sh). Missing binary = bake or copy regressed.
_section "ZFS Console"
test_cmd "zxplore-tui" "zxplore-tui"
if zxplore-tui --version 2>/dev/null | grep -q '^zxplore'; then
    _pass "zxplore-tui --version reports"
else
    _fail "zxplore-tui --version" "no version output"
fi
# kvm ships gnome-shell + GL, so the GUI variant and its tray tile must be
# present too (capability-gated in build-iso.sh, copied by profiles.sh).
test_cmd "zxplore (GUI)" "zxplore"
test_file "zxplore launcher" "/usr/share/applications/zxplore.desktop"
# Icon=zxplore-tui is the launcher's face (the dark tile) — BOTH svgs ship.
test_file "zxplore icon (dark, launcher face)" "/usr/share/icons/hicolor/scalable/apps/zxplore-tui.svg"
test_file "zxplore icon (logo)" "/usr/share/icons/hicolor/scalable/apps/zxplore.svg"
test_file "zxplore commit breadcrumb" "/etc/kldload/zxplore-commit"

# ── Secure Boot repair tool ───────────────────────────────────────────────────
# Rescue tooling must exist and its read-only status mode must run clean on
# a UEFI install (the smoke VM boots UEFI, so efivars/mokutil are live).
_section "Secure Boot Repair"
test_cmd "kldload-mok-repair" "kldload-mok-repair"
if kldload-mok-repair status >/dev/null 2>&1; then
    _pass "kldload-mok-repair status runs clean"
else
    _fail "kldload-mok-repair status" "non-zero exit"
fi
test_file "SB repair launcher" "/usr/share/applications/kldload-mok-repair.desktop"

# ── WG networks console (prototype) ───────────────────────────────────────────
_section "WG Networks"
test_cmd "wgx" "wgx"
# "WireGuard networks" was the prototype's tagline; wgxplore 0.2.0 prints "the
# WireGuard estate console", and this FAILed on a working tool (4-k8s, 2026-09-14).
if wgx --help 2>/dev/null | grep -qE 'WireGuard (estate|networks)'; then
    _pass "wgx --help reports"
else
    _fail "wgx --help" "no usage output"
fi
# GUI-capable rootfs: the console must have a tile like zxplore's.
test_file "wgxplore launcher" "/usr/share/applications/wgxplore.desktop"
test_file "wgxplore icon" "/usr/share/icons/hicolor/scalable/apps/wgxplore.svg"

_section "eBPF / Observability"
# The eBPF tools are installed only when the install asked for them
# (KLDLOAD_ENABLE_EBPF=1); first boot stopped pulling them in regardless on
# 2026-09-14. So check them only then, the same way Secure Boot is checked.
_ebpf_requested=0
grep -qE '^KLDLOAD_ENABLE_EBPF="?1"?$' /etc/kldload/install-manifest.env 2>/dev/null && _ebpf_requested=1
if ((_ebpf_requested)); then
    test_cmd "bpftrace" "bpftrace"

    if [[ "$DISTRO" == "deb" ]]; then
        if dpkg -l bpfcc-tools 2>/dev/null | grep -q ^ii; then
            _pass "bpfcc-tools installed"
        else
            _warn "bpfcc-tools" "not installed"
        fi
    else
        if rpm -q bcc-tools >/dev/null 2>&1 || [[ -d /usr/share/bcc/tools ]]; then
            _pass "bcc-tools installed"
        else
            _warn "bcc-tools" "not installed"
        fi
    fi
else
    _pass "eBPF tools not expected: this install did not request eBPF"
fi

if [[ -f /sys/kernel/btf/vmlinux ]]; then
    _pass "BTF available (eBPF CO-RE)"
else
    _warn "BTF" "not available"
fi

# ── NVIDIA (optional) ────────────────────────────────────────────────────────
_section "NVIDIA (optional)"
if command -v nvidia-smi >/dev/null 2>&1; then
    _pass "nvidia-smi found"
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null && _pass "GPU detected" || _warn "GPU" "driver loaded but no GPU"
else
    _pass "NVIDIA not installed (expected if not selected)"
fi

# ── Containers ───────────────────────────────────────────────────────────────
_section "Containers"
test_cmd "podman" "podman"

# ── Kubernetes Cluster (if deployed) ─────────────────────────────────────────
_section "Kubernetes Cluster (if deployed)"
if virsh list --name 2>/dev/null | grep -q kldload-cp; then
    _pass "Control plane VM running"
    CP_MAC=$(virsh domiflist kldload-cp 2>/dev/null | awk '/bridge/ {print $5}' | head -1)
    CP_IP=$(virsh net-dhcp-leases default 2>/dev/null | awk -v m="$CP_MAC" '$3 == m {print $5}' | cut -d/ -f1 | head -1)
    if [[ -n "$CP_IP" ]]; then
        _pass "CP IP: $CP_IP"
        if sshpass -p kldload ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${CP_IP} "kubectl get nodes --no-headers" 2>/dev/null; then
            _pass "kubectl get nodes works"
            NODES=$(sshpass -p kldload ssh -o StrictHostKeyChecking=no root@${CP_IP} "kubectl get nodes --no-headers 2>/dev/null | wc -l")
            READY=$(sshpass -p kldload ssh -o StrictHostKeyChecking=no root@${CP_IP} "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'")
            _pass "Nodes: ${READY}/${NODES} Ready"
        else
            _warn "kubectl" "cannot reach API server"
        fi
    else
        _warn "CP IP" "could not determine"
    fi

    WORKER_COUNT=$(virsh list --name 2>/dev/null | grep -c 'kldload-w-')
    _pass "Worker VMs: $WORKER_COUNT"
else
    _pass "No cluster deployed (expected — run kube-cluster bootstrap)"
fi

# ── VM snapshots actually happen ─────────────────────────────────────────────
# Not "the timer is enabled" -- it was enabled and firing hourly on fiend while
# taking nothing at all, because its ExecStart= relied on shell variables that
# systemd had already expanded away. The only check worth having is to run it
# and count what came back, so this asserts the OUTCOME: a snapshot with this
# run's own marker prefix exists afterwards, on a dataset that was there before.
_section "VM Snapshots"
if zfs list rpool/vms >/dev/null 2>&1; then
    test_cmd "kldload-vm-snapshot present" "kldload-vm-snapshot"
    _snapmark="smoketest-$$-"
    if kldload-vm-snapshot --root rpool/vms --prefix "$_snapmark" --keep 1 >/dev/null 2>&1; then
        # grep -c exits 1 when it counts zero, and zero is precisely the
        # answer this check exists to catch -- the old ExecStart took no
        # snapshots at all and still reported success. So the failing status is
        # handled by naming the value it means, rather than swallowed with a
        # `|| true` that would say nothing about why it is safe.
        _snapn=$(zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null |
            grep -c "@${_snapmark}") || _snapn=0
        _dsn=$(zfs list -H -o name -r rpool/vms 2>/dev/null | tail -n +2 | wc -l)
        if [[ "${_snapn:-0}" -gt 0 ]] && [[ "${_snapn:-0}" -eq "${_dsn:-0}" ]]; then
            _pass "VM snapshots taken: ${_snapn}/${_dsn} datasets"
        else
            _fail "VM snapshots" "took ${_snapn:-0} snapshots for ${_dsn:-0} datasets"
        fi
        # Clean up only the snapshots this run named. A snapshot that will
        # not destroy is worth saying so about -- it carries this run's marker,
        # so nothing else will ever clean it up -- but it is not a reason to
        # fail the KVM suite, which is why this warns rather than failing.
        # Filter in the loop rather than with grep: when the snapshotter took
        # nothing -- exactly the case this section exists to catch -- grep
        # matches nothing and exits 1, and under the ERR trap that printed a
        # bogus "FAIL at line 36" on top of the real failure. zfs list exits 0
        # whether or not it lists anything, so the status here means what it
        # should.
        while read -r _s; do
            case "$_s" in
            *"@${_snapmark}"*) ;;
            *) continue ;;
            esac
            zfs destroy "$_s" 2>/dev/null ||
                _warn "VM snapshot cleanup" "could not destroy $_s"
        done < <(zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null)
    else
        _fail "VM snapshots" "kldload-vm-snapshot could not take a snapshot"
    fi
    # The timer is what makes it hourly, so it still has to be enabled.
    test_service_enabled "kvm-snapshot.timer" "kvm-snapshot.timer"
else
    _pass "No rpool/vms on this machine (expected — not a VM host)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
summary
