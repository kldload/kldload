#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# bootloader.sh — ZFSBootMenu EFI installation with Secure Boot support
# ═══════════════════════════════════════════════════════════════════════════════
#
# Sourced by kldload-install-target. Provides:
#   k_install_bootloader  — main entry: EFI install, initramfs, efibootmgr
#   k_finalize_bootloader — cleanup: unbind chroot, export ZFS pools
#
# SECURE BOOT CHAIN:
#   UEFI firmware (Microsoft CA)
#     → shimx64.efi (Microsoft-signed, ships with distro)
#       → MokManager (mmx64.efi) — first-boot enrollment blue screen
#         → MOK key (generated during install, stored at /var/lib/dkms/mok.*)
#           → ZFSBootMenu EFI (signed with MOK key via sbsign)
#           → ZFS kernel modules (signed with MOK key via DKMS sign_tool)
#
# Without Secure Boot: ZFSBootMenu loads directly, no shim, no MOK.
# With Secure Boot:    shim validates MOK → MOK validates ZFSBootMenu + ZFS.
#
# ENTERPRISE: Replace /var/lib/dkms/mok.{key,pub,der} with corporate signing
# keys before install. The same chain works with any RSA-2048+ key pair.
#
# EFI LAYOUT ON TARGET:
#   /boot/efi/EFI/BOOT/BOOTX64.EFI  — shimx64 (or ZFSBootMenu if no shim)
#   /boot/efi/EFI/BOOT/mmx64.efi    — MokManager (Secure Boot enrollment UI)
#   /boot/efi/EFI/zbm/BOOTX64.EFI   — ZFSBootMenu (MOK-signed if sbsign available)
#   /boot/efi/EFI/zbm/BOOTX64-BACKUP.EFI — unsigned backup copy
#   /boot/efi/EFI/zbm/mmx64.efi     — MokManager copy
#
# BOOT ORDER (registered via efibootmgr):
#   1. "ZFSBootMenu"        → \EFI\zbm\BOOTX64.EFI
#   2. "ZFSBootMenu (Backup)" → \EFI\zbm\BOOTX64-BACKUP.EFI
#   3. UEFI fallback         → \EFI\BOOT\BOOTX64.EFI (shim)
#
# ═══════════════════════════════════════════════════════════════════════════════
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

  k_log "Installing bootloader"
  k_log "  target:   ${target}"
  k_log "  efi_part: ${efi_part}"
  k_log "  root_ds:  ${root_ds}"

  # ── FreeBSD: loader.efi (native ZFS boot — no ZFSBootMenu) ──────────────

  if [[ "${KLDLOAD_DISTRO:-}" == "freebsd" || "${KLDLOAD_DISTRO:-}" == "ghostbsd" ]]; then
    k_log "FreeBSD bootloader: loader.efi (native ZFS boot)"

    # loader.efi is already copied by bootstrap — verify it's in place
    local fbsd_efi_dir="${target}/boot/efi/EFI/BOOT"
    mkdir -p "${fbsd_efi_dir}"
    if [[ -f "${target}/boot/loader.efi" ]]; then
      cp "${target}/boot/loader.efi" "${fbsd_efi_dir}/BOOTX64.EFI"
      k_log "loader.efi installed to ${fbsd_efi_dir}/BOOTX64.EFI"
    else
      k_log "WARNING: loader.efi not found in ${target}/boot/"
    fi

    # startup.nsh for exported images
    echo '\EFI\BOOT\BOOTX64.EFI' > "${target}/boot/efi/startup.nsh"

    # FreeBSD fstab — no EFI automount (loader handles it)
    cat > "${target}/etc/fstab" <<EOFSTAB
