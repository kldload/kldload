# root's login profile — shipped by kldload.
#
# On the live medium, booted with kldload.tui=1, tty1 logs root in on its own
# (kldload-tty1) and this is where the install menu starts: `kld install`,
# the netboot menu's questions on this machine. Only tty1, only the live
# medium, only that flag — an ssh login or an installed host gets a shell.
# When the menu exits (its Shell entry, or q) the login shell continues, so
# the operator lands in bash rather than in a login loop.
if [[ "$(tty 2>/dev/null)" == /dev/tty1 ]] && grep -qwE 'kldload\.tui=1' /proc/cmdline 2>/dev/null; then
    for _m in /run/initramfs/live /run/live/medium /lib/live/mount/medium; do
        if [[ -d "$_m" ]] && command -v kld >/dev/null 2>&1; then
            kld install
            break
        fi
    done
    unset _m
fi
[[ -f ~/.bashrc ]] && . ~/.bashrc
