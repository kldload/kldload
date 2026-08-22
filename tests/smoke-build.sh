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
            usr/share/icons/hicolor/scalable/apps/kldload-webui.svg
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
