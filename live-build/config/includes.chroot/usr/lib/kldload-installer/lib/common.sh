#!/usr/bin/env bash
# Sourced by kldload-install-target — core helpers: k_log, k_die, k_mount_bind, k_umount_if_mounted
#
# 2026-09-23: k_log_section (shadowed by logging.sh's, which is sourced after
# this on every path that calls it), k_need_cmd, k_run, k_capture,
# k_require_root, k_install_file, k_assert_landed, k_bool and k_mkdir were
# removed -- each had zero callers across the tree (grep -rn per name; the
# only "k_bool" outside this file was a comment in kldload-install-target's
# header, and the only "k_run" was the unrelated kiosk_run). A helper nobody
# calls is a helper nobody exercised.
set -Eeuo pipefail

KLDLOAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
KLDLOAD_ROOT_DIR="$(cd "${KLDLOAD_LIB_DIR}/.." && pwd)"
KLDLOAD_LOG_DIR="${KLDLOAD_LOG_DIR:-/var/log/installer}"
KLDLOAD_STATE_DIR="${KLDLOAD_STATE_DIR:-/var/lib/kldload-installer}"
KLDLOAD_TARGET="${KLDLOAD_TARGET:-/target}"
KLDLOAD_DEBUG="${KLDLOAD_DEBUG:-0}"

mkdir -p "${KLDLOAD_LOG_DIR}" "${KLDLOAD_STATE_DIR}"

k_log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${KLDLOAD_LOG_DIR}/kldload-installer.log" >&2
}

k_debug() {
    if [[ "${KLDLOAD_DEBUG}" == "1" ]]; then
        k_log "DEBUG: $*"
    fi
}

k_die() {
    k_log "ERROR: $*"
    exit 1
}

# k_console_args — the console= boot arguments, ordered so the console a human
# will actually type at comes LAST.
#
# WHY THE ORDER MATTERS: given several console= arguments the kernel MIRRORS
# output to all of them, but /dev/console — the single device that carries
# interactive INPUT — is the LAST one on the line. Anything that prompts by
# reading /dev/console is therefore answerable from exactly one of them.
#
# HISTORY: 2026-08-13, fiend. A Debian install on an encrypted root booted,
# loaded ZFS, printed "zfs filesystem version 5000" and then sat there taking
# no keyboard input. The cmdline was "console=tty1 console=ttyS0,115200", so
# /dev/console was the SERIAL port; Debian's zfs-initramfs asks for the
# encryption passphrase by reading /dev/console directly, so the prompt went
# out the serial line and the physical keyboard could not answer it. Fedora
# never showed this because dracut asks via systemd-ask-password, which
# BROADCASTS the prompt to every console instead of reading one.
#
# Returns: the console arguments on stdout, interactive console last. A
# connected DRM output is the test for "somebody can stand at this machine";
# with no display attached the box is headless and serial is the only console
# that can be typed at, so the order flips.
# k_prompt_extension_applies — will the passphrase-prompt extension actually run
#                              on this target's initramfs?
#
# stdout: nothing. Exit 0 if yes, 1 if no.
#
# /etc/zfs/initramfs-tools-load-key.d/ is an INITRAMFS-TOOLS mechanism. Its
# /scripts/zfs sources everything in that directory before its own prompt
# branches, which is what lets kldload replace the prompt without patching
# upstream. dracut (Fedora, EL) and mkinitcpio (Arch) have no equivalent hook
# and will never source it -- the file lands on those targets and does nothing.
#
# This matters because `quiet` on an encrypted install is only safe WHERE THE
# EXTENSION RUNS. The extension lowers printk while it asks, so quiet cannot
# hide the prompt; without it, quiet hides the prompt exactly as it did before
# 2026-08-18 and the machine looks hung at a blank screen.
#
# Caught 2026-08-27 before shipping: the quiet change was written and verified
# entirely on Debian trixie and then applied to all nine substrates at once.
# On Fedora it would have reintroduced the invisible prompt on the one path
# nobody had tested. Portable by default, specific by intent.
k_prompt_extension_applies() {
    case "${KLDLOAD_DISTRO:-debian}" in
    debian | ubuntu) return 0 ;;
    *) return 1 ;;
    esac
}

k_console_args() {
    local _c
    for _c in /sys/class/drm/card*/status; do
        [[ -r "$_c" ]] || continue
        if grep -qx connected "$_c" 2>/dev/null; then
            printf 'console=ttyS0,115200 console=tty1'
            return 0
        fi
    done
    printf 'console=tty1 console=ttyS0,115200'
}

