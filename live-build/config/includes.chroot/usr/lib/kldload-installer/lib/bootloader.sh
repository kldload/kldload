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
    k_log "hostid already exists: $(xxd -p "${target}/etc/hostid" 2>/dev/null)"
    return 0
  fi

  # Try zgenhostid inside chroot first (ZFS provides this)
  if chroot "${target}" command -v zgenhostid >/dev/null 2>&1; then
    chroot "${target}" zgenhostid -f >&"${log_fd}" 2>&1 || true
  fi

  # Fallback: copy from live environment or generate random
  if [[ ! -s "${target}/etc/hostid" ]]; then
    if [[ -s /etc/hostid ]]; then
      cp -f /etc/hostid "${target}/etc/hostid"
    else
      # Generate a stable 4-byte hostid from /dev/urandom
      python3 -c "
import os, struct
hid = struct.unpack('<I', os.urandom(4))[0] or 1  # never zero
with open('${target}/etc/hostid', 'wb') as f:
    f.write(struct.pack('<I', hid))
" 2>&"${log_fd}" || \
        dd if=/dev/urandom of="${target}/etc/hostid" bs=4 count=1 status=none 2>&"${log_fd}" || true
    fi
  fi

  # Final safety check — hostid MUST exist for ZFS pool imports
  if [[ ! -s "${target}/etc/hostid" ]]; then
    k_log "CRITICAL: Failed to generate /etc/hostid — creating from /dev/urandom"
    head -c4 /dev/urandom > "${target}/etc/hostid" 2>/dev/null || true
  fi

  chmod 0644 "${target}/etc/hostid" || true
  k_log "hostid written: $(xxd -p "${target}/etc/hostid" 2>/dev/null)"
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
  # ── Install grubx64.efi (shim's second stage) ────────────────────────────
  #
  # Shim loads grubx64.efi as its second stage and verifies it against:
  #   1. Secure Boot db (Microsoft/distro CA)
  #   2. Shim's built-in certificate
  #   3. MOK database (enrolled by user)
  #
  # With MOK: install MOK-signed ZFSBootMenu directly AS grubx64.efi.
  #   Chain: shim → ZFSBootMenu (as grubx64.efi, MOK-verified) → kernel
  #   This is the cleanest path — no GRUB middleman, no chainloader.
  #   GRUB's chainloader command calls firmware LoadImage() which does NOT
  #   check MOK, causing "security violation" errors with Secure Boot.
  #
  # Without MOK: install distro-signed GRUB as grubx64.efi with a config
  #   that chainloads ZFSBootMenu from \EFI\zbm\. This only works without
  #   Secure Boot (unsigned ZFSBootMenu can't be verified).

  local _zbm_signed="${zbm_efi_dir}/BOOTX64.EFI"
  local _zbm_is_signed=0
  if [[ -f "$mok_key" && -f "$mok_pub" ]] && command -v sbverify >/dev/null 2>&1; then
    sbverify --cert "$mok_pub" "$_zbm_signed" >&7 2>&1 && _zbm_is_signed=1
  fi

  if [[ "$_zbm_is_signed" -eq 1 ]]; then
    # MOK-signed ZFSBootMenu — install as grubx64.efi so shim loads it directly.
    # Shim verifies against MOK → no GRUB chainloader needed → no security violation.
    cp "$_zbm_signed" "${zbm_fallback_dir}/grubx64.efi"
    cp "$_zbm_signed" "${zbm_efi_dir}/grubx64.efi"
    k_log "MOK-signed ZFSBootMenu installed as grubx64.efi (shim → ZFSBootMenu direct, Secure Boot ready)"

    # Also install distro-signed GRUB as a recovery option at \EFI\zbm\grub-recovery.efi
    for _sg in "${target}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
               "${target}/boot/efi/EFI/centos/grubx64.efi" \
               "${target}/boot/efi/EFI/rocky/grubx64.efi" \
               "${target}/boot/efi/EFI/fedora/grubx64.efi" \
               "${target}/boot/efi/EFI/redhat/grubx64.efi"; do
      if [[ -f "$_sg" ]]; then
        cp "$_sg" "${zbm_efi_dir}/grub-recovery.efi"
        k_log "Distro-signed GRUB saved as recovery: ${zbm_efi_dir}/grub-recovery.efi"
        break
      fi
    done
  else
    # No MOK signing — fall back to distro-signed GRUB with chainloader config.
    # This only works without Secure Boot (GRUB chainloader can't verify MOK-signed binaries).
    k_log "ZFSBootMenu is unsigned — using GRUB chainloader (Secure Boot requires MOK signing)"
    local signed_grub=""
    for _sg in "${target}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
               "${target}/boot/efi/EFI/centos/grubx64.efi" \
               "${target}/boot/efi/EFI/rocky/grubx64.efi" \
               "${target}/boot/efi/EFI/fedora/grubx64.efi" \
               "${target}/boot/efi/EFI/redhat/grubx64.efi"; do
      if [[ -f "$_sg" ]]; then signed_grub="$_sg"; break; fi
    done

    if [[ -n "$signed_grub" ]]; then
      cp "$signed_grub" "${zbm_efi_dir}/grubx64.efi"
      cp "$signed_grub" "${zbm_fallback_dir}/grubx64.efi"
      k_log "Distro-signed GRUB installed as grubx64.efi (source: ${signed_grub})"
    else
      cp "${zbm_efi_dir}/BOOTX64.EFI" "${zbm_efi_dir}/grubx64.efi"
      cp "${zbm_efi_dir}/BOOTX64.EFI" "${zbm_fallback_dir}/grubx64.efi"
      k_log "WARNING: No distro-signed GRUB found — ZFSBootMenu used as grubx64.efi"
    fi

    # GRUB chainloader config — written to all paths GRUB might search.
    local _efi_fs_uuid
    _efi_fs_uuid="$(blkid -s UUID -o value "${efi_part}" 2>/dev/null || true)"
    for _gcfg_dir in "${zbm_efi_dir}/grub" "${zbm_fallback_dir}/grub" \
                     "${zbm_efi_dir}" "${zbm_fallback_dir}" \
                     "${target}/boot/efi/grub" "${target}/boot/grub" \
                     "${target}/boot/efi/EFI/centos" "${target}/boot/efi/EFI/rocky" \
                     "${target}/boot/efi/EFI/fedora" "${target}/boot/efi/EFI/redhat" \
                     "${target}/boot/efi/EFI/debian" \
                     "${target}/boot/efi/EFI/ubuntu"; do
      [[ -d "$(dirname "$_gcfg_dir")" ]] || continue
      mkdir -p "$_gcfg_dir" 2>/dev/null || true
      cat > "${_gcfg_dir}/grub.cfg" <<CHAINGRUB
