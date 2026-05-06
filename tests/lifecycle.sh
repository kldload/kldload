#!/usr/bin/env bash
# lifecycle.sh — full-loop install smoke test in KVM.
#
# Closes the gap between `./deploy.sh build` (produces an ISO) and the
# tests/smoke-*.sh suite (runs on a booted installed system). Boots the
# latest ISO in a throwaway KVM VM with OVMF/UEFI, waits for the live
# env's sshd, drives the installer headlessly with an answers env file,
# reboots into the installed target, and runs smoke-auto.sh against it.
#
# Usage:
#   sudo tests/lifecycle.sh <distro> <profile>
#   sudo ./deploy.sh smoke-test <distro> <profile>   # same thing, via deploy.sh
#
#   distro:   centos | debian | ubuntu | fedora | rocky | rhel | arch | alpine
#   profile:  core | server | desktop | kvm
#
# Examples:
#   sudo tests/lifecycle.sh centos server
#   sudo tests/lifecycle.sh debian desktop
#
# Env knobs:
#   VM_NAME      default: kldload-smoke-<distro>-<profile>
#   VM_MEMORY    default: 8192 (MB)
#   VM_CORES     default: 4
#   VM_DISK_GB   default: 32
#   KEEP_VM      if set, leaves the VM around for inspection on success
#                (the VM is always kept on failure regardless of this)
#   SB_ON        if set non-empty, boots with Secure Boot enabled. Without
#                MOK pre-enrolled this means our zfs.ko won't load on first
#                boot (kernel rejects it as unsigned-by-trusted-key) — useful
#                only for testing that shim → grub → kernel signed chain
#                links up. Default: SB off (full functional smoke).
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

# ── Args + deps ──────────────────────────────────────────────────────────────
if [[ $# -ne 2 ]]; then
  echo "usage: $0 <distro> <profile>" >&2
  echo "   distro:  centos|debian|ubuntu|fedora|rocky|rhel|arch|alpine" >&2
  echo "   profile: core|server|desktop|kvm" >&2
  exit 64
fi
DISTRO="$1"
PROFILE="$2"

case "$DISTRO" in
  centos|debian|ubuntu|fedora|rocky|rhel|arch|alpine) ;;
  *) echo "unknown distro: $DISTRO" >&2; exit 64 ;;
esac
case "$PROFILE" in
  core|server|desktop|kvm) ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 64 ;;
esac

for _bin in virsh virt-install virt-xml qemu-img sshpass scp ssh; do
  command -v "$_bin" >/dev/null 2>&1 \
    || { echo "missing dependency: $_bin (install libvirt-client + virt-install + sshpass)" >&2; exit 69; }
done

# ── State ────────────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -u +%Y%m%d-%H%M%S)"
VM_NAME="${VM_NAME:-kldload-smoke-${DISTRO}-${PROFILE}}"
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_GB="${VM_DISK_GB:-32}"
LOG="/tmp/kldload-smoke-${DISTRO}-${PROFILE}-${TS}.log"
ISO_DST="/var/lib/libvirt/images/kldload-smoke-iso.iso"
DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
ANSWERS="/tmp/kldload-smoke-${VM_NAME}-answers.env"
SB_ENABLED="${SB_ON:+yes}"; SB_ENABLED="${SB_ENABLED:-no}"

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_CYN=$'\033[1;36m'; C_RST=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$C_CYN" "$(date +%H:%M:%S)" "$C_RST" "$*" | tee -a "$LOG"; }
fail() { printf '%sFAIL%s %s\n' "$C_RED" "$C_RST" "$*" | tee -a "$LOG"; exit 1; }
ok()   { printf '%sOK%s   %s\n' "$C_GRN" "$C_RST" "$*" | tee -a "$LOG"; }

trap 'rc=$?; [[ $rc -ne 0 ]] && log "exiting with rc=$rc — VM left for inspection: virsh console $VM_NAME"' EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o ServerAliveInterval=30)

# ── Locate the latest built ISO ──────────────────────────────────────────────
ISO="$(find "$ROOT/live-build/output" -maxdepth 1 -name 'kldload-*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | awk '{print $2}')"
[[ -n "$ISO" && -f "$ISO" ]] || fail "no ISO in $ROOT/live-build/output — run ./deploy.sh build first"
log "ISO: $(basename "$ISO") ($(numfmt --to=iec --suffix=B "$(stat -c%s "$ISO")"))"

# ── Tear down any prior VM with this name ────────────────────────────────────
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  log "tearing down existing VM $VM_NAME"
  virsh destroy "$VM_NAME"  >/dev/null 2>&1 || true
  virsh undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 || true
fi
rm -f "$DISK"

# ── Stage ISO + create disk ──────────────────────────────────────────────────
install -m 644 -o qemu -g qemu "$ISO" "$ISO_DST"
qemu-img create -f qcow2 "$DISK" "${VM_DISK_GB}G" >/dev/null
chown qemu:qemu "$DISK"

