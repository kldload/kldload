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

    # ALWAYS overwrite from live env's /etc/hostid — pool was created
    # with that hostid, target initramfs MUST match it. dnf install /
    # zfs-dkms's zgenhostid / systemd-machine-id-setup may have written
    # a different /etc/hostid into target during install. Check explicitly:
    #
    #   live hostid    : $(hostid) — matches pool stamp
    #   target hostid  : different value if any package set it
    #   pool stamp     : matches live hostid (set at zpool create time)
    #
    # If target's hostid != pool's hostid, `zpool import` at boot fails
    # silently, dracut goes to "emergency mode generating
    # /run/initramfs/rdsosreport.txt." Always copy live → target so they
    # match by definition.
    if [[ -s /etc/hostid ]]; then
        cp -f /etc/hostid "${target}/etc/hostid"
        k_log "hostid pinned to live env's value: $(xxd -p /etc/hostid 2>/dev/null) → ${target}/etc/hostid"
    else
        # Live env should always have /etc/hostid (storage stage wrote it).
        # If it doesn't, we're in trouble — pool stamp is unknown. Fall
        # back to zgenhostid in target chroot, but warn loudly.
        k_log "WARNING: live /etc/hostid is empty — falling back to zgenhostid in target"
        if chroot "${target}" command -v zgenhostid >/dev/null 2>&1; then
            chroot "${target}" zgenhostid -f >&"${log_fd}" 2>&1 || true
        fi
        if [[ ! -s "${target}/etc/hostid" ]]; then
            dd if=/dev/urandom of="${target}/etc/hostid" bs=4 count=1 status=none 2>&"${log_fd}" || true
        fi
    fi

    # Final safety check — hostid MUST exist for ZFS pool imports
    if [[ ! -s "${target}/etc/hostid" ]]; then
        k_log "CRITICAL: Failed to generate /etc/hostid — creating from /dev/urandom"
        head -c4 /dev/urandom >"${target}/etc/hostid" 2>/dev/null || true
    fi

    chmod 0644 "${target}/etc/hostid" || true
    k_log "hostid written: $(xxd -p "${target}/etc/hostid" 2>/dev/null)"
}

# k_install_initramfs_zfs_key — make the FIRST boot single-prompt too.
#
# Args:    $1 the target root.
# Returns: 0 always. This is an ergonomics win, never a reason to fail an
#          install — and kldload-firstboot installs the same key on first boot,
#          so the worst case here is the behaviour we already shipped.
#
# WHY AT INSTALL TIME: kldload-firstboot writes the pool key into the initramfs,
# but it can only run once the system is up — which is one boot too late. The
# first boot after an install therefore asked for the passphrase twice: once at
# ZFSBootMenu, once at an initramfs that did not yet have the key. Correct, and
# still the thing an operator notices first (fiend, 2026-08-19). The installer
# already knows the passphrase and the target, so it can close that gap.
#
# SECURITY: identical to the firstboot path — the key file and the initramfs
# that carries it both live on the encrypted root, so both are protected by the
# passphrase ZFSBootMenu already demanded. Refused outright when Secure Boot is
# on, because that path stages a copy of the initramfs on the unencrypted ESP.
k_install_initramfs_zfs_key() {
    local target="$1"
    local keyfile="${target}/etc/zfs/kldload-rpool.key"
    local pass="${KLDLOAD_ZFS_PASSPHRASE:-}"

    [[ "${KLDLOAD_ZFS_ENCRYPT:-0}" == "1" ]] || return 0
    [[ -n "$pass" ]] || return 0

    if [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-0}" == "1" ]]; then
        k_log "Secure Boot on — not embedding a pool key (the ESP copy is unencrypted)"
        return 0
    fi
    if [[ ! -d "${target}/etc/initramfs-tools" ]]; then
        k_log "target has no initramfs-tools — first boot will ask for the passphrase twice"
        return 0
    fi

    install -d -m 0700 "${target}/etc/zfs" "${target}/etc/zfs/initramfs-tools-load-key.d"
    (
        umask 077
        printf '%s' "$pass" >"$keyfile"
    )
    chmod 0400 "$keyfile"

    # Prove the key unwraps the pool before anything depends on it. The pool is
    # imported right now, so this is a real check, not a guess.
    local encroot="${KLDLOAD_ZFS_POOL:-rpool}"
    if ! zfs load-key -n -L "file://${keyfile}" "$encroot" >&7 2>&1; then
        k_log "WARNING: staged passphrase does not unlock ${encroot} — not embedding it"
        rm -f "$keyfile"
        return 0
    fi

    cat >"${target}/etc/zfs/initramfs-tools-load-key.d/kldload" <<'KEYHOOK'
# Sourced by /usr/share/initramfs-tools/scripts/zfs with $ZFS and
# $ENCRYPTIONROOT already set. Loading the key here is what keeps the boot to a
# single passphrase prompt. Returning non-zero simply falls through to
# prompting, which is the right behaviour if the key is missing or wrong.
[ -r /etc/zfs/kldload-rpool.key ] || return 1
"${ZFS}" load-key -L file:///etc/zfs/kldload-rpool.key "${ENCRYPTIONROOT}"
KEYHOOK
    chmod 0444 "${target}/etc/zfs/initramfs-tools-load-key.d/kldload"

    cat >"${target}/etc/initramfs-tools/hooks/kldload-zfs-key" <<'HOOK'
#!/bin/sh
# Copy the pool key and its loader INTO the image. At unlock time the pool is
# not mounted, so /etc/zfs on the root filesystem does not exist yet.
set -e
[ "$1" = "prereqs" ] && {
    echo
    exit 0
}
. /usr/share/initramfs-tools/hook-functions
mkdir -p "${DESTDIR}/etc/zfs/initramfs-tools-load-key.d"
[ -r /etc/zfs/kldload-rpool.key ] &&
    cp -a /etc/zfs/kldload-rpool.key "${DESTDIR}/etc/zfs/kldload-rpool.key"
[ -r /etc/zfs/initramfs-tools-load-key.d/kldload ] &&
    cp -a /etc/zfs/initramfs-tools-load-key.d/kldload \
        "${DESTDIR}/etc/zfs/initramfs-tools-load-key.d/kldload"
exit 0
HOOK
    chmod 0755 "${target}/etc/initramfs-tools/hooks/kldload-zfs-key"

    # update-initramfs needs a live /proc; the bootstrap phase already unmounted
    # the chroot binds by now, so re-establish them just for this and put them
    # back exactly as they were.
    # Mount only what is missing, and remember it, so the target is left
    # exactly as it was found. Testing with mountpoint instead of swallowing a
    # failure means an unmountable /proc is reported rather than assumed
    # harmless — it is the one thing update-initramfs cannot run without.
    local _unbind=() _m
    if ! mountpoint -q "${target}/proc" && mount -t proc proc "${target}/proc"; then
        _unbind+=("${target}/proc")
    fi
    if ! mountpoint -q "${target}/sys" && mount -t sysfs sys "${target}/sys"; then
        _unbind+=("${target}/sys")
    fi
    if ! mountpoint -q "${target}/dev" && mount --bind /dev "${target}/dev"; then
        _unbind+=("${target}/dev")
    fi

    chroot "${target}" update-initramfs -u -k all >&7 2>&1 ||
        k_log "WARNING: update-initramfs failed in the target"

    for _m in ${_unbind[@]+"${_unbind[@]}"}; do
        umount "$_m" || k_log "note: ${_m} still busy — left mounted"
    done

    # Verify the OUTCOME. An image rebuilt without the key is indistinguishable
    # from one rebuilt with it until the machine asks twice.
    local img
    img="$(ls -1t "${target}"/boot/initrd.img-* 2>/dev/null | head -1)"
    if [[ -n "$img" ]] && lsinitramfs "$img" 2>/dev/null |
        grep -q '^etc/zfs/kldload-rpool.key$'; then
        k_log "First boot will be single-prompt (key embedded in $(basename "$img"))"
    else
        k_log "NOTE: key not in the target initramfs — the first boot will ask twice, firstboot fixes it after"
    fi
    return 0
}

