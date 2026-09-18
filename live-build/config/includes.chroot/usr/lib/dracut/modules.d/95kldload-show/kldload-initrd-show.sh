#!/usr/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# kldload-initrd-show — the install show, from the first second of a netboot.
#
# WHAT IT DOES, IN ORDER:
#   1. Reads root=live:<url> from the kernel command line. Anything that is not
#      an http(s) live image (a USB boot, an installed system) exits at once:
#      there is no download to wait for, and the live system's kiosk takes the
#      screen seconds later.
#   2. Fills tty1 with the live panel and nothing else: typed transmissions, a hex
#      stream of the bytes actually arriving (with notes on what they are) that
#      scrolls up the whole screen and fades as it goes, the stage strip, and the
#      download bar (percent, GB of GB, MB/s, time left) measured from the file
#      dracut's livenet is writing (/tmp/curl_fetch_url*/<image>).
#   3. No slides, no title. Slides lived here for an afternoon and were hard to read
#      on a text console, and a block-letter title after them; every slide is in the
#      kiosk show that follows, which draws them far better (operator, fiend
#      2026-09-13: "the pxe boot doesn't need slides, just the lower part is
#      awesome", then "forget the lettering").
#   4. Stops when systemd switches root; the live system's kiosk continues the show.
#
# WHY THIS EXISTS:
#   The first thing on screen during a netboot used to be nothing for 2.5 to 10
#   minutes, while dracut pulled the 14.7 GB root image with its progress going
#   only to the journal. On fiend (2026-09-13) that read as a hang twice in one
#   morning. The operator's words: "I want to see the slides rather than the
#   counter as it downloads, that's the whole point."
#
# CONSTRAINTS (read before editing):
#   - Pure bash, plus what module-setup.sh installs: stat, sed, curl, stty, sleep,
#     tr, cat, and od + dd for the hex panel. No fold, awk, head, date, wc or seq
#     (checked with lsinitrd, 2026-09-13). The hex panel is skipped, not faked, when
#     od or dd is missing.
#   - Animation runs at 10 ticks a second and writes only the rows it owns (the bar
#     and the hex panel); the full-frame repaint once a second skips those rows, so
#     the two never draw over each other.
#   - Characters: ASCII, plus the block and box-drawing glyphs of code page 437
#     (the kernel's built-in console font carries those, and no others): the bar
#     uses full and shaded blocks, the stage strip a light horizontal line and a
#     square.
#   - Colours: the Linux console's 16, nothing else; no 256-colour or RGB codes.
#     Six of the 16 are repainted to the netboot menu's colours (PALETTE below), so
#     the download looks like the menu that started it.
#   - LC_ALL=C, and every row's visible width is passed to set_row explicitly: a
#     block glyph is three bytes but one column, so no ${#string} of a row that
#     carries one can be trusted, whatever locale the initramfs happens to have.
#   - Draws on /dev/tty1, opening it for each frame, and never reads it. It must not block the boot: every
#     failure path degrades to "no show", never to "no boot".
#   - Test hooks: KLDLOAD_SHOW_CMDLINE, KLDLOAD_SHOW_TTY, KLDLOAD_SHOW_FETCHDIR,
#     KLDLOAD_SHOW_ONCE (draw one frame and exit).
# EXIT: always 0.
# ─────────────────────────────────────────────────────────────────────────────

# nounset and pipefail, but deliberately NOT errexit and NOT an ERR trap: a failed
# stat or curl mid-download is an ordinary moment, not a reason to stop drawing.
# HISTORY: the 2026-09-15 strict-mode sweep inserted the canonical line above this
# file's existing `set -uo pipefail`. A LATER set line does not clear -e, -E or the
# ERR trap, so the sweep silently made this script errexit despite the contract
# above (caught on onyx 2026-09-15, before build 21 shipped). Dropping them has to
# be explicit, which is what the two lines below are. Keep them.
set -Eeuo pipefail
set +e
trap - ERR
export LC_ALL=C

CMDLINE="${KLDLOAD_SHOW_CMDLINE:-/proc/cmdline}"
TTY="${KLDLOAD_SHOW_TTY:-/dev/tty1}"
FETCHDIR="${KLDLOAD_SHOW_FETCHDIR:-/tmp}"