# ── Boot the live ISO ────────────────────────────────────────────────────────
log "creating VM $VM_NAME (mem=${VM_MEMORY}M cores=${VM_CORES} disk=${VM_DISK_GB}G SB=${SB_ENABLED})"
virt-install --name "$VM_NAME" --ram "$VM_MEMORY" --vcpus "$VM_CORES" \
  --disk "path=${DISK},format=qcow2,bus=virtio" \
  --disk "path=${ISO_DST},device=cdrom,bus=sata,readonly=on" \
  --os-variant fedora-unknown \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0 \
  --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=${SB_ENABLED}" \
  --noautoconsole >>"$LOG" 2>&1 || fail "virt-install failed (see $LOG)"

# ── Find the VM's IP ─────────────────────────────────────────────────────────
# Tries qemu-guest-agent first (most reliable when present), then DHCP lease,
# then a MAC-based ARP lookup as a last resort.
get_vm_ip() {
  # Three sources, in order of preference:
  #   1. qemu-guest-agent (if running in the guest) — fastest, but emits
  #      ALL interfaces including lo (127.0.0.1) and link-local — those
  #      MUST be filtered out, otherwise the function returns 127.0.0.1
  #      and the caller endlessly fails ssh against loopback. Bug seen
  #      2026-05-05 on fiend's first CI run: smoke-test waited 23 min,
  #      ssh'd to 127.0.0.1 every iteration, declared "live env never
  #      came up" while the VM had been ssh-reachable on its real IP.
  #   2. virsh net-dhcp-leases — authoritative when libvirt's default
  #      network's dnsmasq leased the address (i.e. the VM is on virbr0).
  #   3. fail.
  local mac ip
  mac="$(virsh domiflist "$VM_NAME" 2>/dev/null | awk 'NR>2 && $1!="" {print $5; exit}')"
  ip="$(virsh domifaddr "$VM_NAME" --source agent 2>/dev/null \
          | awk '/ipv4/ {print $4}' \
          | cut -d/ -f1 \
          | grep -vE '^(127\.|169\.254\.|0\.0\.0\.0$)' \
          | head -1)"
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  ip="$(virsh net-dhcp-leases default 2>/dev/null \
          | awk -v m="$mac" 'tolower($3)==tolower(m) {print $5}' | cut -d/ -f1 | head -1)"
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  return 1
}

