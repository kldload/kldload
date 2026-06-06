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

    # ALWAYS stage the MOK via mokutil --import, regardless of the live
    # environment's Secure Boot state. Users commonly install with SB off,
    # and the old "skip if SB disabled" short-circuit meant the NEW per-
    # install MOK never got queued for MokManager. Users who later enabled
    # SB saw MokManager (from a stale enrollment queue left by a previous
    # install) and "enrolled" an old cert that didn't match the current
    # install's signed grubx64.efi — shim then rejected grubx64.efi on
    # every boot under SB with "signature failed". Always staging means:
    # MokManager always prompts for THIS install's key on first boot after
    # the user enables SB, and the key it enrolls always matches the ZBM
    # signature sbsign just produced in bootloader.sh.
    #
    # If efivars aren't mounted (running in a non-EFI container or similar)
    # we skip — mokutil cannot write staging variables without them.

    # TODO: restore random password once web UI displays it before reboot
    # mok_pass="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    local mok_pass="kldload"

    local enrolled=0
    if chroot "${target}" command -v mokutil >/dev/null 2>&1; then
        if [[ -d /sys/firmware/efi/efivars ]]; then
            # --ignore-keyring: don't skip when a prior cert with the same CA is
            #   already trusted (we generate a new key+subject per install; mokutil
            #   without this flag sees "CA already enrolled" and silently skips,
            #   leaving SB boot broken when the new ZFS module is loaded).
            if printf '%s\n%s\n' "${mok_pass}" "${mok_pass}" |
                chroot "${target}" /usr/bin/mokutil --ignore-keyring --import /var/lib/dkms/mok.der >&8 2>&1; then
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
    } >"${log_dir}/mok-password.txt"
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
