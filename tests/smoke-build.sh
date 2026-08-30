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

# Size check — should be 8-12GB for a full free edition
SIZE=$(stat -c%s "$ISO" 2>/dev/null || echo 0)
SIZE_GB=$(echo "scale=1; $SIZE / 1073741824" | bc 2>/dev/null || echo "?")
if [[ $SIZE -gt 8000000000 && $SIZE -lt 13000000000 ]]; then
    _pass "ISO size: ${SIZE_GB}G (expected 8-12G)"
elif [[ $SIZE -gt 5000000000 ]]; then
    _warn "ISO size" "${SIZE_GB}G — smaller than expected (missing darksites?)"
else
    _fail "ISO size" "${SIZE_GB}G — too small, build likely failed"
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
        else
            _warn "unit ExecStart gate" "could not list the squashfs — this gate DID NOT RUN"
        fi
        rm -f "$ULIST"
    fi

    umount "$MOUNTPOINT" 2>/dev/null
    _pass "ISO unmounted cleanly"
else
    _warn "ISO mount" "could not mount ISO (may need root)"
fi
rmdir "$MOUNTPOINT" 2>/dev/null

# ── Git state ────────────────────────────────────────────────────────────────
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
