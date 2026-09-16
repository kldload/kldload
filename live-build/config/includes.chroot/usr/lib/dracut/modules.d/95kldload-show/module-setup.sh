#!/usr/bin/bash
# dracut module 95kldload-show — the install show during a netboot image download.
#
# Installed by builder/build-iso.sh (dracut --add kldload-show) into the live
# initramfs. Pulls in livenet, because the only thing the show is for is the time
# livenet spends downloading the root image. It carries no slides: those are the
# kiosk's, which follows once the live system is up.

set -Eeuo pipefail
trap 'echo "module-setup.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

check() {
    # Only when asked for by name: never auto-included into an installed system's
    # initramfs.
    return 255
}

depends() {
    echo livenet
}

install() {
    # od and dd feed the live hex panel; the show draws without it if they are absent.
    inst_multiple bash stat sed curl stty sleep tr cat od dd
    inst_script "$moddir/kldload-initrd-show.sh" /usr/bin/kldload-initrd-show
    inst_simple "$moddir/kldload-initrd-show.service" "$systemdsystemunitdir/kldload-initrd-show.service"
    inst_script "$moddir/kldload-show-generator" "$systemdutildir/system-generators/kldload-show-generator"
    $SYSTEMCTL -q --root "$initdir" add-wants sysinit.target kldload-initrd-show.service
}
