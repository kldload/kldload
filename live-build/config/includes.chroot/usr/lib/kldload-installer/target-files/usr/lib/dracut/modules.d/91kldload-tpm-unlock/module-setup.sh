#!/usr/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# dracut module 91kldload-tpm-unlock — unlock the ZFS root with the TPM before
# 90zfs asks for the passphrase.
#
# WHAT: installs kldload-tpm-unlock.sh as a pre-mount hook at priority 85, ahead
#   of 90zfs's zfs-load-key.sh (priority 90), plus systemd-creds and the sealed
#   credential /etc/kldload/tpm/zfs.cred that kldload-tpm-seal wrote.
# WHY: Secure Boot on its own is not enforced -- turn it off and the machine
#   boots anyway (operator, fiend 2026-09-18). The pool key sealed to TPM PCR 7
#   (the Secure Boot state) makes the machine unlock itself only while that
#   state is unchanged, and fall back to the passphrase, with a warning, when
#   it is not.
# CHECK: included automatically when the credential exists, never otherwise.
# ─────────────────────────────────────────────────────────────────────────────

check() {
    [[ -r /etc/kldload/tpm/zfs.cred ]] || return 255
    require_binaries systemd-creds || return 1
    return 0
}

depends() {
    echo zfs tpm2-tss
}

# Strict, in a subshell. dracut sources this file, so the options must not leak
# into dracut's own shell -- and dracut runs on every kernel update, where a
# module that aborts it costs the next boot. A failure here costs only the TPM
# unlock (90zfs still prompts), so it is reported with dwarn and dracut goes on.
# The subshell also contains a -u trip inside dracut's own helpers, whose
# variable hygiene differs by distro and is not mine to depend on. Before
# 2026-09-19 these three steps had no error handling at all.
# WARN: each step says `|| exit 1` because errexit does NOTHING here: bash
# switches it off for anything left of `||`, subshells included. The first
# version relied on it, and a stand-in inst_simple that failed let inst_hook
# run and dwarn stay silent. -u still holds, and is what the subshell is for.
install() {
    (
        set -Eeuo pipefail
        inst_multiple systemd-creds || exit 1
        inst_simple /etc/kldload/tpm/zfs.cred /etc/kldload/tpm/zfs.cred || exit 1
        inst_hook pre-mount 85 "${moddir}/kldload-tpm-unlock.sh" || exit 1
    ) || dwarn "kldload-tpm-unlock: not fully installed into this initramfs; the passphrase prompt still works"
}