# k_zbm_find_efi — locate the ZFSBootMenu EFI binary.
# Checks the baked-in darksite first, then falls back to downloading.
k_zbm_find_efi() {
    local candidates=(
        "/root/darksite/boot/zfsbootmenu.EFI"
        "/root/darksite/boot/zfsbootmenu.efi"
    )

    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && {
            echo "$p"
            return 0
        }
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
    timeout 5 zpool export rpool >&"${log_fd}" 2>&1 ||
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
    : >"${KLDLOAD_LOG_DIR}/bootloader.log"
    exec 7>>"${KLDLOAD_LOG_DIR}/bootloader.log"

    [[ -d "${target}" ]] || k_die "target mount missing: ${target}"
    [[ -d "${target}/boot/efi" ]] || k_die "EFI mountpoint missing: ${target}/boot/efi"
    [[ -n "${efi_part}" ]] || k_die "EFI partition variable (KLDLOAD_PART_EFI) is not set"

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
        echo '\EFI\BOOT\BOOTX64.EFI' >"${target}/boot/efi/startup.nsh"

        # FreeBSD fstab — no EFI automount (loader handles it)
        cat >"${target}/etc/fstab" <<EOFSTAB
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
                -l '\EFI\BOOT\BOOTX64.EFI' >&7 2>&1 ||
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
        cat >"${target}/etc/fstab" <<EOFSTAB
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
                -l '\EFI\BOOT\BOOTX64.EFI' >&7 2>&1 ||
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
            --output "${zbm_efi_dir}/BOOTX64.EFI" "$zbm_src" >&7 2>&1 &&
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

    # ── Secure-Boot-compatible boot path: distro-signed GRUB → CentOS kernel ──
    # Prior versions made MOK-signed ZFSBootMenu THE grubx64.efi that shim
    # loads. That broke on CentOS shim v15.8 with "Verification failed":
    # shim's SBAT enforcement (SbatLevelRT=sbat,1,2021030218) rejects ZBM
    # regardless of MOK enrollment because ZBM's embedded .sbat section
    # declares only systemd-stub components, not a shim-trust entry.
    #
    # The reliable SB path:
    #   shim (MS-signed) → distro GRUB (CentOS/Rocky/Fedora-signed, in db) →
    #   distro kernel (signed) → zfs.ko (MOK-signed, MOK enrolled)
    #
    # To let GRUB load the kernel/initramfs without a grub-zfs module on the
    # ESP (grub2-efi-x64-modules isn't shipped by default and building a
    # custom signed grubx64.efi would break the signing chain), we copy
    # vmlinuz + initramfs to the FAT32 ESP and point grub.cfg at them with
    # plain paths. GRUB's built-in FAT driver handles this; no zfs.mod
    # required. A kernel-install hook keeps them in sync after yum updates.
    #
    # ZBM stays at /EFI/zbm/BOOTX64.EFI — MOK-signed for non-SB boots (user
    # can also try it under SB via firmware boot menu; MokManager confirms).
    # Boot env selection via ZBM remains available; it's just not the
    # primary SB path.
    # Find distro-signed shim + grubx64. Most distros drop these at
    # /boot/efi/EFI/<distro>/ via RPM/dpkg post-install scriptlets that
    # write directly to the mounted ESP. Fedora 44+ moved to a `bootupd`
    # model: shim/grub2 RPMs ship reference files at /usr/lib/efi/ for
    # `bootupctl update` to copy onto the ESP later. If we don't search
    # both locations, the F44+ ESP looks empty even though the packages
    # are installed, the fallback ("install ZBM as grubx64") fires, and
    # SB refuses to boot — exactly the failure mode kldload 1.1.0-dev
    # hit on Fedora 44 desktop installs.
    #
    # Globs catch versioned subdirs under /usr/lib/efi/{shim,grub2}/
    # (e.g. /usr/lib/efi/shim/16.1-5/EFI/fedora/shim.efi). We pick the
    # newest one if multiple are present (sort -V | tail).
    local signed_grub=""
    for _sg in "${target}/boot/efi/EFI/centos/grubx64.efi" \
        "${target}/boot/efi/EFI/rocky/grubx64.efi" \
        "${target}/boot/efi/EFI/fedora/grubx64.efi" \
        "${target}/boot/efi/EFI/redhat/grubx64.efi" \
        "${target}/usr/lib/efi/grub2/"*/EFI/fedora/grubx64.efi \
        "${target}/usr/lib/efi/grub2/"*/EFI/redhat/grubx64.efi \
        "${target}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
        "${target}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"; do
        if [[ -f "$_sg" ]]; then
            signed_grub="$_sg"
            break
        fi
    done

    # Same for shim — used a bit later in the function but resolve here so
    # the bootupd-glob logic lives in one place.
    local signed_shim=""
    for _ss in "${target}/boot/efi/EFI/centos/shimx64.efi" \
        "${target}/boot/efi/EFI/rocky/shimx64.efi" \
        "${target}/boot/efi/EFI/fedora/shimx64.efi" \
        "${target}/boot/efi/EFI/fedora/shim.efi" \
        "${target}/boot/efi/EFI/redhat/shimx64.efi" \
        "${target}/usr/lib/efi/shim/"*/EFI/fedora/shimx64.efi \
        "${target}/usr/lib/efi/shim/"*/EFI/fedora/shim.efi \
        "${target}/usr/lib/efi/shim/"*/EFI/redhat/shimx64.efi \
        "${target}/usr/lib/shim/shimx64.efi.signed"; do
        if [[ -f "$_ss" ]]; then
            signed_shim="$_ss"
            break
        fi
    done

    if [[ -n "$signed_grub" ]]; then
        cp "$signed_grub" "${zbm_fallback_dir}/grubx64.efi"
        k_log "Distro-signed GRUB installed as \\EFI\\BOOT\\grubx64.efi (source: ${signed_grub})"
    else
        # Truly no distro grub on the target — fall back to unsigned ZBM as
        # grubx64.efi. SB will refuse; user has to disable SB to boot.
        cp "${zbm_efi_dir}/BOOTX64.EFI" "${zbm_fallback_dir}/grubx64.efi"
        k_log "WARNING: no distro-signed GRUB on target — ZBM installed as grubx64.efi (SB won't work)"
    fi

    # F44+ also expects an /EFI/fedora/ directory on the ESP (firmware
    # boot manager often looks there directly). Stage shim+grub there so
    # both shim's lookup and the bootupd model land in the same place.
    if [[ -n "$signed_shim" && "$signed_shim" =~ /usr/lib/efi/shim/ ]]; then
        local _esp_distro_dir="${target}/boot/efi/EFI/fedora"
        [[ "$signed_shim" =~ /redhat/ ]] && _esp_distro_dir="${target}/boot/efi/EFI/redhat"
        mkdir -p "$_esp_distro_dir"
        cp "$signed_shim" "${_esp_distro_dir}/shimx64.efi"
        cp "$signed_shim" "${_esp_distro_dir}/shim.efi"
        [[ -n "$signed_grub" ]] && cp "$signed_grub" "${_esp_distro_dir}/grubx64.efi"
        # bootupd ships mmx64.efi alongside shim — copy it too so MokManager
        # works on first SB-on boot.
        local _mm_src="${signed_shim%/shim*.efi}/mmx64.efi"
        [[ -f "$_mm_src" ]] && cp "$_mm_src" "${_esp_distro_dir}/mmx64.efi"
        k_log "F44 bootupd-style: staged $(basename "$_esp_distro_dir") to ESP from /usr/lib/efi/"
    fi

    # Copy kernel + initramfs to the ESP so GRUB can boot without zfs.mod.
    #
    # Pick the highest-versioned kernel that has BOTH a vmlinuz AND a matching
    # initramfs — NOT just `sort -V | tail -1`. Multi-kernel installs (dnf can
    # pull in both base and update kernel as a side-effect of dependency
    # resolution) routinely leave one kernel without a usable initramfs:
    # DKMS only builds zfs.ko for the kernel matching the chroot's running
    # headers, so dracut's `installkernel` for the OTHER kernel fails inside
    # `*** Including module: zfs ***` and skips the .img write entirely.
    #
    # Old code blindly picked the highest version, found vmlinuz, found NO
    # initramfs, logged a warning, left /EFI/BOOT/ empty of kernel files —
    # `set default=direct` in grub.cfg then dropped to dracut emergency shell
    # at boot. ZBM still worked (kexecs the BLS-default kernel from inside
    # the imported rpool, doesn't depend on /EFI/BOOT/ contents).
    #
    # Bug seen Rocky 9 desktop install 2026-05-03: dnf installed kernel-697.el9
    # AND kernel-611.49.1.el9_7. Only 611 had zfs.ko (DKMS built it for the
    # 611 chroot kernel). 697 was higher version, picked, no initramfs,
    # silent fail. See project_f44_cutover_findings.md.
    local _kver _kpath _ipath _zfs_root _kv _kp _ip
    _zfs_root="$(zfs list -H -o name,mountpoint 2>/dev/null | awk '$2=="/"{print $1; exit}')"
    if [[ -z "$_zfs_root" ]]; then
        _zfs_root="$(zfs list -H -o name 2>/dev/null | grep -E 'ROOT/[^/]+$' | head -1)"
    fi
    while read -r _kv; do
        [[ -z "$_kv" ]] && continue
        _kp="${target}/boot/vmlinuz-${_kv}"
        _ip="${target}/boot/initramfs-${_kv}.img"
        [[ -f "$_ip" ]] || _ip="${target}/boot/initrd.img-${_kv}"
        if [[ -f "$_kp" && -f "$_ip" ]]; then
            _kver="$_kv"
            _kpath="$_kp"
            _ipath="$_ip"
            break
        fi
        k_log "skipping kernel ${_kv} — vmlinuz=$([[ -f $_kp ]] && echo present || echo MISSING) initramfs=$([[ -f $_ip ]] && echo present || echo MISSING)"
    done < <(ls "${target}/boot" 2>/dev/null | grep -oP '^vmlinuz-\K[^ ]+' | sort -V -r)

    # The staged kernel + initramfs exist for ONE consumer: GRUB's "direct"
    # entry, which is the Secure Boot path. With Secure Boot off the firmware
    # boots ZFSBootMenu directly and nothing ever reads these.
    #
    # SECURITY: the ESP is a plain FAT partition with no encryption. A copy of
    # the initramfs there is a copy OUTSIDE the encrypted root — fine while it
    # holds nothing secret, and a disclosure the moment anything does. That
    # matters because the fix for the double passphrase prompt is to give the
    # initramfs a key file (Debian's /etc/zfs/initramfs-tools-load-key.d/), and
    # an initramfs carrying a key must never be written anywhere but the
    # encrypted dataset. Not staging it when it cannot be used keeps those two
    # changes from colliding.
    if [[ -n "${_kver:-}" ]] && [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" != "1" ]]; then
        k_log "Secure Boot off — not staging kernel/initramfs on the ESP (nothing boots them, and the ESP is unencrypted)"
        # Same branch, same reason: with no ESP copy to leak it to, the pool key
        # can go into the initramfs now instead of one boot later.
        k_install_initramfs_zfs_key "${target}"
    elif [[ -n "${_kver:-}" ]]; then
        mkdir -p "${zbm_fallback_dir}"
        cp "$_kpath" "${zbm_fallback_dir}/vmlinuz"
        cp "$_ipath" "${zbm_fallback_dir}/initrd.img"
        k_log "Kernel + initramfs copied to \\EFI\\BOOT\\ (kver=${_kver}, root=${_zfs_root:-rpool/ROOT/default})"

        # Re-sign the staged kernel with the kldload MOK private key so it
        # verifies under Secure Boot. Without this, distros whose kernel-
        # signing key isn't shim's compiled-in vendor cert AND isn't enrolled
        # in MokListRT will fail at GRUB's load-kernel step with:
        #   grub-core/kern/efi/sb.c:182  bad shim signature
        #   grub-core/loader/i386/efi/linux.c:260  you need to load the kernel
        #
        # Bug seen Rocky 9 desktop install 2026-05-04 (.109/.128) under SB:
        # Rocky kernel signed by Rocky CA, shim's vendor cert is CentOS Secure
        # Boot CA 2 (we use CentOS-shipped shim because Rocky's RPMs install
        # to /EFI/centos/), MokListRT has only the kldload per-install leaf →
        # zero overlap, shim returns SECURITY_VIOLATION, GRUB throws the above.
        #
        # Fix: sbsign the staged kernel with kldload's MOK key so its sig
        # chains to the leaf already in MokListRT. Same trick we use on
        # zfs.ko, ZFSBootMenu, and (where applicable) the bootloader chain.
        # Only signs the COPY in /EFI/BOOT/, not the original on /boot — the
        # original stays distro-signed for any kernel-install or in-place
        # upgrade flow that expects vendor signatures.
        local _mok_key="${target}/var/lib/dkms/mok.key"
        local _mok_pub="${target}/var/lib/dkms/mok.pub"
        # Gate the kernel re-sign on the user's SB intent. When SB is OFF (the
        # default for most installs), the staged kernel will be booted via ZBM
        # chainload (no SB verification involved) — re-signing is dead work AND
        # actively harmful: it strips the distro signature and replaces it with a
        # per-install MOK leaf signature that shim rejects if the user later
        # toggles SB on in firmware without enrolling the leaf (shim "signature
        # error" on every GRUB kernel entry — exact failure mode seen on .119
        # 2026-05-15 after a user enrolled MOK and flipped SB on post-install).
        # SB-on installs keep the re-sign because some distros (notably Rocky 9
        # under a CentOS-built shim whose vendor_cert doesn't chain to Rocky's CA)
        # still need it for the direct-kernel grub entry to verify.
        # Does the staged kernel actually NEED our MOK signature?
        # HISTORY 2026-08-03 (fiend, real hardware): re-signing a FEDORA
        # kernel BROKE Secure Boot. Fedora's kernel is signed by the Fedora
        # CA that Fedora's shim 16.1 already carries as its vendor cert, so
        # the pristine kernel verifies on its own; stripping that signature
        # and substituting a per-install MOK leaf made SB boot die at GRUB's
        # load-kernel step EVEN WITH the MOK correctly enrolled (verified:
        # mokutil --test-key said "already enrolled", ZBM + zfs.ko both
        # MOK-signed and fine). Swapping the pristine kernel back onto the
        # ESP booted immediately — SecureBoot enabled, lockdown=integrity,
        # ZFS loaded. So: re-sign ONLY where the distro's own kernel
        # signature cannot chain to the shim we ship (the documented Rocky-
        # under-CentOS-shim case, .109/.128 2026-05-04), or where the kernel
        # carries no signature at all. Never strip a good vendor signature.
        local _need_resign=0
        case "${KLDLOAD_DISTRO:-}" in
        rocky)
            _need_resign=1
            ;;
        *)
            if command -v sbverify >/dev/null 2>&1 &&
                ! sbverify --list "${zbm_fallback_dir}/vmlinuz" >/dev/null 2>&1; then
                _need_resign=1 # unsigned kernel — our leaf beats nothing
            fi
            ;;
        esac

        if ((_need_resign == 0)) && [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]]; then
            k_log "Kernel re-sign skipped — ${KLDLOAD_DISTRO:-distro} kernel keeps its vendor signature (shim's vendor cert validates it; re-signing broke SB on Fedora 2026-08-03)"
        fi

        if ((_need_resign)) &&
            [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]] &&
            [[ -f "$_mok_key" && -f "$_mok_pub" ]] &&
            command -v sbsign >/dev/null 2>&1; then
            local _signed="${zbm_fallback_dir}/vmlinuz.signed"
            # Strip the distro-supplied signature first so we ship a SINGLE
            # signature on the staged kernel. sbsign appends rather than
            # replaces — leaving Rocky's sig in front of ours produces a
            # multi-signature PE. Some shim versions iterate properly and
            # accept; some only check the first sig and reject. Single-sig
            # is portable and avoids that question entirely. `sbattach
            # --remove` strips one sig per call — Rocky kernels ship with
            # exactly one, so a single call is enough. If sbattach is
            # unavailable, fall through and live with multi-sig.
            if command -v sbattach >/dev/null 2>&1; then
                sbattach --remove "${zbm_fallback_dir}/vmlinuz" >&7 2>&1 || true
            fi
            # NB: redirect to fd 7 (the bootloader.log), NOT ${log_fd} —
            # k_install_bootloader() doesn't take log_fd as a parameter; the
            # ZBM sbsign at line ~292 uses literal `>&7` for the same reason.
            # First version of this block used `>&"${log_fd}"` — bash saw an
            # empty redirect target, refused to run sbsign, fell into the
            # failure branch silently. Bug seen Rocky 9 .109 install
            # 2026-05-04: WARNING logged but no actual sbsign error captured.
            if sbsign --key "$_mok_key" --cert "$_mok_pub" \
                --output "$_signed" "${zbm_fallback_dir}/vmlinuz" >&7 2>&1; then
                mv -f "$_signed" "${zbm_fallback_dir}/vmlinuz"
                k_log "/EFI/BOOT/vmlinuz re-signed with kldload MOK leaf (SB-validated via MokListRT)"
            else
                rm -f "$_signed" 2>/dev/null
                k_log "WARNING: sbsign failed for /EFI/BOOT/vmlinuz — SB direct-boot will fail until manually signed"
            fi
        elif [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" != "1" ]]; then
            k_log "Kernel re-sign skipped — SB off (ZBM is the default boot target; staged kernel kept with distro-signed vmlinuz for direct-boot fallback)"
        else
            k_log "INFO: skipping kernel re-sign (no MOK key at ${_mok_key} or sbsign missing) — SB direct-boot will need distro-signed kernel + matching shim vendor cert"
        fi
    else
        k_log "WARNING: no kernel with matching initramfs found on target — direct-boot path will fail (ZBM still usable)"
    fi

    # Write grub.cfg at both paths the distro GRUB might look for:
    # CentOS/Rocky/Fedora grubx64.efi is built with prefix \EFI\<vendor>\,
    # so it reads \EFI\<vendor>\grub.cfg first. The copy we installed at
    # \EFI\BOOT\grubx64.efi keeps that embedded prefix, so it ALSO reads
    # \EFI\centos\grub.cfg (or rocky/fedora). Write both dirs' grub.cfg to
    # the same content so whichever path runs, the menu shows up.
    #
    # Default depends on the user's Secure Boot intent:
    #
    #   SB OFF (KLDLOAD_ENABLE_SECURE_BOOT=0, the majority install case):
    #     default = `zbm`. GRUB silently chainloads ZFSBootMenu, which is
    #     the canonical kldload boot UX — boot-env picker, snapshot rollback,
    #     read-only recovery shell. This is what users see in production.
    #
    #   SB ON (KLDLOAD_ENABLE_SECURE_BOOT=1):
    #     default = `direct`. Canonical Linux SB path:
    #       shim (MS db) → grubx64 (distro CA, db) → vmlinuz (distro CA, db)
    #                   → zfs.ko (per-install MOK leaf, MokListRT)
    #     ZBM is NOT the default under SB because shim 15.8's SBAT enforcement
    #     rejects ZBM's chainload regardless of cert validity (upstream gap —
    #     ZBM's `.sbat` declares only `sbat,1` + `systemd-stub`, no `shim,X`
    #     entry). Diagnosed end-to-end in commits 06fd6f2 + ccae3d3. Real fix
    #     is upstream or via 1.2.0's sd-boot+UKI replacement plan.
    #
    # ZBM stays installed at /EFI/zbm/ in both cases — SB users can pick it
    # from the GRUB menu (ESC at boot) after disabling SB in firmware to reach
    # the boot-env selector for rollback.
    #
    # Why this matters: from kldload 1.0.5 through 1.1.0 the default was
    # `direct` unconditionally, which silently hid ZBM from EVERY install —
    # SB users (small minority) AND non-SB users (the majority). Users
    # reported "ZBM has been gone for a week." Restoring SB-state-aware
    # default brings the boot-env UX back for the 95% case without breaking
    # SB users' chain.
    #
    # A visible 5s menu (timeout=5, timeout_style=menu) lists ZBM, direct and
    # rescue; without a keypress the default boots exactly as before. This was
    # a hidden zero-timeout menu reachable only by pressing ESC, which meant
    # in practice it was not reachable at all.
    # The default keys on the operator's Secure Boot INTENT, never on the
    # firmware SB state at install time. The install-then-enable-SB flow
    # (install with SB intent, then enable SB + enroll MOK in firmware
    # afterward) means firmware SB is commonly OFF during install — so a
    # `mokutil --sb-state` check here baked `default=zbm` and then FAILED
    # under SB: ZBM cannot load a kernel under Secure Boot (SBAT gap), and
    # `fallback=direct` can't rescue it because the ZBM *chainload succeeds*
    # (the failure is inside ZBM, after grub handed off). Confirmed on
    # hardware 2026-07-24. `direct` (shim → distro-signed grub → MOK-signed
    # kernel) boots under SB AND without it, so it is the correct default
    # whenever SB is intended; ZBM stays reachable with ESC. SB-off installs
    # (intent=0) keep ZBM as the default boot-env picker.
    #
    # KEYS ON INTENT, NOT FIRMWARE STATE — and that is deliberate.
    #
    # Reading mokutil --sb-state here looks obviously right and is wrong. The
    # normal flow is install with SB intent, then enable SB and enroll the MOK
    # in firmware AFTERWARDS, so firmware SB is commonly OFF during the
    # install. A firmware check therefore bakes default=zbm and the machine
    # breaks the moment SB is switched on: ZBM cannot load a kernel under
    # Secure Boot (SBAT gap), and fallback=direct cannot rescue it because the
    # chainload SUCCEEDS — the failure happens inside ZBM after grub has
    # handed off. Confirmed on hardware 2026-07-24, and re-introduced by
    # mistake on 2026-08-18 before this note was expanded.
    #
    # `direct` boots with SB and without it, so it is the safe default
    # whenever SB is intended. Operators who are not using Secure Boot untick
    # the Secure Boot card in the installer and get ZBM as the default
    # boot-environment picker; ZBM also stays reachable from the 5s menu.
    local _grub_default="zbm"
    [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]] && _grub_default="direct"
    k_log "GRUB default entry: ${_grub_default} (Secure Boot intent: ${KLDLOAD_ENABLE_SECURE_BOOT:-1})"

    # Kernel args for the `direct` entry differ for ENCRYPTED installs: the
    # passphrase prompt raised by the initramfs (dracut 90zfs / distro zfs hook)
    # MUST be visible. `rhgb quiet` routes it through plymouth's splash, and if
    # the plymouth password agent isn't pulled into the initramfs the prompt is
    # swallowed — the box sits at a blank splash looking hung when it is really
    # waiting for a passphrase (the "encryption is presumed broken" symptom).
    # For encrypted installs drop the splash and force the prompt onto tty1 +
    # serial so it's unmistakable. Plaintext installs keep the quiet splash.
    # HISTORY: 2026-07-26 encrypted-boot path audit.
    #
    # APPEND the console args, do not replace. This line used to assign, so an
    # encrypted install lost `quiet` and was the only configuration that booted
    # with full kernel log output — straight over the passphrase prompt.
    #
    # zfs-initramfs writes the prompt to /dev/console and then waits. With
    # kernel messages still printing, the prompt scrolls away as soon as it
    # appears, so the screen looks like log spam with no question on it.
    # Pressing Enter submits an empty passphrase, zfs-initramfs re-prompts, and
    # THAT copy is visible because the message storm has died down by then —
    # which is exactly the reported behaviour: "it never displays the prompt
    # unless you press enter", with corrupted output before it (2026-08-18).
    #
    # rhgb is a Fedora-ism and inert on Debian; `quiet` is the one that matters
    # here, and it is precisely the flag the encrypted path was dropping.
    local _direct_bootargs="rhgb quiet"
    [[ "${KLDLOAD_ZFS_ENCRYPT:-0}" == "1" ]] &&
        _direct_bootargs="rhgb quiet $(k_console_args)"

    # The GPU args have to be HERE as well as in the ZBM property, because
    # this entry is the one Secure Boot actually boots.
    #
    # bootstrap.sh blacklists nouveau by setting org.zfsbootmenu:commandline,
    # on the stated assumption that "kldload boots via ZBM". That is true
    # only when Secure Boot is OFF. Ten lines above, _grub_default flips to
    # "direct" when KLDLOAD_ENABLE_SECURE_BOOT=1, because ZBM cannot
    # chainload under shim 15.8 — and the direct entry's command line is
    # written right here, from scratch, carrying none of it.
    #
    # HISTORY: 2026-08-13, fiend. First install with Secure Boot enabled.
    # The ZFS property was set correctly and read by nobody: /proc/cmdline
    # showed BOOT_IMAGE=/EFI/BOOT/vmlinuz with no blacklist, nouveau claimed
    # the RTX 3080, and akmod-nvidia's freshly built, correctly MOK-signed
    # nvidia.ko could not bind — `modprobe nvidia` returned "No such
    # device", which reads like missing hardware rather than a boot
    # argument. Turning Secure Boot on silently disabled the GPU. The
    # operator also lost the boot-environment picker without being told.
    #
    # Same detection as bootstrap.sh (lspci on the LIVE system, which is the
    # same hardware being installed to) so the two cannot disagree.
    #
    # ONLY when a driver will actually load. Hardware detection alone is not
    # enough: blacklisting nouveau with no nvidia.ko removes the last display
    # driver, and THIS is the cmdline that boots — the ZFS property above is
    # not read on the direct-EFI path.
    #
    # HISTORY: 2026-08-18, RTX 3080, offline install. NVIDIA's vendor repo was
    # unreachable and Debian's driver cannot build on the backports kernel, so
    # nothing provided nvidia.ko — but the blacklist went on regardless and the
    # machine booted with /sys/class/drm holding only `version`: no card, no
    # display, lightdm "active" with nothing to draw on. The operator saw a
    # dead desktop; every log line claimed the driver was installed.
    #
    # The UNKNOWN case must fail toward keeping a display. An earlier version of
    # this guard put the blacklist in the else branch, so a missing
    # _k_nvidia_will_load (lib load order changing) silently restored the very
    # bug being fixed. Blacklisting on no information risks a black screen;
    # not blacklisting costs NVIDIA one extra reboot, because kldload-firstboot
    # applies the blacklist itself once nvidia.ko actually exists.
    if lspci 2>/dev/null | grep -qiE 'vga.*nvidia|3d.*nvidia'; then
        _nv_will_load=0
        if declare -F _k_nvidia_will_load >/dev/null 2>&1; then
            _k_nvidia_will_load "${target}" && _nv_will_load=1
        else
            k_log "WARNING: _k_nvidia_will_load unavailable — not blacklisting nouveau (fail-safe)"
        fi
        if [[ "$_nv_will_load" == "1" ]]; then
            _direct_bootargs+=" rd.driver.blacklist=nouveau,nova_core"
            _direct_bootargs+=" modprobe.blacklist=nouveau,nova_core nvidia-drm.modeset=1"
        else
            k_log "NVIDIA GPU present but NO driver installed — not blacklisting nouveau"
            k_log "  Blacklisting it without nvidia.ko would leave this machine with no display"
            k_log "  driver at all. nouveau stays enabled; kldload-firstboot adds the blacklist"
            k_log "  once a driver is really present."
        fi
        unset _nv_will_load
    fi

    # Cap the ARC on the COMMAND LINE, not only in /etc/modprobe.d.
    #
    # profiles.sh writes zfs_arc_max into /etc/modprobe.d/zfs.conf and that
    # file has never taken effect on a kldload install. On root-on-ZFS the zfs
    # module is loaded by the INITRAMFS, before that file exists, and nothing
    # regenerates the initramfs afterwards — `lsinitrd | grep
    # modprobe.d/zfs.conf` returns zero on a fresh install.
    #
    # HISTORY: 2026-08-13. zfs.conf said 31.3G; the live limit was 61.7G, the
    # whole machine. That host also ran a 39 GB VM fleet with no swap: ARC took
    # 21.6 GB, free memory fell to 6 GB of 62 GB, and the desktop stopped
    # responding well enough to be reported as frozen. Capping ARC by hand
    # returned 17 GB within twenty seconds.
    #
    # A module parameter on the kernel command line is honoured wherever the
    # module loads, initramfs included, so it cannot be missed by an initramfs
    # that was built at the wrong moment. Half of RAM, matching the value
    # profiles.sh documents.
    local _ram_b _arc_b
    _ram_b="$(awk '/MemTotal/{print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)"
    _arc_b=$((_ram_b / 2))
    ((_arc_b > 0)) || _arc_b=8589934592
    _direct_bootargs+=" zfs.zfs_arc_max=${_arc_b}"
    local _grub_cfg=""
    read -r -d '' _grub_cfg <<GRUBCFG || true
