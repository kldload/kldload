#!/usr/bin/sh
# kldload-tpm-unlock.sh — dracut pre-mount hook 85: try the TPM before 90zfs's
# passphrase prompt (hook 90).
#
# Finds the boot dataset and its encryption root exactly as 90zfs's
# zfs-load-key.sh does, and only if that root's key is still unavailable asks
# the TPM to unseal /etc/kldload/tpm/zfs.cred (sealed to PCR 7 by
# kldload-tpm-seal) straight into `zfs load-key`. On success 90zfs finds the key
# loaded and does not prompt. On failure it says why on the console and returns,
# and 90zfs prompts as it always has: a changed Secure Boot state costs a
# passphrase, never a boot.
#
# Never prints the key. Never fails the boot: every path returns 0.
#
# NO `set -Eeuo pipefail`, and the one file the strict-mode ratchet counts on
# purpose (baseline 1 -> 2, 2026-09-19). dracut SOURCES this into its init at
# boot: errexit would turn any failing probe into an aborted boot, breaking the
# promise above, and -E and pipefail do not exist in POSIX sh. Every command's
# status is checked by hand instead.

[ -e /bin/systemctl ] || [ -e /usr/bin/systemctl ] || return 0
[ -r /etc/kldload/tpm/zfs.cred ] || return 0

# shellcheck source=/dev/null
. /lib/dracut-zfs-lib.sh

decode_root_args || return 0

while ! systemctl is-active --quiet zfs-import.target; do
    systemctl is-failed --quiet zfs-import-cache.service zfs-import-scan.service && return 0
    sleep 0.1s
done

BOOTFS="$root"
if [ "$BOOTFS" = "zfs:AUTO" ]; then
    BOOTFS="$(zpool get -Ho value bootfs | grep -m1 -vFx -)"
fi
[ -n "$BOOTFS" ] || return 0

ER="$(zfs get -Ho value encryptionroot "$BOOTFS")"
[ -n "$ER" ] && [ "$ER" != "-" ] || return 0
[ "$(zfs get -Ho value keystatus "$ER")" = "unavailable" ] || return 0

# WHY a variable and not a pipe: sh has no pipefail, so a pipe's status is
# zfs load-key's alone, and a TPM refusal "succeeded" whenever load-key took
# the empty stdin (smoke-unit caught it, 2026-09-18). printf is a builtin, so
# the key never shows in a process listing.
if _key="$(systemd-creds decrypt --name=kldload-zfs /etc/kldload/tpm/zfs.cred - 2>/tmp/kldload-tpm.err)" &&
    [ -n "$_key" ] &&
    printf '%s' "$_key" | zfs load-key "$ER" 2>>/tmp/kldload-tpm.err; then
    unset _key
    info "kldload: ${ER} unlocked by the TPM (Secure Boot state unchanged since it was sealed)"
    echo "kldload: ${ER} unlocked by the TPM" >/dev/kmsg
    return 0
fi

unset _key
_why="$(tr '\n' ' ' </tmp/kldload-tpm.err 2>/dev/null | cut -c1-200)"
rm -f /tmp/kldload-tpm.err
warn "kldload: the TPM did not release the key for ${ER}: ${_why}"
{
    echo ""
    echo "  kldload: the TPM did not unlock ${ER}."
    echo "  The Secure Boot state or boot chain changed since this machine was sealed"
    echo "  (Secure Boot turned off, keys changed, or a firmware update). Type the"
    echo "  passphrase. Once booted, run 'kldload-tpm-seal' to seal it again."
    echo ""
} >/dev/console 2>/dev/null
return 0
