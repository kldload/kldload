#!/usr/bin/env bash
# Sourced by kldload-install-target — k_install_bootloader (ZFSBootMenu EFI, fstab, zpool.cache)
set -Eeuo pipefail

# k_zfs_bootloader_write_hostid — ensure target has a stable, unique hostid.
# ZFS requires a consistent hostid across reboots or pool imports will fail.
k_zfs_bootloader_write_hostid() {
  local target="${1:?}"
  local log_fd="${2:?}"

  mkdir -p "${target}/etc"

  if [[ -s "${target}/etc/hostid" ]]; then
    chmod 0644 "${target}/etc/hostid" || true
    return 0
  fi

  if chroot "${target}" command -v zgenhostid >/dev/null 2>&1; then
    chroot "${target}" zgenhostid -f >&"${log_fd}" 2>&1 || true
  fi

  if [[ ! -s "${target}/etc/hostid" ]]; then
    if [[ -s /etc/hostid ]]; then
      cp -f /etc/hostid "${target}/etc/hostid"
    else
      dd if=/dev/urandom of="${target}/etc/hostid" bs=4 count=1 status=none
    fi
  fi

  chmod 0644 "${target}/etc/hostid" || true
}

# k_zbm_find_efi — locate the ZFSBootMenu EFI binary.
# Checks the baked-in darksite first, then falls back to downloading.
k_zbm_find_efi() {
  local candidates=(
    "/root/darksite/boot/zfsbootmenu.EFI"
    "/root/darksite/boot/zfsbootmenu.efi"
  )

  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done

  # Not in darksite — download on demand
  local zbm_tmp="/tmp/zfsbootmenu.EFI"
  if [[ ! -f "$zbm_tmp" ]]; then
    k_log "ZFSBootMenu EFI not in darksite — downloading..."
    curl -sL --connect-timeout 30 --max-time 300 \
      -o "$zbm_tmp" "https://get.zfsbootmenu.org/efi" || {
      k_log "ERROR: Failed to download ZFSBootMenu EFI binary"
      return 1
    }
  fi
  echo "$zbm_tmp"
}

k_finalize_zfs_pools() {
  local target="${1:?}"
  local log_fd="${2:?}"

  k_log "Finalizing ZFS pools for clean first boot"

  sync || true

  # Unmount EFI partition
  if mountpoint -q "${target}/boot/efi" 2>/dev/null; then
    umount "${target}/boot/efi" >&"${log_fd}" 2>&1 || true
  fi

  # Unmount ZFS datasets
  zfs unmount -a >&"${log_fd}" 2>&1 || true

  # Update zpool.cache in the target before export
  mkdir -p "${target}/etc/zfs"
  zpool set cachefile="${target}/etc/zfs/zpool.cache" rpool >&"${log_fd}" 2>&1 || true

  # Try to export pool — timeout after 5 seconds if it hangs (live system may hold it)
  timeout 5 zpool export rpool >&"${log_fd}" 2>&1 || \
    k_log "Pool export timed out (live system still using it) — pool will import cleanly on reboot"

  k_log "ZFS pool finalized"
  return 0
}

