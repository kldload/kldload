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

    # ── Bob + RAG content inside the squashfs ───────────────────────────
    # Catches the regression where RAG code shipped but indexer/units/
    # deps were missing. unsquashfs returns 0 even when some requested
    # files don't exist in the image, so we verify each file
    # individually after the extract instead of trusting its exit code.
    if [[ -f "$MOUNTPOINT/LiveOS/squashfs.img" ]] && command -v unsquashfs >/dev/null 2>&1; then
        SQEXTRACT=$(mktemp -d)
        declare -a RAG_FILES=(
            usr/local/bin/bob
            usr/local/bin/kldload-rag-index
            usr/local/bin/kai-rag
            usr/local/lib/kldload-rag/kldload_rag.py
            usr/local/lib/kldload-rag/kldload_rag_index.py
            usr/lib/systemd/system/kldload-rag.service
            usr/lib/systemd/system/kldload-rag-firstboot.service
            usr/lib/systemd/system/kldload-rag-index.timer
            usr/lib/systemd/system/kldload-rag-index.service
        )
        unsquashfs -q -f -d "$SQEXTRACT/root" "$MOUNTPOINT/LiveOS/squashfs.img" \
            "${RAG_FILES[@]}" >/dev/null 2>&1 || true

        # Per-file existence + content checks
        for _f in "${RAG_FILES[@]}"; do
            if [[ -f "$SQEXTRACT/root/$_f" ]]; then
                _pass "squashfs has $_f"
            else
                _fail "squashfs has $_f" "file missing from squashfs"
            fi
        done

        # bob must contain BOB_RAG (the bridge marker) -- catches the stub
        if [[ -f "$SQEXTRACT/root/usr/local/bin/bob" ]]; then
            if grep -q 'BOB_RAG' "$SQEXTRACT/root/usr/local/bin/bob"; then
                _pass "squashfs bob CLI has RAG bridge"
            else
                _fail "squashfs bob CLI has RAG bridge" "stub installed instead of full bob -- RAG won't be used"
            fi
        fi

        rm -rf "$SQEXTRACT"
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
            usr/share/icons/hicolor/scalable/apps/kldload-webui.svg
            usr/share/icons/hicolor/scalable/apps/bob-chat.svg
            usr/share/icons/hicolor/scalable/apps/kldload-zfs.svg
            usr/local/bin/bob-models
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

        # bob delegates model mgmt to bob-models; bob-models swaps the resident
        # model via the ollama keep_alive API (load/unload).
        if [[ -f "$WSEXTRACT/root/usr/local/bin/bob-models" ]] && grep -q 'keep_alive' "$WSEXTRACT/root/usr/local/bin/bob-models"; then
            _pass "bob-models has load/unload (keep_alive) support"
        else
            _fail "bob-models load/unload" "keep_alive missing — model swap won't work"
        fi

        rm -rf "$WSEXTRACT"
    fi

    umount "$MOUNTPOINT" 2>/dev/null
    _pass "ISO unmounted cleanly"
else
    _warn "ISO mount" "could not mount ISO (may need root)"
fi
rmdir "$MOUNTPOINT" 2>/dev/null

# ── Git state ────────────────────────────────────────────────────────────────
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

# ── Key scripts syntax check ─────────────────────────────────────────────────
_section "Script Syntax"

for script in kube-cluster kube-init kube-setup kube-demo kzfs-lab kvm-demo kvm-clone; do
    FILE=$(find "$ROOT/live-build/config/includes.chroot" -name "$script" -type f 2>/dev/null | head -1)
    if [[ -n "$FILE" ]]; then
        if bash -n "$FILE" 2>/dev/null; then
            _pass "$script syntax OK"
        else
            _fail "$script syntax" "bash -n failed"
        fi
    fi
done

# ── Shellcheck (if available) ────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
    _section "Shellcheck"
    for script in kube-cluster kube-init kube-setup kzfs-lab profiles.sh build-iso.sh; do
        FILE=$(find "$ROOT" -name "$script" -not -path "*cache*" -not -path "*.git*" -type f 2>/dev/null | head -1)
        if [[ -n "$FILE" ]]; then
            ERRORS=$(shellcheck -S error "$FILE" 2>&1 | grep -c "SC[0-9]" || true)
            if [[ "$ERRORS" -eq 0 ]]; then
                _pass "$script shellcheck clean"
            else
                _fail "$script shellcheck" "$ERRORS errors"
            fi
        fi
    done
else
    _warn "Shellcheck" "not installed — install ShellCheck (dnf/apt)"
fi

# ── shfmt drift (style enforcement, if available) ────────────────────────────
# Every tracked *.sh + ci/kldload-ci-run must match `shfmt -i 4`. After the
# 2026 bulk-reformat this is the gate that keeps the codebase from drifting.
if command -v shfmt >/dev/null 2>&1; then
    _section "shfmt drift"
    DRIFT=$(cd "$ROOT" && find . -type f \( -name '*.sh' -o -path './ci/kldload-ci-run' \) \
        -not -path './.git/*' \
        -not -path './live-build/*' \
        -not -path './build/darksite-*/output/*' \
        -not -path './builder/.cache/*' \
        -print0 | xargs -0 shfmt -l -i 4 2>/dev/null)
    if [[ -z "$DRIFT" ]]; then
        _pass "all shell scripts shfmt-clean"
    else
        while IFS= read -r f; do
            _fail "$f" "needs 'shfmt -w -i 4'"
        done <<<"$DRIFT"
    fi
else
    _warn "shfmt" "not installed — install shfmt (github.com/mvdan/sh releases)"
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