wait_for_ssh() {
  # Default max=180 iterations × 5s = 15 min. The kldload live ISO is
  # ~5 GB squashfs + ZFS rootfs init + all the kldload tools loading.
  # On a 4-core VM backed by qcow2-on-ZFS (smoke-test default) the live
  # env routinely needs 7-10 min from -boot to ssh-ready. 5 min was too
  # tight — caused spurious "live env never came up" failures in CI.
  # Bug seen 2026-05-05 on fiend's first CI run (smoke-test fedora-core).
  local who="$1" pass="$2" max="${3:-180}"
  local ip
  for _ in $(seq 1 "$max"); do
    ip="$(get_vm_ip 2>/dev/null || true)"
    if [[ -n "$ip" ]] && timeout 2 bash -c ">/dev/tcp/${ip}/22" 2>/dev/null; then
      if sshpass -p "$pass" ssh "${SSH_OPTS[@]}" "${who}@${ip}" true 2>/dev/null; then
        echo "$ip"
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

log "waiting for live env DHCP + sshd"
VM_IP="$(wait_for_ssh live live 180)" \
  || fail "live env never came up — VNC: $(virsh vncdisplay "$VM_NAME" 2>/dev/null || echo n/a)"
ok "live env up at $VM_IP"

ssh_live() { sshpass -p live ssh "${SSH_OPTS[@]}" "live@${VM_IP}" "$@"; }

# ── Compose answers env file ─────────────────────────────────────────────────
cat > "$ANSWERS" <<EOF
# auto-generated by tests/lifecycle.sh @ ${TS}
KLDLOAD_DISTRO=${DISTRO}
KLDLOAD_PROFILE=${PROFILE}
KLDLOAD_DISK=/dev/vda
KLDLOAD_HOSTNAME=smoke-${DISTRO}-${PROFILE}
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=admin
KLDLOAD_NET_METHOD=dhcp
KLDLOAD_STORAGE_MODE=zfs
KLDLOAD_ZFS_TOPOLOGY=single
KLDLOAD_ZFS_ENCRYPT=0
KLDLOAD_DEBIAN_RELEASE=trixie
KLDLOAD_FEDORA_RELEASE=44
KLDLOAD_NVIDIA_DRIVERS=0
KLDLOAD_WIREGUARD=0
KLDLOAD_ENABLE_KVM=$([[ "$PROFILE" == "kvm" ]] && echo 1 || echo 0)
KLDLOAD_TIMEZONE=UTC
EOF

# scp without sshpass falls back to pubkey auth (no key installed in the
# live ISO) and fails silently. Bug seen 2026-05-05 on fiend's CI run.
sshpass -p live scp "${SSH_OPTS[@]}" "$ANSWERS" "live@${VM_IP}:/tmp/answers.env" >>"$LOG" 2>&1 \
  || fail "couldn't scp answers to live env"
ok "answers staged → /tmp/answers.env"

# ── Drive the installer headlessly ───────────────────────────────────────────
log "starting headless install (15-25 min typical)"
# `setsid` so the install survives our SSH disconnect; `nohup` belt-and-suspenders.
ssh_live 'sudo bash -c "setsid nohup /usr/sbin/kldload-install-target --config /tmp/answers.env >/tmp/install.log 2>&1 </dev/null &"' \
  || fail "couldn't kick off installer"

# Poll until the install-target process exits. Ceiling 60 min.
for i in $(seq 1 360); do
  sleep 10
  # Anchor on the full path so pgrep doesn't match its own SSH session.
  # Bug seen 2026-05-06: `pgrep -f kldload-install-target` matched the
  # parent bash invoked by sshd (whose cmdline contained the pattern as
  # a literal arg), so the loop never saw the install exit and ran out
  # the 60-min ceiling instead. Real install cmdline starts with the
  # absolute path; SSH session's cmdline does not.
  if ! ssh_live 'pgrep -f /usr/sbin/kldload-install-target >/dev/null' 2>/dev/null; then
    if ssh_live 'sudo grep -q "Install completed successfully" /var/log/installer/kldload-installer.log 2>/dev/null' 2>/dev/null; then
      ok "install completed (after ~$((i*10/60)) min)"
      break
    else
      log "installer exited without success marker — last 40 lines:"
      ssh_live 'sudo tail -40 /var/log/installer/kldload-installer.log /var/log/installer/bootstrap.log 2>/dev/null' \
        | tee -a "$LOG" || true
      # Auto-bundle the live env's state so the failure is debuggable
      # without ssh'ing back in. The tool ships in the live ISO itself,
      # so it's available even before the install completes.
      log "running kldload-debug-bundle on the live env"
      if ssh_live 'sudo kldload-debug-bundle --quiet --out /tmp >/dev/null 2>&1'; then
        local _bundle
        _bundle="$(ssh_live 'ls -t /tmp/kldload-debug-*.tar.gz 2>/dev/null | head -1')"
        if [[ -n "$_bundle" ]]; then
          sshpass -p live scp "${SSH_OPTS[@]}" "live@${VM_IP}:${_bundle}" "/tmp/" >>"$LOG" 2>&1 \
            && ok "debug bundle saved → /tmp/$(basename "$_bundle")"
        fi
      fi
      fail "installer aborted"
    fi
  fi
  [[ $((i % 6)) -eq 0 ]] && log "  install still running ($((i*10/60)) min elapsed)"
done

# ── Reboot into the installed target ─────────────────────────────────────────
log "shutting down VM, switching boot order to disk-first, restarting"
virsh shutdown "$VM_NAME" >>"$LOG" 2>&1 || true
# Wait for graceful shutdown; force after 30s.
for _ in $(seq 1 6); do
  sleep 5
  virsh domstate "$VM_NAME" 2>/dev/null | grep -q 'shut off' && break
done
virsh destroy "$VM_NAME" >>"$LOG" 2>&1 || true

# Set boot order to hd-first; the CDROM stays attached but ignored.
virt-xml "$VM_NAME" --edit --boot hd,cdrom >>"$LOG" 2>&1 \
  || log "  (warning) virt-xml --boot hd,cdrom failed — VM may re-boot from ISO"
virsh start "$VM_NAME" >>"$LOG" 2>&1 || fail "VM didn't restart after shutdown"

log "waiting for installed-target sshd"
VM_IP_NEW="$(wait_for_ssh admin admin 180)" \
  || fail "installed system never came up — VNC: $(virsh vncdisplay "$VM_NAME" 2>/dev/null || echo n/a)"
ok "installed target up at $VM_IP_NEW"

ssh_admin() { sshpass -p admin ssh "${SSH_OPTS[@]}" "admin@${VM_IP_NEW}" "$@"; }

# ── Upload + run the existing post-install smoke suite ───────────────────────
log "uploading tests/ to installed target"
sshpass -p admin scp "${SSH_OPTS[@]}" -r "$ROOT/tests" "admin@${VM_IP_NEW}:/tmp/" >>"$LOG" 2>&1 \
  || fail "couldn't upload tests/ to installed target"

log "running smoke-auto.sh on the installed target"
if ssh_admin 'sudo bash /tmp/tests/smoke-auto.sh' 2>&1 | tee -a "$LOG"; then
  ok "smoke-auto passed"
else
  fail "smoke-auto reported failures (full log: $LOG)"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
if [[ -n "${KEEP_VM:-}" ]]; then
  log "KEEP_VM set — leaving $VM_NAME running at $VM_IP_NEW"
  log "  ssh: sshpass -p admin ssh admin@${VM_IP_NEW}"
  log "  destroy: virsh destroy $VM_NAME && virsh undefine $VM_NAME --nvram --remove-all-storage"
else
  log "tearing down $VM_NAME"
  virsh destroy "$VM_NAME"  >/dev/null 2>&1 || true
  virsh undefine "$VM_NAME" --nvram --remove-all-storage >/dev/null 2>&1 || true
  rm -f "$DISK" "$ANSWERS"
fi

ok "lifecycle smoke test PASSED for ${DISTRO}/${PROFILE}"
log "log: $LOG"
trap - EXIT
