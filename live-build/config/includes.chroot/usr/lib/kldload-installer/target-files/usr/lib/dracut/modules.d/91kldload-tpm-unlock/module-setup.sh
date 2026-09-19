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

install() {
    inst_multiple systemd-creds
    inst_simple /etc/kldload/tpm/zfs.cred /etc/kldload/tpm/zfs.cred
    inst_hook pre-mount 85 "${moddir}/kldload-tpm-unlock.sh"
}