search --no-floppy --fs-uuid --set=root ${_efi_fs_uuid}
set timeout=1
menuentry "ZFSBootMenu" {
    chainloader /EFI/zbm/BOOTX64.EFI
}
CHAINGRUB
    done
    k_log "GRUB chainloader config installed (EFI UUID: ${_efi_fs_uuid})"
  fi

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
            "${target}/boot/efi/EFI/redhat/shimx64.efi" \
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
               "${target}/boot/efi/EFI/redhat/mmx64.efi" \
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
    # Verify zfs-dracut is installed — without it, dracut --add "zfs" silently
    # produces an initramfs that can't import ZFS pools, causing a boot loop.
    if [[ ! -d "${target}/usr/lib/dracut/modules.d/90zfs" ]]; then
      k_log "WARNING: dracut ZFS module (90zfs) not found — attempting zfs-dracut install"
      # Try host-side dnf first (has network), fall back to chroot dnf
      dnf --installroot="${target}" --releasever="$(rpm -q --qf '%{VERSION}' centos-stream-release 2>/dev/null || echo 9)" \
        --nogpgcheck --skip-broken -y install zfs-dracut >&7 2>&1 || \
        chroot "${target}" dnf install -y --nogpgcheck zfs-dracut >&7 2>&1 || \
        k_log "CRITICAL: zfs-dracut install failed — system may not boot from ZFS"
    fi
    local _kver
    for _kver in "${target}"/usr/lib/modules/*/vmlinuz "${target}"/lib/modules/*/vmlinuz; do
      [[ -f "$_kver" ]] || continue
      _kver="$(basename "$(dirname "$_kver")")"
      chroot "${target}" dracut --force --add "zfs" --kver "$_kver" >&7 2>&1 || \
        k_log "WARNING: dracut rebuild failed for ${_kver}"
    done
    # Verify ZFS made it into the initramfs
    if ! chroot "${target}" lsinitrd "/boot/initramfs-$(ls "${target}"/usr/lib/modules/ 2>/dev/null | head -1).img" 2>/dev/null | grep -q '90zfs'; then
      k_log "WARNING: ZFS module may not be in initramfs — check bootloader.log"
    fi
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
    #
    # Pattern includes "Red Hat" (with space) because RHEL's efibootmgr entry
    # is "Red Hat Enterprise Linux" or "RedHat Boot Manager", not "RedHat".
    local _efi_uuid
    _efi_uuid=$(blkid -s PARTUUID -o value "${efi_part}" 2>/dev/null || true)
    k_log "Cleaning EFI boot entries for target disk: ${disk} (PARTUUID: ${_efi_uuid:-unknown})"
    efibootmgr -v 2>/dev/null | grep '^Boot[0-9A-Fa-f]' | while read -r _line; do
      local _bnum
      _bnum=$(echo "$_line" | grep -oP 'Boot\K[0-9A-Fa-f]+')
      if echo "$_line" | grep -qi "ZFSBootMenu\|kldload\|Red.Hat\|RedHat\|centos\|rocky\|fedora\|debian\|ubuntu\|UEFI OS\|${disk##*/}\|${_efi_uuid:-NOMATCH}"; then
        efibootmgr -b "${_bnum}" -B >&7 2>&1 || true
        k_log "  Removed Boot${_bnum}: $(echo "$_line" | sed 's/Boot[0-9A-Fa-f]*.//')"
      fi
    done || true

    # Remove BOOTX64.CSV files from distro EFI directories. These files tell
    # the UEFI firmware to auto-create boot entries on every boot, which
    # re-creates the distro entry we just deleted and overrides our boot order.
    for _csv in "${target}/boot/efi/EFI"/*/BOOTX64.CSV; do
      [[ -f "$_csv" ]] || continue
      k_log "  Removing firmware auto-discovery file: ${_csv}"
      rm -f "$_csv"
    done

    # Remove fbx64.efi (RHEL's fallback boot manager). This EFI binary reads
    # BOOTX64.CSV files and re-creates distro boot entries, which overrides
    # our boot order. With CSV files removed above, fbx64 is harmless but some
    # firmware (ASUS, Dell) runs it proactively on boot — remove to be safe.
    if [[ -f "${target}/boot/efi/EFI/BOOT/fbx64.efi" ]]; then
      rm -f "${target}/boot/efi/EFI/BOOT/fbx64.efi"
      k_log "  Removed fbx64.efi (RHEL fallback boot manager)"
    fi

    # Always create a fresh "kldload" boot entry pointing to shim.
    # Chain: firmware → shim → signed GRUB → chainloader → ZFSBootMenu
    efibootmgr \
      -c -d "${disk}" -p "${part_num}" \
      -L "kldload" \
      -l '\EFI\BOOT\BOOTX64.EFI' >&7 2>&1 || \
      k_log "WARNING: efibootmgr entry creation failed"

    local _uefi_bootnum
    _uefi_bootnum=$(efibootmgr 2>/dev/null | grep -i 'kldload' | head -1 | grep -oP 'Boot\K[0-9A-Fa-f]+' || true)
    if [[ -n "$_uefi_bootnum" ]]; then
      efibootmgr -o "${_uefi_bootnum}" >&7 2>&1 || \
        k_log "WARNING: Could not set boot order"
      k_log "Boot order set: ${_uefi_bootnum} (shim → signed GRUB → ZFSBootMenu)"
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
