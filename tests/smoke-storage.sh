#!/bin/bash
# =============================================================================
# smoke-storage.sh — does a kldloadOS STORAGE profile install actually SERVE?
# =============================================================================
#
# WHAT IT CHECKS, IN ORDER
#   1. The share dataset: rpool/srv/share exists and is what is mounted at
#      /srv/share (not a directory on the root dataset).
#   2. NFS: the server unit is active, `exportfs -v` lists /srv/share, and a
#      real mount from this host, through its OWN address, sees the share.
#   3. SMB: smbd is active and `smbclient -L` lists [share]; where anonymous
#      listing is refused (the shipped share is authenticated) the fallback is
#      the parsed config plus a live port 445.
#   4. iSCSI: the target daemon the installer enabled is active, and portal
#      discovery from this host answers -- or says plainly that it could not
#      be tried.
#
# WHY: the storage profile shipped for months as "nfs-utils, targetcli and
# samba installed" with no dataset, no export and no enabled daemon, and the
# matrix passed it because no check asked whether a storage server can serve
# storage (profiles.sh, 2026-09-18). Every check here asks the daemon or the
# kernel, not the package database: a listing from smbclient, a mount from
# mount.nfs, a portal from iscsiadm.
#
# WHY NOT 127.0.0.1 FOR NFS: first boot exports /srv/share to the machine's
# own link network (kldload-firstboot, "storage: make the machine actually
# SERVE something"). The loopback address is not in that network, so a mount
# from 127.0.0.1 is refused by a CORRECT export list. The mount goes through
# the address on the default-route interface, which is the client every real
# consumer on that network looks like.
#
# Needs root (mount). Run by tests/smoke-all.sh on the storage profile, or by
# hand: sudo bash smoke-storage.sh
# Exit: 0 every check passed · 1 a check failed · 2 not root or missing library
# =============================================================================
set -euo pipefail

case "${1:-}" in
-h | --help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

if ((EUID != 0)); then
    echo "smoke-storage.sh: needs root (a real NFS mount is part of the test)" >&2
    exit 2
fi

DISTRO=$(detect_distro)
SHARE=/srv/share
SHARE_DS=rpool/srv/share

export TERM=xterm
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — STORAGE profile                  ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
echo ""

# ─── helpers ─────────────────────────────────────────────────────────────────
# Each probe is a function so it can be exercised on its own with shims on
# PATH, without a storage server to hand.

# first_active <unit...> — the first unit of the list that is active, on
# stdout; returns 1 when none is. The daemons have one name per family
# (nfs-server / nfs-kernel-server, smb / smbd, target / tgt), and the installer
# enables whichever exists, so the test asks the same way.
first_active() {
    local u
    for u in "$@"; do
        if [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]]; then
            echo "$u"
            return 0
        fi
    done
    return 1
}