# kldload — auto-generated at install time
# default boot target depends on FIRMWARE Secure Boot state at install time:
#   SB inactive → zbm (boot-env picker, the kldload UX)
#   SB active   → direct (signed chain — ZBM cannot chainload under shim 15.8)
# fallback=direct: if the zbm entry fails (e.g. the operator enables SB in
# firmware AFTER install, and shim then rejects ZBM's chainload), GRUB falls
# through to the signed direct entry instead of stalling at a hidden menu.
# A VISIBLE five-second menu, not a hidden zero.
#
# It used to be timeout=0 + timeout_style=hidden, with ESC as the documented
# way to reach ZBM and rescue. In practice nobody finds a key you have to know
# about and press inside a window with no prompt: the operator's report was
# simply "didn't see any zfsbm" (2026-08-15). Five seconds is long enough to
# read three entries and choose one, short enough that an unattended reboot in
# a cluster is not meaningfully slower.
#
# The DEFAULT is unchanged, so behaviour without a keypress is identical --
# this only makes the choice discoverable.
set timeout=5
set timeout_style=menu
set default=${_grub_default}
set fallback=direct

menuentry "kldload — ZFS Boot Menu (boot environments + snapshot rollback)" --id=zbm {
    chainloader /EFI/zbm/BOOTX64.EFI
}