# FreeBSD ZFS root — datasets are mounted by loader.efi and zfs
# EFI partition is not auto-mounted (loader.efi reads it directly)
EOFSTAB

    # zpool.cache
    mkdir -p "${target}/etc/zfs"
    if command -v zpool >/dev/null 2>&1; then
      zpool set cachefile="${target}/etc/zfs/zpool.cache" rpool >&7 2>&1 || true
      k_log "zpool.cache written"
    fi

    # hostid
    k_zfs_bootloader_write_hostid "${target}" 7

    # Register with efibootmgr (from the Linux live env)
    local disk
    disk="$(lsblk -no PKNAME "${efi_part}" 2>/dev/null | head -n1 || true)"
    [[ -n "$disk" ]] && disk="/dev/$disk"
    local part_num
    part_num="$(lsblk -no PARTN "${efi_part}" 2>/dev/null | head -n1 || true)"
    part_num="${part_num:-1}"

    if [[ -n "${disk}" && -b "${disk}" ]]; then
      efibootmgr \
        -c -d "${disk}" -p "${part_num}" \
        -L "FreeBSD" \
        -l '\EFI\BOOT\BOOTX64.EFI' >&7 2>&1 || \
        k_log "WARNING: efibootmgr registration failed"
      k_log "EFI boot entry registered: FreeBSD on ${disk}"
    fi

    k_log "FreeBSD bootloader complete (loader.efi + ZFS native)"
    return 0
  fi

  # ── OpenBSD: separate boot path (no ZFS) ─────────────────────────────────

  if [[ "${KLDLOAD_DISTRO:-}" == "openbsd" ]]; then
    k_log "OpenBSD bootloader: BOOTX64.EFI"

    # OpenBSD's BOOTX64.EFI is in the base set at /usr/mdec/BOOTX64.EFI
    local obsd_efi_dir="${target}/boot/efi/EFI/BOOT"
    mkdir -p "${obsd_efi_dir}"
    if [[ -f "${target}/usr/mdec/BOOTX64.EFI" ]]; then
      cp "${target}/usr/mdec/BOOTX64.EFI" "${obsd_efi_dir}/BOOTX64.EFI"
      k_log "OpenBSD BOOTX64.EFI installed"
    else
      k_log "WARNING: OpenBSD BOOTX64.EFI not found in ${target}/usr/mdec/"
    fi

    # OpenBSD fstab — FFS root
    local efi_uuid
    efi_uuid="$(blkid -s UUID -o value "${efi_part}" 2>/dev/null || true)"
    cat > "${target}/etc/fstab" <<EOFSTAB
