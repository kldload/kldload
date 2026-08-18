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
    *nvme* | *mmcblk* | *loop*) echo "${disk}p" ;;
    *) echo "${disk}" ;;
    esac
}

k_zfs_cleanup_old() {
    k_zfs_log "Cleaning previous mounts/pools on ${KLDLOAD_DISK}"

    # Stop zfs-zed + zfs-import-cache.service on the LIVE env so they
    # don't race the install — zed reacts to DKMS load events / pool
    # state changes triggered during pass 3 install scripts and can
    # `zpool export` rpool mid-install, leaving /target as an empty
    # mountpoint dir for everything downstream. We re-enable on
    # reboot when the new system comes up. Idempotent.
    systemctl stop zfs-zed.service 2>/dev/null || true
    systemctl stop zfs-import-cache.service 2>/dev/null || true
    # Mask the F44 zfs udev rule too — it auto-runs `zpool import`
    # without altroot when udev sees ZFS module load events, which the
    # chroot's zfs-dkms %post triggers. udev import overrides our
    # altroot=/target setup → /target unmounts mid-install, every chroot
    # call against /target then fails with "command not found".
    # Move the rule out of the way; restore on reboot via tmpfs reset.
    if [[ -f /usr/lib/udev/rules.d/90-zfs.rules ]]; then
        mv -f /usr/lib/udev/rules.d/90-zfs.rules /usr/lib/udev/rules.d/90-zfs.rules.kldload-disabled 2>/dev/null ||
            ln -sf /dev/null /etc/udev/rules.d/90-zfs.rules 2>/dev/null || true
        udevadm control --reload-rules 2>/dev/null || true
    fi

    sync || true
    swapoff -a || true

    umount -R "${KLDLOAD_TARGET_MNT}/boot/efi" 2>/dev/null || true
    umount -R "${KLDLOAD_TARGET_MNT}" 2>/dev/null || true

    # ── Defensive: release anything holding the target disk ───────────────────
    # Most real-world installs aren't replacing a prior kldload — the target
    # disk has Windows, stock Linux, LVM, mdraid, or auto-mounted partitions
    # that will refuse to wipe until deactivated. Do everything with `|| true`
    # so a box with none of these still breezes through.
    local _disk_basename="${KLDLOAD_DISK##*/}"
    # Exact device names of the target disk + its partitions (sda, sda1, …;
    # nvme0n1, nvme0n1p1, …), matched below as WHOLE WORDS. Fixes a data-loss
    # b652-class bug: an unanchored basename "sda" also matched "sdab" (a DIFFERENT
    # disk) and could DESTROY ITS POOL. grep -wE against the exact set can only ever
    # hit the real target disk.
    local _disk_devs
    _disk_devs="$(lsblk -lno NAME "${KLDLOAD_DISK}" 2>/dev/null | paste -sd'|')"
    [[ -n "${_disk_devs}" ]] || _disk_devs="${_disk_basename}"

    # 1. Unmount every filesystem currently mounted from this disk (auto-mount
    #    daemons, leftover /mnt entries, etc.). Iterate child partitions too.
    lsblk -ln -o NAME,MOUNTPOINT "${KLDLOAD_DISK}" 2>/dev/null |
        awk 'NF==2 && $2!="[SWAP]" {print $2}' |
        while read -r _mp; do
            [[ -n "${_mp}" ]] && umount -R "${_mp}" 2>/dev/null || true
        done

    # 2. Deactivate any LVM volume groups that include a PV on this disk.
    if command -v pvs >/dev/null 2>&1; then
        pvs --noheadings -o pv_name,vg_name 2>/dev/null |
            grep -wE "(${_disk_devs})" | awk '{print $2}' | sort -u |
            while read -r _vg; do
                [[ -n "${_vg}" ]] && {
                    vgchange -a n "${_vg}" 2>/dev/null || true
                    k_zfs_log "  Deactivated LVM VG: ${_vg}"
                }
            done
    fi

    # 3. Stop any mdraid arrays that include this disk as a member.
    if [[ -e /proc/mdstat ]] && command -v mdadm >/dev/null 2>&1; then
        awk '/^md/ {print $1}' /proc/mdstat 2>/dev/null |
            while read -r _md; do
                if ls "/sys/block/${_md}/slaves/" 2>/dev/null | grep -qwE "(${_disk_devs})"; then
                    mdadm --stop "/dev/${_md}" 2>/dev/null || true
                    k_zfs_log "  Stopped mdraid array: /dev/${_md}"
                fi
            done
    fi

    # 4. Close any LUKS/dm-crypt mappings backed by this disk.
    if command -v dmsetup >/dev/null 2>&1; then
        dmsetup ls --target crypt 2>/dev/null | awk '{print $1}' |
            while read -r _dm; do
                [[ -z "${_dm}" || "${_dm}" == "No" ]] && continue
                if dmsetup deps -o devname "${_dm}" 2>/dev/null | grep -qwE "(${_disk_devs})"; then
                    cryptsetup close "${_dm}" 2>/dev/null || dmsetup remove "${_dm}" 2>/dev/null || true
                    k_zfs_log "  Closed LUKS mapping: ${_dm}"
                fi
            done
    fi

    # 5. Destroy any ZFS pool (not just 'rpool') that has a vdev on this disk.
    #    zpool import with no args lists importable pools; running pools show in
    #    `zpool status`. Destroy imported first, then try to import + destroy.
    if command -v zpool >/dev/null 2>&1; then
        zpool status 2>/dev/null | awk '/pool:/ {print $2}' |
            while read -r _pool; do
                if zpool status -LP "${_pool}" 2>/dev/null | grep -qwE "(${_disk_devs})"; then
                    zpool destroy -f "${_pool}" 2>/dev/null || true
                    k_zfs_log "  Destroyed imported ZFS pool on this disk: ${_pool}"
                fi
            done
        zpool import 2>/dev/null | awk '/pool:/ {print $2}' |
            while read -r _pool; do
                zpool import -f -N "${_pool}" 2>/dev/null || continue
                if zpool status -LP "${_pool}" 2>/dev/null | grep -qwE "(${_disk_devs})"; then
                    zpool destroy -f "${_pool}" 2>/dev/null || true
                    k_zfs_log "  Destroyed exported-then-imported pool: ${_pool}"
                else
                    zpool export "${_pool}" 2>/dev/null || true
                fi
            done
    fi

    # Legacy rpool-specific cleanup (redundant with #5 but kept for belt-and-suspenders)
    zpool export rpool 2>/dev/null || true
    zpool destroy -f rpool 2>/dev/null || true

    # ── Clear the TARGET boot disk — this MUST succeed ───────────────────────
    # Everything above is best-effort teardown of OTHER pools/VGs/mdraid (|| true
    # so a clean box breezes through). Clearing the disk we're about to install
    # ONTO is different: it is load-bearing. A surviving ZFS label or partition
    # table outlives `zpool create -f` and re-surfaces at import time, so the box
    # can boot the WRONG pool — exactly the "install succeeds, reboots into a
    # brick" failure this repo exists to prevent. So: retry a few times (a disk
    # can be transiently held right after teardown), VERIFY no signatures remain,
    # and abort loudly if it's still dirty instead of building on a dirty disk.
    local _wipe_ok=0 _try
    for _try in 1 2 3; do
        wipefs -a -f "${KLDLOAD_DISK}" >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true
        sgdisk --zap-all "${KLDLOAD_DISK}" >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true
        zpool labelclear -f "${KLDLOAD_DISK}" >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true
        partprobe "${KLDLOAD_DISK}" >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true
        udevadm settle 2>/dev/null || true
        # wipefs (read-only listing here — no -a) prints nothing when the whole
        # disk carries no FS/partition/RAID signatures. Empty ⇒ genuinely clean.
        if [[ -z "$(wipefs "${KLDLOAD_DISK}" 2>/dev/null)" ]]; then
            _wipe_ok=1
            break
        fi
        k_zfs_log "Target ${KLDLOAD_DISK} still has signatures after wipe attempt ${_try}/3; retrying"
        sleep 2
    done
    if [[ "${_wipe_ok}" -ne 1 ]]; then
        k_die "Refusing to install: could not clear ${KLDLOAD_DISK} — it still holds partition/filesystem/ZFS signatures after 3 attempts. Something is holding the disk (check 'lsblk', 'zpool status', 'dmsetup ls') or the disk is failing. Aborting rather than building on a dirty disk."
    fi
    rm -rf "${KLDLOAD_TARGET_MNT:?}/"* 2>/dev/null || true

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
        sgdisk -n2:0:0 -t2:BF01 -c2:"KLDload rpool" "${disk}"
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

    # Materialise /etc/hostid on the live env BEFORE zpool create. ZFS stamps
    # the pool's owner with gethostid() at create time — if /etc/hostid
    # doesn't exist, glibc falls back to a value derived from the hostname,
    # and that derived value then does NOT match whatever the installed
    # system ends up with post-boot → rpool import fails silently → dracut
    # hangs. Writing /etc/hostid now pins the value, and the bootloader
    # step later copies this same file into target/etc/hostid so both ends
    # of the chain agree. Classic ZFS-on-root footgun; bit every XPS install
    # up through v3.5.
    if [[ ! -s /etc/hostid ]]; then
        if command -v zgenhostid >/dev/null 2>&1; then
            zgenhostid -f 2>/dev/null || true
        fi
        if [[ ! -s /etc/hostid ]]; then
            local _hex
            _hex="$(hostid 2>/dev/null | tr -cd 'a-fA-F0-9' | head -c8)"
            if [[ -n "${_hex}" ]]; then
                python3 -c "
import struct
hid = int('${_hex}', 16)
open('/etc/hostid','wb').write(struct.pack('<I', hid))
" 2>/dev/null || true
            fi
        fi
        if [[ ! -s /etc/hostid ]]; then
            dd if=/dev/urandom of=/etc/hostid bs=4 count=1 status=none 2>/dev/null || true
        fi
        chmod 0644 /etc/hostid 2>/dev/null || true
        k_zfs_log "live /etc/hostid pinned for zpool create: $(xxd -p /etc/hostid 2>/dev/null)"
    else
        k_zfs_log "live /etc/hostid already present: $(xxd -p /etc/hostid 2>/dev/null)"
    fi

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
        [[ ${#data_disks[@]} -ge 2 ]] ||
            die "mirror topology requires at least 2 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
        rpool_vdevs=(mirror "${data_disks[0]}" "${data_disks[1]}")
        k_zfs_log "rpool topology: mirror ${data_disks[0]} ${data_disks[1]}"
        ;;
    raidz1)
        [[ ${#data_disks[@]} -ge 3 ]] ||
            die "raidz1 topology requires at least 3 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
        rpool_vdevs=(raidz1 "${data_disks[@]}")
        k_zfs_log "rpool topology: raidz1 ${KLDLOAD_ZFS_DATA_DISKS}"
        ;;
    mirror-stripe)
        [[ ${#data_disks[@]} -ge 4 ]] ||
            die "mirror-stripe topology requires exactly 4 data disks; got: '${KLDLOAD_ZFS_DATA_DISKS}'"
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

    # Compatibility: live env runs OpenZFS 2.4 (Fedora 44), but target
    # distros ship a range of older ZFS versions. If we let zpool create
    # enable the full 2.4 feature set, the pool gets features like
    # raidz_expansion / longname / zilsaxattr that older ZFS doesn't
    # understand. Target boots into "pool can only be accessed in
    # read-only mode" — dracut fails to mount /sysroot r/w, drops to
    # emergency mode.
    #
    # Map (distro, release) → known ZFS major version → profile name.
    # The profile is a curated feature subset; both live (2.4) and target
    # honor it so pools created here work natively on either side.
    local _zfs_compat_target="" _zfs_compat_reason=""
    # Default 44 to match bootstrap.sh's install target (F44 + 6.19 GA + fc43 ZFS
    # bridge = the live-env combo). F44 >= 44 -> the zfs-2.4 "no restriction" branch.
    local _fedora_rel="${KLDLOAD_FEDORA_RELEASE:-44}"
    case "${KLDLOAD_DISTRO:-centos}" in
    centos | rocky)
        # CentOS Stream / Rocky default to EL10 (kernel 6.12) — EL9's 5.14 +
        # zfs-2.2 DKMS path was wedging dracut/NVIDIA on first boot. EL10 ships
        # zfs 2.3 (same el10 OpenZFS repos RHEL 10 uses). KLDLOAD_RELEASE=9 still
        # gets the conservative EL9 (zfs 2.2) profile for anyone pinning it.
        if [[ "${KLDLOAD_RELEASE:-10}" == "9" ]]; then
            _zfs_compat_target="openzfs-2.2-linux"
            _zfs_compat_reason="EL9 (centos/rocky 9) ships zfs 2.2"
        else
            _zfs_compat_target="openzfs-2.3-linux"
            _zfs_compat_reason="EL10 (centos/rocky 10) ships zfs 2.3"
        fi
        ;;
    rhel)
        # RHEL 10 (GA May 2025, kernel 6.12) — OpenZFS publishes 2.3.x for el10.
        # If 2.3 DKMS won't build against the running kernel, the resolver loop
        # at line ~340 falls back through openzfs-2.2-linux. KLDLOAD_RELEASE=9
        # users get the EL9 profile anyway (we map by distro, not release here —
        # if someone pins KLDLOAD_RELEASE=9 with distro=rhel the resolver still
        # picks a working profile, just a more conservative one).
        _zfs_compat_target="openzfs-2.3-linux"
        _zfs_compat_reason="RHEL 10 ships zfs 2.3 (el10 OpenZFS repos)"
        ;;
    fedora)
        if [[ "${_fedora_rel}" -ge 44 ]]; then
            _zfs_compat_target="" # F44+ = zfs 2.4, matches live
            _zfs_compat_reason="Fedora ${_fedora_rel} ships zfs 2.4 — same as live, no restriction"
        else
            _zfs_compat_target="openzfs-2.3-linux"
            _zfs_compat_reason="Fedora ${_fedora_rel} ships zfs 2.3"
        fi
        ;;
    debian)
        # Debian 12 bookworm = 2.1, 13 trixie = 2.3
        case "${KLDLOAD_SUITE:-trixie}" in
        bookworm)
            _zfs_compat_target="openzfs-2.1-linux"
            _zfs_compat_reason="Debian 12 bookworm ships zfs 2.1"
            ;;
        *)
            _zfs_compat_target="openzfs-2.3-linux"
            _zfs_compat_reason="Debian 13 trixie ships zfs 2.3"
            ;;
        esac
        ;;
    ubuntu)
        # Ubuntu 22.04 jammy = 2.1, 24.04 noble = 2.2
        case "${KLDLOAD_SUITE:-noble}" in
        jammy)
            _zfs_compat_target="openzfs-2.1-linux"
            _zfs_compat_reason="Ubuntu 22.04 jammy ships zfs 2.1"
            ;;
        *)
            _zfs_compat_target="openzfs-2.2-linux"
            _zfs_compat_reason="Ubuntu 24.04 noble ships zfs 2.2"
            ;;
        esac
        ;;
    arch | alpine | *)
        _zfs_compat_target=""
        _zfs_compat_reason="${KLDLOAD_DISTRO} ships rolling/unconstrained zfs"
        ;;
    esac

    # Resolve the chosen profile name; fall back to next-lower if unavailable.
    local _compat="off"
    if [[ -n "$_zfs_compat_target" ]]; then
        for _candidate in "$_zfs_compat_target" \
            openzfs-2.3-linux openzfs-2.2-linux openzfs-2.1-linux; do
            if [[ -f "/usr/share/zfs/compatibility.d/${_candidate}" ]]; then
                _compat="$_candidate"
                break
            fi
        done
    fi
    k_zfs_log "ZFS feature compat: ${_compat} (${_zfs_compat_reason})"
    local _compat_opt=()
    [[ "$_compat" != "off" ]] && _compat_opt=(-o "compatibility=${_compat}")

    local -a _zpool_create_args=(
        -o ashift=12
        -o autotrim=on
        "${_compat_opt[@]}"
        -O acltype=posixacl
        -O canmount=off
        -O compression=lz4
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=on
        -O xattr=sa
        -O mountpoint=none
        "${enc_opts[@]}"
        -R "${KLDLOAD_TARGET_MNT}"
        rpool "${rpool_vdevs[@]}"
    )
    if [[ "${KLDLOAD_ZFS_ENCRYPT}" == "1" ]]; then
        # keylocation=prompt reads the key from stdin when stdin is not a
        # TTY — feed the recorded passphrase. Without this pipe the create
        # re-prompted on the installer's TTY (TUI installs could end up with
        # a pool key that differs from the recorded answer) and got EOF on
        # webui/autoinstall runs. Mirrors backend/storage-zfs.sh
        # create_rpool_*. printf, not echo: passphrase may start with '-'.
        printf '%s\n' "${KLDLOAD_ZFS_PASSPHRASE}" | zpool create -f "${_zpool_create_args[@]}"
    else
        zpool create -f "${_zpool_create_args[@]}"
    fi

    # Root dataset hierarchy
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=noauto -o mountpoint=/ "${root_ds}"
    zfs mount "${root_ds}"

    # Stage the passphrase for firstboot TPM/clevis sealing (encrypted pools
    # only). kldload-firstboot setup_zero_trust seals it against TPM2(+tang)
    # when the seal tool is present and SHREDS this file unconditionally on
    # first boot either way. 0600 root-only, and it lives INSIDE the
    # encrypted root dataset, so at rest it is protected by the very key it
    # holds — exposure window is the first boot only. Mirrors the (dormant)
    # backend/storage-zfs.sh staging; without this the firstboot seal block
    # never had anything to seal on real installs.
    if [[ "${KLDLOAD_ZFS_ENCRYPT}" == "1" ]]; then
        mkdir -p "${KLDLOAD_TARGET_MNT}/etc/kldload"
        printf '%s' "${KLDLOAD_ZFS_PASSPHRASE}" >"${KLDLOAD_TARGET_MNT}/etc/kldload/zfs-passphrase"
        chmod 0600 "${KLDLOAD_TARGET_MNT}/etc/kldload/zfs-passphrase"
        k_zfs_log "ZFS passphrase staged for firstboot sealing (shredded at first boot)"
    fi

    # Set ZFSBootMenu properties — inherited by all boot environments
    # Both consoles get kernel output; k_console_args decides which one is
    # LAST and therefore owns /dev/console and interactive input. That choice
    # is what makes an encrypted root answerable — see k_console_args.
    # psi=1 enables Pressure Stall Information (/proc/pressure/*) — built into
    # the kernel but disabled by default on RHEL-family builds. The kldload
    # console F12 cockpit reads PSI as its headline "what's saturated right
    # now" pane; without psi=1 the pane falls back to vmstat. Detected
    # 2026-05-27 on a RHEL 10 kernel (6.12.0-211.16.1.el10_2.x86_64) that
    # ships PSI built in but boot-disabled.
    zfs set org.zfsbootmenu:commandline="rw $(k_console_args) psi=1 selinux=0" rpool/ROOT

    # ── Make the boot menu reachable ─────────────────────────────────────────
    # ZFSBootMenu is the rollback path: it is where you pick an older boot
    # environment when an update goes wrong. Nothing here set a timeout, so it
    # used ZFSBootMenu's built-in default — and on a machine whose monitor takes
    # a few seconds to sync after the firmware hands off, that countdown is over
    # before anything is on screen. Operators reported never once seeing the
    # menu (2026-08-15), which means the recovery tool was effectively absent
    # even though the boot chain was correct.
    #
    # 10 seconds: long enough to see the countdown and press a key on a slow
    # display, short enough not to feel like the machine has hung. Override with
    # KLDLOAD_ZBM_TIMEOUT; 0 boots straight through, -1 waits for a key.
    zfs set org.zfsbootmenu:timeout="${KLDLOAD_ZBM_TIMEOUT:-10}" rpool/ROOT

    # Data datasets
    zfs create -o mountpoint=/root rpool/root
    zfs create -o mountpoint=/home rpool/home
    # Per-user home dataset
    if [[ -n "${KLDLOAD_USERNAME:-}" ]]; then
        zfs create -o mountpoint="/home/${KLDLOAD_USERNAME}" "rpool/home/${KLDLOAD_USERNAME}"
        k_zfs_log "Created user home dataset: rpool/home/${KLDLOAD_USERNAME}"
    fi
    zfs create -o mountpoint=/srv rpool/srv
    zfs create -o mountpoint=/opt rpool/opt

    zfs create -o canmount=off -o mountpoint=/usr rpool/usr
    zfs create -o mountpoint=/usr/local rpool/usr/local

    zfs create -o canmount=off -o mountpoint=/var rpool/var
    zfs create -o mountpoint=/var/cache rpool/var/cache
    zfs create -o mountpoint=/var/lib rpool/var/lib
    zfs create -o mountpoint=/var/log rpool/var/log
    zfs create -o mountpoint=/var/spool rpool/var/spool
    zfs create -o mountpoint=/var/tmp rpool/var/tmp

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
    k_zfs_log "Writing stable target hostid (matching live env's pool-create hostid)"

    mkdir -p "${KLDLOAD_TARGET_MNT}/etc"

    # ALWAYS overwrite — the pool was created with the live env's hostid,
    # and the installed system MUST match it for `zpool import` to succeed
    # at boot. If we early-return here when /target/etc/hostid already
    # exists (which dnf / zfs-dkms's zgenhostid / systemd-machine-id may
    # have populated with a DIFFERENT random value during install), the
    # target's initramfs reads its own hostid, sees the pool was last
    # touched by a different hostid, refuses to import, and dracut drops
    # to "emergency mode generating /run/initramfs/rdsosreport.txt".
    if [[ -s /etc/hostid ]]; then
        cp -f /etc/hostid "${KLDLOAD_TARGET_MNT}/etc/hostid"
        k_zfs_log "  copied live /etc/hostid → ${KLDLOAD_TARGET_MNT}/etc/hostid: $(xxd -p /etc/hostid 2>/dev/null)"
    else
        dd if=/dev/urandom of="${KLDLOAD_TARGET_MNT}/etc/hostid" bs=4 count=1 status=none
        k_zfs_log "  WARNING: live /etc/hostid was empty — wrote random hostid (pool may not import on boot)"
    fi

    chmod 0644 "${KLDLOAD_TARGET_MNT}/etc/hostid" || true
}