k_install_bootloader() {
  : "${KLDLOAD_TARGET_MNT:=/target}"
  : "${KLDLOAD_LOG_DIR:=/var/log/installer}"

  local target="${KLDLOAD_TARGET_MNT}"
  local efi_part="${KLDLOAD_EFI_PART:-${KLDLOAD_PART_EFI:-}}"
  local host_short="${KLDLOAD_HOSTNAME:-kldload}"
  local root_ds

  if declare -F k_zfs_root_dataset_name >/dev/null 2>&1; then
    root_ds="$(k_zfs_root_dataset_name "${host_short}")"
  else
    root_ds="rpool/ROOT/${host_short}"
  fi

  mkdir -p "${KLDLOAD_LOG_DIR}"
  : > "${KLDLOAD_LOG_DIR}/bootloader.log"
  exec 7>>"${KLDLOAD_LOG_DIR}/bootloader.log"

  [[ -d "${target}" ]]          || k_die "target mount missing: ${target}"
  [[ -d "${target}/boot/efi" ]] || k_die "EFI mountpoint missing: ${target}/boot/efi"
  [[ -n "${efi_part}" ]]        || k_die "EFI partition variable (KLDLOAD_PART_EFI) is not set"

  k_log "Installing ZFSBootMenu bootloader"
  k_log "  target:   ${target}"
  k_log "  efi_part: ${efi_part}"
  k_log "  root_ds:  ${root_ds}"

  # ── Locate ZFSBootMenu EFI binary ────────────────────────────────────────

  local zbm_src
  zbm_src="$(k_zbm_find_efi)" || k_die "ZFSBootMenu EFI binary not available"

  local zbm_efi_dir="${target}/boot/efi/EFI/zbm"
  mkdir -p "${zbm_efi_dir}"

  cp "${zbm_src}" "${zbm_efi_dir}/BOOTX64.EFI"
  cp "${zbm_src}" "${zbm_efi_dir}/BOOTX64-BACKUP.EFI"
  k_log "ZFSBootMenu EFI installed: ${zbm_efi_dir}/BOOTX64.EFI"

  # Also install to the UEFI fallback path so the firmware finds ZFSBootMenu
  # even if efibootmgr entries are missing or the boot order is reset.
  local zbm_fallback_dir="${target}/boot/efi/EFI/BOOT"
  mkdir -p "${zbm_fallback_dir}"
  cp "${zbm_src}" "${zbm_fallback_dir}/BOOTX64.EFI"
  k_log "ZFSBootMenu EFI fallback installed: ${zbm_fallback_dir}/BOOTX64.EFI"

  # ── Write fstab (ESP only — ZFS mounts are handled by zfs-mount) ─────────

  local efi_uuid
  efi_uuid="$(blkid -s UUID -o value "${efi_part}")"
  [[ -n "${efi_uuid}" ]] || k_die "could not determine EFI UUID for ${efi_part}"

  cat > "${target}/etc/fstab" <<EOFSTAB
# ZFSBootMenu system — ZFS datasets are mounted by the initramfs and zfs-mount.service
# Only the EFI System Partition needs a fstab entry.
UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1
EOFSTAB

  k_log "fstab written (ESP UUID: ${efi_uuid})"

  # ── Bind chroot mounts for initramfs rebuild ──────────────────────────────

  if declare -F k_bind_chroot_mounts >/dev/null 2>&1; then
    k_bind_chroot_mounts
  fi

  # ── Write zpool.cache ─────────────────────────────────────────────────────

  mkdir -p "${target}/etc/zfs"
  if command -v zpool >/dev/null 2>&1; then
    zpool set cachefile="${target}/etc/zfs/zpool.cache" rpool >&7 2>&1 || true
    k_log "zpool.cache written"
  fi

  # ── Write hostid ──────────────────────────────────────────────────────────

  k_zfs_bootloader_write_hostid "${target}" 7

  # ── Enable ZFS systemd services ───────────────────────────────────────────

  for svc in zfs-import-cache.service zfs-mount.service zfs-zed.service \
             zfs.target zfs-import.target; do
    systemctl --root="${target}" enable "${svc}" >&7 2>&1 || true
  done
  k_log "ZFS services enabled"

  # ── Rebuild initramfs (picks up ZFS + hostid) ─────────────────────────────

  if chroot "${target}" command -v update-initramfs >/dev/null 2>&1; then
    chroot "${target}" update-initramfs -c -k all >&7 2>&1 || \
      chroot "${target}" update-initramfs -u -k all >&7 2>&1 || \
      k_log "WARNING: update-initramfs had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
  elif chroot "${target}" command -v dracut >/dev/null 2>&1; then
    local _kver
    for _kver in "${target}"/usr/lib/modules/*/vmlinuz "${target}"/lib/modules/*/vmlinuz; do
      [[ -f "$_kver" ]] || continue
      _kver="$(basename "$(dirname "$_kver")")"
      chroot "${target}" dracut --force --add "zfs" --kver "$_kver" >&7 2>&1 || \
        k_log "WARNING: dracut rebuild failed for ${_kver}"
    done
  else
    k_log "WARNING: no initramfs tool found — check ${KLDLOAD_LOG_DIR}/bootloader.log"
  fi

  k_log "initramfs rebuilt"

  # ── Register ZFSBootMenu with efibootmgr ──────────────────────────────────

  local disk
  disk="$(lsblk -no PKNAME "${efi_part}" 2>/dev/null | head -n1 || true)"
  [[ -n "$disk" ]] && disk="/dev/$disk"

  local part_num
  part_num="$(lsblk -no PARTN "${efi_part}" 2>/dev/null | head -n1 || true)"
  part_num="${part_num:-1}"

  if [[ -n "${disk}" && -b "${disk}" ]]; then
    # Remove any stale ZFSBootMenu entries first
    # grep exits 1 when no entries exist — || true prevents pipefail triggering ERR
    efibootmgr 2>/dev/null | grep -i "ZFSBootMenu" | \
      awk -F'[^0-9]*' '{print $2}' | \
      while read -r boot_num; do
        efibootmgr -b "${boot_num}" -B >&7 2>&1 || true
      done || true

    # Register main and backup entries (backup registered first = lower priority)
    efibootmgr \
      -c -d "${disk}" -p "${part_num}" \
      -L "ZFSBootMenu (Backup)" \
      -l '\EFI\zbm\BOOTX64-BACKUP.EFI' >&7 2>&1 || \
      k_log "WARNING: efibootmgr backup entry failed"

    efibootmgr \
      -c -d "${disk}" -p "${part_num}" \
      -L "ZFSBootMenu" \
      -l '\EFI\zbm\BOOTX64.EFI' >&7 2>&1 || \
      k_log "WARNING: efibootmgr main entry failed"

    k_log "EFI boot entries registered: disk=${disk} part=${part_num}"
  else
    k_log "WARNING: Could not determine disk for efibootmgr — skipping EFI registration"
  fi

  # ── MOK enrollment queue (if configured) ─────────────────────────────────

  if declare -F k_configure_mok >/dev/null 2>&1; then
    k_configure_mok
  fi

  # ── Unbind chroot mounts BEFORE pool export ───────────────────────────────
  # zpool export fails if any process holds file descriptors inside the pool.
  # The bind mounts (dev/proc/sys/run) must be gone before we export rpool.

  if declare -F k_unbind_chroot_mounts >/dev/null 2>&1; then
    k_unbind_chroot_mounts
    k_log "Chroot mounts unbound"
  fi

  # ── Export pools cleanly ──────────────────────────────────────────────────

  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    k_finalize_zfs_pools "${target}" 7
  fi

  k_log "Bootloader installation complete (ZFSBootMenu)"
}
