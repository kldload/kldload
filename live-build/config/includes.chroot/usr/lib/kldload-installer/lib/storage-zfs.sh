#!/usr/bin/env bash
# Sourced by kldload-install-target — k_storage_zfs_install (partitioning, rpool creation, encryption, EFI)
set -Eeuo pipefail

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${LIBDIR}/common.sh"
# shellcheck disable=SC1091
source "${LIBDIR}/logging.sh"

: "${KLDLOAD_TARGET:=/target}"
: "${KLDLOAD_TARGET_MNT:=${KLDLOAD_TARGET}}"
: "${KLDLOAD_DISK:=/dev/sda}"
: "${KLDLOAD_HOSTNAME:=kldload}"
: "${KLDLOAD_LOG_DIR:=/var/log/installer}"
: "${KLDLOAD_ZFS_ENCRYPT:=0}"

# Pool topology — controls how the rpool vdev is built.
#   single        — rpool on KLDLOAD_DISK partition 2 (default; one-disk install)
#   mirror        — rpool mirror across 2 KLDLOAD_ZFS_DATA_DISKS (EFI stays on KLDLOAD_DISK)
#   raidz1        — rpool raidz1 across 3–4 KLDLOAD_ZFS_DATA_DISKS
#   mirror-stripe — rpool RAID10: two mirrored pairs from 4 KLDLOAD_ZFS_DATA_DISKS
: "${KLDLOAD_ZFS_TOPOLOGY:=single}"

# Space-separated block device paths for multi-disk pool vdevs.
# Auto-populated by guided_prompt; must be set manually for --config mode.
: "${KLDLOAD_ZFS_DATA_DISKS:=}"

# Optional special vdev disks (metadata/dedup acceleration).
# If set, a mirrored special vdev is added to rpool after pool creation.
: "${KLDLOAD_ZFS_SPECIAL_DISKS:=}"

KLDLOAD_ZFS_LOG="${KLDLOAD_ZFS_LOG:-${KLDLOAD_LOG_DIR}/zfs.log}"

k_zfs_root_dataset_name() {
  local host="${1:?}"
  echo "rpool/ROOT/${host}"
}

k_zfs_log() {
  mkdir -p "${KLDLOAD_LOG_DIR}"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${KLDLOAD_ZFS_LOG}" >&2
}

k_zfs_disk_prefix() {
  local disk="${1:?}"
  case "${disk}" in
    *nvme*|*mmcblk*) echo "${disk}p" ;;
    *) echo "${disk}" ;;
  esac
}

k_zfs_cleanup_old() {
  k_zfs_log "Cleaning previous mounts/pools on ${KLDLOAD_DISK}"

  sync || true
  swapoff -a || true

  umount -R "${KLDLOAD_TARGET_MNT}/boot/efi" 2>/dev/null || true
  umount -R "${KLDLOAD_TARGET_MNT}" 2>/dev/null || true

  zpool export rpool 2>/dev/null || true
  zpool destroy -f rpool 2>/dev/null || true

  wipefs -a -f "${KLDLOAD_DISK}" || true
  sgdisk --zap-all "${KLDLOAD_DISK}" || true
  rm -rf "${KLDLOAD_TARGET_MNT:?}/"* 2>/dev/null || true
  partprobe "${KLDLOAD_DISK}" || true

  # For multi-disk topologies, also wipe data and special vdev disks
  local _extra_disk
  for _extra_disk in ${KLDLOAD_ZFS_DATA_DISKS:-} ${KLDLOAD_ZFS_SPECIAL_DISKS:-}; do
    [[ -b "${_extra_disk}" ]] || continue
    k_zfs_log "Wiping data/special disk: ${_extra_disk}"
    wipefs -a -f "${_extra_disk}" 2>/dev/null || true
    zpool labelclear -f "${_extra_disk}" 2>/dev/null || true
  done

  sleep 2
}

k_zfs_partition_disk() {
  local disk="${KLDLOAD_DISK}"
  local prefix

  k_zfs_log "Partitioning boot disk ${disk} (topology: ${KLDLOAD_ZFS_TOPOLOGY})"

  if [[ "${KLDLOAD_ZFS_TOPOLOGY}" == "single" ]]; then
    # Single-disk: EFI (part 1) + rpool (part 2)
    sgdisk -n1:1M:+512M -t1:EF00 -c1:"EFI System Partition" "${disk}"
    sgdisk -n2:0:0      -t2:BF01 -c2:"KLDload rpool"           "${disk}"
  else
    # Multi-disk: EFI on boot disk only; rpool lives on the data disks
    sgdisk -n1:1M:+512M -t1:EF00 -c1:"EFI System Partition" "${disk}"
  fi

  partprobe "${disk}" || true
  sleep 2

  prefix="$(k_zfs_disk_prefix "${disk}")"

  export KLDLOAD_PART_EFI="${prefix}1"
  if [[ "${KLDLOAD_ZFS_TOPOLOGY}" == "single" ]]; then
    export KLDLOAD_PART_RPOOL="${prefix}2"
  fi

  k_zfs_log "EFI=${KLDLOAD_PART_EFI} RPOOL=${KLDLOAD_PART_RPOOL:-<data disks>}"
}

