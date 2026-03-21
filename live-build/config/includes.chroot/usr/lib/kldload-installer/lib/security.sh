#!/usr/bin/env bash
# Sourced by kldload-install-target — k_configure_mok (MOK enrollment queuing)
#
# MOK key generation and DKMS signing configuration happen earlier, in
# k_generate_mok_keys() (bootstrap.sh), BEFORE package installation.
# By the time this runs, zfs-dkms has already been built and signed by DKMS.
# This step only queues the MOK for first-boot enrollment via MokManager.
set -Eeuo pipefail

k_configure_mok() {
  local target="${KLDLOAD_TARGET:-${KLDLOAD_TARGET_MNT:-/target}}"
  local log_dir="${KLDLOAD_LOG_DIR:-/var/log/installer}"
  local mok_der="${target}/var/lib/dkms/mok.der"

  mkdir -p "${log_dir}"
  exec 8>>"${log_dir}/security.log"

  k_log "Queuing MOK enrollment for first-boot Secure Boot activation"

  if [[ ! -f "${mok_der}" ]]; then
    k_log "WARNING: MOK key not found at /var/lib/dkms/mok.der — was k_generate_mok_keys called?"
    exec 8>&-
    return 0
  fi

  # Generate a random one-time enrollment password.
  # Use openssl (finite output) to avoid SIGPIPE from "tr < /dev/urandom | head"
  # under set -Eeuo pipefail.
  local mok_pass
  mok_pass="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-20)"

  local enrolled=0
  if chroot "${target}" command -v mokutil >/dev/null 2>&1; then
    if [[ -d /sys/firmware/efi/efivars ]]; then
      if printf '%s\n%s\n' "${mok_pass}" "${mok_pass}" | \
           chroot "${target}" mokutil --import /var/lib/dkms/mok.der >&8 2>&1
      then
        enrolled=1
        k_log "MOK enrollment queued via mokutil"
      else
        k_log "WARNING: mokutil --import returned non-zero — manual enrollment may be needed"
      fi
    else
      k_log "WARNING: EFI vars not mounted — skipping mokutil (non-EFI environment)"
    fi
  else
    k_log "WARNING: mokutil not present in chroot"
  fi

  # Save password and enrollment state for the user
  {
    echo "MOK_PASSWORD=${mok_pass}"
    echo "MOK_ENROLLED=${enrolled}"
    echo "MOK_DER=/var/lib/dkms/mok.der"
    echo "MOK_PUB=/var/lib/dkms/mok.pub"
    echo "MOK_KEY=/var/lib/dkms/mok.key"
  } > "${log_dir}/mok-password.txt"
  chmod 0600 "${log_dir}/mok-password.txt"

  k_log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  k_log " MOK ENROLLMENT — action required on first boot"
  k_log " 1. Enable Secure Boot in your firmware / hypervisor"
  k_log " 2. On first boot, MokManager will appear (blue screen)"
  k_log " 3. Select: Enroll MOK → Continue → enter this password:"
  k_log " Password: ${mok_pass}"
  k_log " (also saved to ${log_dir}/mok-password.txt)"
  k_log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  exec 8>&-
}
