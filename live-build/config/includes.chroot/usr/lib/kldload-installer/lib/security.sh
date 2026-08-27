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

    # DELIBERATELY DETERMINISTIC, and honouring the documented override.
    #
    # A random password here is strictly worse, and the old TODO asking for one
    # back had the trade upside down. MokManager runs BEFORE first boot, on the
    # console, and asks for this password with no way to look it up: the machine
    # it is installing is not running yet. A random value the operator never saw
    # is therefore not "more secure", it is an unbootable Secure Boot install.
    #
    # And it buys almost nothing. The real gate on MOK enrollment is PHYSICAL
    # PRESENCE — MokManager only runs at the console and needs a human. The
    # password confirms that the person at the console is the one who staged the
    # import; but staging requires root already, and the password is stored on
    # the same machine, so an attacker with root reads it either way. The one
    # case it helps is an operator who reboots into a MokManager they did not
    # expect, and there the fix is to make them stop and read, not to make the
    # password unguessable.
    #
    # HISTORY fiend 2026-08-26: install with Secure Boot + encryption, MokManager
    # appeared, the operator had no password to type, enrollment was abandoned.
    # zfs.ko was correctly signed by kldload-mok-20260826231823 and that exact
    # key sat in MokNew, never enrolled — so the kernel refused the module with
    # "Loading of module with unavailable key is rejected" and the boot died at
    # an initramfs prompt. Every mechanical step worked; the operator simply
    # could not answer a prompt whose answer was written only to the target's
    # /root, readable only after a boot that could not happen.
    #
    # Operators who want their own set KLDLOAD_MOK_PASSWORD; it is already
    # documented in `kldload-secure-boot --help`.
    local mok_pass="${KLDLOAD_MOK_PASSWORD:-kldload}"

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

    # ALSO write it where it can be read BEFORE the machine boots. The file
    # above lives on the target's /root at mode 0600 — unreadable until the
    # install boots, which is exactly the boot MokManager is standing in front
    # of. The ESP is FAT, mounted by any live USB or any other machine, and
    # present at the moment it is needed.
    #
    # Not treated as a secret, and that is a deliberate call: this password
    # authorises one thing, enrolling a key that is already sitting on this
    # disk, and only from the physical console. Anyone who can read the ESP can
    # already boot the machine and turn Secure Boot off in firmware, which is
    # strictly more powerful. Recoverability wins.
    local _esp="${target}/boot/efi"
    if [[ -d "$_esp" ]]; then
        {
            echo "kldload — Secure Boot MOK enrollment"
            echo
            echo "On the next boot a blue MokManager screen appears. Choose:"
            echo "    Enroll MOK  ->  Continue  ->  Yes  ->  password below  ->  Reboot"
            echo
            echo "    password: ${mok_pass}"
            echo
            echo "Enable Secure Boot in firmware AFTER the key is enrolled."
            echo "If the screen never appears, the enrollment did not queue --"
            echo "run: mokutil --import /var/lib/dkms/mok.der   and reboot."
            echo
            echo "This is not a secret: it authorises enrolling a key already on"
            echo "this disk, from the console only. See kldload-secure-boot --help."
        } >"${_esp}/MOK-ENROLLMENT.txt" 2>/dev/null &&
            k_log "MOK instructions written to the ESP: /boot/efi/MOK-ENROLLMENT.txt"
    fi

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