k_zfs_create_esp() {
  k_zfs_log "Creating EFI filesystem on ${KLDLOAD_PART_EFI}"
  mkfs.vfat -F 32 -n EFI "${KLDLOAD_PART_EFI}"
}

k_zfs_create_rpool() {
  local root_ds
  local -a enc_opts=() rpool_vdevs=()

  root_ds="$(k_zfs_root_dataset_name "${KLDLOAD_HOSTNAME}")"

  if [[ "${KLDLOAD_ZFS_ENCRYPT}" == "1" ]]; then
    : "${KLDLOAD_ZFS_PASSPHRASE:?KLDLOAD_ZFS_PASSPHRASE required when encryption is enabled}"
    enc_opts=(
      -O encryption=aes-256-gcm
      -O keyformat=passphrase
      -O keylocation=prompt
    )
  fi

  # Build vdev spec based on pool topology
  # shellcheck disable=SC2206
  local -a data_disks=(${KLDLOAD_ZFS_DATA_DISKS:-})
  case "${KLDLOAD_ZFS_TOPOLOGY}" in
    single)
      rpool_vdevs=("${KLDLOAD_PART_RPOOL:?KLDLOAD_PART_RPOOL not set for single topology}")
      k_zfs_log "rpool topology: single disk on ${KLDLOAD_PART_RPOOL}"
      ;;
    mirror)
      [[ ${#data_disks[@]} -ge 2 ]] \
        || die "mirror topology requires at least 2 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
      rpool_vdevs=(mirror "${data_disks[0]}" "${data_disks[1]}")
      k_zfs_log "rpool topology: mirror ${data_disks[0]} ${data_disks[1]}"
      ;;
    raidz1)
      [[ ${#data_disks[@]} -ge 3 ]] \
        || die "raidz1 topology requires at least 3 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
      rpool_vdevs=(raidz1 "${data_disks[@]}")
      k_zfs_log "rpool topology: raidz1 ${KLDLOAD_ZFS_DATA_DISKS}"
      ;;
    mirror-stripe)
      [[ ${#data_disks[@]} -ge 4 ]] \
        || die "mirror-stripe topology requires exactly 4 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
      rpool_vdevs=(
        mirror "${data_disks[0]}" "${data_disks[1]}"
        mirror "${data_disks[2]}" "${data_disks[3]}"
      )
      k_zfs_log "rpool topology: RAID10 mirror ${data_disks[0]}+${data_disks[1]} | mirror ${data_disks[2]}+${data_disks[3]}"
      ;;
    *)
      die "Unknown ZFS topology '${KLDLOAD_ZFS_TOPOLOGY}'. Valid: single mirror raidz1 mirror-stripe"
      ;;
  esac

  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=lz4 \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=none \
    "${enc_opts[@]}" \
    -R "${KLDLOAD_TARGET_MNT}" \
    rpool "${rpool_vdevs[@]}"

  # Root dataset hierarchy
  zfs create -o canmount=off -o mountpoint=none rpool/ROOT
  zfs create -o canmount=noauto -o mountpoint=/ "${root_ds}"
  zfs mount "${root_ds}"

  # Set ZFSBootMenu properties — inherited by all boot environments
  # console=tty1 keeps VGA output; console=ttyS0 adds serial (Proxmox console tab)
  zfs set org.zfsbootmenu:commandline="ro console=tty1 console=ttyS0,115200" rpool/ROOT

  # Data datasets
  zfs create -o mountpoint=/root      rpool/root
  zfs create -o mountpoint=/home      rpool/home
  # Per-user home dataset
  if [[ -n "${KLDLOAD_USERNAME:-}" ]]; then
    zfs create -o mountpoint="/home/${KLDLOAD_USERNAME}" "rpool/home/${KLDLOAD_USERNAME}"
    k_zfs_log "Created user home dataset: rpool/home/${KLDLOAD_USERNAME}"
  fi
  zfs create -o mountpoint=/srv       rpool/srv
  zfs create -o mountpoint=/opt       rpool/opt

  zfs create -o canmount=off -o mountpoint=/usr rpool/usr
  zfs create -o mountpoint=/usr/local rpool/usr/local

  zfs create -o canmount=off -o mountpoint=/var rpool/var
  zfs create -o mountpoint=/var/cache rpool/var/cache
  zfs create -o mountpoint=/var/lib   rpool/var/lib
  zfs create -o mountpoint=/var/log   rpool/var/log
  zfs create -o mountpoint=/var/spool rpool/var/spool
  zfs create -o mountpoint=/var/tmp   rpool/var/tmp

  # /tmp — not snapshotted, no suid/exec/devices for security
  zfs create \
    -o mountpoint=/tmp \
    -o sync=disabled \
    -o setuid=off \
    -o exec=off \
    -o devices=off \
    rpool/tmp

  chmod 1777 "${KLDLOAD_TARGET_MNT}/tmp" || true
  chmod 1777 "${KLDLOAD_TARGET_MNT}/var/tmp" || true

  # Set pool bootfs — ZFSBootMenu uses this to select the default BE
  zpool set bootfs="${root_ds}" rpool || true
}

# Add special vdev to rpool for metadata/small-block acceleration.
# Mirrors the two disks if two are provided; uses single disk otherwise.
# No-op if KLDLOAD_ZFS_SPECIAL_DISKS is empty.
k_zfs_add_special_vdev() {
  [[ -n "${KLDLOAD_ZFS_SPECIAL_DISKS:-}" ]] || return 0

  # shellcheck disable=SC2206
  local -a sdisks=(${KLDLOAD_ZFS_SPECIAL_DISKS})
  [[ ${#sdisks[@]} -gt 0 ]] || return 0

  if [[ ${#sdisks[@]} -ge 2 ]]; then
    k_zfs_log "Adding special vdev: mirror ${sdisks[0]} ${sdisks[1]}"
    zpool add rpool special mirror "${sdisks[0]}" "${sdisks[1]}"
  else
    k_zfs_log "Adding special vdev: ${sdisks[0]}"
    zpool add rpool special "${sdisks[0]}"
  fi
}

k_zfs_mount_esp() {
  k_zfs_log "Mounting EFI partition"
  mkdir -p "${KLDLOAD_TARGET_MNT}/boot/efi"
  mount "${KLDLOAD_PART_EFI}" "${KLDLOAD_TARGET_MNT}/boot/efi"
}

k_zfs_write_cachefile() {
  k_zfs_log "Writing zpool cachefile into target"
  mkdir -p "${KLDLOAD_TARGET_MNT}/etc/zfs"
  zpool set cachefile="${KLDLOAD_TARGET_MNT}/etc/zfs/zpool.cache" rpool || true
}

k_zfs_write_target_hostid() {
  k_zfs_log "Writing stable target hostid"

  mkdir -p "${KLDLOAD_TARGET_MNT}/etc"

  if [[ -s "${KLDLOAD_TARGET_MNT}/etc/hostid" ]]; then
    chmod 0644 "${KLDLOAD_TARGET_MNT}/etc/hostid" || true
    return 0
  fi

  if [[ -s /etc/hostid ]]; then
    cp -f /etc/hostid "${KLDLOAD_TARGET_MNT}/etc/hostid"
  else
    dd if=/dev/urandom of="${KLDLOAD_TARGET_MNT}/etc/hostid" bs=4 count=1 status=none
  fi

  chmod 0644 "${KLDLOAD_TARGET_MNT}/etc/hostid" || true
}

k_storage_zfs_install() {
  export KLDLOAD_STORAGE_MODE=zfs
  export KLDLOAD_ROOT_FS_TYPE=zfs
  export KLDLOAD_TARGET_MNT

  mkdir -p "${KLDLOAD_LOG_DIR}"
  : > "${KLDLOAD_ZFS_LOG}"

  k_zfs_log "==== ZFS install start ===="
  k_zfs_log "disk=${KLDLOAD_DISK}"
  k_zfs_log "topology=${KLDLOAD_ZFS_TOPOLOGY}"
  k_zfs_log "data_disks=${KLDLOAD_ZFS_DATA_DISKS:-}"
  k_zfs_log "special_disks=${KLDLOAD_ZFS_SPECIAL_DISKS:-}"
  k_zfs_log "target=${KLDLOAD_TARGET_MNT}"
  k_zfs_log "host=${KLDLOAD_HOSTNAME}"
  k_zfs_log "encrypt=${KLDLOAD_ZFS_ENCRYPT}"

  modprobe zfs
  zpool --version >> "${KLDLOAD_ZFS_LOG}" 2>&1 || true

  mkdir -p "${KLDLOAD_TARGET_MNT}"

  k_zfs_cleanup_old
  k_zfs_partition_disk
  k_zfs_create_esp
  k_zfs_create_rpool
  k_zfs_add_special_vdev
  k_zfs_mount_esp
  k_zfs_write_cachefile
  k_zfs_write_target_hostid

  k_zfs_log "Current zpool status:"
  zpool status >> "${KLDLOAD_ZFS_LOG}" 2>&1 || true

  k_zfs_log "Current zfs list:"
  zfs list >> "${KLDLOAD_ZFS_LOG}" 2>&1 || true

  k_zfs_log "==== ZFS install complete ===="
}