# k_splash_args — kernel arguments that keep plymouth from running at all.
#
# kldload boots without a splash on purpose (bootloader.sh), but the desktop package
# set pulls plymouth in and dracut then puts it in the initramfs, so plymouthd ran
# anyway. HISTORY: 5-desktop, build 15, fiend 2026-09-14: plymouthd stopped answering
# during plymouth-read-write.service, boot sat before sysinit.target for 7 hours with
# no sshd, and resumed the moment someone pressed Enter on the console. Fedora's
# plymouth units skip themselves on plymouth.enable=0; rd.plymouth=0 does the same in
# the initramfs. Passphrase prompts do not need it: ZFSBootMenu asks before the
# kernel starts, and systemd-ask-password falls back to the console without plymouth.
k_splash_args() {
    printf 'rd.plymouth=0 plymouth.enable=0'
}

# ── Install-time copy helper — fails loudly on shortfalls ────────────────────
# Adopted 2026-06-05 after the .135 incident: every `cp -r ... && k_log "N items"`
# call site silently dropped files (1/6 ansible playbooks, wallpapers, dock pin
# overlay, dock favorites file, dconf GDM overrides) without surfacing anything
# to the operator. "WARNING: feature will fail" buried in install logs is not
# a fail. Use this instead of bare cp at install time. If a future
# call site shows up in the next post-install audit as missing, the
# install dies loudly. That's the only way to keep the pattern from coming back.
# (k_install_file and k_assert_landed were its siblings; nothing ever called
# them, so they are gone -- see the header.)
k_install_tree() {
    # Recursively copy DIR contents and verify file count didn't shrink.
    # Usage: k_install_tree <src-dir> <dst-dir> <label>
    local src="$1" dst="$2" label="$3"
    [[ -d "$src" ]] || k_die "${label}: source directory missing: $src"
    mkdir -p "$dst"
    cp -r "$src/." "$dst/" ||
        k_die "${label}: cp failed: $src → $dst"
    local src_n dst_n
    src_n=$(find "$src" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | wc -l)
    dst_n=$(find "$dst" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | wc -l)
    ((dst_n >= src_n)) ||
        k_die "${label}: short copy — ${dst_n}/${src_n} entries landed in $dst"
    k_log "${label}: ${dst_n} entries → $dst"
}

k_mount_bind() {
    local src="$1"
    local dst="$2"
    mkdir -p "${dst}"
    mountpoint -q "${dst}" || mount --bind "${src}" "${dst}"
}

k_umount_if_mounted() {
    local p="$1"
    if mountpoint -q "${p}" 2>/dev/null; then
        umount -lf "${p}" || true
    fi
}

k_log_to() {
    local logfile="$1"
    shift
    mkdir -p "$(dirname "${logfile}")"
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${logfile}" >&2
}

k_in_chroot() {
    local target="$1"
    shift
    chroot "${target}" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

# k_kvm_wanted — does THIS install want the hypervisor? Exit 0 for yes.
#
# ONE answer, for the package list, the ZFS layout, the units and the manifest.
# It used to be a bare ${KLDLOAD_ENABLE_KVM:-0} repeated at four gates, plus a
# default set inside k_write_manifest() -- which is a function, so the default
# only existed while the manifest was being written. The result: the manifest
# recorded KVM=1 and the package phase ran with 0, and a storage install came
# up with no libvirt at all while its own manifest said it had been asked for
# (fiend, deb-11-storage, 2026-09-20). A default that lives in one function is
# not a default.
#
# Precedence, strongest first:
#   1. PROFILE=kvm always wants it. The profile IS the statement, and an
#      answers file that says kvm=0 on a hypervisor profile is a typo — the
#      old gate read `profile == kvm || ENABLE_KVM == 1` for that reason, and
#      shipping a KVM host with no libvirt because of one stray key would be a
#      worse outcome than ignoring the key.
#   2. An explicit 0 or 1 from the answers file.
#   3. Otherwise: every profile but core, because vmxplore and kfire ship
#      everywhere and 118 MB is not worth a question.
k_kvm_wanted() {
    [[ "${KLDLOAD_PROFILE:-server}" == "kvm" ]] && return 0
    case "${KLDLOAD_ENABLE_KVM:-}" in
    1) return 0 ;;
    0) return 1 ;;
    esac
    [[ "${KLDLOAD_PROFILE:-server}" == "core" ]] && return 1
    return 0
}