menuentry "kldload — direct kernel boot (Secure Boot compatible)" --id=direct {
    linux  /EFI/BOOT/vmlinuz root=ZFS=${_zfs_root:-rpool/ROOT/default} ro ${_direct_bootargs} spl_hostid=\${spl_hostid} psi=1 selinux=0
    initrd /EFI/BOOT/initrd.img
}

menuentry "kldload — rescue (single-user)" --id=rescue {
    linux  /EFI/BOOT/vmlinuz root=ZFS=${_zfs_root:-rpool/ROOT/default} ro single
    initrd /EFI/BOOT/initrd.img
}
GRUBCFG

    for _gcfg_dir in "${target}/boot/efi/EFI/centos" \
        "${target}/boot/efi/EFI/rocky" \
        "${target}/boot/efi/EFI/fedora" \
        "${target}/boot/efi/EFI/redhat" \
        "${target}/boot/efi/EFI/debian" \
        "${target}/boot/efi/EFI/ubuntu" \
        "${zbm_fallback_dir}"; do
        if [[ -d "$_gcfg_dir" ]]; then
            printf '%s\n' "$_grub_cfg" >"${_gcfg_dir}/grub.cfg"
        fi
    done
    k_log "grub.cfg installed — direct kernel boot (no ZFS grub module needed)"

    # Keep ZBM at \EFI\zbm\ as an alternate boot target; don't promote it to
    # grubx64.efi any more (causes SBAT rejection under CentOS shim).
    k_log "ZFSBootMenu kept at \\EFI\\zbm\\BOOTX64.EFI for non-SB / MOK-chain use"

    # Install a kernel-install hook so the ESP copies stay in sync when
    # yum/dnf/apt upgrades the kernel. Without this the ESP boots a stale
    # kernel after the first kernel update.
    mkdir -p "${target}/etc/kernel/install.d"
    cat >"${target}/etc/kernel/install.d/99-kldload-esp.install" <<'ESPHOOK'