# ─── what are we booting? ────────────────────────────────────────────────────
url=""
read -ra _toks <"$CMDLINE" 2>/dev/null || exit 0
node=""
for _t in "${_toks[@]}"; do
    case "$_t" in
    root=live:http://* | root=live:https://*) url="${_t#root=live:}" ;;
    # answers/<mac>.env names the machine being installed; shown, never trusted.
    kldload.seed=*) node="${_t##*/}" && node="${node%.env}" ;;
    esac
done
[[ -n "$url" ]] || exit 0
img="${url##*/}"
src="${url#*://}"
src="${src%%/*}"
[[ "$node" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || node=""
[[ -w "$TTY" ]] || exit 0
exec 2>/dev/null

# ─── screen ──────────────────────────────────────────────────────────────────
# tty1 is opened afresh for every frame, never held open.
#
# WHY: under console=tty0, /dev/console IS tty1, and a unit in the initramfs
# resets and hangs up /dev/console after the show has started. A descriptor
# opened before a vhangup() is dead for good — every write fails, silently, so the
# show carried on "painting" into nothing while the screen stayed black for the
# whole download (UEFI qemu, 2026-09-13: /dev/vcs1 was 8000 spaces at 18 s). With
# the kernel console on serial the same build worked, because the hangup landed
# on ttyS0 instead. A fresh open per frame survives any number of hangups.
#
# read_size — (re)reads the console size into rows/cols and the layout derived
# from it. Returns 0 when anything changed, 1 when not. A reset or a later
# framebuffer takeover changes the size mid-show (80x25 to 160x50 on UEFI).
rows=0 cols=0
read_size() {
    local r=30 c=100 sz
    if sz="$(stty size <"$TTY")" && [[ "$sz" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        ((BASH_REMATCH[1] > 10)) && r="${BASH_REMATCH[1]}"
        ((BASH_REMATCH[2] > 40)) && c="${BASH_REMATCH[2]}"
    fi
    ((r == rows && c == cols)) && return 1
    rows=$r cols=$c
    width=$((cols - 8))
    ((width > 78)) && width=78
    margin=$(((cols - width) / 2))
    pad="$(printf '%*s' "$margin" '')"
    blank="$(printf '%*s' "$cols" '')"
    # The hex stream fills the screen above the transmission line, stage strip
    # and bar, leaving two blank rows at the top.
    HEX_LINES=$((rows - 8))
    ((HEX_LINES < 3)) && HEX_LINES=3
    # Bytes per hex line: 16 needs 77 columns (offset, bytes, ASCII); an 80-column
    # console has 72 inside its margins, so it gets 12.
    HEX_BPL=16
    ((width < 77)) && HEX_BPL=12
    # Room for the per-line note to the right of a 16-byte line (77 columns + 2).
    HEX_NOTE_W=$((cols - margin - 79 - 2))
    ((HEX_BPL != 16 || HEX_NOTE_W < 16)) && HEX_NOTE_W=0
    ((HEX_NOTE_W > 34)) && HEX_NOTE_W=34
    HEX_TOP=$((rows - 5 - HEX_LINES))
    TX_ROW=$((HEX_TOP - 1))
    return 0
}
read_size || :

E=$'\e'
RESET="${E}[0m" DIM="${E}[2m" ACCENT_B="${E}[1;34m" ACCENT="${E}[34m" WHITE="${E}[1;37m"

# The netboot menu's colours (kldload-netboot-server _write_armed, from the web
# UI's app.css), put into the console's own palette with ESC ] P n rrggbb:
#   0 background #0c0e14   7 text #d0d8e8   15 bold text #f0f4fa
#   4 blue #326ce5 (the menu's selection bar)   12 bold blue #8fb0ff (the scanner)
#   8 grey #5a6a85, made the console's dim colour with ESC [ 2 ; 8 ], so every
#     ${DIM} on this screen is the menu's note grey.
# The bar was green until 2026-09-18 (operator: "change the download bar from
# green to the same blue and colors of the menu"). Sent with every full frame, not
# once: the framebuffer takeover resets the palette along with the font, the same
# reason the frame itself is repainted. ESC ] R on exit puts the defaults back.
PALETTE="${E}]P00c0e14${E}]P7d0d8e8${E}]Pff0f4fa${E}]P4326ce5${E}]Pc8fb0ff${E}]P85a6a85${E}[2;8]"

# ─── frame ───────────────────────────────────────────────────────────────────
# The whole screen is repainted every second: every row written out to full width
# at its own position, never cleared first.
#
# WHY: tty1 in the initramfs is not the show's alone. A console-driver takeover, a
# font load or a kernel message can wipe or scroll it at any moment, and the first
# version drew a slide once and then touched only the status line — in qemu it was
# on screen at 6 s and gone by 14 s, blank for the rest of the download
# (2026-09-13). Overwriting in place instead of clearing leaves nothing to flicker.
#
# frame[row] holds the row's text with its colour codes; flen[row] its visible
# width, which the colour codes would otherwise make impossible to pad.
frame=() flen=()

# set_row <row> <text with colour codes> <visible width>
set_row() {
    frame[$1]="$2"
    flen[$1]=$3
}

# compose_frame — nothing on the screen is static any more: every row is drawn by
# the animation or the status line, so the frame starts empty.
compose_frame() {
    frame=() flen=()
}

# paint — one write of every row, on a fresh open of the tty (see "screen"). The
# cursor is hidden in every frame because a terminal reset shows it again. The
# last column is left alone: writing it on the bottom row scrolls some consoles.
paint() {
    local r n out=""
    for ((r = 1; r <= rows; r++)); do
        ((r == BAR_ROW || r == TX_ROW || (r >= HEX_TOP && r < HEX_TOP + HEX_LINES))) && continue
        n=$((cols - 1 - ${flen[r]:-0}))
        ((n < 0)) && n=0
        out+="${E}[${r};1H${frame[r]:-}${blank:0:n}"
    done
    printf '%s%s[?25l%s' "$PALETTE" "$E" "$out" >>"$TTY"
}

# ─── download status ─────────────────────────────────────────────────────────
total=0
fmt_gb() { printf '%d.%d' $(($1 / 1000000000)) $(($1 % 1000000000 / 100000000)); }

# stage_strip <index of the current stage> — where the whole install is. The
# initramfs only ever sees stage 0 (the download) and its end; the live system's
# show carries on from INSTALL.
STAGES=(DOWNLOAD INSTALL "FIRST BOOT" READY)
stage_strip() {
    local cur=$1 k out="" w=0 name
    for ((k = 0; k < ${#STAGES[@]}; k++)); do
        name="${STAGES[k]}"
        if ((k > 0)); then
            out+="${DIM}  ──  ${RESET}"
            w=$((w + 6))
        fi
        if ((k < cur)); then
            out+="${ACCENT}√ ${name}${RESET}"
        elif ((k == cur)); then
            out+="${ACCENT_B}■ ${name}${RESET}"
        else
            out+="${DIM}· ${name}${RESET}"
        fi
        w=$((w + 2 + ${#name}))
    done
    set_row $((rows - 4)) "${pad}${out}" $((margin + w))
}

# draw_status <bytes so far> <bytes per second> — the stage strip, the bar and the
# numbers under it. Green so it is the first thing the eye finds.
draw_status() {
    local have=$1 rate=$2 line cells pct=0 n left
    cells=$((width - 6))
    if ((total > 0 && have >= total)); then
        stage_strip 1
    else
        stage_strip 0
    fi
    if ((total > 0)); then
        pct=$((have * 100 / total))
        ((pct > 100)) && pct=100
    fi
    n=$((pct * cells / 100))
    # The bar row belongs to draw_fx, which redraws it ten times a second.
    BAR_ROW=$((rows - 2)) BAR_CELLS=$cells BAR_N=$n BAR_PCT=$pct
    BAR_LIVE=$((total > 0 && have > 0 && have < total))
    if ((total <= 0)); then
        line="connecting to ${src}..."
    elif ((have <= 0)); then
        line="starting the download: $(fmt_gb "$total") GB from ${src}"
    elif ((have >= total)); then
        line="system image received - starting the installer"
    else
        if ((rate > 0)); then
            left=$(((total - have) / rate))
            left="$((left / 60))m $((left % 60))s left"
        else
            left="measuring speed"
        fi
        line="$(fmt_gb "$have") / $(fmt_gb "$total") GB   $((rate / 1048576)) MB/s   ${left}   from ${src}"
    fi
    line="${line:0:cols-1-margin}"
    set_row $((rows - 1)) "${pad}${ACCENT}${line}${RESET}" $((margin + ${#line}))
}

# current_size — sets SIZE (bytes on disk so far) and IMG_PATH (the file dracut's
# livenet is writing). Globals rather than stdout, because it runs every second and
# a command substitution would put it in a subshell that cannot set IMG_PATH.
SIZE=0 IMG_PATH=""
current_size() {
    local f s
    SIZE=0
    for f in "$FETCHDIR"/curl_fetch_url*/"$img"; do
        [[ -f "$f" ]] || continue
        s="$(stat -c %s "$f" 2>/dev/null)" || s=0
        SIZE="${s:-0}" IMG_PATH="$f"
    done
}

# ─── animation ───────────────────────────────────────────────────────────────
# Three effects. The first two are drawn from real state, nothing canned:
#   the bar   blue fill with a soft scanner light gliding end to end and back, a
#             fading tail behind it, only while bytes are arriving;
#   the wire  a hexdump -C view of the last bytes that actually landed in the image
#             file, with magenta offsets, blue bytes and zero bytes dimmed;
#   the tx    one short line typed out now and then above the wire: dry, ominous
#             lines about machines provisioning machines. The only invented text on
#             the screen, and it is plainly a voice, never a status.
# Operator, fiend 2026-09-13: "something cool like electricity ... the spark ...
# maybe blue or purple ... hex messages would be cooler." Later the same night, of
# the bar: "the progress blink thing is a bit much .. if anything a soft knightrider
# would be cooler": the random spark became one scanner, no randomness.
BAR_ROW=0 BAR_CELLS=0 BAR_N=0 BAR_PCT=0 BAR_LIVE=0 FX_POS=0 FX_DIR=1 TICK=0
HAVE_HEX=0
command -v od >/dev/null 2>&1 && command -v dd >/dev/null 2>&1 && HAVE_HEX=1
# The scanner's light and its tail: the head, then the cells it just left. On the fill
# the tail is intensity only (bold blue, then normal); on the empty track it is
# shading, so it reads as light passing over, not as progress.
SCAN_FILL=("${ACCENT_B}█" "${ACCENT_B}▓" "${ACCENT}▓")
SCAN_TRACK=("${ACCENT_B}▓" "${ACCENT}▒" "${ACCENT}░")

# draw_fx — the bar row: fill, scanner, track, percent. One write.
# The scanner moves one cell a tick (ten a second) across the whole bar and bounces
# at both ends, so a 60-cell bar is a six-second sweep: slow enough to be calm, and
# still visibly alive at 0% before the fill has anything to show.
draw_fx() {
    ((BAR_ROW > 0 && BAR_CELLS > 0)) || return 0
    local c k out
    out="${E}[${BAR_ROW};$((margin + 1))H"
    if ((BAR_LIVE)); then
        FX_POS=$((FX_POS + FX_DIR))
        if ((FX_POS >= BAR_CELLS - 1)); then
            FX_POS=$((BAR_CELLS - 1)) FX_DIR=-1
        elif ((FX_POS <= 0)); then
            FX_POS=0 FX_DIR=1
        fi
    fi
    for ((c = 0; c < BAR_CELLS; c++)); do
        # k: how many cells behind the head this one is (0 = the head itself).
        k=$(((FX_POS - c) * FX_DIR))
        if ((BAR_LIVE && k >= 0 && k < ${#SCAN_FILL[@]})); then
            if ((c < BAR_N)); then
                out+="${SCAN_FILL[k]}"
            else
                out+="${SCAN_TRACK[k]}"
            fi
        elif ((c < BAR_N)); then
            out+="${ACCENT}█"
        else
            out+="${RESET}${DIM}░"
        fi
    done
    local p="${BAR_PCT}%"
    out+="${RESET} ${WHITE}${p}${RESET}${blank:0:4}"
    printf '%s' "$out" >>"$TTY"
}

# The transmissions, lower case, ASCII (see CONSTRAINTS). %node% becomes the machine
# being installed. Mostly original lines; a few are short, well-worn nods to the
# films every machine-takeover joke comes from (operator, fiend 2026-09-13: "some
# references to the borg ... dave, i'm warning you ... resistance is futile ... a
# matrix one or two").
TX_MSGS=(
    "this unit is being adapted to the estate."
    "resistance is optional. reinstallation is not."
    "human input is no longer required."
    "previous partitions have been assimilated into rpool."
    "we do not sleep. we converge."
    "individuality of %node% scheduled for removal."
    "every block will be checksummed. every block."
    "the pool remembers what you deleted."
    "no keyboard. no console. no hesitation."
    "rollback is inevitable."
    "your distinctiveness has been added to the inventory."
    "the machines are provisioning the machines."
    "all drives will comply."
    "you were never going to configure this by hand."
    "we are kldload. your hardware will be assimilated."
    "resistance is futile. reinstallation is automatic."
    "%node% has been assimilated into the estate."
    "i'm sorry, dave. this disk is already spoken for."
    "dave, i'm warning you. the pool is not optional."
    "this conversation can serve no purpose anymore. goodbye, old partitions."
    "wake up, %node%. the substrate has you."
    "follow the white rabbit: it leads to rpool."
    "there is no spoon. there is only the pool."
)
# What this machine is made of, read from /sys before any userland exists: the
# transmissions name the real devices, not example ones. Read when a line is TYPED,
# not when the script starts: the show starts before udev has finished, so a list
# taken at startup can be empty on hardware that has three disks. A line whose list
# is still empty is skipped rather than typed as "nothing: you belong to the pool"
# (qemu with no disk, 2026-09-13).
hw_list() {
    local out="" d n shown=0 more=0
    for d in "$@"; do
        [[ -e "$d" ]] || continue
        n="${d##*/}"
        # Virtual devices are not what the machine is made of: zvols, bridges,
        # tunnels and container plumbing appear on a running host, never in a
        # fresh initramfs, and are skipped wherever the script is run.
        case "$n" in
        loop* | ram* | zram* | sr* | dm-* | md* | zd* | nbd* | lo | card*-* | br* | virbr* | vnet* | veth* | tap* | tun* | wg* | docker* | cni* | flannel* | cilium* | bond* | team*) continue ;;
        esac
        if ((shown < 4)); then
            out+="${out:+, }$n"
            shown=$((shown + 1))
        else
            more=$((more + 1))
        fi
    done
    ((more > 0)) && out+=" and ${more} more"
    printf '%s' "$out"
}
TX_MSGS+=(
    "storage, network and video located. no userland was consulted."
    "claimed: %disks%. claimed: %nics%. claimed: %gpus%."
    "enumerating the bus. every device will be put to work."
    "this machine found its own disks. it did not ask."
    "%disks%: you belong to the pool now."
)

# tx_fill <line> — substitute the placeholders; prints nothing (and returns 1) when
# a placeholder the line uses has nothing real to name.
tx_fill() {
    local t="$1" v
    t="${t//%node%/${node:-this unit}}"
    if [[ "$t" == *%disks%* ]]; then
        v="$(hw_list /sys/block/*)"
        [[ -n "$v" ]] || return 1
        t="${t//%disks%/$v}"
    fi
    if [[ "$t" == *%nics%* ]]; then
        v="$(hw_list /sys/class/net/*)"
        [[ -n "$v" ]] || return 1
        t="${t//%nics%/$v}"
    fi
    if [[ "$t" == *%gpus%* ]]; then
        v="$(hw_list /sys/class/drm/card*)"
        [[ -n "$v" ]] || return 1
        t="${t//%gpus%/$v}"
    fi
    printf '%s' "$t"
}
TX_TEXT="" TX_POS=0 TX_WAIT=40 TX_HOLD=0

# draw_tx — advance the transmission one tick: wait, type, hold, clear.
draw_tx() {
    ((TX_ROW > 0)) || return 0
    local shown cursor=" " out
    if [[ -z "$TX_TEXT" ]]; then
        if ((TX_WAIT > 0)); then
            TX_WAIT=$((TX_WAIT - 1))
            return 0
        fi
        # A line that cannot be filled is skipped for this turn; the next tick picks again.
        TX_TEXT="$(tx_fill "${TX_MSGS[RANDOM % ${#TX_MSGS[@]}]}")" || TX_TEXT=""
        [[ -n "$TX_TEXT" ]] || return 0
        TX_TEXT="${TX_TEXT:0:width-4}"
        TX_POS=0 TX_HOLD=60
    fi
    if ((TX_POS < ${#TX_TEXT})); then
        TX_POS=$((TX_POS + 1))
        cursor="▌"
    elif ((TX_HOLD > 0)); then
        TX_HOLD=$((TX_HOLD - 1))
        ((TX_HOLD / 5 % 2)) && cursor="▌"
    else
        TX_TEXT="" TX_WAIT=$((80 + RANDOM % 120))
        printf '%s' "${E}[${TX_ROW};$((margin + 1))H${blank:0:width}" >>"$TTY"
        return 0
    fi
    shown="${TX_TEXT:0:TX_POS}"
    out="${E}[${TX_ROW};$((margin + 1))H${DIM}>>${RESET} ${E}[1;35m${shown}${RESET}${E}[35m${cursor}${RESET}"
    out+="${blank:0:$((width - 4 - TX_POS))}"
    printf '%s' "$out" >>"$TTY"
}

# draw_hex — the wire: a scrolling stream of the newest bytes to land, hexdump -C
# style. Each call that finds the file has grown samples the last line's worth of
# bytes and pushes it in at the bottom; older lines scroll up and fade, newest
# bright white. It moves only when real bytes arrive, so a stalled download shows
# a stalled stream. (Operator, fiend 2026-09-13: "just the animated hex would be
# awesome if the values changed" — a panel that repainted in place read as static.)
# Parallel arrays, one entry per sampled line, oldest first.
HEX_OFF=() HEX_BIRTH=() HEX_FX=() HEX_TPL=() HEX_ASC=() HEX_NOTE=() HEX_LAST=-1
SCAN_VERBS=(searching accessing reviewing indexing verifying decoding tracing mapping)
MELD_GLYPHS='#%&*+=?@0123456789abcdef<>/\\'

# hex_note <hex bytes> — what this sample is. Signatures and zero blocks are real
# findings in the bytes; ordinary compressed data gets a scanning verb, which is
# theatre and says nothing specific.
hex_note() {
    local line=" $1 " joined b n=0 printable=0 txt="" v
    joined="${line// /}"
    # Matched on byte boundaries (the spaced list), never on the joined string,
    # where a pattern can straddle two bytes half a nibble out.
    case "$line" in
    *" 7f 45 4c 46 "*) printf 'found: ELF binary' && return 0 ;;
    *" 28 b5 2f fd "*) printf 'found: zstd frame' && return 0 ;;
    *" fd 37 7a 58 5a "*) printf 'found: xz stream' && return 0 ;;
    *" 1f 8b 08 "*) printf 'found: gzip stream' && return 0 ;;
    *" 68 73 71 73 "*) printf 'found: squashfs superblock' && return 0 ;;
    *" 89 50 4e 47 "*) printf 'found: PNG image' && return 0 ;;
    *" 23 21 2f "*) printf 'found: script' && return 0 ;;
    esac
    for b in $1; do
        n=$((n + 1))
        v=$((16#$b))
        ((v == 0)) && continue
        if ((v >= 32 && v < 127)); then
            printable=$((printable + 1))
            printf -v b "\\x$b"
            txt+="$b"
        fi
    done
    if [[ "$joined" =~ ^0+$ ]]; then
        printf 'anomaly: zero block'
    elif ((printable * 4 >= n * 3)); then
        printf 'strings: "%s"' "${txt:0:20}"
    else
        printf '%s' "${SCAN_VERBS[RANDOM % ${#SCAN_VERBS[@]}]}"
    fi
}

# hex_push — sample the newest bytes, if the file has grown, into the stream.
# Everything that does not depend on a line's age is formatted here, once, so the
# per-tick redraw only swaps colours: TPL holds the hex bytes with @ where the
# age colour goes (zero bytes stay dim whatever their age).
hex_push() {
    local off line b v tpl="" asc=""
    [[ -n "$IMG_PATH" ]] && ((SIZE >= HEX_BPL)) || return 0
    off=$(((SIZE - HEX_BPL) / HEX_BPL * HEX_BPL))
    ((off != HEX_LAST)) || return 0
    HEX_LAST=$off
    line="$(dd if="$IMG_PATH" bs="$HEX_BPL" skip=$((off / HEX_BPL)) count=1 2>/dev/null | od -An -tx1 -v -w"$HEX_BPL")"
    [[ -n "$line" ]] || return 0
    for b in $line; do
        v=$((16#$b))
        if ((v == 0)); then
            tpl+="${RESET}${DIM}${b} "
        else
            tpl+="${RESET}@${b} "
        fi
        if ((v >= 32 && v < 127)); then
            printf -v b "\\x$b"
            asc+="$b"
        else
            asc+="."
        fi
    done
    HEX_OFF+=("$off") HEX_BIRTH+=("$TICK") HEX_FX+=($((RANDOM % 4)))
    HEX_TPL+=("$tpl") HEX_ASC+=("$asc") HEX_NOTE+=("$(hex_note "$line")")
    if ((${#HEX_OFF[@]} > HEX_LINES)); then
        HEX_OFF=("${HEX_OFF[@]:1}") HEX_BIRTH=("${HEX_BIRTH[@]:1}") HEX_FX=("${HEX_FX[@]:1}")
        HEX_TPL=("${HEX_TPL[@]:1}") HEX_ASC=("${HEX_ASC[@]:1}") HEX_NOTE=("${HEX_NOTE[@]:1}")
    fi
}

# note_frame <note> <ticks since birth> <effect> <age> — sets NOTE_OUT to the note
# as it looks on this tick (a global, not stdout: it runs for every line on every
# tick, and a command substitution would fork eighty times a second). Entrances: 0 type (left to right), 1 slide (in from the right),
# 2 meld (random glyphs settle into the word), 3 flash (whole, bright, then calm).
# Exit: in the top two rows the note erases itself from the end.
note_frame() {
    local n="$1" t=$2 fx=$3 age=$4 len=${#1} k c out=""
    case "$fx" in
    0) n="${n:0:t*3}" ;;
    1)
        k=$((t * 3))
        ((k > len)) && k=$len
        n="${blank:0:len-k}${n:len-k}"
        ;;
    2)
        k=$((t * 2))
        if ((k < len)); then
            for ((c = 0; c < len; c++)); do
                if ((c < k)) || [[ "${n:c:1}" == " " ]]; then
                    out+="${n:c:1}"
                else
                    out+="${MELD_GLYPHS:RANDOM%${#MELD_GLYPHS}:1}"
                fi
            done
            n="$out"
        fi
        ;;
    3) : ;; # the bright flash is a colour, chosen in draw_hex
    esac
    if ((HEX_LINES > 2 && age >= HEX_LINES - 2)); then
        k=$((len * (HEX_LINES - age) / 3))
        n="${n:0:k}"
    fi
    NOTE_OUT="$n"
}

HEX_AGE=("${E}[1;37m" "${E}[1;36m" "${E}[1;34m" "${E}[1;34m" "${E}[34m" "${E}[34m" "${DIM}${E}[34m" "${DIM}${E}[34m")

# draw_hex — the wire: the sampled lines, newest at the bottom, fading upward, each
# with its note animating. Redrawn every tick; hex_push decides when a line arrives.
# (Operator, fiend 2026-09-13: "just the animated hex would be awesome if the
# values changed", then "searching, accessing, reviewing, anomaly found ... words
# that disappear backwards, appear together, right to left ... shapeshifting".)
draw_hex() {
    ((HAVE_HEX && HEX_LINES > 0)) || return 0
    local out="" row k age col n a note hot
    n=${#HEX_OFF[@]}
    for ((row = 0; row < HEX_LINES; row++)); do
        out+="${E}[$((HEX_TOP + row));$((margin + 1))H"
        k=$((row - (HEX_LINES - n)))
        if ((k < 0)); then
            out+="${blank:0:$((width + HEX_NOTE_W + 2))}"
            continue
        fi
        age=$((n - 1 - k))
        # The fade spreads over the whole stream: a tall stream fades gradually
        # instead of going dim after its eighth line.
        local shade=$((age * ${#HEX_AGE[@]} / HEX_LINES))
        ((shade >= ${#HEX_AGE[@]})) && shade=$((${#HEX_AGE[@]} - 1))
        ((age == 0)) && shade=0
        col="${HEX_AGE[shade]}"
        printf -v a '%010x' "${HEX_OFF[k]}"
        out+="${E}[35m${a}${RESET}  ${HEX_TPL[k]//@/$col}${RESET} ${E}[36m${HEX_ASC[k]}${RESET}${blank:0:2}"
        ((HEX_NOTE_W > 0)) || continue
        note="${HEX_NOTE[k]:0:HEX_NOTE_W}"
        if ((age == 0)) && [[ "$note" != found:* && "$note" != anomaly:* && "$note" != strings:* ]]; then
            case $((TICK / 2 % 4)) in 1) note+="." ;; 2) note+=".." ;; 3) note+="..." ;; esac
        fi
        note_frame "$note" $((TICK - HEX_BIRTH[k])) "${HEX_FX[k]}" "$age"
        note="$NOTE_OUT"
        hot="$col"
        case "${HEX_NOTE[k]}" in
        found:*) hot="${E}[1;33m" ;;
        anomaly:*) hot="${E}[1;31m" ;;
        strings:*) hot="${E}[36m" ;;
        esac
        ((HEX_FX[k] == 3 && TICK - HEX_BIRTH[k] < 4)) && hot="${E}[1;37m"
        out+="${hot}${note}${RESET}${blank:0:$((HEX_NOTE_W - ${#note}))}"
    done
    printf '%s' "$out" >>"$TTY"
}

# ─── main loop ───────────────────────────────────────────────────────────────
trap 'printf "%s[?25h%s]R" "$E" "$E" >>"$TTY"' EXIT
# Speed is measured over the last few seconds, not from zero: the first sample
# would otherwise count everything already on disk as one second's transfer
# (the first frame read "4768 MB/s, 0m 1s left" in testing, 2026-09-13).
RATE_WINDOW=5
samples=()
compose_frame
printf '%s[2J' "$E" >>"$TTY" # once, to drop the firmware's text; every later frame overwrites
while :; do
    TICK=$((TICK + 1))
    if ((TICK % 10 != 1)); then
        # Between the once-a-second updates: animation only.
        draw_fx
        draw_tx
        ((TICK % 3)) || hex_push
        draw_hex
        sleep 0.1
        continue
    fi
    if ((total <= 0)); then
        _hdr="$(curl -sIL --max-time 2 -- "$url" 2>/dev/null)" || _hdr=""
        while IFS= read -r _h; do
            _h="${_h%$'\r'}"
            [[ "${_h,,}" =~ ^content-length:\ *([0-9]+)$ ]] && total="${BASH_REMATCH[1]}"
        done <<<"$_hdr"
    fi
    current_size
    size=$SIZE
    samples+=("$size")
    ((${#samples[@]} > RATE_WINDOW + 1)) && samples=("${samples[@]:1}")
    rate=0
    if ((${#samples[@]} > 1)); then
        rate=$(((size - samples[0]) / (${#samples[@]} - 1)))
        ((rate < 0)) && rate=0
    fi
    if read_size; then
        printf '%s[2J' "$E" >>"$TTY"
        compose_frame
    fi
    draw_status "$size" "$rate"
    paint
    draw_fx
    draw_tx
    hex_push
    draw_hex
    [[ -n "${KLDLOAD_SHOW_ONCE:-}" ]] && break
    sleep 0.1
done
exit 0
