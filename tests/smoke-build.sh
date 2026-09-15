#!/bin/bash
# smoke-build.sh — verify a built ISO is valid before burning
# Run from the build machine after ./deploy.sh build completes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
WARN=0

_pass() {
    echo -e "  \033[1;32mPASS\033[0m  $*"
    ((++PASS))
}
_fail() {
    echo -e "  \033[1;31mFAIL\033[0m  $1 — $2"
    ((++FAIL))
}
_warn() {
    echo -e "  \033[1;33mWARN\033[0m  $1 — $2"
    ((++WARN))
}
_section() {
    echo ""
    echo -e "\033[1;36m=== $* ===\033[0m"
}

echo -e "\033[1;36m╔══════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;36m║  kldloadOS Build Smoke Test                              ║\033[0m"
echo -e "\033[1;36m╚══════════════════════════════════════════════════════════╝\033[0m"

# ── ISO exists ───────────────────────────────────────────────────────────────
_section "ISO File"

ISO=$(find "$ROOT/live-build/output/" -name "kldload-*.iso" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [[ -n "$ISO" && -f "$ISO" ]]; then
    _pass "ISO exists: $(basename "$ISO")"
else
    _fail "ISO exists" "no ISO found in live-build/output/"
    echo -e "\n  \033[1;31mFAIL: $FAIL\033[0m — cannot continue without ISO"
    exit 1
fi

# Size check — the floor depends on what the image was told to carry, and
# the name says that (builder/build-iso.sh): -net has no payload, -core has
# no tools either, a single mirror (-fedora, -debian, -el) is one payload
# piece, the plain name is the full free image. A floor per shape, not one
# window for all of them: the old "8-12G" window flagged the 2.2 GB net
# image as a failed build and the 14.9 GB full one as suspect (2026-09-06).
# awk, not bc: bc is not on every host and "?G" is not a measurement.
iso_size_floor() { # iso_size_floor NAME → minimum bytes for an image of that shape
    case "$1" in
    *-core.iso) echo 900000000 ;;                              # ~1.4 GB built
    *-net.iso) echo 1500000000 ;;                              # ~2.2 GB built
    *-fedora.iso | *-debian.iso | *-el.iso) echo 3500000000 ;; # one mirror, ~6 GB built
    *) echo 10000000000 ;;                                     # full: ~15 GB built
    esac
}
SIZE=$(stat -c%s "$ISO" 2>/dev/null || echo 0)
SIZE_GB=$(awk -v b="$SIZE" 'BEGIN{printf "%.1f", b/1073741824}')
_floor=$(iso_size_floor "$(basename "$ISO")")
if [[ $SIZE -ge $_floor ]]; then
    _pass "ISO size: ${SIZE_GB}G ($(basename "$ISO"); floor $(awk -v b="$_floor" 'BEGIN{printf "%.1f", b/1073741824}')G for this shape)"
else
    _fail "ISO size" "${SIZE_GB}G — under the $(awk -v b="$_floor" 'BEGIN{printf "%.1f", b/1073741824}')G floor for $(basename "$ISO"); the build likely lost a payload piece"
fi

# Timestamp — should be recent (within last hour)
ISO_AGE=$(($(date +%s) - $(stat -c%Y "$ISO" 2>/dev/null || echo 0)))
if [[ $ISO_AGE -lt 3600 ]]; then
    _pass "ISO age: ${ISO_AGE}s old (fresh)"
elif [[ $ISO_AGE -lt 86400 ]]; then
    _warn "ISO age" "$((ISO_AGE / 3600))h old — may be stale"
else
    _fail "ISO age" "$((ISO_AGE / 86400))d old — definitely stale"
fi

# SHA256
if [[ -f "${ISO}.sha256" ]]; then
    _pass "SHA256 checksum file exists"
else
    _warn "SHA256" "no checksum file"
fi

# ── ISO content (mount and check) ───────────────────────────────────────────
_section "ISO Content"