#!/bin/bash
# kldload — copy new kernel + initramfs to the ESP so the SB GRUB path
# (grubx64.efi + /EFI/BOOT/vmlinuz + /EFI/BOOT/initrd.img) boots the
# latest kernel instead of the install-time one. Runs for every
# add/remove kernel event from kernel-install(8) and systemd's dkms hooks.
#
# NB: this hook uses if/elif rather than the ergonomic `[[ -f X ]] && cmd`
# chain because `set -e` treats a failed test as a script-aborting error
# (the test itself returns 1 when the file is absent, and the AND-list's
# exit propagates). On Fedora, the Debian-style /boot/initrd.img-$KVER
# never exists; under the old `&&` form the hook copied the real Fedora
# initramfs successfully, then tested for the Debian path, failed the
# test, and exited 1 — making dnf report a phantom kernel-install
# failure on every kernel update. Caught on .107 XPS 2026-05-16 after a
# routine `dnf update` pulled kernel 7.0.8. The actual ESP sync had
# already succeeded; the warning was cosmetic noise. if/elif also short-
# circuits the second copy cleanly so we don't overwrite the just-copied
# Fedora initramfs with a (non-existent) Debian one.
set -e
COMMAND="${1:-}"
KVER="${2:-}"
ESP=/boot/efi/EFI/BOOT
[[ -d "$ESP" ]] || exit 0
case "$COMMAND" in
    add)
        if [[ -f /boot/vmlinuz-"$KVER" ]]; then
            cp -f /boot/vmlinuz-"$KVER" "$ESP/vmlinuz"
        fi
        if   [[ -f /boot/initramfs-"$KVER".img ]]; then
            cp -f /boot/initramfs-"$KVER".img "$ESP/initrd.img"
        elif [[ -f /boot/initrd.img-"$KVER" ]]; then
            cp -f /boot/initrd.img-"$KVER" "$ESP/initrd.img"
        fi
        ;;
    remove)
        # If this was the kernel whose initramfs lives on ESP, point back
        # at the newest remaining one.
        newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
        if [[ -n "$newest" ]]; then
            cp -f "$newest" "$ESP/vmlinuz"
        fi
        newer_ir="$(ls -1 /boot/initramfs-*.img /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)"
        if [[ -n "$newer_ir" ]]; then
            cp -f "$newer_ir" "$ESP/initrd.img"
        fi
        ;;
