#!/bin/bash
# smoke-kvm.sh — verify a kldloadOS KVM profile install
# Tests everything in server PLUS: KVM, libvirt, kube-*, kzfs-lab, virbr0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm; clear
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
test_succeeds "Has IP" "ip -4 addr show | grep -q 'inet '"

# ── Secure Boot ──────────────────────────────────────────────────────────────
_section "Secure Boot"
if command -v mokutil >/dev/null 2>&1; then
  _pass "mokutil installed"
  local _sb_state
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
    local _lockdown
    _lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'unknown')"
    _pass "Kernel lockdown: ${_lockdown}"
  else
    _pass "Secure Boot: disabled (optional)"
  fi
else
  _warn "mokutil" "not installed"
fi
test_file "MOK key (DER)" "/var/lib/dkms/mok.der"
test_file "MOK key (private)" "/var/lib/dkms/mok.key"
test_file "MOK key (public)" "/var/lib/dkms/mok.pub"
if command -v sbsign >/dev/null 2>&1; then
  _pass "sbsigntool installed"
else
  _warn "sbsigntool" "not installed — modules can't be signed locally"
fi
# Check shim on EFI partition
if [[ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
  local _boot_hash _zbm_hash
  _boot_hash="$(sha256sum /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null | awk '{print $1}')"
  _zbm_hash="$(sha256sum /boot/efi/EFI/zbm/BOOTX64.EFI 2>/dev/null | awk '{print $1}')"
  if [[ "$_boot_hash" != "$_zbm_hash" ]]; then
    _pass "Shim installed as UEFI fallback (different from ZFSBootMenu)"
  else
    _warn "BOOT/BOOTX64.EFI" "same as ZFSBootMenu — shim may not be installed"
  fi
fi
test_file "MokManager" "/boot/efi/EFI/BOOT/mmx64.efi"
test_file "MOK cert on EFI" "/boot/efi/EFI/BOOT/mok.der"
test_file "grubx64.efi (ZBM for shim)" "/boot/efi/EFI/BOOT/grubx64.efi"

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
test_service_active "libvirtd" "libvirtd"

# virbr0
if ip addr show virbr0 >/dev/null 2>&1; then
  _pass "virbr0 interface up"
else
  _fail "virbr0" "interface not found"
fi

if virsh net-list 2>/dev/null | grep -q "active"; then
  _pass "default network active"
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
_section "eBPF / Observability"
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

# ── Summary ──────────────────────────────────────────────────────────────────
summary