MOUNTPOINT=$(mktemp -d)
if mount -o loop,ro "$ISO" "$MOUNTPOINT" 2>/dev/null; then
    _pass "ISO mounts successfully"

    # Check squashfs
    if [[ -f "$MOUNTPOINT/LiveOS/squashfs.img" ]]; then
        SQ_SIZE=$(stat -c%s "$MOUNTPOINT/LiveOS/squashfs.img" 2>/dev/null || echo 0)
        SQ_GB=$(echo "scale=1; $SQ_SIZE / 1073741824" | bc 2>/dev/null || echo "?")
        _pass "squashfs.img: ${SQ_GB}G"
    else
        _fail "squashfs.img" "not found in LiveOS/"
    fi

    # Check EFI
    if [[ -d "$MOUNTPOINT/EFI" ]]; then
        _pass "EFI directory present"
    else
        _fail "EFI" "no EFI directory — won't UEFI boot"
    fi

    # Check isolinux/BIOS boot
    if [[ -f "$MOUNTPOINT/isolinux/isolinux.bin" ]] || [[ -f "$MOUNTPOINT/boot/grub/grub.cfg" ]]; then
        _pass "Boot loader present"
    else
        _warn "Boot loader" "no isolinux or grub — may not boot on all systems"
    fi

    # ── Workstation launchers + custom app icons inside the squashfs ────
    # Catches the icon-drop regression: build-iso.sh must copy the hicolor
    # app-icon theme + the Web UI launcher into the live rootfs, else the
    # menu (live AND installed — profiles.sh sources icons from the live
    # rootfs) falls back to generic icons.
    if [[ -f "$MOUNTPOINT/LiveOS/squashfs.img" ]] && command -v unsquashfs >/dev/null 2>&1; then
        WSEXTRACT=$(mktemp -d)
        declare -a WS_FILES=(
            usr/share/applications/kldload-webui.desktop
            # kldload-console.svg, not kldload-webui.svg: the webui icon was
            # RETIRED in 0d65de24 ("icons: xplore-family redesign; retire
            # tiles"), and kldload-webui.desktop has read `Icon=kldload-console`
            # ever since. This list was never updated, so the gate demanded a
            # file the tree deliberately no longer has and failed every build
            # from that commit onward -- a test failing on a correct system,
            # which trains everyone to ignore the whole suite.
            usr/share/icons/hicolor/scalable/apps/kldload-console.svg
            usr/share/icons/hicolor/scalable/apps/bob-chat.svg
            usr/share/icons/hicolor/scalable/apps/kldload-zfs.svg
        )
        unsquashfs -q -f -d "$WSEXTRACT/root" "$MOUNTPOINT/LiveOS/squashfs.img" \
            "${WS_FILES[@]}" usr/share/applications/kldload-console.desktop >/dev/null 2>&1 || true

        for _f in "${WS_FILES[@]}"; do
            if [[ -f "$WSEXTRACT/root/$_f" ]]; then
                _pass "squashfs has $_f"
            else
                _fail "squashfs has $_f" "launcher/icon dropped from ISO"
            fi
        done

        # The Console/Argus launcher was replaced by Web UI — it must be gone.
        if [[ -f "$WSEXTRACT/root/usr/share/applications/kldload-console.desktop" ]]; then
            _fail "console launcher replaced" "kldload-console.desktop still in squashfs"
        else
            _pass "console launcher replaced by Web UI"
        fi

        # ── Voice models ────────────────────────────────────────────────────
        # Downloaded at build time from HuggingFace. 2026-09-13 builds 9 full
        # and net each lost one or both to a transient failure logged only as
        # a WARNING, and both ISOs passed this suite. They now come from
        # live-build/download-cache (build-iso.sh fetch_cached); an image
        # without them fails here instead of shipping without voice.
        _vm_list="$(unsquashfs -lls "$MOUNTPOINT/LiveOS/squashfs.img" \
            opt/whisper.cpp/models/ggml-base.en.bin \
            opt/piper/models/en_US-lessac-medium.onnx \
            opt/piper/models/en_US-lessac-medium.onnx.json 2>/dev/null)" || _vm_list=""
        _vm_bad=""
        for _vm in opt/whisper.cpp/models/ggml-base.en.bin opt/piper/models/en_US-lessac-medium.onnx opt/piper/models/en_US-lessac-medium.onnx.json; do
            # -lls: "<mode> <owner> <size> <date> <time> squashfs-root/<path>"; size > 0
            awk -v p="squashfs-root/$_vm" '$NF == p && $3 + 0 > 0 {f = 1} END {exit !f}' <<<"$_vm_list" ||
                _vm_bad+=" $_vm"
        done
        if [[ -z "$_vm_bad" ]]; then
            _pass "voice models in the image (whisper base.en, piper lessac-medium)"
        else
            _fail "voice models in the image" "missing or empty:${_vm_bad} — the build could not fetch them and they are not in live-build/download-cache"
        fi

        # ── Desktop files profiles.sh carries from the live rootfs ──────────
        # The installer copies the GNOME extensions and the Firefox policy
        # from the LIVE rootfs to the target, and the builder never put either
        # in the live rootfs: every install from 2026-09-07 logged that it had
        # nothing to carry, and shipped a dead workspace keymap and Firefox's
        # first-run pages (fiend 2026-09-14, build 16). Each extension in the
        # tree must be in the image with its entry point.
        declare -a DESK_FILES=(etc/firefox/policies/policies.json)
        for _e in "$ROOT"/live-build/config/includes.chroot/usr/share/gnome-shell/extensions/*@*; do
            [[ -d "$_e" ]] && DESK_FILES+=("usr/share/gnome-shell/extensions/${_e##*/}/extension.js")
        done
        _desk_list="$(unsquashfs -lls "$MOUNTPOINT/LiveOS/squashfs.img" "${DESK_FILES[@]}" 2>/dev/null)" || _desk_list="" # absent paths make unsquashfs exit non-zero; the loop below names them
        _desk_bad=""
        for _df in "${DESK_FILES[@]}"; do
            awk -v p="squashfs-root/$_df" '$NF == p && $1 ~ /^-/ {f = 1} END {exit !f}' <<<"$_desk_list" ||
                _desk_bad+=" $_df"
        done
        if ((${#DESK_FILES[@]} < 2)); then
            _fail "desktop carry files in the image" "no GNOME extension found in includes.chroot — the list this gate checks is empty"
        elif [[ -z "$_desk_bad" ]]; then
            _pass "desktop carry files in the image (${#DESK_FILES[@]}: Firefox policy + GNOME extensions)"
        else
            _fail "desktop carry files in the image" "missing:${_desk_bad} — builder/build-iso.sh did not copy them, so no install can carry them"
        fi

        # ── Part 2 of the show: what the installer carries to the target ────
        # An install that builds reboots into firstboot.html in a cage kiosk
        # (operator, 2026-09-14). profiles.sh copies the page, the kiosk unit and
        # the PAM stack from the LIVE rootfs; any one missing and every such
        # install shows the console fallback instead, with nothing failing loudly.
        declare -a FB2_FILES=(usr/local/share/kldload-webui/active/firstboot.html
            usr/lib/systemd/system/kldload-firstboot-kiosk.service
            etc/pam.d/kldload-kiosk usr/local/bin/kldload-firstboot-show)
        # usr/local/bin, not sbin: on the Fedora 44 live rootfs usr/local/sbin is a
        # symlink to bin, so the listing has the script under bin and the sbin path
        # is a link line. The first cut probed sbin and failed build 17 on a script
        # that was there (2026-09-15).
        _fb2_list="$(unsquashfs -lls "$MOUNTPOINT/LiveOS/squashfs.img" "${FB2_FILES[@]}" 2>/dev/null)" || _fb2_list="" # absent paths make unsquashfs exit non-zero; the loop below names them
        _fb2_bad=""
        for _df in "${FB2_FILES[@]}"; do
            awk -v p="squashfs-root/$_df" '$NF == p && $1 ~ /^-/ {f = 1} END {exit !f}' <<<"$_fb2_list" ||
                _fb2_bad+=" $_df"
        done
        if [[ -z "$_fb2_bad" ]]; then
            _pass "first-boot show part 2 in the image (page, kiosk unit, PAM stack, script)"
        else
            _fail "first-boot show part 2 in the image" "missing:${_fb2_bad} — installs that build will show the console fallback"
        fi

        # ── Every tool in includes.chroot/usr/local/{bin,sbin} must ship ────
        # The builder copies bin/ by glob and, since 2026-09-05, sbin/ too.
        # Before that sbin/ was an allow-list, and the list dropped a new tool
        # five times over four months (rhel-composer-build, boot-assert,
        # journal-assert, live-ssh-init, kfire) — each one found by hand, in
        # the built squashfs, after the build. The includes tree is the source
        # of truth for what ships, so compare it against the artefact: any
        # regular file there that is not in the image is a red gate, whatever
        # the copy mechanism of the day is.
        #
        # The image is usrmerged one level further than the tree: in the
        # squashfs usr/local/sbin is a SYMLINK to bin (and usr/sbin to bin).
        # unsquashfs extracts a path literally and never follows a link in
        # it, so asking for usr/local/sbin/kfire yields nothing while the file
        # sits at usr/local/bin/kfire. The first version of this gate did
        # exactly that and flagged all 27 sbin tools on a correct ISO
        # (2026-09-05) — a gate that fails on a correct system trains everyone
        # to ignore the suite. So each directory is resolved through the
        # image's own link chain first (unsquashfs -lls shows the target).
        _sq_resolve_dir() { # $1 = image, $2 = dir → the dir the image stores it under
            local img=$1 d=$2 hop tgt
            for hop in 1 2 3 4; do
                tgt=$(unsquashfs -lls "$img" "$d" 2>/dev/null |
                    awk -v want="squashfs-root/$d" '$1 ~ /^l/ && $(NF-2)==want {print $NF}')
                [[ -n "$tgt" ]] || break
                case "$tgt" in
                /*) d="${tgt#/}" ;;
                *) d="$(realpath -m "/${d%/*}/$tgt")" && d="${d#/}" ;;
                esac
            done
            printf '%s\n' "$d"
        }
        TOOLEXTRACT=$(mktemp -d)
        declare -a TOOL_FILES=() TOOL_IN_IMAGE=()
        for _d in usr/local/bin usr/local/sbin; do
            _img_d=$(_sq_resolve_dir "$MOUNTPOINT/LiveOS/squashfs.img" "$_d")
            for _t in "$ROOT"/live-build/config/includes.chroot/"$_d"/*; do
                [[ -f "$_t" ]] || continue
                TOOL_FILES+=("$_d/${_t##*/}")
                TOOL_IN_IMAGE+=("$_img_d/${_t##*/}")
            done
        done
        # unsquashfs exits non-zero when any requested path is absent, which is
        # exactly what the per-file check below reports.
        unsquashfs -q -f -d "$TOOLEXTRACT/root" "$MOUNTPOINT/LiveOS/squashfs.img" "${TOOL_IN_IMAGE[@]}" >/dev/null 2>&1 || true
        _tool_missing=0
        for _i in "${!TOOL_FILES[@]}"; do
            if [[ ! -f "$TOOLEXTRACT/root/${TOOL_IN_IMAGE[$_i]}" ]]; then
                _fail "squashfs has ${TOOL_FILES[$_i]}" "in includes.chroot but not in the ISO (looked at ${TOOL_IN_IMAGE[$_i]}) — the builder's copy step dropped it"
                _tool_missing=$((_tool_missing + 1))
            fi
        done
        if ((_tool_missing == 0)); then
            _pass "all ${#TOOL_FILES[@]} usr/local/{bin,sbin} tools from includes.chroot are in the squashfs"
        fi
        # extracted dirs carry the image's 0555 modes; make them removable
        chmod -R u+w "$TOOLEXTRACT" 2>/dev/null || true
        rm -rf "$TOOLEXTRACT"

        # ── The shipped kernel pin must not exclude itself ──────────────────
        # This is the invariant that was violated: build-iso.sh derived its
        # excludes from the resolver while lib/bootstrap.sh carried its own
        # literal, and nothing compared them. OpenZFS raised its cap, the pin
        # moved onto the 7.1 line, the installer kept excluding all of 7.1, and
        # an rc10 darksite holding kernel-7.1.9 installed 7.0.14 from July.
        # Silent, and the install reported success. (fiend .101, 2026-08-28.)
        #
        # Checking self-consistency in the SHIPPED artifact catches it whichever
        # half drifts, and needs no knowledge of which kernel is current.
        KPEXTRACT=$(mktemp -d)
        # The true-guard covers one case: unsquashfs exits non-zero when the
        # requested path is not in the image, which is exactly the condition
        # the missing-file check below reports properly.
        unsquashfs -q -f -d "$KPEXTRACT/root" "$MOUNTPOINT/LiveOS/squashfs.img" etc/kldload-kernel-pin >/dev/null 2>&1 || true
        _kpf="$KPEXTRACT/root/etc/kldload-kernel-pin"
        if [[ ! -f "$_kpf" ]]; then
            _fail "ISO ships /etc/kldload-kernel-pin" \
                "missing — the installer will fall back to its legacy literal and may install an older kernel than ZFS allows"
        else
            _kp_nvr=$(sed -n "s/^KPIN_NVR='\(.*\)'\$/\1/p" "$_kpf")
            _kp_ex=$(sed -n "s/^KPIN_EXCLUDES='\(.*\)'\$/\1/p" "$_kpf")
            _kp_blocked=no
            for _e in $_kp_ex; do
                # shellcheck disable=SC2254  # the glob IS the thing under test
                case "kernel-${_kp_nvr}" in ${_e#--exclude=}) _kp_blocked=yes ;; esac
            done
            if [[ -z "$_kp_nvr" ]]; then
                _fail "ISO ships a resolved kernel pin" "manifest present but KPIN_NVR is empty"
            elif [[ "$_kp_blocked" == yes ]]; then
                _fail "shipped kernel pin is not excluded by its own excludes" \
                    "pin ${_kp_nvr} is blocked by '${_kp_ex}' — the installer cannot install the kernel this ISO pinned"
            else
                _pass "ISO ships a self-consistent kernel pin (${_kp_nvr})"
            fi
        fi
        rm -rf "$KPEXTRACT"

        rm -rf "$WSEXTRACT"
    else
        # A gate that cannot run is not a gate. onyx had no squashfs-tools for
        # months and every content gate above -- launchers, shipped tools,
        # kernel pin -- silently skipped, reading as green (found 2026-09-05
        # when the tool gate was added and printed nothing at all).
        _warn "squashfs content gates" "unsquashfs missing — launcher, shipped-tool and kernel-pin gates DID NOT RUN (dnf install squashfs-tools)"
    fi

    # ── Every shipped unit's ExecStart must EXIST in the rootfs ─────────────
    # This repo copies binaries out of includes.chroot/ using CURATED LISTS in
    # build-iso.sh and profiles.sh, while systemd units are copied wholesale.
    # So adding a unit is one edit and shipping the program it runs is another,
    # and forgetting the second produces a unit that fails 203/EXEC on every
    # boot -- silently, because a failed oneshot rarely stops anything visible.
    #
    # It has now happened at least twice: kldload-rhel-composer-build (build
    # #50, caught on .103) and kldload-boot-assert (2026-08-25, caught only by
    # grepping the built squashfs by hand). Both were invisible to every
    # linter this repo runs, because nothing about either FILE is wrong -- the
    # defect is a file that is absent from an image, which only the image shows.
    # (That wording is deliberate: a comment line beginning with the linter's
    # own name is parsed as a directive and fails the parse. Learned here.)
    #
    # Checking the finished image is the only place this is visible, so it is
    # checked here rather than in a linter that cannot see it.
    if [[ -f "$MOUNTPOINT/LiveOS/squashfs.img" ]] && command -v unsquashfs >/dev/null 2>&1; then
        # LIST the squashfs, do not extract a subset of it. The first version of
        # this gate extracted five directories and then asked whether each
        # ExecStart existed underneath them -- so every unit pointing anywhere
        # else (/bin/sh, /sbin/agetty, /usr/libexec/...) was reported missing.
        # Seven false positives on a good image. A gate that cries wolf gets
        # ignored, which is worse than not having one.
        ULIST=$(mktemp)
        if unsquashfs -l "$MOUNTPOINT/LiveOS/squashfs.img" 2>/dev/null | sed 's|^squashfs-root||' | grep '^/' >"$ULIST"; then
            UUNITS=$(mktemp -d)
            unsquashfs -q -f -d "$UUNITS/root" "$MOUNTPOINT/LiveOS/squashfs.img" \
                usr/lib/systemd/system >/dev/null 2>&1 || true
            _missing=0
            _checked=0
            while IFS= read -r _unit; do
                case "$(basename "$_unit")" in kldload-* | klab-* | zexplore-* | bob-*) ;; *) continue ;; esac
                while IFS= read -r _exec; do
                    [[ -n "$_exec" ]] || continue
                    # Strip systemd's leading modifiers (- @ : ! +) and arguments.
                    _bin="${_exec#"${_exec%%[!-@:!+]*}"}"
                    _bin="${_bin%% *}"
                    [[ "$_bin" == /* ]] || continue
                    # usrmerge: /bin, /sbin, /lib and /usr/sbin are symlinks into
                    # /usr/bin and /usr/lib, and /usr/local/sbin is a symlink to
                    # /usr/local/bin. A listing shows the TARGET, so normalise
                    # before asking whether the file is there.
                    _alt="$_bin"
                    case "$_bin" in
                    /bin/*) _alt="/usr${_bin}" ;;
                    /sbin/*) _alt="/usr/bin/${_bin#/sbin/}" ;;
                    /usr/sbin/*) _alt="/usr/bin/${_bin#/usr/sbin/}" ;;
                    /usr/local/sbin/*) _alt="/usr/local/bin/${_bin#/usr/local/sbin/}" ;;
                    /lib/*) _alt="/usr${_bin}" ;;
                    esac
                    # /var/lib is state, not image content. kldload-headlamp's
                    # server binary is downloaded from GitHub at runtime by
                    # kldload-headlamp-install, so it is CORRECTLY absent from
                    # the ISO. Flagging it would be a false positive, and the
                    # first version of this gate produced seven of those --
                    # enough to make the whole suite ignorable.
                    case "$_bin" in /var/*) continue ;; esac
                    _checked=$((_checked + 1))
                    if ! grep -qxF "$_bin" "$ULIST" && ! grep -qxF "$_alt" "$ULIST"; then
                        # KNOWN-UNIMPLEMENTED, named explicitly rather than
                        # skipped silently. kldload-autobootstrap's program has
                        # never existed in this repository -- the unit and timer
                        # ship, and until 2026-08-25 firstboot enabled the timer,
                        # so it failed 203/EXEC on every install unnoticed.
                        # firstboot now refuses to enable it while the binary is
                        # absent, which makes it inert rather than broken. It
                        # stays on this list, and stays reported every build, so
                        # it is not forgotten again. Delete the entry the day the
                        # program lands -- or delete the units if it never will.
                        case "$(basename "$_unit")" in
                        kldload-autobootstrap.service)
                            _warn "unit ExecStart missing (known, unimplemented)" "$(basename "$_unit") -> ${_bin} — the program was never written; firstboot does not enable it"
                            continue
                            ;;
                        esac
                        _fail "unit ExecStart exists" "$(basename "$_unit") -> ${_bin} is NOT in the rootfs (would fail 203/EXEC)"
                        _missing=$((_missing + 1))
                    fi
                done < <(grep -hoP '^ExecStart=\K.*' "$_unit" 2>/dev/null)
            done < <(find "$UUNITS/root/usr/lib/systemd/system" -maxdepth 1 -name '*.service' 2>/dev/null)
            if ((_checked == 0)); then
                _warn "unit ExecStart gate" "no kldload unit ExecStart paths were checked — this gate DID NOT RUN"
            elif ((_missing == 0)); then
                _pass "all ${_checked} kldload unit ExecStart paths exist in the rootfs"
            fi
            rm -rf "$UUNITS"

            # ── The install kiosk ────────────────────────────────────────
            # Five files have to be in the image together or the unattended
            # install falls back to a full GNOME session -- which still works,
            # which is exactly why nobody would notice. The unit and the tool
            # reach the image by two DIFFERENT mechanisms (an explicit copy in
            # build-iso.sh and the usr/local/sbin glob), so either can go
            # missing on its own, and neither shows up in a linter.
            #
            # usr/local/sbin is a symlink to usr/local/bin in the image, hence
            # the bin spelling of the tool here -- the same usrmerge trap the
            # ExecStart gate above documents.
            _kiosk_missing=0
            for _kf in \
                /usr/bin/cage \
                /usr/local/bin/kldload-install-kiosk \
                /etc/systemd/system/kldload-install-kiosk.service \
                /etc/systemd/system/kldload-install-kiosk-fallback.service \
                /usr/lib/systemd/system-generators/kldload-kiosk-generator \
                /etc/pam.d/kldload-kiosk; do
                if grep -qxF "$_kf" "$ULIST"; then
                    continue
                fi
                _kiosk_missing=$((_kiosk_missing + 1))
                case "$_kf" in
                /usr/bin/cage)
                    _fail "install kiosk: cage" "not in the image — an unattended install falls back to the full GNOME session"
                    ;;
                */system-generators/*)
                    _fail "install kiosk: generator" "not in the image — nothing ever starts the kiosk, and an unattended install shows the text installer"
                    ;;
                *)
                    _fail "install kiosk" "${_kf} is not in the image"
                    ;;
                esac
            done
            # The inverse check. The unit has no ExecCondition any more, so an
            # enable symlink would put a full-screen kiosk on EVERY boot of the
            # image, hands-on USB boots included.
            if grep -qxF /etc/systemd/system/multi-user.target.wants/kldload-install-kiosk.service "$ULIST"; then
                _fail "install kiosk: not enabled" "the unit is enabled in the image — it would take the screen on every boot; only kldload-kiosk-generator may start it"
                _kiosk_missing=$((_kiosk_missing + 1))
            fi
            ((_kiosk_missing == 0)) &&
                _pass "install kiosk: cage, the tool, the unit, its fallback, the generator and the PAM stack are in the image, and the unit is not enabled"

            # The live ISO's Secure Boot MOK private key shipped in the image
            # from 2026-04-10 to 2026-09-13. The builder now keeps it outside
            # the rootfs and scans for private keys before mksquashfs; this is
            # the independent check on the artifact itself.
            if grep -qxE '/var/lib/dkms/mok\.key' "$ULIST"; then
                _fail "no MOK private key in the image" "/var/lib/dkms/mok.key is in the squashfs — every download would carry the Secure Boot signing key"
            else
                _pass "no MOK private key in the image (/var/lib/dkms/mok.key absent)"
            fi
        else
            _warn "unit ExecStart gate" "could not list the squashfs — this gate DID NOT RUN"
        fi
        rm -f "$ULIST"
    else
        _warn "systemd drop-in gate" "unsquashfs missing — gate DID NOT RUN (dnf install squashfs-tools)"
    fi

    umount "$MOUNTPOINT" 2>/dev/null
    _pass "ISO unmounted cleanly"
else
    _warn "ISO mount" "could not mount ISO (may need root)"
fi
rmdir "$MOUNTPOINT" 2>/dev/null

# ── Git state ────────────────────────────────────────────────────────────────
_section "Observability binaries the installer can actually copy"

# Every observability unit names a binary in its ExecStart. profiles.sh copies
# tools to the target with a LIST OF GLOBS, and a binary whose name matches no
# glob is dropped in silence -- the unit ships, the binary does not, and the
# service fails 203/EXEC on a machine nobody is watching yet.
#
# That is not hypothetical. zexplore, wgx, vmxplore and ztx were each found
# this way, one broken install at a time, and the comment above the glob list
# says so in three paragraphs. Then it happened to six tools at once:
# zfs_exporter, smartctl_exporter, ebpf_exporter, zpool-scrub-exporter, loki
# and promtail all shipped in the ISO and reached no installed machine ever,
# because not one of those names begins with k (fiend, 2026-09-13).
#
# So this gate reads the globs OUT of profiles.sh and tests each unit's
# ExecStart against them. It tracks the code rather than restating it: edit the
# glob list and this gate follows, delete a glob and it goes red.
_obs_units="${ROOT}/live-build/config/includes.chroot/usr/lib/systemd/system"
_obs_prof="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
if [[ ! -d "$_obs_units" || ! -f "$_obs_prof" ]]; then
    _warn "observability copy gate" "units dir or profiles.sh missing — gate DID NOT RUN"
else
    # The glob list, lifted from the loop itself.
    mapfile -t _obs_globs < <(
        sed -n '/^        for _src in \/usr\/local\/bin\/k\*/,/; do$/p' "$_obs_prof" |
            grep -oE '/usr/local/bin/[^ \\;]+'
    )
    if ((${#_obs_globs[@]} == 0)); then
        _warn "observability copy gate" "could not read the glob list out of profiles.sh — gate DID NOT RUN"
    else
        _obs_bad=0
        _obs_seen=0
        for _ou in "$_obs_units"/*exporter*.service "$_obs_units"/loki.service "$_obs_units"/promtail.service; do
            [[ -f "$_ou" ]] || continue
            _oe=$(grep -m1 '^ExecStart=' "$_ou" | cut -d= -f2- | awk '{print $1}')
            # Only /usr/local/bin matters: anything in /usr/bin came from a
            # package and the package manager put it on the target.
            [[ "$_oe" == /usr/local/bin/* ]] || continue
            _obs_seen=$((_obs_seen + 1))
            _hit=0
            for _g in "${_obs_globs[@]}"; do
                # The glob IS the pattern here -- that is the whole test, so the
                # right-hand side must stay unquoted.
                # shellcheck disable=SC2053
                [[ "$_oe" == $_g ]] && {
                    _hit=1
                    break
                }
            done
            ((_hit)) || {
                _fail "observability copy gate" "$(basename "$_ou") runs ${_oe}, which matches no glob in profiles.sh — it will never reach an installed system"
                _obs_bad=$((_obs_bad + 1))
            }
        done
        if ((_obs_seen == 0)); then
            _warn "observability copy gate" "no observability unit named a /usr/local/bin binary — gate DID NOT RUN"
        elif ((_obs_bad == 0)); then
            _pass "observability copy gate: all ${_obs_seen} exporter binaries match a profiles.sh copy glob"
        fi
    fi
fi

_section "Grafana dashboards point at a datasource that exists"

# Every shipped dashboard names its datasource by uid. Provisioning decides
# what uids exist. Nothing connects the two, so a dashboard can reference a uid
# no provisioning file defines and Grafana will load it, render every panel,
# and draw nothing -- on a machine where Prometheus is green and every exporter
# is up. It reads as "metrics is broken" and is a missing line of YAML.
#
# HISTORY: fiend, 2026-09-13. 226 panel references to uid "prometheus" and no
# Prometheus datasource file in the repo at all; Grafana generated
# PBFA97CFB590B2093 for the one added by hand and every panel stayed empty. The
# Loki panels worked the whole time because loki.yaml pinned uid "loki".
_g_dash="${ROOT}/live-build/config/includes.chroot/var/lib/grafana/dashboards"
_g_ds="${ROOT}/live-build/config/includes.chroot/etc/grafana/provisioning/datasources"
if [[ ! -d "$_g_dash" || ! -d "$_g_ds" ]]; then
    _warn "grafana datasource gate" "dashboards or provisioning dir missing — gate DID NOT RUN"
else
    # uids the provisioning actually defines.
    mapfile -t _g_have < <(grep -rhoE '^[[:space:]]*uid:[[:space:]]*[A-Za-z0-9_-]+' "$_g_ds" | awk '{print $2}' | sort -u)
    # uids the dashboards reference, but only for real datasource types --
    # panels, rows and library elements carry uids of their own.
    mapfile -t _g_want < <(
        grep -rhoE '"datasource":[[:space:]]*\{[^}]*\}' "$_g_dash" |
            grep -oE '"uid":[[:space:]]*"[^"]+"' | sed 's/.*"\(.*\)"/\1/' |
            grep -vE '^\$' | sort -u
    )
    if ((${#_g_want[@]} == 0)); then
        _warn "grafana datasource gate" "no datasource uids found in the dashboards — gate DID NOT RUN"
    else
        _g_bad=0
        for _w in "${_g_want[@]}"; do
            _ok=0
            for _h in "${_g_have[@]}"; do [[ "$_w" == "$_h" ]] && _ok=1 && break; done
            ((_ok)) && continue
            # A dashboard may reference a datasource kldload does not provision
            # (an imported community board). Those are a warning, not a failure
            # -- but the two kldload pins are not optional.
            case "$_w" in
            prometheus | loki)
                _fail "grafana datasource gate" "dashboards reference uid '${_w}' and no provisioning file defines it — every one of those panels renders empty"
                _g_bad=$((_g_bad + 1))
                ;;
            *)
                _warn "grafana datasource gate" "uid '${_w}' is referenced but not provisioned (imported dashboard?)"
                ;;
            esac
        done
        ((_g_bad == 0)) &&
            _pass "grafana datasource gate: every core datasource uid the dashboards use is provisioned (${#_g_have[@]} defined)"
    fi
fi

_section "The install kiosk decides before the boot transaction"

# The kiosk/desktop decision was made too late twice on 2026-09-13.
#   1. Conflicts= on tty1's owners with the decision in ExecCondition=: the
#      conflicts are resolved while the transaction is built, so every hands-on
#      USB boot lost GDM and the text installer to a kiosk that then skipped.
#   2. No Conflicts=, and the run path stopped getty itself: StandardInput=tty
#      is acquired for the ExecCondition process too, getty already held tty1,
#      and the kiosk died "Operation not permitted" before any of its code ran.
#      Its OnFailure=getty@tty1 then handed tty1 back after the first crash, so
#      no restart could ever win (fiend netboot).
# Both passed a text gate that checked the previous fault. The design now is a
# generator that decides before any transaction exists, and this gate checks
# the SHAPE of that design, in both files, so neither half can drift back.
_kio_src="${ROOT}/live-build/config/includes.chroot"
_kio="${_kio_src}/etc/systemd/system/kldload-install-kiosk.service"
_kio_gen="${_kio_src}/usr/lib/systemd/system-generators/kldload-kiosk-generator"
_kio_tool="${_kio_src}/usr/local/sbin/kldload-install-kiosk"
if [[ ! -f "$_kio" || ! -f "$_kio_gen" || ! -f "$_kio_tool" ]]; then
    _fail "kiosk decision gate" "the unit, the generator or the tool is missing from includes.chroot"
else
    _kio_bad=0
    _kio_fail() {
        _fail "kiosk decision gate" "$1"
        _kio_bad=$((_kio_bad + 1))
    }
    while IFS= read -r _line; do
        case "$_line" in
        Conflicts=*) _kio_fail "the unit declares '${_line}' — conflicts are resolved while the transaction is built; the generator masks tty1's owners instead" ;;
        ExecCondition=*) _kio_fail "the unit declares '${_line}' — a decision there runs after tty1 is already owned (fiend, 2026-09-13)" ;;
        WantedBy=*) _kio_fail "the unit declares '${_line}' — enabling it starts the kiosk on every boot; only the generator may add it" ;;
        TTYReset=* | TTYVHangup=*) _kio_fail "the unit sets '${_line}' — the kiosk unit must not hang up a terminal it may not own" ;;
        OnFailure=getty@tty1.service) _kio_fail "OnFailure=getty@tty1.service — that unit is masked on kiosk boots, and it hands tty1 back after one crash" ;;
        esac
    done < <(grep -E '^(Conflicts|ExecCondition|WantedBy|TTYReset|TTYVHangup|OnFailure)=' "$_kio")
    grep -qxF 'RestartMode=direct' "$_kio" ||
        _kio_fail "no RestartMode=direct — every crash passes through 'failed' and fires OnFailure= before the restart"
    [[ -x "$_kio_gen" ]] ||
        _kio_fail "the generator is not executable in the source tree — systemd skips a generator it cannot exec"
    grep -qE '"\$TOOL" check' "$_kio_gen" ||
        _kio_fail "the generator does not call 'kldload-install-kiosk check' — the decision must have exactly one implementation"
    grep -qF 'getty@tty1.service' "$_kio_gen" ||
        _kio_fail "the generator does not mask getty@tty1 — the kiosk would fight the console login for tty1 again"
    grep -qF 'Unable to create the wlroots renderer' "$_kio_tool" && grep -qF 'WLR_RENDERER=pixman' "$_kio_tool" ||
        _kio_fail "the tool has no software-renderer fallback — a GPU with no usable GL (nouveau on Ampere, fiend) leaves a black screen"
    ((_kio_bad == 0)) &&
        _pass "kiosk decision gate: generator decides and masks tty1's owners, unit has no ExecCondition/WantedBy/Conflicts, direct restarts, own fallback, pixman retry"
fi

_section "Install show in the initramfs"

# A netboot spends minutes in the initramfs downloading the root image, and the
# screen used to be blank for all of it (fiend, 2026-09-13). Four things have to
# hold for the show to appear: the module is complete, build-iso.sh adds it and
# asserts the outcome with lsinitrd, the slide list in the page still parses, and
# the script draws a frame. The last two are EXECUTED here, not grepped.
_sh_mod="${ROOT}/live-build/config/includes.chroot/usr/lib/dracut/modules.d/95kldload-show"
_sh_bad=0
_sh_fail() {
    _fail "initramfs show" "$1"
    _sh_bad=$((_sh_bad + 1))
}
for _f in module-setup.sh kldload-initrd-show.sh kldload-show-generator; do
    [[ -x "${_sh_mod}/${_f}" ]] || _sh_fail "${_f} is missing or not executable in 95kldload-show"
done
[[ -f "${_sh_mod}/kldload-initrd-show.service" ]] || _sh_fail "kldload-initrd-show.service is missing"
grep -qE -- '--add "[^"]*\bkldload-show\b' "$ROOT/builder/build-iso.sh" ||
    _sh_fail "build-iso.sh does not --add kldload-show to the live initramfs"
grep -qF 'etc/systemd/system/sysinit.target.wants/kldload-initrd-show.service' "$ROOT/builder/build-iso.sh" ||
    _sh_fail "build-iso.sh no longer asserts the module landed (lsinitrd outcome check) — dracut exits 0 when it skips a module"
# Without fbcon=nodefer a quiet boot never binds the framebuffer console, and the
# show paints into the dummy console for the whole download (UEFI qemu, 2026-09-13).
grep -qE "^ISO_ARGS='[^']*\bfbcon=nodefer\b" "${ROOT}/live-build/config/includes.chroot/usr/local/sbin/kldload-netboot-server" ||
    _sh_fail "kldload-netboot-server's ISO_ARGS lack fbcon=nodefer — under quiet the show is invisible"
# A descriptor to tty1 opened once dies at the first vhangup of /dev/console, and
# every later frame goes nowhere (UEFI qemu, 2026-09-13). Open per frame.
if grep -qE '^[[:space:]]*exec[[:space:]]+[0-9]*>>?[[:space:]]*"?\$TTY' "${_sh_mod}/kldload-initrd-show.sh"; then
    _sh_fail "kldload-initrd-show holds tty1 open with exec — a hangup of /dev/console kills the show for the rest of the download"
fi
_sh_tmp="$(mktemp -d)"
printf 'root=live:http://192.0.2.1/kldload/squashfs.img quiet\n' >"${_sh_tmp}/cmdline"
: >"${_sh_tmp}/tty"
KLDLOAD_SHOW_CMDLINE="${_sh_tmp}/cmdline" KLDLOAD_SHOW_TTY="${_sh_tmp}/tty" \
    KLDLOAD_SHOW_FETCHDIR="${_sh_tmp}" KLDLOAD_SHOW_ONCE=1 timeout 20 bash "${_sh_mod}/kldload-initrd-show.sh" </dev/null
grep -qF 'connecting to 192.0.2.1' "${_sh_tmp}/tty" ||
    _sh_fail "kldload-initrd-show drew no download status line"
grep -qF 'DOWNLOAD' "${_sh_tmp}/tty" ||
    _sh_fail "kldload-initrd-show drew no stage strip"
mkdir -p "${_sh_tmp}/gen"
KLDLOAD_SHOW_CMDLINE="${_sh_tmp}/cmdline" bash "${_sh_mod}/kldload-show-generator" "${_sh_tmp}/gen"
grep -qxF 'StandardError=journal' "${_sh_tmp}/gen/dracut-initqueue.service.d/50-kldload-show.conf" 2>/dev/null ||
    _sh_fail "the generator did not move dracut-initqueue's stderr off the console — curl's meter draws over the show"
rm -rf "$_sh_tmp"
((_sh_bad == 0)) &&
    _pass "initramfs show: module complete, added and asserted by build-iso.sh, a frame draws, initqueue quieted"

_section "Installer outcome checks"

# Substrate safety must run before core's early return. fiend, 2026-09-13: the
# journal, the kernel/ZFS holds and the boot repair all sat after it, so core
# installs had no working journal and an unpinned kernel.
_isp="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_isp_call="$(awk '/^k_install_system_files\(\) \{/{f=1} f&&/^[[:space:]]*k_install_substrate_safety/{print NR; exit}' "$_isp")"
_isp_core="$(awk '/^k_install_system_files\(\) \{/{f=1} f&&/"\$_profile" == "core"/{print NR; exit}' "$_isp")"
if [[ -z "$_isp_call" ]]; then
    _fail "substrate safety on core" "k_install_system_files never calls k_install_substrate_safety"
elif [[ -z "$_isp_core" ]] || ((_isp_call < _isp_core)); then
    _pass "substrate safety on core: called before the core early return (line ${_isp_call} < ${_isp_core:-none})"
else
    _fail "substrate safety on core" "k_install_substrate_safety (line ${_isp_call}) runs after the core return (line ${_isp_core}) — core installs lose journal, holds and boot repair"
fi

# The trust-bundle paths are substrate, not a first-boot job: core has no first boot
# (fiend 2026-09-13, every https repo naming ca-bundle.crt failed on core).
_iss_body="$(awk '/^k_install_substrate_safety\(\) \{/,/^}/' "$_isp")"
if grep -qF '/etc/pki/tls/certs/ca-bundle.crt' <<<"$_iss_body" && grep -qF '/etc/pki/tls/cert.pem' <<<"$_iss_body"; then
    _pass "substrate safety creates the legacy CA bundle paths on every profile"
else
    _fail "substrate safety on core" "k_install_substrate_safety no longer creates /etc/pki/tls/certs/ca-bundle.crt and cert.pem — core has no firstboot to repair them"
fi

# k_chroot_tool's first argument is the target root. Called with a tool name first
# it chroots into a directory named after the tool, and its output goes to the log
# fd, so nothing downstream can read it (install-target, fiend 2026-09-13: the
# firmware boot-entry check could never pass).
_kct="$(grep -rnE 'k_chroot_tool[[:space:]]+[a-z]' \
    "${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-install-target" \
    "${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || :)"
if [[ -z "$_kct" ]]; then
    _pass "k_chroot_tool: every call passes a target root first"
else
    _fail "k_chroot_tool called without a target root" "$_kct"
fi

# lsinitrd lists files, never dracut module directory names such as 90zfs. And its
# listing is captured before it is searched: `lsinitrd | grep -q` under pipefail is
# false on a MATCH, because grep exits at the first hit and lsinitrd dies of SIGPIPE
# (fiend 2026-09-13: "zfs.ko is NOT in initramfs" for an image that booted from ZFS).
_zc_dir="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer"
_zc_pipe="$(awk 'FNR == 1 { prev = "" }
    /^[[:space:]]*#/ { next }
    prev ~ /lsinitrd/ && prev ~ /\|[[:space:]]*$/ && $0 ~ /grep -q/ { print FILENAME ":" FNR }
    $0 ~ /lsinitrd.*\|[[:space:]]*grep -q/ { print FILENAME ":" FNR }
    { prev = $0 }' "$_zc_dir"/lib/*.sh "$_zc_dir"/backend/*.sh 2>/dev/null)"
if grep -rnE "grep -q[a-zA-Z]* ['\"]?[0-9]{2}zfs" "$_zc_dir" >/dev/null 2>&1; then
    _fail "initramfs ZFS check" "a check greps lsinitrd output for a dracut module directory (NNzfs), which lsinitrd never prints — it warns on every install"
elif [[ -n "$_zc_pipe" ]]; then
    _fail "initramfs ZFS check" "lsinitrd piped straight into grep -q, which is false on a match under pipefail: ${_zc_pipe}"
else
    _pass "initramfs ZFS check looks for the zfs.ko file in a captured listing"
fi

# The akmods signing key is given to the akmods group AFTER the package transaction
# that creates the group. fiend 2026-09-13 (full-secure): the early chgrp did not
# take, akmodsbuild could not read the key, nvidia.ko built unsigned and the desktop
# came up on nouveau.
_bs="${_zc_dir}/lib/bootstrap.sh"
_bs_tx="$(grep -nE '^[[:space:]]*akmod-nvidia xorg-x11-drv-nvidia' "$_bs" | head -n 1 | cut -d: -f1)"
_bs_fix="$(grep -nE 'chroot "\$\{target\}" chgrp akmods "\$\{_ak_key_rel\}"' "$_bs" | head -n 1 | cut -d: -f1)"
if [[ -n "$_bs_tx" && -n "$_bs_fix" ]] && ((_bs_fix > _bs_tx)); then
    _pass "akmods signing key is re-grouped after the akmod-nvidia transaction (line ${_bs_fix} > ${_bs_tx})"
else
    _fail "akmods signing key ownership" "no chgrp akmods of the signing key after the akmod-nvidia install (transaction line ${_bs_tx:-none}, fix line ${_bs_fix:-none}) — nvidia.ko builds unsigned under Secure Boot"
fi

# A BootNext left by the netboot trigger outranks BootOrder. fiend 2026-09-13: the
# reboot after install went straight back to PXE and MokManager never appeared.
if grep -qE 'efibootmgr -N' "${_zc_dir}/lib/bootloader.sh" &&
    grep -qF 'the next boot is the kldload entry' "${_zc_dir}/lib/bootloader.sh"; then
    _pass "installer clears a stale BootNext and verifies the next boot is kldload"
else
    _fail "firmware next boot" "bootloader.sh no longer clears BootNext (efibootmgr -N) or verifies BootOrder/BootNext — a netboot reinstall can reboot into PXE instead of the install"
fi

# kube-cluster falls back to the Fedora master when the redirector's mirror is down
# (fiend 2026-09-13: muug.ca refused 443, the k8s bootstrap died 4 s in).
_kc="${ROOT}/live-build/config/includes.chroot/usr/local/bin/kube-cluster"
# The release LISTING needs the same fallback: with only the redirector asked, a dead
# mirror made the F44 listing empty and the loop built Fedora 43 nodes instead.
if ! grep -qE 'curl -fSL --retry [0-9]+ .*-o "\$\{dest\}\.partial"' "$_kc" ||
    ! grep -qF 'url="https://dl.fedoraproject.org/${url#https://download.fedoraproject.org/}"' "$_kc"; then
    _fail "kube-cluster cloud image download" "no retry or no dl.fedoraproject.org fallback for the download — one dead mirror kills the k8s bootstrap"
elif ! grep -qE '^[[:space:]]+https://dl\.fedoraproject\.org/pub/fedora/linux/releases; do' "$_kc"; then
    _fail "kube-cluster cloud image listing" "the release listing does not ask dl.fedoraproject.org before dropping a Fedora version — a dead mirror silently builds older nodes"
else
    _pass "kube-cluster cloud image listing and download fall back to the Fedora master"
fi

# vmx --build-all prints generated appliance passwords. autodeploy.log is 0644
# (fiend 2026-09-13: the Web Stack's PostgreSQL and Valkey passwords were
# world-readable), so its output reaches that log only through the redaction.
_ad="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-autodeploy"
if grep -qE 'vmx --build-all[^|]*>>[[:space:]]*"\$LOG_FILE"' "$_ad"; then
    _fail "appliance passwords in autodeploy.log" "vmx --build-all output is appended to the world-readable log unredacted"
elif grep -qE 'vmx --build-all 2>&1 \| tee "\$_apps_summary"' "$_ad" && grep -qF '(PASS|PASSWORD|PASSPHRASE|SECRET|TOKEN|KEY)' "$_ad"; then
    _pass "appliance passwords: build-all summary to a 0600 root file, masked in autodeploy.log"
else
    _fail "appliance passwords in autodeploy.log" "the build-all redaction (tee to /root/kldload-appliances.txt, sed mask) is gone"
fi

# nvidia-smi loads the driver. Probing it with a desktop already up hands the boot
# framebuffer to nvidia-drm under the live session (fiend 2026-09-13: gnome-shell
# drew on a vanished device for six hours, then SIGSEGV). The AI probe must hold off
# when display-manager is active and the module is not loaded.
_adh="$(awk '/_nv_hold=1/{h=NR} /nvidia-smi -L/{if(!l)l=NR} END{print h+0, l+0}' "$_ad")"
if [[ "${_adh% *}" -gt 0 && "${_adh#* }" -gt 0 ]] && ((${_adh% *} < ${_adh#* })) &&
    grep -qF 'systemctl is-active --quiet display-manager.service' "$_ad" &&
    grep -qF '[[ "${_nv_hold:-0}" != 1 ]] && command -v nvidia-smi' "$_ad"; then
    _pass "AI GPU probe does not load nvidia under a running desktop"
else
    _fail "AI GPU probe" "kldload-autodeploy probes nvidia-smi without the display-manager hold — a first-boot driver rebuild hot-loads nvidia-drm under the desktop"
fi

# RPM Fusion is installed one release at a time with the master as a second source,
# in the installer and in first boot's NVIDIA healing net. 7-net, fiend 2026-09-13:
# one transaction from the redirector, nonfree sent to a dead mirror, no repo, no
# driver; the healing net failed the same way two seconds into first boot.
_rf_bs="$(grep -c 'https://download1.rpmfusion.org/${_rf}/fedora' "${_zc_dir}/lib/bootstrap.sh" || true)"
# swallow: grep -c exits 1 at a zero count, and zero is the failing answer judged below
_rf_fb="$(grep -c 'https://download1.rpmfusion.org/${rf}/fedora' "${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-firstboot" || true)"
if grep -qE 'rpmfusion-free-release-\$\{release\}\.noarch\.rpm" \\$' "${_zc_dir}/lib/bootstrap.sh" &&
    grep -A1 -E 'rpmfusion-free-release-\$\{release\}\.noarch\.rpm" \\$' "${_zc_dir}/lib/bootstrap.sh" | grep -q 'rpmfusion-nonfree-release'; then
    _fail "RPM Fusion install" "bootstrap.sh installs free and nonfree release packages in one transaction again — one dead mirror loses both repos"
elif [[ "$_rf_bs" -ge 1 && "$_rf_fb" -ge 1 ]]; then
    _pass "RPM Fusion repos: per-release install with the download1 master fallback (installer and first boot)"
else
    _fail "RPM Fusion install" "no download1.rpmfusion.org fallback (installer ${_rf_bs}, first boot ${_rf_fb}) — a dead mirror means no NVIDIA driver on net installs"
fi

# rpm -q prints "package X is not installed" on stdout; its output must not be used
# as data without checking the exit status (7-net: version "package kmod").
if grep -qE "_nv_ver=\\\$\(rpm .*-q --qf '%\{VERSION\}' kmod-nvidia-open-dkms.*\|\| echo" "${_zc_dir}/lib/bootstrap.sh"; then
    _fail "NVIDIA DKMS version probe" "bootstrap.sh reads rpm -q --qf output without checking that the package is installed"
else
    _pass "NVIDIA DKMS version probe checks rpm -q before trusting its output"
fi

# state.db is group-writable by kldload (non-root tools deregister through it). The
# web UI creates it, on the rpool/kldload/state dataset it mounts over /var/lib/kldload
# on first boot, so that is where the permissions are set: an installer-side chgrp
# lands in the directory the mount hides (7-net and 2-server, fiend 2026-09-13/14).
_wu="${ROOT}/live-build/config/includes.chroot/usr/local/bin/kldload-webui"
if grep -qE '^def _state_db_group_perms\(' "$_wu" &&
    awk '/con.close\(\)/{c=NR} /_state_db_group_perms\(DB_PATH\)/{if (c && NR - c <= 2) f=1} END{exit !f}' "$_wu"; then
    _pass "web UI gives the state.db it creates to the kldload group"
else
    _fail "state.db permissions" "kldload-webui creates state.db without _state_db_group_perms — server editions fail the permissions smoke check"
fi

# The kiosk opens the page as the install show, so the dashboard never flashes.
if grep -qF 'export KLDLOAD_KIOSK_SHOW=1' "${ROOT}/live-build/config/includes.chroot/usr/local/sbin/kldload-install-kiosk" &&
    grep -qF 'exec /usr/local/bin/kldload-chrome-app "$_app_id" "$page_url"' "${ROOT}/live-build/config/includes.chroot/usr/local/bin/kldload-webui-launch" &&
    grep -qF "html.ishow-boot::after" "${ROOT}/live-build/config/includes.chroot/usr/local/share/kldload-webui/free/index.html"; then
    _pass "kiosk opens the page as the install show (no dashboard flash)"
else
    _fail "kiosk dashboard flash" "the kiosk marker (KLDLOAD_KIOSK_SHOW -> ?show=1 -> html.ishow-boot cover) is incomplete"
fi

# First-boot smoke waits for autodeploy's own final phase, long enough for the full
# edition, not for k8s-ready AND ai-ready (4-k8s, 2026-09-14: no AI requested, so
# it waited out 90 min and ran in the middle of the golden builds).
_it="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
_sm_wait="$(awk '/kldload-smoke-firstboot/{f=1} f && /^ExecStartPre=/{g=1} g{print} g && /running anyway/{exit}' "$_it")"
_sm_tmo="$(awk '/kldload-smoke-firstboot/{f=1} f && /^TimeoutStartSec=/{sub(/TimeoutStartSec=/, ""); print; exit}' "$_it")"
if grep -q 'ai-ready' <<<"$_sm_wait"; then
    _fail "first-boot smoke wait" "still waits for ai-ready — editions without AI wait out the whole timeout"
elif ! grep -q 'current-phase' <<<"$_sm_wait" || ! grep -q 'nothing-requested' <<<"$_sm_wait"; then
    _fail "first-boot smoke wait" "does not wait on autodeploy's final phase (ready|partial|nothing-requested)"
elif [[ "$(grep -oE '\+ [0-9]+' <<<"$_sm_wait" | head -1 | tr -dc 0-9)" -ge "${_sm_tmo:-0}" ]]; then
    _fail "first-boot smoke wait" "TimeoutStartSec=${_sm_tmo:-unset} is not longer than the wait — systemd kills the unit first"
else
    _pass "first-boot smoke waits for autodeploy to finish (TimeoutStartSec=${_sm_tmo})"
fi

# Secure Boot artefacts are checked only on installs that asked for Secure Boot.
if grep -qF '_sb_requested=1' "${ROOT}/tests/smoke-kvm.sh" &&
    awk '/_sb_requested\)\); then/{f=1} f && /MOK key \(DER\)/{ok=1} END{exit !ok}' "${ROOT}/tests/smoke-kvm.sh"; then
    _pass "smoke-kvm checks MOK keys and the shim chain only when Secure Boot was requested"
else
    _fail "smoke-kvm Secure Boot checks" "MOK and shim files are required on installs that did not request Secure Boot"
fi

# Lab sites are powered off only after their WireGuard mesh has handshaked (6-full,
# 2026-09-14: a peer stopped 12 s after the mesh came up read as never-worked).
_ad2="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-autodeploy"
if grep -qE '^_await_mesh_handshakes\(\) \{' "$_ad2" &&
    awk '/_await_mesh_handshakes klab-green/{w=NR} /power_off_group .klab-green-\*. 1/{if (w && w < NR) ok=1} END{exit !ok}' "$_ad2"; then
    _pass "autodeploy waits for each lab mesh to handshake before powering its VMs off"
else
    _fail "lab mesh power-off" "klab-blue/green VMs are powered off without waiting for their mesh handshakes"
fi

# klab builds goldens for centos rocky fedora debian ubuntu only; asking it for rhel
# is a FATAL on every klab install.
if grep -qE '^ExecStart=.*klab golden rhel' "${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"; then
    _fail "klab-firstboot distros" "klab-firstboot runs 'klab golden rhel', which klab rejects (Unknown distro: rhel)"
else
    _pass "klab-firstboot asks klab only for distros it builds"
fi

_section "Install slides"

# The kiosk deck is a JS array in the canonical SPA. Each slide is [kicker, title,
# body]; the kicker picks the accent colour. A kicker missing from ACCENT renders in
# the default blue, a duplicate title reads as the show repeating itself, and the
# operator asked for 150-200 slides (2026-09-13).
_sl_html="${ROOT}/live-build/config/includes.chroot/usr/local/share/kldload-webui/free/index.html"
if command -v python3 >/dev/null 2>&1; then
    _sl_out="$(
        python3 - "$_sl_html" <<'PYSLIDES' 2>&1
import json, re, sys
s = open(sys.argv[1], encoding="utf-8").read()
a = s.index("  var SLIDES = [")
b = s.index("\n  ];", a)
slides = json.loads(s[a + len("  var SLIDES = "):b + 4])
ai = s.index("  var ACCENT = {")
accent = set(re.findall(r'"([^"]+)"\s*:\s*"#[0-9a-fA-F]{6}"', s[ai:s.index("};", ai)]))
errs = []
if len(slides) < 150:
    errs.append("only %d slides (want at least 150)" % len(slides))
titles = [x[1] for x in slides]
dup = sorted({t for t in titles if titles.count(t) > 1})
if dup:
    errs.append("duplicate titles: " + "; ".join(dup))
bad = sorted({x[0] for x in slides if x[0] not in accent})
if bad:
    errs.append("kickers with no ACCENT colour: " + ", ".join(bad))
shape = [str(i) for i, x in enumerate(slides) if len(x) != 3 or not all(isinstance(y, str) and y.strip() for y in x)]
if shape:
    errs.append("malformed slides at index " + ",".join(shape))
print("ERR " + " | ".join(errs) if errs else "OK %d slides, %d kickers" % (len(slides), len({x[0] for x in slides})))
PYSLIDES
    )"
    if [[ "$_sl_out" == OK* ]]; then
        _pass "install slides: ${_sl_out#OK }, unique titles, every kicker has a colour"
    else
        _fail "install slides" "$_sl_out"
    fi
else
    _warn "install slides: python3 missing — this check DID NOT RUN"
fi

_section "Answers files"

# The installer reads answers files line by line (k_answers_load_env_file), not as
# shell. The shipped TEMPLATE.env failed that loader for months while `bash -n` and
# arm-install both passed it (audit, 2026-09-13). Every shipped answers file is
# LOADED here with the real loader, and every value it produces is checked.
_an_lib="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/answers.sh"
_an_bad=0 _an_n=0
for _af in "${ROOT}"/live-build/config/includes.chroot/etc/kldload/answers/*.env \
    "${ROOT}"/live-build/config/includes.chroot/etc/kldload/debz/answers/*.env; do
    [[ -f "$_af" ]] || continue
    _an_n=$((_an_n + 1))
    _an_out="$(bash -c 'set -uo pipefail
        k_die() { echo "loader refused: $*"; exit 1; }
        source "$1"
        k_answers_load_env_file "$2"
        for v in $(compgen -v KLDLOAD_); do
            [[ "${!v}" =~ [[:space:]]# ]] && echo "value of $v carries a comment: ${!v}"
        done
        exit 0' _ "$_an_lib" "$_af" 2>&1)" || _an_out="${_an_out:-loader exited non-zero}"
    if [[ -n "$_an_out" ]]; then
        _fail "answers file ${_af#"$ROOT"/}" "$_an_out"
        _an_bad=$((_an_bad + 1))
    fi
done
if ((_an_n == 0)); then
    _fail "answers files" "found no shipped answers files to check — gate DID NOT RUN"
elif ((_an_bad == 0)); then
    _pass "answers files: all ${_an_n} shipped files load through the installer's loader with clean values"
fi

# Arming must use that same loader, never `bash -n` alone.
_an_nb="${ROOT}/live-build/config/includes.chroot/usr/local/sbin/kldload-netboot-server"
_an_chk="$(awk '/^_check_answers\(\) \{/,/^}/' "$_an_nb")"
if grep -qF 'k_answers_load_env_file "$answers"' <<<"$_an_chk"; then
    _pass "netboot-server checks answers files with the installer's own loader"
else
    _fail "netboot-server answers check" "_check_answers no longer loads the file with k_answers_load_env_file — it will arm files the installer rejects"
fi

# Secrets never reach effective-config.env, which is copied to the installed
# system's /root. Executed with a fake secret in every name shape that exists.
_an_tmp="$(mktemp -d)"
bash -c 'set -uo pipefail
    k_die() { :; }
    source "$1"
    export KLDLOAD_LOG_DIR="$2" KLDLOAD_PASSWORD=s3cr3t-a KLDLOAD_ROOT_PASSWORD=s3cr3t-b \
        KLDLOAD_ZFS_PASSPHRASE=s3cr3t-c KLDLOAD_WIFI_PSK=s3cr3t-d KLDLOAD_EXPORT_SCP_PASS=s3cr3t-e \
        KLDLOAD_MOK_PASSWORD=s3cr3t-f KLDLOAD_RHEL_KEY=s3cr3t-g KLDLOAD_RHEL_PASSWORD=s3cr3t-h \
        KLDLOAD_HOSTNAME=visible-host
    k_save_effective_config' _ "$_an_lib" "$_an_tmp" >/dev/null 2>&1 || :
if [[ ! -s "${_an_tmp}/effective-config.env" ]]; then
    _fail "effective-config redaction" "k_save_effective_config wrote nothing — gate DID NOT RUN"
elif grep -q 's3cr3t-' "${_an_tmp}/effective-config.env"; then
    _fail "effective-config redaction" "secrets written in clear: $(grep -o 'KLDLOAD_[A-Z_]*=s3cr3t-[a-z]' "${_an_tmp}/effective-config.env" | tr '\n' ' ')"
elif ! grep -q '^KLDLOAD_HOSTNAME=visible-host$' "${_an_tmp}/effective-config.env"; then
    _fail "effective-config redaction" "non-secret KLDLOAD_HOSTNAME was redacted too — autodeploy reads this file"
else
    _pass "effective-config.env redacts every password/passphrase/PSK/key and keeps the rest"
fi
rm -rf "$_an_tmp"

# First-boot sets default OFF when an answers file does not ask for them.
_an_it="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
_an_heavy="$(grep -E '^KLDLOAD_(K8S_BOOTSTRAP|ENABLE_AI|KLAB_ZFS_DEV)="\$\{KLDLOAD_[A-Z_]+:-' "$_an_it" | grep -v ':-0}"' || :)"
if [[ -z "$_an_heavy" ]]; then
    _pass "install manifest: cluster, AI and ZFS-lab default to 0 unless asked for"
else
    _fail "install manifest defaults" "a first-boot set defaults ON again — every answers-file install converges it: ${_an_heavy}"
fi

_section "autodeploy reads only what the install manifest writes"

# kldload-autodeploy runs on the INSTALLED system and learns what the operator
# asked for from /etc/kldload/install-manifest.env. A KLDLOAD_ key it reads that
# the manifest does not write is a setting that works in the live installer and
# silently vanishes at reboot. fiend, 2026-09-13: an answers file set
# KLDLOAD_K8S_WORKERS and KLDLOAD_K8S_CONTROL_PLANES, the manifest wrote
# neither, and 3+3 only came out right because it matched the template default.
_ad="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-autodeploy"
_it="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
if [[ ! -f "$_ad" || ! -f "$_it" ]]; then
    _fail "manifest coverage gate" "kldload-autodeploy or kldload-install-target is missing"
else
    _man_start="$(grep -nF 'cat >"${target}/etc/kldload/install-manifest.env" <<EOF' "$_it" | head -1 | cut -d: -f1)"
    if [[ -z "$_man_start" ]]; then
        _fail "manifest coverage gate" "cannot find the install-manifest heredoc in kldload-install-target — gate DID NOT RUN"
    else
        _man_writes="$(awk -v s="$_man_start" 'NR > s && /^EOF$/ { exit } NR > s' "$_it" | grep -oE '^KLDLOAD_[A-Z0-9_]+' | sort -u)"
        _ad_reads="$(grep -oE '\$\{?KLDLOAD_[A-Z0-9_]+' "$_ad" | tr -d '${' | sort -u)"
        _missing="$(comm -23 <(printf '%s\n' "$_ad_reads") <(printf '%s\n' "$_man_writes"))"
        if [[ -n "$_missing" ]]; then
            _fail "manifest coverage gate" "autodeploy reads keys the install manifest never writes (lost at reboot): $(tr '\n' ' ' <<<"$_missing")"
        else
            _pass "manifest coverage gate: all $(wc -l <<<"$_ad_reads") KLDLOAD_ keys autodeploy reads are persisted by the install manifest"
        fi
    fi
fi

_section "Duplicated files that must not drift"

# Some files are shipped TWICE on purpose: once into the live rootfs and once
# into the installer's target-files/, which profiles.sh reads FIRST. Editing
# only one is silent — the repo looks correct, the ISO builds, and the install
# quietly uses the stale copy.
#
# HISTORY: 2026-08-16. The dock pin list gained chromium.desktop in the
# includes.chroot copy only. Two ISOs were built and verified before anyone
# noticed the installed dock still had the old list, because the file that
# ships to the target is the OTHER one.
_dupes=(
    "etc/dconf/db/local.d/50-kldload-installed-favorites"
)
_ic="${ROOT}/live-build/config/includes.chroot"
for _d in "${_dupes[@]}"; do
    _a="${_ic}/${_d}"
    _b="${_ic}/usr/lib/kldload-installer/target-files/${_d}"
    if [[ ! -f "$_a" || ! -f "$_b" ]]; then
        _warn "$(basename "$_d")" "only one copy present — nothing to compare"
        continue
    fi
    if diff -q "$_a" "$_b" >/dev/null 2>&1; then
        _pass "$(basename "$_d") — both copies identical"
    else
        _fail "$(basename "$_d")" "the two shipped copies DIFFER — the installer reads target-files/ first and would use the stale one"
    fi
done

_section "Git State"

cd "$ROOT"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | wc -l)

_pass "Branch: $BRANCH"
_pass "Commit: $COMMIT"

if [[ $DIRTY -eq 0 ]]; then
    _pass "Working tree clean"
else
    _warn "Working tree" "$DIRTY uncommitted changes"
fi

# Check version in build-iso.sh matches
VERSION=$(grep 'VERSION=' "$ROOT/builder/build-iso.sh" | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
ISO_NAME=$(basename "$ISO")
if echo "$ISO_NAME" | grep -q "$VERSION"; then
    _pass "ISO version matches build-iso.sh: $VERSION"
else
    _warn "Version mismatch" "ISO=$ISO_NAME, build-iso.sh=$VERSION"
fi

# ── Darksite caches ──────────────────────────────────────────────────────────
_section "Darksite Caches"

for ds in debian ubuntu; do
    CACHE="$ROOT/live-build/darksite-${ds}-cache"
    if [[ -d "$CACHE" ]]; then
        PKG_COUNT=$(find "$CACHE" -name "*.deb" -o -name "*.rpm" 2>/dev/null | wc -l)
        CACHE_SIZE=$(du -sh "$CACHE" 2>/dev/null | cut -f1)
        if [[ $PKG_COUNT -gt 100 ]]; then
            _pass "${ds} darksite: $PKG_COUNT packages ($CACHE_SIZE)"
        else
            _warn "${ds} darksite" "only $PKG_COUNT packages — may be incomplete"
        fi
    else
        _warn "${ds} darksite" "no cache — offline install won't work for $ds"
    fi
done

# ── Shell-script inventory ───────────────────────────────────────────────────
# Enumerate every tracked shell script by SHEBANG, not extension: most shipped
# tools (usr/local/bin/*, usr/sbin/kldload-*, live hooks) are extensionless,
# so a '*.sh' glob misses ~120 of them. HISTORY: the extension-based gates let
# 122 shfmt-drifted files and 5 shellcheck-error files ship unchecked until
# the 2026-07 audit. git ls-files also keeps untracked caches/darksite output
# out of the sweep without a -not -path list.
_section "Script Syntax"

SHELL_SCRIPTS=()
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        [[ -f "$ROOT/$f" ]] || continue # tracked but deleted in worktree
        # Symlinks are the SAME script under a second name, and every gate
        # below would then check it twice. Harmless for bash -n / shellcheck /
        # shfmt, fatal for anything that COUNTS: the silent-failure ratchet
        # tallied kldload-rollback's `|| true` lines once per name and reported
        # the tree as having regressed by the size of the duplicate.
        # HISTORY: onyx 2026-08-30. b1268 added usr/sbin/rollback as a symlink to
        # kldload-rollback; smoke-build went red at 1454 vs a 1450 baseline
        # with 2 of the 4 being that file counted a second time.
        [[ -L "$ROOT/$f" ]] && continue
        if head -c 80 "$ROOT/$f" 2>/dev/null | head -n 1 |
            grep -qE '^#!.*(bash|/bin/sh)'; then
            SHELL_SCRIPTS+=("$f")
        fi
    done < <(git -C "$ROOT" ls-files -z)
fi

if [[ ${#SHELL_SCRIPTS[@]} -eq 0 ]]; then
    _fail "script inventory" "git ls-files found no shell scripts under $ROOT — gates below did not run"
else
    SYNTAX_BAD=0
    for f in "${SHELL_SCRIPTS[@]}"; do
        if ! bash -n "$ROOT/$f" 2>/dev/null; then
            _fail "$f syntax" "bash -n failed"
            SYNTAX_BAD=1
        fi
    done
    [[ $SYNTAX_BAD -eq 0 ]] && _pass "all ${#SHELL_SCRIPTS[@]} shell scripts bash -n clean"

    # ── Shellcheck (if available) ────────────────────────────────────────────
    # -S error only: the baseline is error-clean; warnings stay advisory.
    if command -v shellcheck >/dev/null 2>&1; then
        _section "Shellcheck"
        SC_OUT=$(cd "$ROOT" && printf '%s\0' "${SHELL_SCRIPTS[@]}" |
            # swallow: shellcheck exits non-zero when it HAS findings, which is
            # the case this gate exists to report. The findings are counted
            # below; a non-zero exit here is data, not an error.
            xargs -0 shellcheck -S error 2>&1) || true
        if [[ -z "$SC_OUT" ]]; then
            _pass "all ${#SHELL_SCRIPTS[@]} shell scripts shellcheck -S error clean"
        else
            while IFS= read -r f; do
                _fail "$f shellcheck" "run: shellcheck -S error $f"
            done < <(awk '/^In /{print $2}' <<<"$SC_OUT" | sort -u)
        fi
    else
        _warn "Shellcheck" "not installed — install ShellCheck (dnf/apt)"
    fi

    # ── shfmt drift (style enforcement, if available) ────────────────────────
    # Every tracked shell script must match `shfmt -i 4`. After the 2026
    # bulk-reformats this is the gate that keeps the codebase from drifting.
    if command -v shfmt >/dev/null 2>&1; then
        _section "shfmt drift"
        DRIFT=$(cd "$ROOT" && printf '%s\0' "${SHELL_SCRIPTS[@]}" |
            # swallow: as above — shfmt -l exits non-zero when files need
            # formatting, which is exactly what is being measured.
            xargs -0 shfmt -l -i 4 2>&1) || true
        if [[ -z "$DRIFT" ]]; then
            _pass "all ${#SHELL_SCRIPTS[@]} shell scripts shfmt-clean"
        else
            while IFS= read -r f; do
                _fail "$f" "needs 'shfmt -w -i 4'"
            done <<<"$DRIFT"
        fi
    else
        _warn "shfmt" "not installed — install shfmt (github.com/mvdan/sh releases)"
    fi
fi

# ── Python gates (shebang-selected, same reason as the shell gates) ─────────
# HISTORY: the repo map claimed gen_icons.py was "the only Python in the tree".
# One file carries a .py extension; twelve are Python by shebang — including
# kldload-webui (7.6k lines) and kldload-doctor, the two programs an operator
# leans on hardest. A '*.py' gate therefore covered 1 of 12, so ruff and mypy
# had never run on either of them (counted 2026-08-16). Same trap the shell
# gates above already document, one language over.
_section "Python Syntax"

PY_SCRIPTS=()
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        [[ -f "$ROOT/$f" ]] || continue
        if [[ "$f" == *.py ]] ||
            head -c 80 "$ROOT/$f" 2>/dev/null | head -n 1 | grep -qE '^#!.*python3?'; then
            PY_SCRIPTS+=("$f")
        fi
    done < <(git -C "$ROOT" ls-files -z)
fi

if [[ ${#PY_SCRIPTS[@]} -eq 0 ]]; then
    _warn "python inventory" "no python files found — gate did not run"
else
    PY_BAD=0
    for f in "${PY_SCRIPTS[@]}"; do
        if ! python3 -m py_compile "$ROOT/$f" 2>/dev/null; then
            _fail "$f py_compile" "python3 -m py_compile $f"
            PY_BAD=1
        fi
    done
    [[ $PY_BAD -eq 0 ]] && _pass "all ${#PY_SCRIPTS[@]} python files py_compile clean"

    # Advisory, not fatal: these files have never been linted, so failing on
    # the existing findings would block every commit. The count is printed so
    # it can be ratcheted down like the shell baseline was.
    if command -v ruff >/dev/null 2>&1; then
        _ruff_n=0
        for f in "${PY_SCRIPTS[@]}"; do
            _ruff_n=$((_ruff_n + $(ruff check --select=E9,F --quiet "$ROOT/$f" 2>/dev/null | grep -cE '^[A-Z][0-9]+' || true)))
        done
        if [[ $_ruff_n -eq 0 ]]; then
            _pass "python: no syntax/undefined-name findings (ruff E9,F)"
        else
            _warn "python ruff" "${_ruff_n} E9/F finding(s) across ${#PY_SCRIPTS[@]} files — ratchet down, do not add more"
        fi
    else
        _warn "python ruff" "ruff not installed — these files are ungated without it"
    fi
fi

# ── systemd enablement symlinks ────────────────────────────────────────────
#
# A unit is enabled by a symlink in <target>.wants pointing at the unit file.
# If that symlink points at a name which does not exist, systemd starts
# nothing and says nothing: the unit file ships, `ls` shows the symlink, and
# the service simply never runs. Same class as §2c -- installed is not enabled.
#
# Found 2026-09-07: both live-ISO enablement symlinks still pointed at debz-*
# names from the project's earlier identity, so kldload-autoinstall.service had
# never once started. The entire unattended-install path was dead on arrival,
# which is why deploy.sh seed-disk was documented and never written.
_section "systemd enablement symlinks"

_wants_bad=0
_wants_n=0
while read -r _l; do
    [[ -n "$_l" ]] || continue
    _wants_n=$((_wants_n + 1))
    _tgt="$(readlink "$_l")"
    if ! git -C "$ROOT" ls-files | grep -qF "/$(basename "$_tgt")"; then
        _fail "enablement symlink ${_l#"$ROOT"/}" "points at $_tgt, which is not in the tree — the unit will never start"
        _wants_bad=$((_wants_bad + 1))
    fi
done < <(find "$ROOT/live-build/config/includes.chroot" -path '*.target.wants/*' -type l 2>/dev/null)

if [[ $_wants_bad -eq 0 ]]; then
    _pass "all ${_wants_n} enablement symlinks resolve to units in the tree"
fi

# ── GNOME shell extensions ─────────────────────────────────────────────────
#
# The keymap is written in two halves that must agree. 00-kldload-desktop
# ENABLES an extension by UUID and binds keys under its settings path; the
# extension's own files and compiled schema supply the other half. Nothing
# connects the two at build time, so a UUID typo, a renamed key or a whole
# missing extension all present identically at runtime: the key does nothing,
# no error anywhere.
#
# That is not hypothetical. Until 2026-09-07 the installer never copied
# /usr/share/gnome-shell/extensions to the target at all, so every installed
# desktop ran with the extension enabled and absent, and Super+Arrow had been
# a dead key since it shipped. Found on fiend by hand. These gates make the
# next instance loud instead.
_section "GNOME shell extensions"

_gse_dconf="$ROOT/live-build/config/includes.chroot/etc/dconf/db/local.d/00-kldload-desktop"
_gse_dir="$ROOT/live-build/config/includes.chroot/usr/share/gnome-shell/extensions"
if [[ ! -f "$_gse_dconf" ]]; then
    _pass "gnome extensions: no desktop keymap shipped, nothing to check"
else
    # Every UUID the keymap enables must exist as a real extension.
    _gse_uuids=$(sed -n "s/^enabled-extensions=\[\(.*\)\]$/\1/p" "$_gse_dconf" |
        tr -d "'\"" | tr ',' ' ')
    _gse_n=0
    for _u in $_gse_uuids; do
        _gse_n=$((_gse_n + 1))
        if [[ -f "$_gse_dir/$_u/extension.js" ]]; then
            _pass "gnome extension $_u present"
        else
            _fail "gnome extension $_u" "enabled-extensions lists it but $_gse_dir/$_u/extension.js is missing — every key bound to it is a dead key"
        fi

        # Each key bound under the extension's dconf path must exist in its
        # COMPILED schema. A key the schema does not carry is silently ignored
        # by the extension's GSettings, which is the same dead key by a
        # different route.
        _gse_schema="$_gse_dir/$_u/schemas"
        if [[ -f "$_gse_schema/gschemas.compiled" ]] && command -v gsettings >/dev/null 2>&1; then
            _gse_id=$(sed -n 's/.*"settings-schema": *"\([^"]*\)".*/\1/p' "$_gse_dir/$_u/metadata.json")
            if [[ -n "$_gse_id" ]]; then
                _gse_have=$(gsettings --schemadir "$_gse_schema" list-keys "$_gse_id" 2>/dev/null | tr '\n' ' ')
                # Keys bound in the dconf file under this extension's path.
                _gse_want=$(awk -v path="[org/gnome/shell/extensions/${_u%%@*}]" '
                    $0 ~ /^\[org\/gnome\/shell\/extensions\// { inblk = ($0 == path) ; next }
                    /^\[/ { inblk = 0; next }
                    inblk && /^[a-z0-9-]+=/ { sub(/=.*/, ""); print }' "$_gse_dconf")
                _gse_bad=0
                for _k in $_gse_want; do
                    [[ " $_gse_have " == *" $_k "* ]] ||
                        {
                            _fail "gnome extension $_u key $_k" "bound in 00-kldload-desktop but absent from the compiled schema — recompile with glib-compile-schemas $_gse_schema"
                            _gse_bad=1
                        }
                done
                [[ $_gse_bad -eq 0 && -n "$_gse_want" ]] &&
                    _pass "gnome extension $_u: every bound key exists in its compiled schema"
            fi
        else
            _warn "gnome extension $_u schema" "no compiled schema or no gsettings — the bound-key gate DID NOT RUN"
        fi
    done
    [[ $_gse_n -gt 0 ]] || _pass "gnome extensions: none enabled by the keymap"

    # The grid geometry runs standalone under gjs, so run it.
    _gse_test="$ROOT/tests/gnome-grid-layout.test.js"
    if [[ -f "$_gse_test" ]]; then
        if command -v gjs >/dev/null 2>&1; then
            if gjs -m "$_gse_test" >/dev/null 2>&1; then
                _pass "gnome grid layout: geometry assertions pass"
            else
                _fail "gnome grid layout" "run: gjs -m tests/gnome-grid-layout.test.js"
            fi
        else
            _warn "gnome grid layout" "gjs not installed — the tiling geometry is UNGATED (this check DID NOT RUN; dnf install gjs)"
        fi
    fi
fi

# ── environment.d ──────────────────────────────────────────────────────────
#
# Same two-leg trip as the systemd drop-ins, and it fails the same silent way:
# this build copies files by NAME, so a file in a directory nobody enumerated
# looks shipped in the repo and reaches nothing. Both legs are asserted, plus
# the pair-consistency that makes the setting actually correct — XCURSOR_SIZE
# and dconf's cursor-size are the same fact written twice, because GLFW reads
# the environment and cannot see dconf.
_section "environment.d"

_envd_src="$ROOT/live-build/config/includes.chroot/usr/lib/environment.d"
if [[ ! -d "$_envd_src" ]]; then
    _pass "environment.d: none shipped, nothing to carry"
else
    # grep -c prints its own "0" and THEN exits 1 when the directory holds no
    # .conf yet -- a work-in-progress, not a build failure. The `|| true` keeps
    # that zero; `|| echo 0` would print a second one and the count would read
    # "0 0".
    _envd_n=$(find "$_envd_src" -name '*.conf' | grep -c . || true)
    if grep -q 'includes.chroot/usr/lib/environment.d' "$ROOT/builder/build-iso.sh"; then
        _pass "environment.d: build-iso.sh carries all ${_envd_n} to the ISO"
    else
        _fail "environment.d (ISO)" \
            "${_envd_n} file(s) in includes.chroot and nothing in build-iso.sh copies them — they will not reach the ISO"
    fi
    if grep -q 'for _envd in /usr/lib/environment.d/\*\.conf' \
        "$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"; then
        _pass "environment.d: profiles.sh carries them to an installed target"
    else
        _fail "environment.d (target)" \
            "${_envd_n} file(s) reach the ISO and the installer does not carry them to the target"
    fi

    # XCURSOR_SIZE and dconf cursor-size must agree, or GLFW apps draw a
    # different-sized pointer than the rest of the desktop the moment they set
    # a cursor -- which is at the title bar and the window edges, because those
    # are client-side decorations. Reported on fiend 2026-09-02.
    _xc="$(sed -n 's/^XCURSOR_SIZE=//p' "$_envd_src"/*.conf 2>/dev/null | head -1)"
    _dc="$(sed -n 's/^cursor-size=//p' "$ROOT/live-build/config/includes.chroot/etc/dconf/db/local.d/00-kldload-desktop" 2>/dev/null | head -1)"
    if [[ -z "$_xc" || -z "$_dc" ]]; then
        _warn "cursor size" "XCURSOR_SIZE=${_xc:-unset} dconf cursor-size=${_dc:-unset} — one of the pair is missing"
    elif [[ "$_xc" == "$_dc" ]]; then
        _pass "cursor size: XCURSOR_SIZE and dconf cursor-size agree (${_xc})"
    else
        _fail "cursor size" \
            "XCURSOR_SIZE=${_xc} but dconf cursor-size=${_dc} — GLFW apps will draw a different pointer than the desktop"
    fi
fi

# ── Go trees ───────────────────────────────────────────────────────────────
#
# kldload ships a Go console -- wg/, the read-only WireGuard estate lens -- and
# until 2026-09-02 nothing had ever looked at it. smoke-build gates shell and
# python; kldload has no GitHub Actions; and wg/ is tracked inside this repo
# rather than in its own, so it inherited none of the sister consoles' CI.
#
# The cost was exactly what you would expect from a tree with no gate: the
# static binary shipped six symbols nobody called, because manual.go had lost
# the //go:build gui tag its upstream copy still carries, and its header
# comment claimed the file was "shared by both consoles" so nobody looked.
# staticcheck found all six in under a second, the first time it was ever run
# there.
#
# Discovered by module, not by a hardcoded path: a second Go tree added later
# gets gated automatically instead of quietly repeating this.
_section "Go trees"

GO_MODS=()
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
        [[ "$(basename "$f")" == "go.mod" ]] && GO_MODS+=("$(dirname "$f")")
    done < <(git -C "$ROOT" ls-files -z '*go.mod')
fi

if [[ ${#GO_MODS[@]} -eq 0 ]]; then
    _pass "go trees: none tracked, nothing to gate"
elif ! command -v go >/dev/null 2>&1; then
    # Loud, never silent. A gate that cannot run is reported as not having run.
    _warn "go trees" "go not installed — ${#GO_MODS[@]} Go tree(s) are UNGATED (this check DID NOT RUN)"
else
    for _gm in "${GO_MODS[@]}"; do
        _gd="$ROOT/$_gm"
        # GOTMPDIR inside the tree: `go test` links a test binary into TMPDIR
        # and executes it, so a host mounting /tmp noexec (onyx does) fails with
        # "fork/exec ...: permission denied" — which reads like a broken test
        # and is actually the gate failing to start.
        mkdir -p "$_gd/.gotmp"
        _go_bad=""
        [[ -n "$(cd "$_gd" && gofmt -l . 2>/dev/null)" ]] && _go_bad+=" gofmt"
        (cd "$_gd" && go vet ./... >/dev/null 2>&1) || _go_bad+=" vet"
        (cd "$_gd" && go vet -tags gui ./... >/dev/null 2>&1) || _go_bad+=" vet(gui)"
        (cd "$_gd" && GOTMPDIR="$_gd/.gotmp" go test ./... >/dev/null 2>&1) || _go_bad+=" test"
        (cd "$_gd" && GOTMPDIR="$_gd/.gotmp" go test -tags gui ./... >/dev/null 2>&1) || _go_bad+=" test(gui)"
        if [[ -z "$_go_bad" ]]; then
            _pass "go ${_gm}: gofmt, vet and test clean (both flavors)"
        else
            _fail "go ${_gm}" "failing:${_go_bad} — run 'cd ${_gm} && make check'"
        fi

        # staticcheck is separate because it catches the class the others miss
        # entirely: code that compiles, passes vet and is reached by nothing.
        if command -v staticcheck >/dev/null 2>&1; then
            _sc_bad=""
            (cd "$_gd" && staticcheck ./... >/dev/null 2>&1) || _sc_bad+=" static"
            (cd "$_gd" && staticcheck -tags gui ./... >/dev/null 2>&1) || _sc_bad+=" gui"
            if [[ -z "$_sc_bad" ]]; then
                _pass "go ${_gm}: staticcheck clean (both flavors)"
            else
                _fail "go ${_gm} staticcheck" "dead or suspect code in:${_sc_bad} — cd ${_gm} && staticcheck ./..."
            fi
        else
            _warn "go ${_gm} staticcheck" "staticcheck not installed — dead code in this tree is UNGATED"
        fi

        # govulncheck needs the online vulnerability database, and this gate is
        # expected to work on a darksite host with no route out. So: report what
        # it found when it ran, and say plainly that it did not when it could
        # not. Never let the offline case read as clean.
        if ! command -v govulncheck >/dev/null 2>&1; then
            _warn "go ${_gm} govulncheck" "govulncheck not installed — dependency advisories are UNGATED"
        elif ! (cd "$_gd" && timeout 180 govulncheck ./... >/tmp/kld-govuln.$$ 2>&1); then
            if grep -qiE 'no such host|dial tcp|timeout|connection refused' /tmp/kld-govuln.$$; then
                _warn "go ${_gm} govulncheck" "no route to the vulnerability database — this check DID NOT RUN"
            else
                _fail "go ${_gm} govulncheck" "$(grep -m1 'Vulnerability #' /tmp/kld-govuln.$$ || echo 'see govulncheck ./...')"
            fi
            rm -f /tmp/kld-govuln.$$
        else
            _pass "go ${_gm}: govulncheck reports no vulnerabilities"
            rm -f /tmp/kld-govuln.$$
        fi
    done
fi

# ── Unit-copy completeness ─────────────────────────────────────────────────
#
# Every kldload systemd unit shipped in includes.chroot must appear in
# profiles.sh's explicit copy list, or it lands on the live ISO and never on an
# installed system.
#
# That list is deliberately explicit so adding a unit is a conscious decision.
# The cost is that FORGETTING one is completely silent: the unit file sits in
# the squashfs, `systemctl enable` in the installer fails into a log nobody
# reads, and the installed machine answers "not-found" for a feature that
# looks, from the repo, entirely present.
#
# By its own comments this has bitten: the kldload-rag-* units, zexplore-api,
# kldload-zfs-dbgmsg.timer, kldload-package-holds.service, sanoid-prune.service
# — and then kldload-inventory-sync.{service,timer} on 2026-08-21, added and
# enabled on the ISO in the same session that documented the previous five.
# Six times is not carelessness, it is a missing gate.
_section "Unit-copy completeness"

_uc_units="$ROOT/live-build/config/includes.chroot/usr/lib/systemd/system"
_uc_profiles="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
if [[ ! -d "$_uc_units" || ! -f "$_uc_profiles" ]]; then
    _warn "unit-copy completeness" "unit dir or profiles.sh missing — gate did not run"
else
    # Search the WHOLE install path, not just profiles.sh: a unit can legitimately
    # reach a target from bootstrap.sh, kldload-install-target or build-iso.sh's
    # own target-copy blocks. Naming it nowhere in any of them is the thing that
    # cannot possibly work.
    _uc_haystack=(
        "$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer"
        "$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
        "$ROOT/builder/build-iso.sh"
    )
    _uc_missing=()
    for _u in "$_uc_units"/kldload-*.service "$_uc_units"/kldload-*.timer; do
        [[ -f "$_u" ]] || continue
        _un="$(basename "$_u")"
        # Templates are instantiated by name, never copied literally.
        [[ "$_un" == *"@"* ]] && continue
        # kldload-live-* exist only on the live ISO by design — the installer
        # is supposed to leave them behind, so absence is correct, not a bug.
        [[ "$_un" == kldload-live-* ]] && continue
        grep -rqF "$_un" "${_uc_haystack[@]}" 2>/dev/null || _uc_missing+=("$_un")
    done
    if [[ ${#_uc_missing[@]} -eq 0 ]]; then
        _pass "unit-copy completeness: every shipped kldload unit is in the installer copy list"
    else
        _fail "unit-copy completeness" \
            "${#_uc_missing[@]} unit(s) ship on the ISO but profiles.sh never copies them to the target: ${_uc_missing[*]}"
    fi
fi

# ── Regression guards for fixes with no other coverage ─────────────────────
#
# Every check here guards a defect that SHIPPED, was found on hardware, and
# was fixed — and that no other gate would notice being undone. They are
# source invariants rather than behavioural tests: they cannot prove the fix
# still works, only that the mechanism is still present. That is a deliberate
# trade, because they cost milliseconds and run on every build, whereas the
# behaviour needs a VM and forty minutes.
#
# The pattern to preserve: when a fix is a LINE that can be deleted by a
# refactor and produce a silently-degraded system, it gets a line here.
_section "Regression guards"

_ic="$ROOT/live-build/config/includes.chroot"

# _guard <label> <file> <regex> <why-it-matters>
# Present = pass. Absent = fail, naming the failure the removal would cause.
_guard() {
    local label="$1" file="$2" rx="$3" why="$4"
    if [[ ! -f "$file" ]]; then
        _fail "$label" "file missing: ${file#"$ROOT"/}"
        return
    fi
    if grep -qE "$rx" "$file" 2>/dev/null; then
        _pass "$label"
    else
        _fail "$label" "$why"
    fi
}

# br0 came up with no port on every boot, so nm-online failed and the box was
# degraded for its whole life. STP off and the cloned MAC are what make the
# handover work at all: with STP the DHCP request lands in a 15s forwarding
# hole, and without the MAC the bridge takes a different lease (.101 -> .118).
_guard "br0: STP disabled" "$_ic/usr/sbin/kldload-firstboot" \
    'bridge\.stp no' \
    "without stp off the bridge cannot forward for 15s and DHCP times out"
_guard "br0: MAC cloned from NIC" "$_ic/usr/sbin/kldload-firstboot" \
    'bridge\.mac-address' \
    "without the NIC's MAC the bridge takes a NEW dhcp lease — the host moves address"
_guard "br0: rollback on failure" "$_ic/usr/sbin/kldload-firstboot" \
    'rolling back' \
    "a half-built bridge with no rollback leaves the host unreachable and unfixable remotely"

# A unit copied to the target but never enabled is a unit that never runs.
# This list has silently disabled a feature six times.
_guard "kldload-collect enabled" "$_ic/usr/lib/kldload-installer/lib/profiles.sh" \
    'timers\.target\.wants/kldload-collect\.timer' \
    "collect ships in the squashfs but never runs without its enable symlink"

# A bare `ansible` found no inventory on a fully registered box, because only
# kldload's own callers exported ANSIBLE_CONFIG.
_guard "ansible.cfg is the system default" "$_ic/usr/lib/kldload-installer/lib/profiles.sh" \
    '/etc/ansible/ansible\.cfg' \
    "without this a bare 'ansible' parses no inventory and sees only localhost"

# Group targeting was impossible from the webui: every target became a
# one-element ad-hoc inventory, so a group name resolved as a hostname.
_guard "ansible runs against the real inventory" "$_ic/usr/local/bin/kldload-webui" \
    '_target_in_inventory' \
    "without this every target becomes '-i host,' and no group can ever be addressed"

# Scaled workers joined k8s and the mesh but never entered the state DB, so
# the Ansible inventory could not see them.
_guard "scaled workers register in the DB" "$_ic/usr/local/bin/kube-cluster" \
    '_db_register_node "\$name" "worker"' \
    "a worker missing from the nodes table is invisible to every playbook"

# Control planes created during bootstrap never joined the host mesh, because
# the hypervisor key does not exist yet at that point in the sequence.
_guard "bootstrap reconciles the mesh" "$_ic/usr/local/bin/kube-cluster" \
    'cmd_mesh_repair' \
    "without this a cluster born with N control planes leaves the extra ones off the mesh"

# The clone seed was attached at sdz on a SCSI bus the goldens do not have, so
# the guest never saw it: no hostname, no keys, no agent, sshd refusing.
_guard "clone seed on the SATA bus" "$_ic/usr/local/bin/kvm-clone" \
    'targetbus sata' \
    "on scsi the guest never enumerates the seed and cloud-init falls back to DataSourceNone"

# Sealing removes host keys promising clones regenerate them; nothing did.
_guard "seal enables cloud-init" "$_ic/usr/local/share/kldload-ansible/playbooks/seal-golden.yml" \
    'systemctl enable cloud-init\.target' \
    "with the target disabled the seed is inert: no hostname, no keys, no agent"
_guard "seal guarantees ssh host keys" "$_ic/usr/local/share/kldload-ansible/playbooks/seal-golden.yml" \
    'ssh-keygen -A' \
    "sshd will not start without host keys, and the seal deletes them"
_guard "seal pins the NoCloud datasource" "$_ic/usr/local/share/kldload-ansible/playbooks/seal-golden.yml" \
    'datasource_list' \
    "unpinned, cloud-init spends up to 240s probing EC2 metadata that cannot exist here"

# Desktop goldens were built on the cloud kernel, which carries no DRM at all,
# so five goldens were built repeatedly and none ever rendered a desktop.
_guard "desktop goldens get a generic kernel" "$_ic/usr/local/bin/klab" \
    'apt-get install -y linux-image-amd64' \
    "the cloud kernel has no drm/virtio_gpu — X exits and the desktop is a black screen"

# Every k8s node reported no-agent because the install lived in a cloud-init
# runcmd that never ran.
_guard "golden installs the guest agent" \
    "$_ic/usr/local/share/kldload-ansible/playbooks/provision-golden.yml" \
    'qemu-guest-agent' \
    "without the agent libvirt cannot read a guest's IP and can only stop it by ACPI"

# Enrollment was a privilege of kube-cluster; every other VM path stopped at
# the DB row.
_guard "kspawn enrols its nodes" "$_ic/usr/local/sbin/kspawn" \
    'kldload-enroll' \
    "cloud VMs land in the DB but never on the mesh — a two-tier estate"

# ── Build-path invariants ──────────────────────────────────────────────────

# No arbitrary versions. Every version is derived from the ZFS cap and locked
# as a unit; a literal here goes stale silently and lies about being tested.
if git -C "$ROOT" grep -qIE '^[^#]*[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc[0-9]+' -- builder build deploy.sh 2>/dev/null; then
    _fail "no literal kernel NVR in the build path" \
        "a hardcoded NVR reintroduces the stale-pin defect the resolver exists to remove"
else
    _pass "no literal kernel NVR in the build path"
fi

# Written-but-never-wired is this repo's most repeated defect: the guest-agent
# install parked in a runcmd, the ansible.cfg that existed but was not the
# default, the resolver committed with zero callers.
if grep -q 'resolve-stack' "$ROOT/build/darksite-debian/build-darksite-debian.sh" 2>/dev/null; then
    _pass "stack resolver is actually called"
else
    _fail "stack resolver is actually called" \
        "resolve-stack.sh exists but nothing invokes it — the stack would be unpinned"
fi

# A shipped tool's imports must be PACKAGED. This is the "coded correctly and
# cannot work" class: kldload-webui imports pam for console password auth,
# python3-pam was in no package list, and because the import sits in a
# try/except the webui came up fine and silently refused every console login
# while logging "PAM auth error" where nobody looks (.107, 2026-08-22). A
# guarded import turns a missing dependency from a crash into a dead feature,
# which is strictly harder to notice.
_ic_pf="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
for _mod in pam websockets yaml; do
    if grep -q "python3-${_mod}" "$_ic_pf" 2>/dev/null; then
        _pass "python3-${_mod} is in a package list"
    else
        _fail "python3-${_mod} is in a package list" \
            "a shipped tool imports ${_mod}; unpackaged it becomes a silently dead feature"
    fi
done
# pip must exist wherever anything falls back to it (profiles.sh installs
# websockets via pip3 on distros whose package is too old).
if grep -q 'python3-pip' "$_ic_pf" 2>/dev/null; then
    _pass "python3-pip is in a package list"
else
    _fail "python3-pip is in a package list" "pip fallbacks silently no-op without it"
fi

# INSTALLED IS NOT ENABLED. Five services shipped dead in one codebase on
# 2026-08-22 — present on disk, package query says installed, nothing errors,
# and none of them ever ran. Each pair below is (thing that must be enabled,
# file that must enable it).
while IFS='|' read -r _svc _file _why; do
    [[ -n "$_svc" ]] || continue
    _p="$ROOT/$_file"
    if [[ ! -f "$_p" ]]; then
        _fail "enabled: $_svc" "missing file: $_file"
    # Two syntaxes count as enabling, because both are used here: a shell
    # `systemctl enable`, and Ansible's systemd module with `enabled: true`.
    # Matching only the shell form failed provision-golden.yml, which enables
    # the agent perfectly well through Ansible — a gate that only knows one
    # dialect reports a bug that is not there.
    elif grep -qE "systemctl enable[^|;&]*${_svc}|timers\.target\.wants/${_svc}|multi-user\.target\.wants/${_svc}" "$_p" 2>/dev/null ||
        { grep -qF "$_svc" "$_p" 2>/dev/null && grep -qE '^[[:space:]]*enabled:[[:space:]]*(true|yes)' "$_p" 2>/dev/null; }; then
        _pass "enabled: $_svc"
    else
        _fail "enabled: $_svc" "$_why"
    fi
done <<'ENABLES'
ssh|live-build/config/includes.chroot/usr/local/bin/klab|a golden whose sshd is not enabled clones into unreachable VMs
qemu-guest-agent|live-build/config/includes.chroot/usr/local/bin/klab|without it the hypervisor cannot read a guest IP or stop it gracefully
cloud-init.target|live-build/config/includes.chroot/usr/local/bin/klab|disabled cloud-init makes every clone seed inert: no hostname, no keys
cloud-init.target|live-build/config/includes.chroot/usr/local/share/kldload-ansible/playbooks/seal-golden.yml|same, on the k8s golden path
kldload-collect.timer|live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh|copied to the target but never enabled means it never runs
sanoid-prune|live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh|nothing prunes snapshots without it
qemu-guest-agent|live-build/config/includes.chroot/usr/local/share/kldload-ansible/playbooks/provision-golden.yml|k8s nodes report no-agent without it
ENABLES

# Per-family package names must BRANCH, not be hardcoded. The pam module is
# the worst case: the same package name ships a different module on each
# family, so one hardcoded name is silently wrong on exactly one of them.
#   fedora python3-pam   -> import pam   OK
#   debian python3-pam   -> import PAM   FAILS
#   debian python3-pampy -> import pam   OK
_pf="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
if grep -q '_pam="python3-pampy"' "$_pf" 2>/dev/null &&
    grep -qE 'fedora \| centos \| rocky \| rhel\).*_pam="python3-pam"' "$_pf" 2>/dev/null; then
    _pass "pam package branches per family"
else
    _fail "pam package branches per family" \
        "one hardcoded name is wrong on one family — console auth dies silently there"
fi

# The encrypted boot path must NOT carry `quiet`: the passphrase prompt goes to
# /dev/console and quiet is what hides it, so the operator has to press Enter to
# force a redraw (.120, 2026-08-22, and .143 before it).
#
# THERE ARE TWO CMDLINES AND ONLY ONE OF THEM IS EVER READ ON A NORMAL BOOT.
# This checked _direct_bootargs — GRUB's direct entry — which a machine booting
# via ZFSBootMenu never reads, because ZBM builds its cmdline EXCLUSIVELY from
# org.zfsbootmenu:commandline. So this passed continuously from 2026-08-18 while
# every encrypted install still hid its prompt, and the bug was only found by an
# operator sitting in front of one on 2026-08-26. A gate on the branch nobody
# takes is not a gate.
# THE INVARIANT CHANGED, and this gate changed with it rather than being deleted.
#
# What must hold is "the passphrase prompt is visible", not "quiet is absent".
# Dropping quiet was the old way of guaranteeing it and it cost every encrypted
# install a boot full of kernel log output. The guarantee now comes from
# /etc/zfs/initramfs-tools-load-key.d/kldload-prompt, which lowers printk while
# it asks and writes the prompt as userspace output straight to the console --
# so quiet, which gates KERNEL messages, cannot hide it.
#
# So quiet is now REQUIRED on both cmdlines, and the extension is what makes
# that safe. The gate above ("ZFS passphrase-prompt extension ships") is the
# other half; if it ever fails, this one becomes a liability rather than a
# feature, which is exactly why they are checked together.
_sz="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/storage-zfs.sh"
_bl="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootloader.sh"
_pfx="$ROOT/live-build/config/includes.chroot/etc/zfs/initramfs-tools-load-key.d/kldload-prompt"

# And quiet on an ENCRYPTED install must be gated on whether the extension
# actually runs there. /etc/zfs/initramfs-tools-load-key.d/ is an
# initramfs-tools mechanism; dracut (Fedora, EL) and mkinitcpio (Arch) never
# source it, so on those substrates quiet would hide the passphrase prompt
# exactly as it did before 2026-08-18.
#
# Caught 2026-08-27 before shipping: the quiet change was written and proven
# entirely on Debian trixie, then applied to all nine substrates at once. An
# encrypted Fedora install would have booted to a blank screen that looked hung.
_cm="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/common.sh"
if ! grep -q 'kernel/printk' "$_pfx" 2>/dev/null; then
    _fail "quiet boot gated on the prompt extension" \
        "the extension no longer quietens the console — quiet would hide the passphrase prompt again"
elif ! grep -q 'k_prompt_extension_applies()' "$_cm" 2>/dev/null; then
    _fail "quiet boot gated on the prompt extension" \
        "k_prompt_extension_applies is gone — quiet would be applied on dracut/mkinitcpio where the extension is inert"
elif ! grep -q 'k_prompt_extension_applies' "$_bl" 2>/dev/null; then
    _fail "quiet boot gated on the prompt extension" \
        "the direct entry does not consult it — encrypted Fedora/EL/Arch would boot quiet with an invisible prompt"
elif ! grep -q 'k_prompt_extension_applies' "$_sz" 2>/dev/null; then
    _fail "quiet boot gated on the prompt extension" \
        "the ZBM cmdline does not consult it — same failure on the SB-off path"
else
    _pass "quiet boot gated per-substrate on whether the prompt extension runs"
fi

# And the hostid must be pinned, or which value ZFS sees depends on how it
# booted: the SPL module parameter when set, /etc/hostid otherwise. Those
# disagreed on fiend and the pool refused to import ("previously in use from
# another system"), dropping to an initramfs prompt.
if grep -qE 'spl_hostid=0x\$\{_hid\}' "$_sz" 2>/dev/null; then
    _pass "spl_hostid pinned on the ZBM cmdline"
else
    _fail "spl_hostid pinned on the ZBM cmdline" \
        "hostid resolves from two sources that can disagree — import fails and drops to initramfs"
fi

# autodeploy's klab-goldens wait must not read "inactive" as "finished".
# klab-firstboot is timer-started 3 min after boot; on 3-kvm (fiend 2026-09-14)
# autodeploy reached the wait 35 s before the timer fired, logged "not running
# — proceeding without it" and marked the phase done in the same second, so the
# lean goldens built on top of the desktop goldens and the appliance catalog.
# The wait has to consult the timer and whether the unit ever started.
_ad="$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-autodeploy"
if grep -q 'InactiveExitTimestampMonotonic --value klab-firstboot.service' "$_ad" 2>/dev/null &&
    grep -q 'is-active --quiet klab-firstboot.timer' "$_ad" 2>/dev/null; then
    _pass "autodeploy waits for a klab-firstboot whose timer has not fired"
else
    _fail "autodeploy waits for a klab-firstboot whose timer has not fired" \
        "the wait no longer checks the timer and the unit's start time — it will skip the lean goldens again"
fi

# The build refuses to pack an image with a PEM private-key header anywhere under
# etc, var, root, usr/local, opt, home or srv, and the repo's tests are copied to
# usr/local/share/kldload/tests. A literal header in a test fixture failed build 17
# ten minutes in (2026-09-14); this finds it in a second, before a build starts.
# swallow: grep exits 1 when nothing matches, which is the passing case
_pk_src="$(grep -rlIE --exclude-dir=darksite -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' \
    "$ROOT/tests" "$ROOT/live-build/config/includes.chroot" 2>/dev/null || true)"
if [[ -z "$_pk_src" ]]; then
    _pass "no private-key headers in files the image carries (tests, includes.chroot)"
else
    _fail "no private-key headers in files the image carries" "$(tr '\n' ' ' <<<"$_pk_src")— the build's key scan will refuse to pack the ISO"
fi

# Vendor systemd drop-ins (the no-BMC ipmi guard among them) must reach EVERY
# install, core included, so their carry has to run before k_install_system_files
# returns early for core. 1-core on build 20 (fiend, 2026-09-15) booted with
# ipmi.service failed because the carry sat below that return.
_pf="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_carry_ln="$(grep -n 'for _droproot in /usr/lib/systemd/system /etc/systemd/system' "$_pf" | head -n 1 | cut -d: -f1)"
_core_ln="$(grep -n 'Core profile — skipping kldload tools' "$_pf" | head -n 1 | cut -d: -f1)"
if [[ -n "$_carry_ln" && -n "$_core_ln" ]] && ((_carry_ln < _core_ln)); then
    _pass "systemd drop-ins are carried for every profile (before core's early return)"
else
    _fail "systemd drop-ins are carried for every profile" "carry at line ${_carry_ln:-missing}, core return at ${_core_ln:-missing} — core installs lose the ipmi no-BMC guard"
fi

# Part 2 of the show needs, from the source tree: cage in the offline package
# sets it is installed from (Firefox is already there for the desktop), and the
# loopback listener the kiosk browser reads over plain HTTP. Either missing turns
# every building install into the console fallback without an error anywhere.
_fb2_src_bad=""
grep -qx 'cage' "$ROOT/build/darksite-fedora/config/package-sets/target-fedora-extras.txt" 2>/dev/null || _fb2_src_bad+=" fedora-package-set-no-cage"
grep -qx 'systemd-pam' "$ROOT/build/darksite-fedora/config/package-sets/target-fedora-extras.txt" 2>/dev/null || _fb2_src_bad+=" fedora-package-set-no-systemd-pam"
grep -qx 'cage' "$ROOT/build/darksite-debian/config/package-sets/target-desktop.txt" 2>/dev/null || _fb2_src_bad+=" debian-package-set-no-cage"
grep -q 'listen      127.0.0.1:8099;' "$ROOT/live-build/config/includes.chroot/etc/nginx/conf.d/kldload.conf" 2>/dev/null || _fb2_src_bad+=" no-loopback-listener"
grep -q 'KIOSK_URL="http://127.0.0.1:8099/firstboot.html"' "$ROOT/live-build/config/includes.chroot/usr/local/sbin/kldload-firstboot-show" 2>/dev/null || _fb2_src_bad+=" kiosk-url-not-the-listener"
if [[ -z "$_fb2_src_bad" ]]; then
    _pass "first-boot kiosk sources: cage in the Fedora and Debian package sets, loopback listener on 127.0.0.1:8099"
else
    _fail "first-boot kiosk sources" "${_fb2_src_bad}"
fi

# Plymouth must be switched off on BOTH cmdlines, not just left out of the
# package list. The desktop set pulls plymouth in and dracut packs it into the
# initramfs (122 files), and the old comment in bootloader.sh swore it was
# absent. fiend 2026-09-14, 5-desktop netboot: plymouthd hung in
# plymouth-read-write.service and the box sat before sysinit.target from 09:46
# to 16:45 until the operator pressed Enter -- seven hours, and the matrix
# stopped with four editions untested.
if ! grep -q '^k_splash_args() {' "$_cm" 2>/dev/null ||
    ! bash -c 'eval "$(sed -n "/^k_splash_args() {/,/^}/p" "$1")"; k_splash_args' _ "$_cm" 2>/dev/null |
    grep -q 'plymouth.enable=0'; then
    _fail "plymouth disabled on the kernel cmdline" \
        "k_splash_args is gone or no longer emits plymouth.enable=0 — a hung splash stalls boot until someone presses Enter"
elif ! grep -q '_zbm_args=.*\$(k_splash_args)' "$_sz" 2>/dev/null; then
    _fail "plymouth disabled on the kernel cmdline" \
        "the ZBM cmdline does not carry k_splash_args — the path every normal boot takes"
elif [[ "$(grep -c '_direct_bootargs=.*\$(k_splash_args)' "$_bl" 2>/dev/null)" != "$(grep -c '_direct_bootargs=' "$_bl" 2>/dev/null)" ]]; then
    _fail "plymouth disabled on the kernel cmdline" \
        "a GRUB direct-entry cmdline was assigned without k_splash_args"
else
    _pass "plymouth disabled on both the ZBM and GRUB direct cmdlines"
fi

# The /usr/local/sbin compat symlink must be guarded against usrmerge.
#
# kldload-install-target links /usr/local/sbin/kldload-* -> /usr/local/bin/... so
# the two copies cannot drift. On Fedora 44 /usr/local/sbin IS /usr/local/bin (a
# symlink), so that link is created at the destination pointing to itself, and
# `ln -sf` forces it over the real binary. Every caller then gets ELOOP.
#
# fiend 2026-08-27, first F44 install: 58 of 168 entries in /usr/local/bin were
# links to themselves. Five units failed at boot and fifty-odd tools were gone.
# Every Debian install that night was fine, because there the two are separate
# directories and the shim is correct -- which is exactly why it shipped.
_it="$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
if ! grep -q 'ln -sf "/usr/local/bin/\${base}"' "$_it" 2>/dev/null; then
    _pass "usrmerge: the /usr/local/sbin compat link is gone entirely"
elif grep -q 'usr/local/sbin" -ef "\${target}/usr/local/bin' "$_it" 2>/dev/null; then
    _pass "usrmerge: the /usr/local/sbin compat link is guarded by an -ef check"
else
    _fail "usrmerge: the /usr/local/sbin compat link is guarded" \
        "ln -sf into /usr/local/sbin with no same-directory check — on Fedora this overwrites every tool with a symlink to itself"
fi

# The ZFS passphrase-prompt extension must ship, or an encrypted install falls
# back to upstream's printk-7 branch and the prompt is buried by kernel output.
#
# Upstream raises printk to 7 to defeat `quiet`; kldload REMOVES `quiet` on
# encrypted pools, so that workaround instead means maximum verbosity while the
# boot waits for input. fiend 2026-08-27: 386 kernel messages in the 5-15s
# window, a blank nine-second pause, operator pressed Enter to reveal the
# prompt. VERIFIED FIXED on that same machine once this extension shipped --
# Secure Boot on, encrypted pool, boxed banner shown, passphrase NOT echoed,
# printk restored to "7 4 1 7" afterwards.
#
# /etc/zfs is NOT copied wholesale into the rootfs -- only zed.d/all-loki.sh
# was, which is exactly how the apt snapshot hooks sat unshipped for months.
_pf="$ROOT/live-build/config/includes.chroot/etc/zfs/initramfs-tools-load-key.d/kldload-prompt"
_pp="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
if [[ ! -f "$_pf" ]]; then
    _fail "ZFS passphrase-prompt extension ships" "missing: $_pf"
elif ! grep -q 'initramfs-tools-load-key.d/kldload-prompt' "$ROOT/builder/build-iso.sh" 2>/dev/null; then
    _fail "ZFS passphrase-prompt extension ships" \
        "build-iso.sh does not copy it into the live rootfs - it would never reach an initramfs"
elif ! grep -q 'initramfs-tools-load-key.d' "$_pp" 2>/dev/null; then
    _fail "ZFS passphrase-prompt extension ships" \
        "profiles.sh does not copy it onto the target - installed systems get upstream's buried prompt"
elif ! grep -q 'kernel/printk' "$_pf" 2>/dev/null; then
    _fail "ZFS passphrase-prompt extension ships" \
        "the extension no longer quietens the console - the prompt will be buried again"
else
    _pass "ZFS passphrase-prompt extension ships and is wired into both copy paths"
fi

# The apt snapshot hooks must reach the live rootfs, or the PATH shim at
# /usr/local/bin/apt is the ONLY thing taking pre-transaction snapshots — and a
# PATH shim cannot see unattended-upgrades (python-apt never execs the binary),
# aptitude, absolute-path /usr/bin/apt-get calls, or a systemd unit with a
# trimmed PATH. Those users get no snapshot and no way back.
#
# This shipped broken for as long as the hooks have existed: two installer loops
# copy them to the target, both read from the LIVE ISO's /etc/apt/apt.conf.d,
# and build-iso.sh never put them there. Both loops globbed nothing and exited
# 0. The wrapper's own header calls these hooks "the belt to this tool's
# braces"; the braces were never on a single install (found 2026-08-26 on rc6).
if grep -q 'includes.chroot/etc/apt/apt.conf.d' "$ROOT/builder/build-iso.sh" 2>/dev/null; then
    _pass "build-iso copies the apt snapshot hooks into the rootfs"
else
    _fail "build-iso copies the apt snapshot hooks into the rootfs" \
        "nothing copies includes.chroot/etc/apt/ — the installer's copy loops will glob nothing, silently"
fi

# And the OUTCOME check, when a built ISO is available: the source having a cp
# is not evidence the file landed.
if [[ -n "${SQUASHFS_ROOT:-}" && -d "${SQUASHFS_ROOT:-/nonexistent}" ]]; then
    _aptmissing=""
    for _h in 00-kldload-snapshot-pre 00-kldload-snapshot-post; do
        [[ -f "${SQUASHFS_ROOT}/etc/apt/apt.conf.d/${_h}" ]] || _aptmissing+="$_h "
    done
    if [[ -z "$_aptmissing" ]]; then
        _pass "apt snapshot hooks are present in the built rootfs"
    else
        _fail "apt snapshot hooks present in the built rootfs" "missing: $_aptmissing"
    fi
fi

# The package database must live INSIDE the boot environment, or a rollback
# produces a system whose dpkg lies. /usr is already in the BE (rpool/usr is
# canmount=off); /var/lib has to be too, because that is where dpkg/rpm keep
# their state. If /var/lib gets its own mounted dataset, a BE rollback removes
# the package FILES and leaves the DATABASE untouched, and `apt-get check`
# passes because it validates dependencies rather than file presence.
#
# Caught on .137 2026-08-26 (SB off, encrypted, ZBM path): install seven
# packages, `kldload-rollback last`, reboot. Right snapshot, right clone, right
# bootfs, binaries correctly gone — and dpkg still reporting 1128 packages
# instead of 1117, listing all seven as installed. Silent.
_sz_varlib="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/storage-zfs.sh"
if grep -qE 'zfs create -o canmount=off -o mountpoint=/var/lib rpool/var/lib' "$_sz_varlib" 2>/dev/null; then
    _pass "/var/lib stays in the boot environment (package DB rolls back with its files)"
elif grep -qE 'zfs create -o mountpoint=/var/lib rpool/var/lib' "$_sz_varlib" 2>/dev/null; then
    _fail "/var/lib stays in the boot environment" \
        "rpool/var/lib is a MOUNTED dataset — dpkg/rpm state will not roll back with the BE"
else
    _fail "/var/lib stays in the boot environment" \
        "could not find the rpool/var/lib create line — the layout changed shape, re-check this gate"
fi

# The dock must keep its browsers. Two independent bugs unpinned both on
# Fedora, and the dock came up with no browser at all:
#   Firefox -- the pin list carried only the Debian names (firefox.desktop,
#     firefox-esr.desktop). Fedora ships org.mozilla.firefox.desktop, so the
#     pruner correctly dropped a launcher that does not exist there.
#   Chrome  -- a RACE, not a name. .105 2026-08-28: favorites pruned 10:18:17,
#     google-chrome-stable installed 10:22:09. profiles.sh installs Chrome, but
#     kldload-firstboot re-installs it if that transaction did not land, so at
#     prune time it can legitimately be absent and arrive minutes later.
#
# Chrome is exempted by the CANONICAL name only. .105 ships both
# google-chrome.desktop and com.google.Chrome.desktop for the same browser --
# exempting both pins Chrome twice, and on a substrate with only one the other
# becomes the dead dock icon the pruner exists to prevent.
_favl="$ROOT/live-build/config/includes.chroot/etc/dconf/db/local.d/50-kldload-installed-favorites"
_favt="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/target-files/etc/dconf/db/local.d/50-kldload-installed-favorites"
_dock=0
grep -qF 'org.mozilla.firefox.desktop' "$_favl" 2>/dev/null && _dock=$((_dock + 1))
grep -qF 'google-chrome.desktop' "$_favl" 2>/dev/null && _dock=$((_dock + 1))
grep -qF 'com.google.Chrome.desktop' "$_favl" 2>/dev/null || _dock=$((_dock + 1))
# Defined locally, NOT borrowed from a later gate: this block sits above the
# one that sets _prof, and under set -u an unbound reference here aborts the
# whole script -- silently skipping every gate below it. (Self-inflicted and
# caught 2026-08-28; the suite ran 5 checks and stopped.)
_prof_dock="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
grep -qF 'google-chrome.desktop)' "$_prof_dock" 2>/dev/null && _dock=$((_dock + 1))
# The two copies are shipped separately; a fix applied to one only is how the
# installed system and the live image drift apart.
[[ -f "$_favl" && -f "$_favt" ]] &&
    [[ "$(sha256sum <"$_favl" | cut -d" " -f1)" == "$(sha256sum <"$_favt" | cut -d" " -f1)" ]] &&
    _dock=$((_dock + 1))
if ((_dock == 5)); then
    _pass "dock pins survive: Fedora Firefox name, Chrome prune race, no duplicate Chrome"
else
    _fail "dock pins survive: Fedora Firefox name, Chrome prune race, no duplicate Chrome" \
        "need the org.mozilla name, google-chrome kept, com.google.Chrome NOT listed, the pruner exemption, and both copies identical — have $_dock/5"
fi

# The journal assert must check PERSISTENCE, not merely that journald records.
# A volatile journal passes a write-then-read probe perfectly -- journald is
# recording, the line comes back, and the entire boot is erased at shutdown.
# The assert shipped with only the probe and printed "journal: recording
# (persistent dir ...)" on .105 while /var/log/journal held 0 files and
# /run/log/journal held 2. That is why the first boot's SSH failure there could
# not be diagnosed afterwards: the evidence was gone before anyone looked.
# (2026-08-28.)
#
# Storage=auto is correct and must stay -- Storage=persistent recreates the
# shadowed-inode bug from .132 2026-08-26. The race is that systemd-journal-flush
# is ordered on local-fs.target, which on a ZFS root does not guarantee
# rpool/var/log is mounted. So the assert has to notice and repair after the mount.
_ja="$ROOT/live-build/config/includes.chroot/usr/local/sbin/kldload-journal-assert"
_ja_ok=0
grep -qF 'journal_is_persistent()' "$_ja" 2>/dev/null && _ja_ok=$((_ja_ok + 1))
grep -qF "grep -q '^File path: /var/log/journal/'" "$_ja" 2>/dev/null && _ja_ok=$((_ja_ok + 1))
grep -qF 'if journal_records && journal_is_persistent; then' "$_ja" 2>/dev/null && _ja_ok=$((_ja_ok + 1))
grep -qF 'Storage=auto' "$ROOT/live-build/config/includes.chroot/etc/systemd/journald.conf.d/persistent.conf" 2>/dev/null && _ja_ok=$((_ja_ok + 1))
if ((_ja_ok == 4)); then
    _pass "journal assert proves persistence, not just that journald records"
else
    _fail "journal assert proves persistence, not just that journald records" \
        "need journal_is_persistent(), the /var/log/journal header check, both conditions gating the success path, and Storage=auto retained — have $_ja_ok/4"
fi

# A desktop must ship GPU firmware for the card it might actually meet.
# Both split-firmware distros listed only WIFI firmware: Debian named
# iwlwifi/realtek/atheros, and Fedora 43+ split linux-firmware so the bare
# package carries licences plus ONE amdgpu file against 679 in
# amd-gpu-firmware. Every Radeon and every recent Intel iGPU therefore
# installed with no firmware, landing on a software framebuffer or a black
# screen -- while firmware-amd-graphics sat unused in our own darksite.
# Found 2026-08-28 checking whether a non-NVIDIA machine works. It did not.
#
# Ubuntu and EL are deliberately absent here: both keep the monolithic
# linux-firmware, which still carries the GPU blobs.
#
# The RPM half MUST be checked in bootstrap.sh, not profiles.sh. _dnf_pkgs is
# what is actually dnf-installed on RPM targets -- the file says so twice, next
# to nss-tools and gnome-terminal -- and k_profile_packages is not used for that
# transaction. The first version of this fix went into profiles.sh only, so it
# was inert on Fedora: .111 (rc13) installed with intel-gpu-firmware absent and
# neither freeworld package present, while all of them sat in the darksite. The
# gate passed the whole time, because it too was reading the wrong file.
_prof="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_boot="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootstrap.sh"
_gpufw=0
grep -qF 'firmware-amd-graphics firmware-misc-nonfree' "$_prof" 2>/dev/null && _gpufw=$((_gpufw + 1))
grep -qE '^[[:space:]]*amd-gpu-firmware intel-gpu-firmware nvidia-gpu-firmware[[:space:]]*$' "$_boot" 2>/dev/null && _gpufw=$((_gpufw + 1))
grep -qE '^[[:space:]]*libavcodec-freeworld mesa-va-drivers-freeworld[[:space:]]*$' "$_boot" 2>/dev/null && _gpufw=$((_gpufw + 1))
# Anchored to a line that is ONLY the package name. A plain substring match
# also hit the explanatory comment above the entry, so the check passed with
# the package deleted -- verified by deleting it, which is the only way that
# ever surfaces. (2026-08-28)
grep -qE '^[[:space:]]*gstreamer1-plugin-libav[[:space:]]*$' "$_boot" 2>/dev/null && _gpufw=$((_gpufw + 1))
if ((_gpufw == 4)); then
    _pass "GPU firmware + codecs are in the lists that actually install (RPM: _dnf_pkgs)"
else
    _fail "GPU firmware + codecs are in the lists that actually install (RPM: _dnf_pkgs)" \
        "Debian needs firmware-amd-graphics+misc-nonfree in profiles.sh; Fedora needs the three *-gpu-firmware, both freeworld packages, and gstreamer1-plugin-libav in bootstrap.sh _dnf_pkgs — have $_gpufw/4"
fi

# Hardware diagnostics and IPMI. These were mirrored as other packages'
# dependencies and named in no install list, so none of them landed -- the .101
# audit found nethogs, iftop and iotop-c absent with their RPMs sitting on the
# media. The IPMI set is the difference between a server that boots and one an
# operator can work on: every server-class driver is already in-tree (ast,
# mpt3sas, megaraid_sas, mlx5, ixgbe, i40e, ice, qla2xxx, lpfc, ipmi_si), so a
# Supermicro sees its RAID, NICs and BMC -- but without ipmitool you cannot read
# the sensors, the SEL or the power state from inside the OS.
#
# Shipped on every profile rather than gated to "server": they are small, inert
# on hardware with no BMC, and gating them means the operator who needs them is
# the one who did not pick the profile that has them. Verified installing and
# running in an F44 container -- ipmitool 1.8.19, sensors 3.6.0, lsscsi, sg_scan.
_tl="$ROOT/build/darksite-fedora/config/package-sets/target-fedora-extras.txt"
_tb="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootstrap.sh"
_tools_missing=""
for _p in nethogs iftop iotop-c ipmitool OpenIPMI lm_sensors sg3_utils lsscsi; do
    grep -qE "^${_p}\$" "$_tl" 2>/dev/null || _tools_missing+=" ${_p}(darksite)"
    grep -qE "(^|[[:space:]])${_p}([[:space:]]|\$)" \
        < <(grep -vE '^[[:space:]]*#' "$_tb" 2>/dev/null) ||
        _tools_missing+=" ${_p}(_dnf_pkgs)"
done
if [[ -z "$_tools_missing" ]]; then
    _pass "hardware diagnostics + IPMI ship (ipmitool, sensors, sg3_utils, lsscsi, nethogs, iftop)"
else
    _fail "hardware diagnostics + IPMI ship" "not wired:${_tools_missing}"
fi

# The same set on the apt path, which the commit above missed entirely. The
# asymmetry survived four hardware installs because the dev box is Fedora, and
# the .113 audit on 2026-08-29 is what found it: smartmontools, nvme-cli,
# usbutils, ipmitool, OpenIPMI, sg3-utils and lsscsi all absent from a finished
# Debian desktop -- and five of them were already in the darksite mirror,
# named by no install list, exactly like the firmware sets a week earlier.
#
# Both halves are checked because either one alone is a silent failure: named
# but not mirrored is a network-only install on a darksite build, mirrored but
# not named is a package that ships on the media and never reaches a machine.
_dl="$ROOT/build/darksite-debian/config/package-sets/target-base.txt"
_dp="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_deb_tools_missing=""
for _p in smartmontools nvme-cli usbutils ipmitool openipmi sg3-utils lsscsi nethogs iftop dmidecode; do
    grep -qE "^${_p}\$" "$_dl" 2>/dev/null || _deb_tools_missing+=" ${_p}(darksite)"
    grep -qE "(^|[[:space:]]|\()${_p}([[:space:]]|\)|\$)" \
        < <(grep -vE '^[[:space:]]*#' "$_dp" 2>/dev/null) ||
        _deb_tools_missing+=" ${_p}(profiles)"
done
if [[ -z "$_deb_tools_missing" ]]; then
    _pass "hardware diagnostics + IPMI ship on the apt path too"
else
    _fail "hardware diagnostics + IPMI ship on the apt path too" "not wired:${_deb_tools_missing}"
fi

# Two CHANGELOG.md files exist: the repo root one, and the copy under
# includes.chroot that actually ships to /usr/local/share/kldload on an
# installed machine. They drifted in BOTH directions before the 1.4.2 release --
# root carried 1.4.2 and had lost 1.4.1, the shipped copy carried 1.4.1 and had
# never heard of 1.4.2 -- so the machine an operator was reading the changelog
# ON was the one with the stale copy. The README links the shipped path, which
# is what made it look authoritative while being a release behind.
#
# Same shape as free/index.html vs index.html: two copies, edits land in one.
_cl_root="$ROOT/CHANGELOG.md"
_cl_ship="$ROOT/live-build/config/includes.chroot/usr/local/share/kldload/CHANGELOG.md"
if [[ ! -f "$_cl_root" || ! -f "$_cl_ship" ]]; then
    _fail "CHANGELOG copies are in sync" "one of the two files is missing"
elif cmp -s "$_cl_root" "$_cl_ship"; then
    _pass "CHANGELOG: repo root and the shipped copy are identical"
else
    _fail "CHANGELOG: repo root and the shipped copy are identical" \
        "they differ — the installed system would ship stale release notes"
fi

# Every long option r2-publish.sh documents in its usage banner must have a
# case arm that actually sets something. --versioned was documented, was
# honoured at all three points downstream (the server-side copy, the size
# check, the prune keep-list), and had no arm -- so it fell through to the
# unknown-option catch-all and exited 1. The flag was unreachable from the
# day it was written; publishing 1.4.2 on 2026-08-28 is what found it.
#
# "--help is the contract" only holds if the contract is executable.
_r2="$ROOT/tools/r2-publish.sh"
_r2_unwired=""
if [[ -f "$_r2" ]]; then
    for _flag in $(sed -n '/^Usage: r2-publish.sh/,/^Environment/p' "$_r2" |
        grep -oE '\-\-[a-z][a-z-]+' | sort -u); do
        grep -qE "^[[:space:]]*(${_flag}|[^)]*\|[[:space:]]*${_flag})[^)]*\)" "$_r2" ||
            _r2_unwired+=" ${_flag}"
    done
    if [[ -z "$_r2_unwired" ]]; then
        _pass "r2-publish: every documented option has a case arm"
    else
        _fail "r2-publish: every documented option has a case arm" \
            "documented but unreachable:${_r2_unwired}"
    fi
fi

# The Timer ships as a GTK4 app, and a GUI app is three things that must agree:
# a binary, a .desktop whose filename matches the app_id, and an icon named the
# same again. Get any one wrong and GNOME shows a generic diamond and opens a
# SECOND dock entry beside the launcher -- which is exactly what happened on
# onyx 2026-08-30 before the names were aligned.
_tmr_bin="$ROOT/live-build/config/includes.chroot/usr/local/bin/timer"
_tmr_dsk="$ROOT/live-build/config/includes.chroot/usr/share/applications/com.kldload.Timer.desktop"
_tmr_ico="$ROOT/live-build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/com.kldload.Timer.svg"
if [[ -f "$_tmr_bin" ]]; then
    _tmr_bad=""
    [[ -f "$_tmr_dsk" ]] || _tmr_bad+=" no-desktop-file"
    [[ -f "$_tmr_ico" ]] || _tmr_bad+=" no-icon"
    grep -q 'APP_ID = "com.kldload.Timer"' "$_tmr_bin" || _tmr_bad+=" app-id-mismatch"
    grep -q '^Icon=com.kldload.Timer$' "$_tmr_dsk" 2>/dev/null || _tmr_bad+=" icon-name-mismatch"
    grep -q '^Exec=/usr/local/bin/timer$' "$_tmr_dsk" 2>/dev/null || _tmr_bad+=" exec-mismatch"
    grep -rq '^python3-gobject$' "$ROOT"/build/*/config/package-sets/*.txt 2>/dev/null ||
        _tmr_bad+=" pygobject-not-packaged"
    if [[ -z "$_tmr_bad" ]]; then
        _pass "Timer: binary, .desktop, icon and app_id all agree; PyGObject packaged"
    else
        _fail "Timer: app_id / icon / packaging mismatch" "problems:${_tmr_bad}"
    fi
fi

# ── Every shipped GUI app has a copy path to the INSTALLED target ──────────
#
# The gate above proves the Timer's three files agree with each other. It says
# NOTHING about whether they reach an installed machine, and on b1294 they did
# not: the ISO carried /usr/local/bin/timer, com.kldload.Timer.desktop and
# com.kldload.Timer.svg, every one verified present in the squashfs, and a
# fresh install at fiend .117 had none of the three (2026-09-01).
#
# The cause is that profiles.sh copies launchers, icons and binaries to the
# target through three hand-curated glob lists. A tool whose name matches no
# pattern is dropped in total silence -- no error, no log line, and the ISO
# checks all still pass because the files really are on the ISO. This has now
# cost five separate installs: ollama.svg, vmxplore, wgx, ztx and timer. Each
# was fixed by appending one more name and one more warning comment to the
# lists, and the next tool broke anyway.
#
# So check the invariant directly instead: parse the three glob lists out of
# profiles.sh, and assert every .desktop in the shipped tree matches a launcher
# pattern, that the binary its Exec= names matches a binary pattern, and that
# the icon its Icon= names matches an icon pattern. Binaries fetched at build
# time (ztx, zxplore) are not in the tree, so an Exec= that resolves to nothing
# here is skipped rather than failed -- this gate reads the repo, not the ISO.
_cp_prof="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_cp_tree="$ROOT/live-build/config/includes.chroot"
if [[ -f "$_cp_prof" && -d "$_cp_tree/usr/share/applications" ]]; then
    # Launchers deliberately never copied. kldload-installer-live is the live
    # ISO's own installer tile; profiles.sh explicitly rm -f's it from the
    # target, so it must NOT be expected to have a copy path.
    _cp_liveonly=" kldload-installer-live.desktop "

    # The launcher globs come from two places: the main loop, and the small
    # explicit `for _dt in ...` list further down that carries kexport.
    _cp_lnch_pat="$(sed -n '/for _lnch in /,/; do$/p' "$_cp_prof" |
        grep -oE '/usr/share/applications/[^ \\]+\.desktop' | sed 's|.*/||')"
    _cp_lnch_pat+=$'\n'"$(sed -n '/for _dt in /,/; do$/p' "$_cp_prof" |
        grep -oE '[A-Za-z0-9._*-]+\.desktop')"
    _cp_ico_pat="$(sed -n '/for _ic in /,/; do$/p' "$_cp_prof" |
        grep -oE '\$\{themedir\}/[^ \\]+\.svg' | sed 's|.*/||')"
    # NB: exclude ';' as well as space/backslash -- the last entry on the last
    # line of each list is followed by '; do', and without this the pattern
    # comes out as 'timer;' and matches nothing.
    _cp_bin_pat="$(sed -n '/for _src in /,/; do$/p' "$_cp_prof" |
        grep -oE '/usr/local/bin/[^ \\;]+' | sed 's|.*/||')"
    # Binaries also reach the target through named one-off `cp` lines.
    _cp_bin_pat+=$'\n'"$(grep -oE 'cp "?/usr/local/bin/[A-Za-z0-9._-]+' "$_cp_prof" | sed 's|.*/||')"

    # _cp_matches <name> <newline-separated patterns> -> 0 if any glob matches.
    _cp_matches() {
        local _n="$1" _p
        while IFS= read -r _p; do
            [[ -n "$_p" ]] || continue
            # shellcheck disable=SC2053  # RHS is a glob on purpose here
            [[ "$_n" == $_p ]] && return 0
        done <<<"$2"
        return 1
    }

    _cp_bad="" _cp_n=0
    for _cp_d in "$_cp_tree"/usr/share/applications/*.desktop; do
        [[ -f "$_cp_d" ]] || continue
        _cp_dn="$(basename "$_cp_d")"
        case "$_cp_liveonly" in *" $_cp_dn "*) continue ;; esac
        _cp_n=$((_cp_n + 1))
        _cp_matches "$_cp_dn" "$_cp_lnch_pat" ||
            {
                _cp_bad+=" ${_cp_dn}:launcher-not-copied"
                continue
            }

        # Exec= binary, only when the binary actually lives in this repo.
        _cp_ex="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$_cp_d" | head -1)"
        if [[ "$_cp_ex" == /usr/local/bin/* && -e "${_cp_tree}${_cp_ex}" ]]; then
            _cp_matches "$(basename "$_cp_ex")" "$_cp_bin_pat" ||
                _cp_bad+=" ${_cp_dn}:binary-not-copied($(basename "$_cp_ex"))"
        fi

        # Icon= svg, only when the icon actually ships in the tree.
        _cp_ic="$(sed -n 's/^Icon=//p' "$_cp_d" | head -1)"
        if [[ -n "$_cp_ic" && -f "$_cp_tree/usr/share/icons/hicolor/scalable/apps/${_cp_ic}.svg" ]]; then
            _cp_matches "${_cp_ic}.svg" "$_cp_ico_pat" ||
                _cp_bad+=" ${_cp_dn}:icon-not-copied(${_cp_ic}.svg)"
        fi
    done

    if [[ -z "$_cp_bad" ]]; then
        _pass "installer copy paths: all ${_cp_n} shipped launchers reach the target (binary+icon too)"
    else
        _fail "installer copy paths: shipped GUI app(s) would NOT reach an installed target" \
            "add the name to the matching glob list in profiles.sh --${_cp_bad}"
    fi
fi

# Debian needs the same hardware sweep, and had it worse. Measured on .105
# 2026-08-28 from a fresh install: amd-ucode AND intel-ucode both EMPTY, so the
# machine ran with no CPU microcode on any processor -- Fedora at least got its
# Intel files from microcode_ctl. Zero VA-API drivers. 1361 firmware files
# against Fedora's 2874. The firmware-linux metapackages were in the darksite
# list and in no install list: mirrored, never installed.
#
# After wiring: amd-ucode 0->5, intel-ucode 0->126, firmware 1361->1523,
# VA-API 0->7 (incl. iHD for modern Intel), gstreamer avdec_* 0->211.
#
# gstreamer1.0-tools is included deliberately: gst-inspect-1.0 lives there on
# Debian, and without it a WORKING codec set reads as "0 decoders" -- a
# diagnostic that lies in the alarming direction, which cost time in this audit.
_dprof="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
_dmissing=""
for _p in amd64-microcode intel-microcode firmware-linux-free firmware-linux-nonfree \
    firmware-amd-graphics firmware-misc-nonfree gstreamer1.0-libav libavcodec-extra \
    gstreamer1.0-tools mesa-va-drivers va-driver-all intel-media-va-driver \
    firmware-brcm80211 firmware-mediatek firmware-cirrus firmware-qcom-soc \
    firmware-intel-graphics firmware-nvidia-graphics firmware-ti-connectivity \
    firmware-libertas firmware-sof-signed; do
    grep -qE "(^|[[:space:]])${_p}([[:space:]]|\"|\\\\|\$)" \
        < <(grep -vE '^[[:space:]]*#' "$_dprof" 2>/dev/null) ||
        _dmissing+=" ${_p}"
done
if [[ -z "$_dmissing" ]]; then
    _pass "Debian hardware: CPU microcode, firmware metapackages, VA-API and codecs all wired"
else
    _fail "Debian hardware: CPU microcode, firmware metapackages, VA-API and codecs all wired" \
        "not in the apt install list:${_dmissing}"
fi

# Every installed machine must be able to say which ISO built it and what it
# was asked to install. Nothing recorded either. Asked "which ISO installed
# .111?" on 2026-08-28 the only way to answer was to infer it from which
# packages happened to be present and compare the boot-environment creation
# time against ISO build times. And when an install came up Fedora where Debian
# was expected, there was no way at all to tell whether the wrong distro was
# requested or the right one ignored -- the installer's answers live in /tmp on
# the live medium and die with the session.
#
# Written before k_finalize_bootloader on purpose: finalize exports the pool and
# the target is unreachable after it. And asserted, because a marker that
# silently fails to land is precisely the blind spot it exists to remove.
_it="$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
_bm=0
grep -qF 'etc/kldload-release' "$_it" 2>/dev/null && _bm=$((_bm + 1))
grep -qF 'requested_distro' "$_it" 2>/dev/null && _bm=$((_bm + 1))
grep -qF 'did not land — this machine will not be able to say which ISO built it' "$_it" 2>/dev/null && _bm=$((_bm + 1))
if ((_bm == 3)); then
    _pass "install records the build id and what was requested (/etc/kldload-release)"
else
    _fail "install records the build id and what was requested (/etc/kldload-release)" \
        "need the file write, the requested_* lines, and the did-not-land assertion — have $_bm/3"
fi

# The holds unit must be ordered after the datasets it writes into.
# /var/lib/kldload is its OWN dataset (rpool/kldload/state). The unit carried no
# After= at all, so it could run before zfs-mount, write platform-holds.list
# into the directory UNDERNEATH the mountpoint, and have the dataset mount on
# top and hide it. The tool logged "pinned 56 package(s)" and exited 0
# throughout, so `kldload-rollback status` reported "holds have not run" on a
# machine with 56 holds actually in force. Every install, both distros: .101,
# .105, .111, .132. Fixed and measured on .105 2026-08-28 -- MISSING -> 57
# lines, with apt-mark, the file and status finally agreeing. (Same shape as
# the journal bug; kldload-journal-flush carries the identical ordering.)
_hu="$ROOT/live-build/config/includes.chroot/etc/systemd/system/kldload-package-holds.service"
_hu_ok=0
grep -qE '^After=.*zfs-mount\.service' "$_hu" 2>/dev/null && _hu_ok=$((_hu_ok + 1))
# RequiresMountsFor is the one that actually works. /var/lib/kldload is mounted
# by a GENERATED var-lib-kldload.mount unit, not by zfs-mount.service, and that
# activates later: .105 2026-08-28 had zfs-mount done at 19:03:16, this unit run
# at 19:03:17, and the mount active only at 19:03:27. Ten seconds where the
# After= is satisfied and the directory is still bare. Both units that write
# into a late-mounted dataset need it -- holds into /var/lib/kldload, journal
# into /var/log/journal.
grep -qF 'RequiresMountsFor=/var/lib/kldload' "$_hu" 2>/dev/null && _hu_ok=$((_hu_ok + 1))
grep -qF 'RequiresMountsFor=/var/log/journal' \
    "$ROOT/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-journal-flush.service" 2>/dev/null &&
    _hu_ok=$((_hu_ok + 1))
# ...and the tool must re-read what it wrote, so the two can never disagree
# silently again even if the ordering is lost.
grep -qF '_state_back' "$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-apply-platform-holds" 2>/dev/null && _hu_ok=$((_hu_ok + 1))
if ((_hu_ok == 4)); then
    _pass "platform holds: unit ordered after zfs-mount, and the write is read back"
else
    _fail "platform holds: unit ordered after zfs-mount, and the write is read back" \
        "need After=zfs-mount.service, RequiresMountsFor on BOTH units, and the read-back check — have $_hu_ok/4"
fi

# Hardware coverage is the product. Fedora 43+ split linux-firmware per vendor
# and this tree named only a handful of wifi packages, so eight firmware sets
# were absent from every install. Measured on .111 2026-08-28: amd-ucode, i915,
# brcm, mediatek, cirrus and qcom directories ALL held zero files; installing
# the set took /usr/lib/firmware from 2874 files to 4139.
#
# amd-ucode-firmware is the one that reads least like a driver and matters
# most: it is CPU MICROCODE. An AMD machine booted with none, so Zenbleed and
# Inception class fixes never loaded, while Intel got 152 files from
# microcode_ctl and looked healthy. Nothing anywhere reported the difference.
#
# Both halves are checked because either alone is useless: the darksite list
# guarantees the RPM is mirrored, _dnf_pkgs is what actually installs it. The
# earlier version of this fix had the packages mirrored and installed none of
# them.
_fwl="$ROOT/build/darksite-fedora/config/package-sets/target-fedora-extras.txt"
_fwb="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootstrap.sh"
_hw_missing=""
for _p in amd-ucode-firmware brcmfmac-firmware mt7xxx-firmware qcom-firmware \
    nxpwireless-firmware tiwilink-firmware cirrus-audio-firmware \
    amd-gpu-firmware intel-gpu-firmware nvidia-gpu-firmware; do
    grep -qE "^${_p}\$" "$_fwl" 2>/dev/null || _hw_missing+=" ${_p}(darksite)"
    # Comments are stripped first: the explanatory block above these entries
    # names the packages in prose, so a plain match went green with the package
    # deleted. Verified by deleting amd-ucode-firmware, which is the only way
    # that ever shows up. (2026-08-28)
    # Process substitution, NOT a pipe. `grep -q` exits on the first match and
    # SIGPIPEs the upstream grep; under pipefail the PIPELINE then reports that
    # failure, so a successful match read as "not found" and every package came
    # back missing. Same trap as the readback verifier earlier today.
    grep -qE "(^|[[:space:]])${_p}([[:space:]]|\$)" \
        < <(grep -vE '^[[:space:]]*#' "$_fwb" 2>/dev/null) ||
        _hw_missing+=" ${_p}(_dnf_pkgs)"
done
if [[ -z "$_hw_missing" ]]; then
    _pass "hardware firmware: all 10 vendor sets mirrored AND installed (CPU microcode, wifi, audio, GPU)"
else
    _fail "hardware firmware: all 10 vendor sets mirrored AND installed" \
        "not wired:${_hw_missing}"
fi

# The desktop profile asks three questions, not nine. Six cards asked the
# operator to opt into things the profile is named for -- KVM, Kubernetes,
# observability, the ZFS console, Ollama -- which ship on the ISO regardless,
# so the buttons only ever gated first-boot work while looking like install
# choices. Every one had to be ticked to get the intended workstation, which
# made the install unrepeatable. Desktop now forces them on and keeps the
# three decisions that vary per machine: NVIDIA, Secure Boot, Build Images.
# (operator request, 2026-08-28.)
#
# Two halves are gated because removing the cards silently broke the second:
# the Arch/BSD K8s guard hung off the opt-k8s CARD, so deleting the card made
# the guard unreachable and would have forced K8s on for the two substrates
# with no K8s darksite. It now drives the checkbox and marks it, and the
# force-on skips anything marked.
_spa="$ROOT/live-build/config/includes.chroot/usr/local/share/kldload-webui/free/index.html"
_spa_ok=0
grep -qF "if (el.dataset.role === 'desktop') {" "$_spa" 2>/dev/null && _spa_ok=$((_spa_ok + 1))
grep -qF "cb.dataset.blocked !== '1'" "$_spa" 2>/dev/null && _spa_ok=$((_spa_ok + 1))
grep -qF "k8sCb.dataset.blocked" "$_spa" 2>/dev/null && _spa_ok=$((_spa_ok + 1))
# The six retired cards must stay retired; the three survivors must stay.
_spa_dead=0
for _c in opt-webui opt-bob opt-kvm opt-k8s opt-ebpf opt-zxplore; do
    grep -qF "id=\"${_c}\"" "$_spa" 2>/dev/null && _spa_dead=$((_spa_dead + 1))
done
_spa_live=0
for _c in opt-nvidia opt-secure-boot opt-images; do
    grep -qF "id=\"${_c}\"" "$_spa" 2>/dev/null && _spa_live=$((_spa_live + 1))
done
if ((_spa_ok == 3 && _spa_dead == 0 && _spa_live == 3)); then
    _pass "desktop asks 3 questions; the rest are silent defaults"
else
    _fail "desktop asks 3 questions; the rest are silent defaults" \
        "force-on/blocked-guard checks $_spa_ok/3, retired cards still present: $_spa_dead (want 0), surviving cards: $_spa_live/3"
fi

# The kernel exclude that protects the pin must COME FROM the pin. These two
# halves lived in different files and drifted: build-iso.sh switched to
# resolver-derived excludes, lib/bootstrap.sh kept a literal
# `--exclude=kernel*-7.[1-9]*`, and nothing failed when they disagreed. OpenZFS
# moved its cap to 7.2.999, the resolver moved the pin onto the 7.1 line, and
# the installer went on excluding all of 7.1 — so an rc10 darksite that
# CONTAINED kernel-7.1.9 installed kernel-7.0.14 from July instead. Five weeks
# of security fixes, silently, on a box that reported a clean install.
# (fiend .101, 2026-08-28.)
#
# The build now writes /etc/kldload-kernel-pin and the installer reads it. The
# legacy literal survives ONLY as the no-manifest fallback for older ISOs, and
# it must stay paired with the warning that says the pin may be stale.
_kpb="$ROOT/builder/build-iso.sh"
_kpi="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootstrap.sh"
_kp_ok=0
grep -qF 'ROOTFS}/etc/kldload-kernel-pin' "$_kpb" 2>/dev/null && _kp_ok=$((_kp_ok + 1))
grep -qF 'kernel pin manifest did not land in the rootfs' "$_kpb" 2>/dev/null && _kp_ok=$((_kp_ok + 1))
grep -qF '_kpin_file=/etc/kldload-kernel-pin' "$_kpi" 2>/dev/null && _kp_ok=$((_kp_ok + 1))
grep -qF 'read -ra _f44_kernel_lockout' "$_kpi" 2>/dev/null && _kp_ok=$((_kp_ok + 1))
grep -qF 'may install an OLDER kernel than its ZFS supports' "$_kpi" 2>/dev/null && _kp_ok=$((_kp_ok + 1))
if ((_kp_ok == 5)); then
    _pass "kernel exclude is derived from the resolved pin, not a literal"
else
    _fail "kernel exclude is derived from the resolved pin, not a literal" \
        "need all 5: build writes the manifest + asserts it landed; installer reads it, splits it with read -ra, and warns loudly on fallback — have $_kp_ok/5"
fi

# The kernel re-sign must never leave the ESP kernel unsigned. `sbattach
# --remove` strips the vendor signature IN PLACE and runs BEFORE the sbsign
# meant to replace it, so every failure path after that point has to put the
# original back — under Secure Boot the direct entry is the ONLY entry that
# runs, and a stripped kernel there is an unbootable machine announced as a
# WARNING. sbsign's exit code is also not evidence: a mismatched key/cert pair
# exits 0 and produces a file shim refuses, so the result is verified against
# the same cert shim will use, BEFORE it overwrites the staged kernel.
#
# Proven on fiend .132 2026-08-27 against the real 14MB kernel and the real
# MOK: old logic left 0 signatures when sbsign failed; new logic restores the
# vendor-signed original byte-identically (sha f5f0ea7c…, Debian Secure Boot CA
# intact) and rejects a rogue-key signature that exits 0.
_blr="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootloader.sh"
_blr_ok=0
grep -qF 'vmlinuz.preresign' "$_blr" 2>/dev/null && _blr_ok=$((_blr_ok + 1))
grep -qF 'sbverify --cert "$_mok_pub" "$_signed"' "$_blr" 2>/dev/null && _blr_ok=$((_blr_ok + 1))
grep -qF 'mv -f "$_orig" "${zbm_fallback_dir}/vmlinuz"' "$_blr" 2>/dev/null && _blr_ok=$((_blr_ok + 1))
if ((_blr_ok == 3)); then
    _pass "kernel re-sign restores the vendor signature on failure (no stripped kernel on the ESP)"
else
    _fail "kernel re-sign restores the vendor signature on failure (no stripped kernel on the ESP)" \
        "need all 3: the .preresign backup, the sbverify --cert outcome check, and the restore on the failure path — have $_blr_ok/3"
fi

# The platform holds must survive their own success. `apt-mark hold` rewrites
# dpkg's SELECTION field, so a package this tool pinned reads back as
# "hold ok installed", not "install ok installed". Matching the latter exactly
# made every already-pinned package invisible on the next run: installed[] came
# back empty, the tool took its "nothing to pin" exit, and truncated the state
# file that `kldload-rollback status` and the web console read. The operator is
# then told the kernel is UNPINNED on a box where all 56 holds are in force.
# (.132, 2026-08-27: showhold 56, status 0.)
#
# The || true is load-bearing too: dpkg-query exits non-zero for a name it has
# never heard of, and the list carries Ubuntu names on Debian on purpose. In a
# bare assignment that aborts the whole tool under set -e.
_kh="$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-apply-platform-holds"
_kh_ok=0
grep -qF 'hold ok installed' "$_kh" 2>/dev/null && _kh_ok=$((_kh_ok + 1))
grep -qF '(install|hold) ok installed$' "$_kh" 2>/dev/null && _kh_ok=$((_kh_ok + 1))
# The literal below is a SEARCH PATTERN for the ratchet's own escape hatch, not
# a swallow in this file.
grep -qF "dpkg-query -W -f='\${Status}' \"\$p\" 2>/dev/null || true" "$_kh" 2>/dev/null && _kh_ok=$((_kh_ok + 1))
if ((_kh_ok == 3)); then
    _pass "platform holds are idempotent (a held package still counts as installed)"
else
    _fail "platform holds are idempotent (a held package still counts as installed)" \
        "need all 3: the 'hold ok installed' arm, the awk (install|hold) alternation, and the true-guard on the dpkg-query capture — have $_kh_ok/3"
fi

# `_pick_last` returns empty when there is no pre-transaction snapshot, and
# every caller is written for that: `last` has a die() explaining what to try
# instead, `status` just omits the line. But the function ends in a `grep | tail`
# pipeline, and grep exits 1 on no-match — under pipefail that 1 escaped the
# command substitution and killed the caller, so the die() was DEAD CODE and the
# operator got a raw ERR trace instead.
#
# The state that triggers it is not exotic, it is the state a successful
# rollback LEAVES YOU IN: the environment you boot into has only sanoid
# autosnaps, no apt-pre. Caught on .132 2026-08-27 running `apt rollback status`
# immediately after verifying a Secure Boot + encrypted rollback.
_kr="$ROOT/live-build/config/includes.chroot/usr/sbin/kldload-rollback"
if grep -qF "{ grep -E '^(apt-pre|dnf-pre|kpkg)-' || " "$_kr" 2>/dev/null &&
    grep -qF 'tail -1' "$_kr" 2>/dev/null; then
    _pass "kldload-rollback: no pre-transaction snapshot is a value, not a crash"
else
    _fail "kldload-rollback: no pre-transaction snapshot is a value, not a crash" \
        "_pick_last's grep must tolerate a no-match exit — pipefail otherwise turns 'none found' into an ERR trace and 'last' never reaches its die()"
fi

# The SAME pin has to reach the GRUB direct entry, and for a long time it did
# not: grub.cfg emitted a literal `spl_hostid=${spl_hostid}` referring to a GRUB
# variable nothing ever set, so every direct boot passed an EMPTY value and SPL
# fell back to /etc/hostid. Under Secure Boot the direct entry is the ONLY entry
# that runs — ZBM cannot chainload through shim 15.8 — so the ZBM-property fix
# above never reached the path that matters most. Caught on fiend .132
# 2026-08-26: /proc/cmdline read "... ro ... spl_hostid= psi=1".
_bl="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/bootloader.sh"
if grep -qE 'spl_hostid=\\\$\{spl_hostid\}' "$_bl" 2>/dev/null; then
    _fail "grub direct entry pins a real spl_hostid" \
        "grub.cfg references \${spl_hostid}, a GRUB variable nothing sets — the direct entry boots with it EMPTY"
elif grep -qE '_hostid_hex:\+ spl_hostid=0x' "$_bl" 2>/dev/null &&
    grep -qE 'od -An -tx4 "\$\{target\}/etc/hostid"' "$_bl" 2>/dev/null; then
    _pass "grub direct entry pins a real spl_hostid (the only entry Secure Boot uses)"
else
    _fail "grub direct entry pins a real spl_hostid" \
        "the direct entry must resolve the target's hostid and inline it, not reference an unset GRUB variable"
fi

# The kernel pin must be installed BY NAME when the mirrors still carry it.
# Handing dnf the same NVR from @commandline while it is also resolvable from
# the repo is a hard conflict that killed a build on 2026-08-22. That case only
# started arising once the pin tracked the ZFS ceiling instead of lagging it.
if grep -q 'KPIN_SOURCE' "$ROOT/builder/kernel-pin.sh" 2>/dev/null &&
    grep -q 'KPIN_SOURCE:-koji' "$ROOT/builder/build-iso.sh" 2>/dev/null; then
    _pass "kernel pin: by-name when mirrors carry it, by-URL only when pruned"
else
    _fail "kernel pin: by-name when mirrors carry it" \
        "resolver must emit KPIN_SOURCE and build-iso must branch on it, or dnf sees a duplicate NVR"
fi

# Capture-then-eval must stay PAIRED. Splitting `eval "$(cmd)"` into a capture
# plus a later eval is correct — eval reports its own status, not the
# command's, so a resolver exiting 2 reads as success. But a half-applied edit
# leaves the capture with no eval, and then the variables it was supposed to
# define are unbound: the build dies with "KPIN_NVR: unbound variable" four
# minutes in, pointing nowhere near the actual mistake (2026-08-22, twice).
for _f in "$ROOT/builder/build-iso.sh" "$ROOT/build/darksite-fedora/build-darksite-fedora.sh"; do
    [[ -f "$_f" ]] || continue
    _cap=$(grep -c '_kpin_out="\$(' "$_f" 2>/dev/null || true)
    _ev=$(grep -c 'eval "\$_kpin_out"' "$_f" 2>/dev/null || true)
    if [[ "${_cap:-0}" -eq "${_ev:-0}" ]]; then
        _pass "kpin capture/eval paired: $(basename "$_f")"
    else
        _fail "kpin capture/eval paired: $(basename "$_f")" \
            "captured ${_cap} time(s) but evaluated ${_ev} — the pin variables will be unbound"
    fi
done

# The resolver must reject kernel FLAVOURS. Its first run picked
# 7.1.8+deb13-rt because sort -V ranks a suffixed name above the bare one, and
# the same bug would happily pick -cloud, the flavour with no DRM.
_guard "resolver rejects kernel flavours" "$ROOT/build/darksite-debian/resolve-stack.sh" \
    'grep -E "\^linux-image-\[0-9\]' \
    "without the flavour filter the resolver picks -rt or -cloud over the plain kernel"

# ── Silent-failure ratchet ─────────────────────────────────────────────────
# Project rule §4.1: no `|| true` unless a comment names the harmless case. The
# tree carries 1,478 that do not, and every "reported success while broken"
# defect has come out of that population: `golden all` exiting 0 after every
# golden failed; a golden with no ZFS sealed and announced ready;
# `kube-network nft` failing silently so two control planes stayed
# unfirewalled; a control-plane scale exiting 0 having added nothing.
#
# Removing 1,478 in one pass is not safe, so this is a RATCHET: the count may
# fall, never rise. New code obeys the rule; the debt only shrinks. Lower
# tests/silent-failure-baseline.txt whenever you clear some.
_section "Silent-failure ratchet"

_sf_baseline_file="$ROOT/tests/silent-failure-baseline.txt"
if [[ ${#SHELL_SCRIPTS[@]} -eq 0 || ! -f "$_sf_baseline_file" ]]; then
    _warn "silent-failure ratchet" "no baseline or no scripts — gate did not run"
else
    _sf_baseline="$(tr -cd '0-9' <"$_sf_baseline_file")"
    _sf_now=0
    for f in "${SHELL_SCRIPTS[@]}"; do
        while IFS= read -r _ln; do
            [[ -n "$_ln" ]] || continue
            # A COMMENT mentioning the swallow is not a swallow -- it is the
            # explanation this gate asks for. Counting it meant documenting one
            # RAISED the number the gate polices: the rule punished the fix.
            # Caught 2026-08-31, when three comments written to satisfy this
            # gate each added one to its own count.
            _self="$(sed -n "${_ln}p" "$ROOT/$f" 2>/dev/null)"
            [[ "$_self" =~ ^[[:space:]]*# ]] && continue
            # A comment directly above is the rule's escape hatch: it must name
            # the specific harmless case being swallowed.
            _prev="$(sed -n "$((_ln - 1))p" "$ROOT/$f" 2>/dev/null)"
            [[ "$_prev" =~ ^[[:space:]]*# ]] || _sf_now=$((_sf_now + 1))
        done < <(grep -n '|| true' "$ROOT/$f" 2>/dev/null | cut -d: -f1)
    done

    if [[ "$_sf_now" -gt "$_sf_baseline" ]]; then
        _fail "silent-failure ratchet" \
            "${_sf_now} unexplained '|| true', baseline ${_sf_baseline} — name the harmless case in a comment above the line"
    elif [[ "$_sf_now" -lt "$_sf_baseline" ]]; then
        _pass "silent-failure ratchet: ${_sf_now} unexplained '|| true' (was ${_sf_baseline} — lower the baseline)"
    else
        _pass "silent-failure ratchet: ${_sf_now} unexplained '|| true' (at baseline, not rising)"
    fi
fi

# ── Strict-mode ratchet ──────────────────────────────────────────────────────
# Every script is supposed to open with `set -Eeuo pipefail`. On 2026-09-06
# 84 of 234 did not, and the same day the installer's whole storage phase
# turned out to have run with errexit OFF since June (a `&& { } ||` idiom):
# a failed `zpool destroy`, a failed `zpool create` and every failed dataset
# step were ignored and the run printed "Installation complete!" over an
# empty ESP. A script that does not fail on error hides the bug that would
# have been fixed. The operator's words: "why not fail on errors, so they
# can be fixed instead of uncovered". This counts the scripts without that
# line; the count may fall, never rise. Baseline: tests/strict-mode-baseline.txt.
_section "Strict-mode ratchet"

_sm_baseline_file="$ROOT/tests/strict-mode-baseline.txt"
if [[ ${#SHELL_SCRIPTS[@]} -eq 0 || ! -f "$_sm_baseline_file" ]]; then
    _warn "strict-mode ratchet" "no baseline or no scripts — gate did not run"
else
    _sm_baseline="$(tr -cd '0-9' <"$_sm_baseline_file")"
    _sm_now=0
    _sm_list=()
    _sm_exempt=()
    for f in "${SHELL_SCRIPTS[@]}"; do
        # A script may opt out only by saying why, in a greppable line with a real
        # reason (a dracut hook sourced into dracut's shell, a generator that must
        # always exit 0). An exemption without a reason still counts.
        if grep -qE '^# strict-mode: exempt — .{30,}' "$ROOT/$f"; then
            _sm_exempt+=("$f")
            continue
        fi
        if ! grep -qE '^[[:space:]]*set -E?euo pipefail' "$ROOT/$f"; then
            _sm_now=$((_sm_now + 1))
            _sm_list+=("$f")
        fi
    done
    if [[ "$_sm_now" -gt "$_sm_baseline" ]]; then
        _fail "strict-mode ratchet" \
            "${_sm_now} scripts without 'set -Eeuo pipefail', baseline ${_sm_baseline} — add it to the new one: $(printf '%s ' "${_sm_list[@]}" | cut -c1-400)"
    elif [[ "$_sm_now" -lt "$_sm_baseline" ]]; then
        _pass "strict-mode ratchet: ${_sm_now} scripts without strict mode (was ${_sm_baseline} — lower the baseline)"
    else
        _pass "strict-mode ratchet: ${_sm_now} scripts without strict mode (at baseline, not rising)"
    fi
    ((${#_sm_exempt[@]} == 0)) || _pass "strict-mode exemptions with a stated reason: ${_sm_exempt[*]}"
fi

# ── systemd drop-ins reach the ISO ──────────────────────────────────────────
#
# build-iso.sh copies unit FILES by name pattern, and every pattern is a
# kldload-owned name. A drop-in that modifies a STOCK unit matches none of them.
# zfs-mount.service.d/10-kldload-never-on-live.conf was written, committed,
# built and was simply absent from the squashfs, while the code half of the same
# fix shipped fine because it lived in a file the build already copied.
#
# A glob now handles drop-ins. This asserts the glob is still there, because the
# failure it prevents is invisible: the build succeeds, the ISO is short a file,
# and nothing says so until the behaviour it was meant to change does not.
_section "systemd drop-ins"

_di_src="$ROOT/live-build/config/includes.chroot/usr/lib/systemd/system"
if [[ -d "$_di_src" ]]; then
    _di_dirs=("$_di_src"/*.d)
    if [[ ! -d "${_di_dirs[0]}" ]]; then
        _pass "systemd drop-ins: none shipped, nothing to carry"
    elif grep -q 'for _dropin_dir in .*includes.chroot/usr/lib/systemd/system/\*\.d' "$ROOT/builder/build-iso.sh"; then
        _pass "systemd drop-ins: build-iso.sh carries all ${#_di_dirs[@]} by glob ($(basename "${_di_dirs[0]}"))"
    else
        _fail "systemd drop-ins" \
            "${#_di_dirs[@]} drop-in dir(s) in includes.chroot and no glob in build-iso.sh to copy them — they will not reach the ISO"
    fi

    # Second leg: ISO -> INSTALLED TARGET. Reaching the squashfs is only half
    # the trip, and the half that was already gated. The installer's carry loop
    # read /etc/systemd/system/*.d only, so every vendor drop-in -- which
    # correctly lives in /usr/lib, because /etc belongs to the operator -- rode
    # the ISO and stopped there. fiend installed 2026-09-02 from an ISO that
    # contained the IPMI BMC guard and still reported `ipmi.service failed` on
    # a chassis with no BMC. The first leg was green the entire time.
    if [[ -d "${_di_dirs[0]}" ]]; then
        if grep -q 'for _droproot in /usr/lib/systemd/system /etc/systemd/system' \
            "$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"; then
            _pass "systemd drop-ins: profiles.sh carries both /usr/lib and /etc to the target"
        else
            _fail "systemd drop-ins (target)" \
                "${#_di_dirs[@]} vendor drop-in dir(s) ship in /usr/lib/systemd/system but the installer's carry loop does not walk that tree — they reach the ISO and never the installed system"
        fi
    fi
fi

# ── Boot-environment coverage ───────────────────────────────────────────────
# Which directories a rollback actually reverts is decided by one property in
# the installer, and getting it wrong is silent in both directions.
#
# .137, 2026-08-26: /var/lib was its own dataset, so a rollback removed seven
# binaries from /usr (inside the BE) and left the package database outside it.
# dpkg reported 1128 packages instead of 1117 and listed all seven as
# installed. `apt-get check` passed, because it validates dependencies and not
# file presence.
#
# fiend, 2026-09-12: the same mistake pointing the other way. /opt was its own
# dataset and every one of its 255 files belonged to google-chrome-stable --
# the browser kldload-webview drives. Proven in a file-backed pool: roll the BE
# back and /opt keeps the NEW Chrome while the database says the old one, so a
# rollback meant to undo a Chrome upgrade leaves the broken Chrome in place.
#
# So: anything holding packaged files stays in the BE, and this asserts it from
# the source rather than from an installed machine.
_section "Boot-environment coverage"

_be_src="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/storage-zfs.sh"
if [[ ! -r "$_be_src" ]]; then
    _fail "BE coverage" "cannot read storage-zfs.sh — this check DID NOT RUN"
else
    _be_bad=()
    while IFS= read -r _be_line; do
        _be_mp="${_be_line#*mountpoint=}"
        _be_mp="${_be_mp%% *}"
        _be_mp="${_be_mp%\"}"
        _be_mp="${_be_mp#\"}"
        case "$_be_mp" in
        /opt | /opt/*)
            _be_bad+=("/opt must stay inside the BE (packaged software): ${_be_line#"${_be_line%%[![:space:]]*}"}")
            ;;
        /usr | /var/lib)
            [[ "$_be_line" == *canmount=off* ]] ||
                _be_bad+=("$_be_mp needs canmount=off or it shadows the BE: ${_be_line#"${_be_line%%[![:space:]]*}"}")
            ;;
        esac
    done < <(grep -E '^[[:space:]]*zfs create .*mountpoint=' "$_be_src")

    # The invariant has a second half: those two containers must still EXIST,
    # because deleting the lines entirely would also pass the loop above.
    for _be_need in "mountpoint=/usr rpool/usr" "mountpoint=/var/lib rpool/var/lib"; do
        grep -q "canmount=off .*$_be_need" "$_be_src" ||
            _be_bad+=("missing container: zfs create -o canmount=off -o $_be_need")
    done

    if ((${#_be_bad[@]} == 0)); then
        _pass "BE coverage: no dataset shadows a packaged path inside the boot environment"
    else
        _fail "BE coverage" "$(printf '%s\n' "${_be_bad[@]}")"
    fi
fi

# ── Behavioural units (installer/security fixes the ISO checks can't reach) ──
_section "Behavioural Units"
if bash "$ROOT/tests/smoke-unit.sh"; then
    _pass "smoke-unit.sh: all behavioural checks passed"
else
    _fail "smoke-unit.sh" "behavioural checks failed (see output above)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "\033[1;36m══════════════════════════════════════════════════════════════\033[0m"
echo -e "\033[1;37m  Build Smoke Test Results                                    \033[0m"
echo -e "\033[1;36m──────────────────────────────────────────────────────────────\033[0m"
echo -e "  \033[1;32mPASS: $PASS\033[0m"
echo -e "  \033[1;31mFAIL: $FAIL\033[0m"
echo -e "  \033[1;33mWARN: $WARN\033[0m"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  \033[1;32mISO is ready to burn.\033[0m"
else
    echo -e "  \033[1;31m$FAIL failures — fix before burning.\033[0m"
fi
echo -e "\033[1;36m══════════════════════════════════════════════════════════════\033[0m"

exit $FAIL