esac
exit 0
ESPHOOK
    chmod 0755 "${target}/etc/kernel/install.d/99-kldload-esp.install"
    k_log "Kernel-install ESP sync hook installed (keeps /EFI/BOOT/vmlinuz fresh on kernel updates)"

    # ── Auto-refresh /EFI/BOOT/grubx64.efi from distro updates ──────────────
    # Defends against BootHole-class CVEs where shim ships a new SBAT level
    # that revokes old grub signatures. The distro updates
    # /boot/efi/EFI/{centos,rocky,fedora,redhat,debian,ubuntu}/grubx64.efi
    # via dnf/apt; our copy at /EFI/BOOT/grubx64.efi goes stale and the next
    # SBAT-aware shim run rejects it under SB.
    #
    # Mechanism: systemd path unit watches every distro grub source path,
    # fires the .service which re-copies to /EFI/BOOT/ if the bytes drifted.
    # Distro-agnostic — no dnf-plugin / apt-trigger to maintain per package
    # manager. Runs on FS-level mtime change, so any package upgrade that
    # touches the source binary triggers exactly one refresh.
    #
    # Defensive mkdir: profiles.sh:819 normally creates ${target}/usr/local/sbin
    # earlier in the install. Caught 2026-05-14 on .113 F44 desktop install:
    # the cat heredoc below failed with set -e because the directory wasn't
    # present (likely a chroot/mount transient — dataset auto-unmount, or the
    # profile stage took a different path for desktop). Without this mkdir,
    # the failure halts bootloader.sh BEFORE the shim install at line ~727,
    # leaving the target with no BOOTX64.EFI in /EFI/BOOT/ and a broken
    # boot chain. Cheap to make this idempotent.
    mkdir -p "${target}/usr/local/sbin"
    cat >"${target}/usr/local/sbin/kldload-grub-refresh" <<'GRUBREFRESH'
