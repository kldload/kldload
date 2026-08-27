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

if ! grep -q 'kernel/printk' "$_pfx" 2>/dev/null; then
    _fail "quiet boot is safe (prompt extension backs it)" \
        "the prompt extension does not quieten the console — quiet on the cmdline would hide the passphrase prompt again"
elif ! grep -qE '_direct_bootargs="\$\(k_console_args\) quiet' "$_bl" 2>/dev/null; then
    _fail "quiet boot is safe (prompt extension backs it)" \
        "the encrypted direct entry does not set quiet — an encrypted install boots with full kernel log output"
elif ! grep -qE '_zbm_args="rw \$\(k_console_args\) quiet' "$_sz" 2>/dev/null; then
    _fail "quiet boot is safe (prompt extension backs it)" \
        "the ZBM cmdline does not set quiet — the path a normal SB-off boot reads"
else
    _pass "quiet boot on both cmdlines, backed by the prompt extension"
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