# OpenBSD — root filesystem is FFS on the target disk
# EFI partition is not auto-mounted
EOFSTAB

    # Register with efibootmgr
    local disk
    disk="$(lsblk -no PKNAME "${efi_part}" 2>/dev/null | head -n1 || true)"
    [[ -n "$disk" ]] && disk="/dev/$disk"
    local part_num
    part_num="$(lsblk -no PARTN "${efi_part}" 2>/dev/null | head -n1 || true)"
    part_num="${part_num:-1}"

    if [[ -n "${disk}" && -b "${disk}" ]]; then
      efibootmgr \
        -c -d "${disk}" -p "${part_num}" \
        -L "OpenBSD" \
        -l '\EFI\BOOT\BOOTX64.EFI' >&7 2>&1 || \
        k_log "WARNING: efibootmgr registration failed"
      k_log "EFI boot entry registered: OpenBSD on ${disk}"
    fi

    k_log "OpenBSD bootloader complete"
    return 0
  fi

  # ── Linux: ZFSBootMenu (all Linux distros) ───────────────────────────────

  # ── Locate ZFSBootMenu EFI binary ────────────────────────────────────────

  local zbm_src
  zbm_src="$(k_zbm_find_efi)" || k_die "ZFSBootMenu EFI binary not available"

  local zbm_efi_dir="${target}/boot/efi/EFI/zbm"
  local zbm_fallback_dir="${target}/boot/efi/EFI/BOOT"
  mkdir -p "${zbm_efi_dir}" "${zbm_fallback_dir}"

  # ── Sign ZFSBootMenu with MOK key (Secure Boot) ────────────────────────
  # If MOK keys were generated during install (by k_generate_mok_keys in
  # bootstrap.sh) and sbsign is available on the live ISO, we sign the
  # ZFSBootMenu EFI binary. This allows shim to verify it via the MOK
  # keyring after the user enrolls the key on first boot.
  #
  # If sbsign isn't available or MOK keys don't exist, ZFSBootMenu is
  # installed unsigned — it will still boot without Secure Boot, or via
  # shim if the user manually enrolls the key later.
  local mok_key="${target}/var/lib/dkms/mok.key"
  local mok_pub="${target}/var/lib/dkms/mok.pub"

  if [[ -f "$mok_key" && -f "$mok_pub" ]] && command -v sbsign >/dev/null 2>&1; then
    k_log "Signing ZFSBootMenu EFI with MOK key (Secure Boot)..."
    sbsign --key "$mok_key" --cert "$mok_pub" \
      --output "${zbm_efi_dir}/BOOTX64.EFI" "$zbm_src" >&7 2>&1 && \
      k_log "ZFSBootMenu EFI signed with MOK key" || {
        k_log "WARNING: sbsign failed — installing unsigned ZFSBootMenu"
        cp "${zbm_src}" "${zbm_efi_dir}/BOOTX64.EFI"
      }
  else
    cp "${zbm_src}" "${zbm_efi_dir}/BOOTX64.EFI"
    k_log "ZFSBootMenu EFI installed (unsigned — no sbsign or no MOK keys)"
  fi
  # Shim expects to chain-load "grubx64.efi" in the same directory.
  # Copy ZFSBootMenu (signed or unsigned) as grubx64.efi so shim finds it.
  cp "${zbm_efi_dir}/BOOTX64.EFI" "${zbm_efi_dir}/grubx64.efi"
  cp "${zbm_efi_dir}/BOOTX64.EFI" "${zbm_fallback_dir}/grubx64.efi"
  k_log "ZFSBootMenu copied as grubx64.efi for shim chain-loading"

  # Backup copy is always unsigned — used if the signed copy is corrupted.
  # The user can manually re-sign it with: sbsign --key mok.key --cert mok.pub ...
  cp "${zbm_src}" "${zbm_efi_dir}/BOOTX64-BACKUP.EFI"

  # ── Install shim as UEFI fallback bootloader ──────────────────────────
  # Secure Boot requires all EFI binaries to be signed. The UEFI firmware
  # only trusts Microsoft's CA. shimx64.efi is signed by Microsoft and
  # acts as the bridge — it trusts our MOK key, which trusts ZFSBootMenu.
  #
  # The fallback path \EFI\BOOT\BOOTX64.EFI is what UEFI firmware loads
  # when no specific boot entry is found (e.g. new disk, reset NVRAM).
  # We put shim there so Secure Boot works even without efibootmgr entries.
  #
  # Search order: distro-specific shim → Debian signed shim → existing fallback
  # CentOS: /boot/efi/EFI/centos/shimx64.efi (installed by shim-x64 RPM)
  # Debian: /usr/lib/shim/shimx64.efi.signed  (installed by shim-signed deb)
  local shim_src=""
  for _s in "${target}/boot/efi/EFI/centos/shimx64.efi" \
            "${target}/boot/efi/EFI/rocky/shimx64.efi" \
            "${target}/boot/efi/EFI/fedora/shimx64.efi" \
            "${target}/boot/efi/EFI/debian/shimx64.efi" \
            "${target}/boot/efi/EFI/ubuntu/shimx64.efi" \
            "${target}/usr/lib/shim/shimx64.efi.signed"; do
    if [[ -f "$_s" ]]; then shim_src="$_s"; break; fi
  done

  if [[ -n "$shim_src" ]]; then
    cp "$shim_src" "${zbm_fallback_dir}/BOOTX64.EFI"
    k_log "Shim installed as UEFI fallback: ${zbm_fallback_dir}/BOOTX64.EFI (source: ${shim_src})"

    # MokManager (mmx64.efi) — the blue screen UI that appears on first boot
    # to let the user enroll the MOK key. Must be in the same directory as shim
    # AND in the ZBM directory (shim searches both).
    for _mm in "${target}/boot/efi/EFI/centos/mmx64.efi" \
               "${target}/boot/efi/EFI/rocky/mmx64.efi" \
               "${target}/boot/efi/EFI/fedora/mmx64.efi" \
               "${target}/boot/efi/EFI/debian/mmx64.efi" \
               "${target}/boot/efi/EFI/ubuntu/mmx64.efi" \
               "${target}/usr/lib/shim/mmx64.efi"; do
      if [[ -f "$_mm" ]]; then
        cp "$_mm" "${zbm_fallback_dir}/mmx64.efi"
        cp "$_mm" "${zbm_efi_dir}/mmx64.efi"
        k_log "MokManager (mmx64.efi) installed for first-boot key enrollment"
        break
      fi
    done

    # Copy MOK DER certificate to EFI partition for "Enroll key from disk" option
    # in MokManager. This lets the user select the file visually instead of
    # entering a password — simpler for demos and enterprise deployments.
    if [[ -f "${target}/var/lib/dkms/mok.der" ]]; then
      cp "${target}/var/lib/dkms/mok.der" "${zbm_efi_dir}/mok.der"
      cp "${target}/var/lib/dkms/mok.der" "${zbm_fallback_dir}/mok.der"
      k_log "MOK certificate (mok.der) copied to EFI partition for enrollment from disk"
    fi
  else
    # No shim found — install ZFSBootMenu directly as the fallback.
    # This works without Secure Boot but will fail with Secure Boot enabled
    # unless the user manually disables it or enrolls via other means.
    cp "${zbm_src}" "${zbm_fallback_dir}/BOOTX64.EFI"
    k_log "WARNING: No shim found — ZFSBootMenu installed unsigned as fallback"
    k_log "  Secure Boot will block this. Install shim-x64 (RPM) or shim-signed (deb)."
  fi

  # startup.nsh — UEFI shell auto-runs this if no boot entries exist (exported images)
  echo '\EFI\BOOT\BOOTX64.EFI' > "${target}/boot/efi/startup.nsh"
  k_log "startup.nsh written for exported image boot support"

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

  if [[ -x "${target}/usr/bin/update-initramfs" ]]; then
    chroot "${target}" update-initramfs -c -k all >&7 2>&1 || \
      chroot "${target}" update-initramfs -u -k all >&7 2>&1 || \
      k_log "WARNING: update-initramfs had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
  elif [[ -x "${target}/usr/bin/mkinitcpio" ]]; then
    # Arch Linux uses mkinitcpio — rebuild all presets
    k_log "Rebuilding initramfs with mkinitcpio..."
    chroot "${target}" mkinitcpio -P >&7 2>&1 || \
      k_log "WARNING: mkinitcpio had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
  elif [[ -x "${target}/sbin/mkinitfs" ]]; then
    # Alpine Linux uses mkinitfs
    k_log "Rebuilding initramfs with mkinitfs..."
    local _akver
    _akver=$(ls "${target}/lib/modules/" 2>/dev/null | grep lts | head -1)
    [[ -z "$_akver" ]] && _akver=$(ls "${target}/lib/modules/" 2>/dev/null | grep -v '^$' | head -1)
    if [[ -n "$_akver" ]]; then
      chroot "${target}" mkinitfs -k "$_akver" >&7 2>&1 || \
        k_log "WARNING: mkinitfs had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
    fi
  elif [[ -x "${target}/usr/bin/dracut" ]]; then
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
    # Remove ALL existing boot entries that point to the target disk.
    # This ensures stale entries (old OS installs, disconnected drives, etc.)
    # don't interfere with ZFSBootMenu booting. Only entries on OTHER disks
    # (e.g. USB boot media) are preserved.
    local _target_disk_id
    _target_disk_id=$(lsblk -dno SERIAL,MODEL "${disk}" 2>/dev/null | tr -s ' ' | head -1)
    k_log "Cleaning EFI boot entries for target disk: ${disk}"
    efibootmgr -v 2>/dev/null | grep '^Boot[0-9A-Fa-f]' | while read -r _line; do
      local _bnum
      _bnum=$(echo "$_line" | grep -oP 'Boot\K[0-9A-Fa-f]+')
      # Remove entries that reference the target disk's GPT UUID or are stale
      local _efi_uuid
      _efi_uuid=$(blkid -s PARTUUID -o value "${efi_part}" 2>/dev/null || true)
      if echo "$_line" | grep -qi "ZFSBootMenu\|${disk##*/}\|${_efi_uuid:-NOMATCH}"; then
        efibootmgr -b "${_bnum}" -B >&7 2>&1 || true
        k_log "  Removed Boot${_bnum}: $(echo "$_line" | sed 's/Boot[0-9A-Fa-f]*.//')"
      fi
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

    # Set the new ZFSBootMenu entry as first in boot order
    local _zbm_bootnum
    _zbm_bootnum=$(efibootmgr 2>/dev/null | grep -i 'ZFSBootMenu' | grep -v 'Backup' | head -1 | grep -oP 'Boot\K[0-9A-Fa-f]+')
    if [[ -n "$_zbm_bootnum" ]]; then
      local _current_order
      _current_order=$(efibootmgr 2>/dev/null | grep '^BootOrder:' | sed 's/BootOrder: //')
      # Put ZFSBootMenu first, keep the rest
      local _new_order="${_zbm_bootnum}"
      for _entry in ${_current_order//,/ }; do
        [[ "$_entry" != "$_zbm_bootnum" ]] && _new_order="${_new_order},${_entry}"
      done
      efibootmgr -o "${_new_order}" >&7 2>&1 || \
        k_log "WARNING: Could not set boot order"
      k_log "Boot order set: ${_new_order} (ZFSBootMenu first)"
    fi

    k_log "EFI boot entries registered: disk=${disk} part=${part_num}"
  else
    k_log "WARNING: Could not determine disk for efibootmgr — skipping EFI registration"
  fi

  # ── MOK enrollment queue (if configured) ─────────────────────────────────

  if declare -F k_configure_mok >/dev/null 2>&1; then
    k_configure_mok
  fi

  k_log "Bootloader EFI + initramfs + efibootmgr complete (ZFSBootMenu)"
}

# k_finalize_bootloader — unbind chroot, export pools. Call AFTER image export.
k_finalize_bootloader() {
  : "${KLDLOAD_TARGET_MNT:=/target}"
  : "${KLDLOAD_LOG_DIR:=/var/log/installer}"
  local target="${KLDLOAD_TARGET_MNT}"

  exec 7>>"${KLDLOAD_LOG_DIR}/bootloader.log"

  # ── Unbind chroot mounts BEFORE pool export ───────────────────────────────
  if declare -F k_unbind_chroot_mounts >/dev/null 2>&1; then
    k_unbind_chroot_mounts
    k_log "Chroot mounts unbound"
  fi

  # ── Export pools cleanly ──────────────────────────────────────────────────
  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    k_finalize_zfs_pools "${target}" 7
  fi

  k_log "Bootloader finalization complete"
}