#!/usr/bin/env bash
# kldload-grub-refresh — sync /EFI/BOOT/grubx64.efi from the distro's
# signed copy after a package update. Needed because shim's SBAT
# enforcement bumps periodically (BootHole, ESET, etc.) and a stale
# on-ESP grub binary will fail verification under SB.
set -euo pipefail

ESP_BOOT="/boot/efi/EFI/BOOT/grubx64.efi"

[[ -d "$(dirname "$ESP_BOOT")" ]] || exit 0

for src in /boot/efi/EFI/centos/grubx64.efi \
           /boot/efi/EFI/rocky/grubx64.efi \
           /boot/efi/EFI/fedora/grubx64.efi \
           /boot/efi/EFI/redhat/grubx64.efi \
           /boot/efi/EFI/debian/grubx64.efi \
           /boot/efi/EFI/ubuntu/grubx64.efi; do
    [[ -f "$src" ]] || continue
    if ! cmp -s "$src" "$ESP_BOOT" 2>/dev/null; then
        cp -f "$src" "${ESP_BOOT}.tmp"
        sync
        mv -f "${ESP_BOOT}.tmp" "$ESP_BOOT"
        sync
        logger -t kldload-grub-refresh "refreshed ${ESP_BOOT} from ${src}"
        break
    fi
done
GRUBREFRESH
    chmod 0755 "${target}/usr/local/sbin/kldload-grub-refresh"

    cat >"${target}/usr/lib/systemd/system/kldload-grub-refresh.service" <<'GRUBREFRESHSVC'
[Unit]
Description=kldload — refresh /EFI/BOOT/grubx64.efi from distro update
ConditionPathIsMountPoint=/boot/efi

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kldload-grub-refresh
GRUBREFRESHSVC

    cat >"${target}/usr/lib/systemd/system/kldload-grub-refresh.path" <<'GRUBREFRESHPATH'
[Unit]
Description=kldload — watch for distro grubx64.efi updates
After=local-fs.target

[Path]
PathChanged=/boot/efi/EFI/centos/grubx64.efi
PathChanged=/boot/efi/EFI/rocky/grubx64.efi
PathChanged=/boot/efi/EFI/fedora/grubx64.efi
PathChanged=/boot/efi/EFI/redhat/grubx64.efi
PathChanged=/boot/efi/EFI/debian/grubx64.efi
PathChanged=/boot/efi/EFI/ubuntu/grubx64.efi

[Install]
WantedBy=multi-user.target
GRUBREFRESHPATH

    # Enable inside chroot so it activates on first boot. Use --no-reload
    # because target systemd isn't running.
    if chroot "${target}" systemctl enable kldload-grub-refresh.path \
        >/dev/null 2>&1; then
        k_log "kldload-grub-refresh.path enabled (auto-refreshes ESP grubx64.efi on distro updates)"
    else
        # Fallback: hand-create the wants symlink.
        mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
        ln -sf /usr/lib/systemd/system/kldload-grub-refresh.path \
            "${target}/etc/systemd/system/multi-user.target.wants/kldload-grub-refresh.path"
        k_log "kldload-grub-refresh.path enabled via wants symlink (chroot systemctl unavailable)"
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
        if [[ -f "$_s" ]]; then
            shim_src="$_s"
            break
        fi
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
    echo '\EFI\BOOT\BOOTX64.EFI' >"${target}/boot/efi/startup.nsh"
    k_log "startup.nsh written for exported image boot support"

    # ── Write fstab (ESP only — ZFS mounts are handled by zfs-mount) ─────────

    local efi_uuid
    efi_uuid="$(blkid -s UUID -o value "${efi_part}")"
    [[ -n "${efi_uuid}" ]] || k_die "could not determine EFI UUID for ${efi_part}"

    cat >"${target}/etc/fstab" <<EOFSTAB
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

    # ── Force-include hostid + zpool.cache in the initramfs ──────────────────
    #
    # The 90zfs dracut module SHOULD pick up /etc/zfs/zpool.cache automatically,
    # but in practice depends on the cache file existing AT THE TIME dracut
    # runs AND on the module version being current. /etc/hostid is NOT
    # auto-included by 90zfs in some Fedora/Rocky packagings, leading to a
    # mismatch between the initramfs hostid and the pool's stamped hostid →
    # zpool import retries with timeout → boot freezes for 60+s on first boot,
    # appears to "fix itself" by the time the operator power-cycles.
    # Caught on Dell XPS 13 (.137) 2026-05-17. Confirmed missing via:
    #   lsinitrd /boot/initramfs-*.img | grep -E 'hostid|zpool.cache'  → empty.
    #
    # Drop an explicit dracut config that:
    #   - Forces both files into the initramfs unconditionally
    #   - Forces 90zfs module (belt + suspenders)
    #   - Disables hostonly so the initramfs is portable across hardware
    mkdir -p "${target}/etc/dracut.conf.d"
    cat >"${target}/etc/dracut.conf.d/90-kldload-zfs.conf" <<'DRACUT'
