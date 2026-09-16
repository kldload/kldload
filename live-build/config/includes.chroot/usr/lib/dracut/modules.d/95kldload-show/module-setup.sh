#!/usr/bin/bash
# dracut module 95kldload-show — the install show during a netboot image download.
#
# Installed by builder/build-iso.sh (dracut --add kldload-show) into the live
# initramfs. Pulls in livenet, because the only thing the show is for is the time
# livenet spends downloading the root image. It carries no slides: those are the
# kiosk's, which follows once the live system is up.
#
# No `set -Eeuo pipefail` at the top, and that is NOT an omission. dracut SOURCES
# every module-setup.sh into its own shell, so options set here become dracut's
# options for the rest of its run -- and dracut is not written to survive them.
# Build 21 (onyx, 2026-09-15) died exactly that way: the two lines that used to be
# here made dracut strict, then stock 73crypt-gpg/module-setup.sh tripped over a
# process substitution that cannot open /dev/fd/63 in the build chroot (no /proc),
# which errexit turned from a harmless warning into an abort, and dracut-init.sh
# line 3 hit `keep: unbound variable` under nounset. Ten minutes of build, no ISO.
# Same trap as /etc/profile.d/kube-helpers.sh, same answer: install() sets the
# options behind `local -`, which bash restores on return, so this module is
# strict and dracut's shell is untouched.

check() {
    # Only when asked for by name: never auto-included into an installed system's
    # initramfs. 255 is dracut's "do not include me unless --add names me".
    return 255
}

depends() {
    echo livenet
}

install() {
    local - # options restored on return: dracut sourced this file
    set -Eeuo pipefail

    # Required: without these the show cannot draw at all, so a miss must be fatal
    # rather than produce an initramfs with a broken unit in it. Checked EXPLICITLY
    # rather than left to the errexit above, because bash suppresses errexit inside
    # a function whose caller invoked it in a condition (`if install; then`), and
    # which way dracut calls this is not mine to depend on.
    inst_multiple bash stat sed curl stty sleep tr cat || {
        derror "kldload-show: a required binary is missing — not building the show"
        return 1
    }

    # WHY: od and dd only feed the live hex panel and the show draws fine without
    # them, so they get their OWN call -- under the errexit above, leaving them in
    # the required list would let a missing optional binary abort the whole module.
    inst_multiple od dd || dwarn "kldload-show: od/dd missing, hex panel disabled"

    inst_script "$moddir/kldload-initrd-show.sh" /usr/bin/kldload-initrd-show
    inst_simple "$moddir/kldload-initrd-show.service" "$systemdsystemunitdir/kldload-initrd-show.service"
    inst_script "$moddir/kldload-show-generator" "$systemdutildir/system-generators/kldload-show-generator"
    $SYSTEMCTL -q --root "$initdir" add-wants sysinit.target kldload-initrd-show.service
}