k_storage_zfs_install() {
    export KLDLOAD_STORAGE_MODE=zfs
    export KLDLOAD_ROOT_FS_TYPE=zfs
    export KLDLOAD_TARGET_MNT

    mkdir -p "${KLDLOAD_LOG_DIR}"
    : >"${KLDLOAD_ZFS_LOG}"

    k_zfs_log "==== ZFS install start ===="
    k_zfs_log "disk=${KLDLOAD_DISK}"
    k_zfs_log "topology=${KLDLOAD_ZFS_TOPOLOGY}"
    k_zfs_log "data_disks=${KLDLOAD_ZFS_DATA_DISKS:-}"
    k_zfs_log "special_disks=${KLDLOAD_ZFS_SPECIAL_DISKS:-}"
    k_zfs_log "target=${KLDLOAD_TARGET_MNT}"
    k_zfs_log "host=${KLDLOAD_HOSTNAME}"
    k_zfs_log "encrypt=${KLDLOAD_ZFS_ENCRYPT}"

    # ZFS is normally ALREADY usable on the live image — the module is built
    # into the live kernel, or dracut loaded it to find the pool. A bare
    # `modprobe zfs` then prints
    #     modprobe: FATAL: Module zfs not found in directory /lib/modules/<kver>
    # to the console, near the top of every install, naming the LIVE kernel
    # (7.0.14-201.fc44) rather than the target's. It is not a failure: zpool
    # works in the very next line, the pool gets created, and the installed
    # system has ZFS. It was reported as a critical error twice on 2026-08-18,
    # which is the whole cost of it — an operator cannot tell a real fault
    # from this one.
    #
    # So ask whether ZFS WORKS, and only try to load it when it does not.
    if zpool --version >/dev/null 2>&1; then
        k_zfs_log "zfs already usable: $(zpool --version 2>/dev/null | head -1)"
    else
        k_zfs_log "zfs not yet usable — loading the module"
        modprobe zfs >>"${KLDLOAD_ZFS_LOG}" 2>&1 ||
            k_zfs_log "WARNING: modprobe zfs failed — the pool commands below will fail loudly if ZFS really is unusable"
    fi
    zpool --version >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true

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
    zpool status >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true

    k_zfs_log "Current zfs list:"
    zfs list >>"${KLDLOAD_ZFS_LOG}" 2>&1 || true

    k_zfs_log "==== ZFS install complete ===="
}