# kldload — explicit hostid + zpool.cache include so first-boot import
# succeeds without retry. hostonly=no makes the initramfs portable.
add_dracutmodules+=" zfs "
install_items+=" /etc/hostid /etc/zfs/zpool.cache "
hostonly="no"
DRACUT
    k_log "Wrote /etc/dracut.conf.d/90-kldload-zfs.conf (hostid + cachefile in initramfs)"

    # ── Rebuild initramfs (picks up ZFS + hostid) ─────────────────────────────

    if [[ -x "${target}/usr/bin/update-initramfs" ]]; then
        chroot "${target}" update-initramfs -c -k all >&7 2>&1 ||
            chroot "${target}" update-initramfs -u -k all >&7 2>&1 ||
            k_log "WARNING: update-initramfs had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
    elif [[ -x "${target}/usr/bin/mkinitcpio" ]]; then
        # Arch Linux uses mkinitcpio — rebuild all presets
        k_log "Rebuilding initramfs with mkinitcpio..."
        chroot "${target}" mkinitcpio -P >&7 2>&1 ||
            k_log "WARNING: mkinitcpio had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
    elif [[ -x "${target}/sbin/mkinitfs" ]]; then
        # Alpine Linux uses mkinitfs
        k_log "Rebuilding initramfs with mkinitfs..."
        local _akver
        _akver=$(ls "${target}/lib/modules/" 2>/dev/null | grep lts | head -1)
        [[ -z "$_akver" ]] && _akver=$(ls "${target}/lib/modules/" 2>/dev/null | grep -v '^$' | head -1)
        if [[ -n "$_akver" ]]; then
            chroot "${target}" mkinitfs -k "$_akver" >&7 2>&1 ||
                k_log "WARNING: mkinitfs had errors — check ${KLDLOAD_LOG_DIR}/bootloader.log"
        fi
    elif [[ -x "${target}/usr/bin/dracut" ]]; then
        # Verify zfs-dracut is installed — without it, dracut --add "zfs" silently
        # produces an initramfs that can't import ZFS pools, causing a boot loop.
        if [[ ! -d "${target}/usr/lib/dracut/modules.d/90zfs" ]]; then
            k_log "WARNING: dracut ZFS module (90zfs) not found — attempting zfs-dracut install"
            # Two issues to handle here:
            #   1. dnf5 (Fedora 44) requires --skip-broken AFTER `install`, not
            #      before. Older dnf4 (CentOS 9 etc) accepts both. We use the
            #      post-subcommand position which is valid for both.
            #   2. The host-side --installroot dnf inherits the BUILD HOST's
            #      --releasever default, not the target's. Hardcoding "9"
            #      worked when live env was CentOS 9; on F44 live env this
            #      now defaults to 44, which 404s for zfs-on-linux. Read the
            #      target's actual release file to get the right value.
            local _tgt_rel
            _tgt_rel="$(rpm --root="${target}" -q --qf '%{VERSION}' system-release 2>/dev/null ||
                rpm --root="${target}" -q --qf '%{VERSION}' centos-stream-release 2>/dev/null ||
                rpm --root="${target}" -q --qf '%{VERSION}' fedora-release 2>/dev/null ||
                echo 9)"
            dnf --installroot="${target}" --releasever="${_tgt_rel}" \
                --nogpgcheck -y install zfs-dracut --skip-broken >&7 2>&1 ||
                chroot "${target}" dnf install -y --nogpgcheck zfs-dracut --skip-broken >&7 2>&1 ||
                k_log "CRITICAL: zfs-dracut install failed — system may not boot from ZFS"
        fi
        # Rebuild initramfs PER kernel that actually has zfs.ko.
        # Skip kernels with no zfs.ko — dracut's `*** Including module: zfs ***`
        # step calls dracut-install -m zfs, which fails when no zfs.ko exists
        # for that kernel, and the whole initramfs build aborts. Multi-kernel
        # installs commonly leave one kernel without zfs.ko (DKMS only builds
        # for the kernel matching chroot's running headers — see Rocky 9
        # kernel-697 vs kernel-611 split, project_f44_cutover_findings.md).
        # No point trying to build that initramfs anyway; the staged direct-
        # boot path already filters to a kernel that HAS zfs.ko.
        local _kver _kdir _zfsko
        for _kver in "${target}"/usr/lib/modules/*/vmlinuz "${target}"/lib/modules/*/vmlinuz; do
            [[ -f "$_kver" ]] || continue
            _kdir="$(dirname "$_kver")"
            _kver="$(basename "$_kdir")"
            # zfs.ko may be at extra/zfs.ko or extra/zfs.ko.xz depending on packager
            _zfsko=""
            for _candidate in "$_kdir/extra/zfs.ko" "$_kdir/extra/zfs.ko.xz" \
                "$_kdir/extra/zfs/zfs.ko" "$_kdir/extra/zfs/zfs.ko.xz"; do
                [[ -f "$_candidate" ]] && {
                    _zfsko="$_candidate"
                    break
                }
            done
            if [[ -z "$_zfsko" ]]; then
                k_log "skipping initramfs build for ${_kver} — no zfs.ko (DKMS didn't build for this kernel)"
                continue
            fi
            chroot "${target}" dracut --force --add "zfs" --kver "$_kver" >&7 2>&1 ||
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

        # Create a fresh "kldload" boot entry. WHERE it points follows the
        # Secure Boot decision, because the shim chain only earns its cost when
        # Secure Boot is actually on.
        #
        #   SB ON:  firmware → shim → signed GRUB → chainloader → ZFSBootMenu.
        #           Every link is needed: only shim is Microsoft-signed, and
        #           shim will not chainload ZBM directly (SBAT gap, shim 15.8).
        #
        #   SB OFF: firmware → ZFSBootMenu. Nothing in between validates
        #           anything, so shim and GRUB are pure cost — an extra two
        #           stages and a five-second menu in front of the boot manager
        #           the operator actually wants.
        #
        # HISTORY: this pointed at shim unconditionally. After Secure Boot
        # became opt-out (2026-08-19) every install still booted
        # firmware → shim → GRUB → 5s menu → ZBM with Secure Boot disabled and
        # nothing verifying a signature anywhere along it. The operator's
        # report was "it went to grub, then to zbm" — two stages they never
        # asked for, on a machine where neither could do its job.
        local _efi_target='\EFI\BOOT\BOOTX64.EFI' _efi_desc="shim (Secure Boot chain)"
        if [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" != "1" ]]; then
            _efi_target='\EFI\zbm\BOOTX64.EFI'
            _efi_desc="ZFSBootMenu (direct — Secure Boot off)"
        fi
        k_log "EFI boot entry → ${_efi_target}  [${_efi_desc}]"
        efibootmgr \
            -c -d "${disk}" -p "${part_num}" \
            -L "kldload" \
            -l "${_efi_target}" >&7 2>&1 ||
            k_log "WARNING: efibootmgr entry creation failed"

        local _uefi_bootnum
        _uefi_bootnum=$(efibootmgr 2>/dev/null | grep -i 'kldload' | head -1 | grep -oP 'Boot\K[0-9A-Fa-f]+' || true)
        if [[ -n "$_uefi_bootnum" ]]; then
            efibootmgr -o "${_uefi_bootnum}" >&7 2>&1 ||
                k_log "WARNING: Could not set boot order"
            k_log "Boot order set: ${_uefi_bootnum} (shim → signed GRUB → ZFSBootMenu)"
        fi

        k_log "EFI boot entries registered: disk=${disk} part=${part_num}"
    else
        k_log "WARNING: Could not determine disk for efibootmgr — skipping EFI registration"
    fi

    # ── MOK enrollment queue (if configured) ─────────────────────────────────

    # Only when Secure Boot was actually asked for. MOK exists to get our own
    # keys trusted by shim; with SB off the modules load unsigned and the
    # enrollment buys nothing — while still showing the operator MokManager's
    # blue screen on first boot, which reads like a fault on a machine that
    # never wanted Secure Boot.
    #
    # This drops the "pre-arm the box for a later SB flip" behaviour from
    # 2026-07-22. That traded a confusing enrollment screen on every install
    # against saving a reinstall for the rare operator who flips SB on later.
    # Enabling SB afterwards now means ticking the box and reinstalling, or
    # enrolling by hand — a deliberate act, rather than a tax on everyone.
    if [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]] &&
        declare -F k_configure_mok >/dev/null 2>&1; then
        k_configure_mok
    else
        k_log "MOK enrollment skipped — Secure Boot not requested (modules load unsigned)"
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