# own_address — this host's IPv4 on the default-route interface, the address
# first boot's export network was derived from. Empty when there is none.
own_address() {
    local dev
    dev="$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -n 1)"
    [[ -n "$dev" ]] || return 1
    ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

# nfs_loopback_mount <server-address> — mount the export from this host and
# look inside. Returns 0 when the mount succeeded AND could be listed; the
# reason is on stdout otherwise. Always unmounts.
nfs_loopback_mount() {
    local addr="$1" mnt err rc=0 mrc=0
    mnt="$(mktemp -d)"
    # soft + short timeo: a server that accepts the TCP connection and never
    # answers the RPC would otherwise hang the mount, and the suite with it.
    err="$(timeout 60 mount -t nfs -o soft,timeo=50,retrans=1 "${addr}:${SHARE}" "$mnt" 2>&1)" || mrc=$?
    if ((mrc == 0)); then
        if ls "$mnt" >/dev/null 2>&1; then
            echo "mounted ${addr}:${SHARE} and listed it"
        else
            echo "mounted ${addr}:${SHARE} but could not list it"
            rc=1
        fi
        timeout 60 umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true # a lazy unmount is the fallback; the mount itself already decided the result
    elif ((mrc == 124)); then
        echo "mount ${addr}:${SHARE} did not finish within 60s"
        rc=1
    else
        echo "mount ${addr}:${SHARE} failed (exit ${mrc}): ${err:-no error text}"
        rc=1
    fi
    rmdir "$mnt" 2>/dev/null || true # gone with a lazy unmount pending; not a result
    return "$rc"
}

# smb_lists_share <name> — does the SMB server list share <name>? Returns 0
# when `smbclient -L` shows it; 2 when anonymous listing is refused (the
# caller falls back to the config); 1 otherwise. Output on stdout.
smb_lists_share() {
    local name="$1" out
    # swallow: a refused listing is an answer this function classifies, not an error
    out="$(timeout 30 smbclient -L 127.0.0.1 -N 2>&1 || true)"
    if grep -qE "^[[:space:]]+${name}[[:space:]]+Disk" <<<"$out"; then
        echo "smbclient lists ${name}"
        return 0
    elif grep -qE 'NT_STATUS_ACCESS_DENIED|NT_STATUS_LOGON_FAILURE' <<<"$out"; then
        echo "anonymous listing refused: $(grep -oE 'NT_STATUS_[A-Z_]+' <<<"$out" | head -n 1)"
        return 2
    fi
    echo "no ${name} in the listing: $(grep -v '^[[:space:]]*$' <<<"$out" | head -n 2 | tr '\n' ' ' | cut -c1-140)"
    return 1
}

# iscsi_discovery — send-targets discovery against this host's portal.
# Returns 0 with the targets on stdout; 1 with iscsiadm's complaint.
iscsi_discovery() {
    local out
    if out="$(timeout 30 iscsiadm -m discovery -t st -p 127.0.0.1 2>&1)"; then
        echo "portal answered: $(head -n 1 <<<"$out")"
        return 0
    fi
    echo "discovery failed: $(head -n 1 <<<"$out" | cut -c1-140)"
    return 1
}

# ─── 1. the share dataset ────────────────────────────────────────────────────
_section "Share dataset"
test_dataset "$SHARE_DS exists" "$SHARE_DS"
_src="$(findmnt -no SOURCE "$SHARE" 2>/dev/null || true)"
if [[ "$_src" == "$SHARE_DS" ]]; then
    _pass "$SHARE is $SHARE_DS"
else
    _fail "$SHARE mount" "findmnt says '${_src:-nothing mounted}', expected $SHARE_DS — shares would land on the root dataset"
fi
for _prop in xattr=sa acltype=posixacl atime=off; do
    _got="$(zfs get -H -o value "${_prop%%=*}" "$SHARE_DS" 2>/dev/null || echo '?')"
    if [[ "$_got" == "${_prop#*=}" ]]; then
        _pass "$SHARE_DS ${_prop%%=*}=${_got}"
    else
        _warn "$SHARE_DS ${_prop%%=*}" "is '${_got}', the profile sets ${_prop#*=}"
    fi
done

# ─── 2. NFS ──────────────────────────────────────────────────────────────────
_section "NFS"
test_cmd "exportfs" "exportfs"
if _nfs_unit="$(first_active nfs-server nfs-kernel-server)"; then
    _pass "NFS server active ($_nfs_unit)"
else
    _fail "NFS server" "neither nfs-server nor nfs-kernel-server is active"
fi
_exports="$(exportfs -v 2>/dev/null || true)"
if grep -qE "^${SHARE}[[:space:]]" <<<"$_exports"; then
    _pass "exportfs lists ${SHARE}: $(grep -E "^${SHARE}[[:space:]]" <<<"$_exports" | head -n 1 | awk '{print $2}' | cut -c1-60)"
else
    _fail "NFS export" "exportfs -v does not list ${SHARE} ($(wc -l <<<"${_exports:-}") export line(s)) — first boot writes it once the network is up"
fi
if ! command -v mount.nfs >/dev/null 2>&1; then
    _fail "NFS mount" "DID NOT RUN — mount.nfs is not installed (nfs-utils / nfs-common ship it)"
elif ! _addr="$(own_address)" || [[ -z "$_addr" ]]; then
    _fail "NFS mount" "DID NOT RUN — no IPv4 address on the default-route interface, so there is no client address inside the export"
elif _why="$(nfs_loopback_mount "$_addr")"; then
    _pass "NFS mount from this host: ${_why}"
else
    _fail "NFS mount" "$_why"
fi

# ─── 3. SMB ──────────────────────────────────────────────────────────────────
_section "SMB"
if _smb_unit="$(first_active smb smbd)"; then
    _pass "SMB server active ($_smb_unit)"
else
    _fail "SMB server" "neither smb nor smbd is active"
fi
if grep -qE '^\[share\]' /etc/samba/smb.conf 2>/dev/null; then
    _pass "[share] is defined in /etc/samba/smb.conf"
else
    _fail "SMB share" "no [share] section in /etc/samba/smb.conf — first boot appends it"
fi
if ! command -v smbclient >/dev/null 2>&1; then
    _fail "SMB listing" "DID NOT RUN — smbclient is not installed (samba-client / smbclient)"
else
    _smb_rc=0
    _why="$(smb_lists_share share)" || _smb_rc=$?
    case "$_smb_rc" in
    0) _pass "SMB listing: ${_why}" ;;
    2)
        # The shipped share is authenticated (guest ok = no), and a server that
        # refuses anonymous enumeration is configured, not broken. Fall back to
        # the parsed config and a live port: both have to hold.
        if command -v testparm >/dev/null 2>&1 && testparm -s 2>/dev/null | grep -qE '^\[share\]' &&
            timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/445' 2>/dev/null; then
            _pass "SMB listing: ${_why}; testparm parses [share] and smbd answers on 445"
        else
            _fail "SMB listing" "${_why}, and testparm does not parse [share] or nothing answers on 445"
        fi
        ;;
    *) _fail "SMB listing" "$_why" ;;
    esac
fi

# ─── 4. iSCSI ────────────────────────────────────────────────────────────────
# The profile installs targetcli (RPM) or tgt (Debian) and the installer
# enables whichever unit exists; nothing configures a target yet. So: the
# daemon must be up, and discovery says whether a portal answers.
_section "iSCSI"
if command -v targetcli >/dev/null 2>&1 || command -v tgtadm >/dev/null 2>&1; then
    _pass "iSCSI target tooling installed ($(command -v targetcli || command -v tgtadm))"
    if _iscsi_unit="$(first_active target tgt)"; then
        _pass "iSCSI target daemon active ($_iscsi_unit)"
    else
        _fail "iSCSI target daemon" "neither target nor tgt is active"
    fi
    if ! command -v iscsiadm >/dev/null 2>&1; then
        # The initiator is not part of the storage profile, so its absence is
        # not this server's defect -- but the check did not run, and the line
        # must say so rather than read as a pass.
        _warn "iSCSI discovery" "DID NOT RUN — iscsiadm is not installed (iscsi-initiator-utils / open-iscsi)"
    elif _why="$(iscsi_discovery)"; then
        _pass "iSCSI discovery: ${_why}"
    else
        _fail "iSCSI discovery" "${_why} — the daemon is up but no portal answers on 127.0.0.1:3260; nothing configures a target yet"
    fi
else
    _fail "iSCSI target tooling" "neither targetcli nor tgtadm is installed — the profile lists one of them"
fi

summary
