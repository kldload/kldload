#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# build-darksite-debian.sh — runs inside a Debian container.
# Downloads all required Debian packages and builds a local APT repository
# that is baked into the kldload CentOS live ISO at /root/darksite/debian/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${PKG_SETS_DIR:-${SCRIPT_DIR}/config/package-sets}"

PROFILE="${PROFILE:-desktop}"
ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"

# Output: mounted from host into this container
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
APT_ROOT="${DARKSITE_OUT}/apt"
APT_POOL="${APT_ROOT}/pool/main"
APT_DISTS="${APT_ROOT}/dists/${SUITE}/main/binary-${ARCH}"

log() { printf '[%s] [darksite-deb] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# Read package sets
# ---------------------------------------------------------------------------

declare -a PACKAGES=()

read_package_set() {
    local name="$1"
    local file="${PKG_SETS_DIR}/${name}.txt"
    if [[ ! -f "$file" ]]; then
        log "Package set not found (skipping): $file"
        return 0
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        line="${line//\$\{ARCH\}/$ARCH}"
        PACKAGES+=("$line")
    done <"$file"
    log "Loaded package set: $name ($(wc -l <"$file") entries)"
}

read_package_set "live-base"
read_package_set "target-base"
read_package_set "target-zfs"
read_package_set "target-desktop"
read_package_set "target-server"
read_package_set "target-kubernetes"

# ─── Packages the installer will actually ask for ────────────────────────────
#
# The seed lists above are hand-maintained, and until now nothing checked them
# against the installer. A package added to lib/profiles.sh stayed invisible to
# this mirror until somebody remembered to edit a second file — so the offline
# path could be asked for something that was never downloaded. That is not a
# warning on the offline path: the machine can only install what this mirror
# contains, so a miss is a feature silently absent from the installed system.
#
# Sourcing the real k_profile_packages is the only way the two cannot drift:
# the mirror now learns every package the installer knows about, by itself.
# fonts-noto-color-emoji is the case that exposed the gap (2026-08-18) — it was
# added to the desktop profile and to no seed list.
declare -a INSTALLER_PKGS=()
INSTALLER_LIB="${INSTALLER_LIB:-/installer-lib}"
if [[ -r "${INSTALLER_LIB}/profiles.sh" ]]; then
    # common.sh creates these on load. Both are env-overridable and neither
    # means anything inside this build container.
    export KLDLOAD_LOG_DIR="${KLDLOAD_LOG_DIR:-/tmp/kld-darksite-log}"
    export KLDLOAD_STATE_DIR="${KLDLOAD_STATE_DIR:-/tmp/kld-darksite-state}"
    # shellcheck source=/dev/null
    source "${INSTALLER_LIB}/profiles.sh"

    # The suite decides which naming branch the installer takes; asking for
    # Debian names while building a noble mirror would mirror the wrong set.
    if [[ "${SUITE}" == "noble" || "${SUITE}" == "jammy" ||
        "${SUITE}" == "mantic" || "${SUITE}" == "oracular" ]]; then
        _kdistro="ubuntu"
    else
        _kdistro="debian"
    fi

    for _prof in core server desktop kvm ai master storage vdi monitoring proxmox klab; do
        # k_die aborts on a profile a distro does not support. That is a
        # legitimate combination to ask about here, so it must not fail the
        # mirror build — only contribute nothing.
        # The `|| ""` must sit OUTSIDE the assignment. k_die exits the
        # substitution subshell, the assignment inherits that status, and
        # under `set -e` a failing assignment kills this script — an inner
        # `|| true` never runs because exit is immediate. klab is not a
        # supported profile and hits exactly that path.
        _base="$(KLDLOAD_DISTRO="$_kdistro" KLDLOAD_PROFILE="$_prof" \
            k_profile_packages 2>/dev/null)" || _base=""
        _opt="$(KLDLOAD_DISTRO="$_kdistro" KLDLOAD_PROFILE="$_prof" \
            KLDLOAD_ENABLE_EBPF=1 KLDLOAD_ENABLE_KVM=1 KLDLOAD_ENABLE_K8S=1 \
            KLDLOAD_STORAGE_MODE=zfs k_profile_optional_packages 2>/dev/null)" || _opt=""
        mapfile -t _arr < <(printf '%s %s' "$_base" "$_opt" | tr -s ' \t\n' '\n' | sed '/^$/d')
        [[ "${#_arr[@]}" -gt 0 ]] && INSTALLER_PKGS+=("${_arr[@]}")
    done
    if [[ "${#INSTALLER_PKGS[@]}" -gt 0 ]]; then
        PACKAGES+=("${INSTALLER_PKGS[@]}")
    fi
    log "Installer profile lists contributed ${#INSTALLER_PKGS[@]} package names (${_kdistro})"
else
    log "WARNING: ${INSTALLER_LIB}/profiles.sh is not mounted — this mirror is"
    log "         built from the seed lists ALONE and may lack packages the"
    log "         installer asks for. Mount it to close that gap."
fi

# Enable extra components — Debian needs contrib (ZFS), Ubuntu needs universe (ZFS)
if [[ "${SUITE}" == "noble" || "${SUITE}" == "jammy" || "${SUITE}" == "mantic" || "${SUITE}" == "oracular" ]]; then
    log "Ubuntu detected — enabling universe, restricted, multiverse..."
    sed -i 's/Components: main/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i 's/main$/main restricted universe multiverse/' /etc/apt/sources.list 2>/dev/null || true
    fi
else
    # No i386 multiarch, deliberately: nothing in this mirror is 32-bit.
    # Steam was the only thing that ever needed it and is no longer carried —
    # see the note in lib/bootstrap.sh.
    log "Debian detected — enabling contrib and non-free-firmware..."
    sed -i 's/Components: main/Components: main contrib non-free-firmware/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i 's/main$/main contrib non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
    fi
fi

# ─── Backports: kernel + ZFS ─────────────────────────────────────────────────
# Debian stable freezes its kernel and ZFS for the life of the release —
# trixie is kernel 6.12.101 / zfs 2.3.2, while trixie-backports carries 7.1.3 /
# zfs 2.4.3, the pair OpenZFS actually tests on Debian and the same ZFS the
# Fedora substrate ships.
#
# WHY IT HAS TO HAPPEN HERE and not only in the installer: the installer
# prefers this darksite mirror and only falls back to the internet
# (_k_bootstrap_apt, "Prefer the local darksite APT mirror"). A backports
# source added at install time is therefore inert on the default offline path
# — the machine can only install what this mirror contains. Missing this is
# how a Debian install shipped 6.12/2.3.2 on 2026-08-13 despite the installer
# asking for backports.
#
# The mirror is a FLAT single-suite pocket, so there is no -backports pocket to
# select from later. Instead the backports versions are pulled INTO the one
# pocket: a pin restricted to the kernel and ZFS packages makes both the
# dependency closure and the downloads below resolve there, and nothing else
# moves off stable.
#
# WHY THAT PAIR IS BUILDABLE: upstream OpenZFS 2.4.3 declares Linux-Maximum
# 7.0, but Debian's zfs-dkms 2.4.3-2~bpo13+1 ships META with Linux-Maximum 7.1
# (verified 2026-08-13 from the .deb), so the backports kernel is inside the
# ceiling of the backports ZFS by construction.
if [[ "${SUITE}" != "noble" && "${SUITE}" != "jammy" && "${SUITE}" != "mantic" &&
    "${SUITE}" != "oracular" && "${BACKPORTS:-1}" == "1" ]]; then
    log "Enabling ${SUITE}-backports for the kernel + ZFS stack..."
    printf 'deb http://deb.debian.org/debian %s-backports main contrib non-free-firmware\n' \
        "${SUITE}" >/etc/apt/sources.list.d/kldload-backports.list

    # Pin ONLY the kernel and ZFS packages. Priority 990 beats stable's 500,
    # so these resolve to backports; every other package is untouched and
    # backports stays at its default 100 for them.
    cat >/etc/apt/preferences.d/kldload-backports <<PREF
Package: linux-image-amd64 linux-headers-amd64 linux-image-*-amd64 linux-headers-*-amd64 linux-kbuild-* linux-compiler-*
Pin: release n=${SUITE}-backports
Pin-Priority: 990

Package: zfs-dkms zfsutils-linux zfs-initramfs zfs-zed libzfs*linux libzpool*linux libnvpair*linux libuutil*linux
Pin: release n=${SUITE}-backports
Pin-Priority: 990
PREF
fi

# Update APT cache
log "Updating APT package lists..."
apt-get update -q 2>&1 | grep -v '^Get\|^Hit\|^Ign' || true

# ─── Gate: every package the installer asks for must exist here ──────────────
#
# This mirror is the ONLY source on the offline path, so a name with no
# candidate becomes a feature silently missing from the installed system —
# apt-cache and the closure resolver both walk straight past an unknown name.
# Three shipped undetected until 2026-08-18: htopfzf (htop and fzf run
# together), plus gcc-c++ and pipewire-utils (RPM names on the Debian arm).
# Only an explicit assertion catches that class.
#
# _external lists names that legitimately cannot resolve here: they install
# from their vendor's own repository, never from Debian. Adding to it is a
# deliberate act that needs a reason, which is the point.
if [[ "${#INSTALLER_PKGS[@]}" -gt 0 ]]; then
    # Subscripts are QUOTED: unquoted, a hyphen inside [ ] is read as
    # arithmetic subtraction and shfmt rewrites [salt-api] to [salt - api],
    # so the key never matches and the gate fires on its own allowlist.
    declare -A _external=(
        ["grafana"]=1  # Grafana Labs repo, added at firstboot
        ["salt-api"]=1 # SaltProject repo — Debian dropped salt after bookworm
        ["salt-master"]=1
        ["salt-minion"]=1
    )
    declare -a _unresolvable=()
    while read -r _p; do
        [[ -n "${_external[$_p]:-}" ]] && continue
        apt-cache show "$_p" >/dev/null 2>&1 || _unresolvable+=("$_p")
    done < <(printf '%s\n' "${INSTALLER_PKGS[@]}" | LC_ALL=C sort -u)
    if [[ "${#_unresolvable[@]}" -gt 0 ]]; then
        log "FATAL: the installer asks for packages that do not exist in ${SUITE}:"
        for _p in "${_unresolvable[@]}"; do log "         ${_p}"; done
        die "fix the name in lib/profiles.sh, or add it to _external with a reason"
    fi
    log "Gate passed: all ${#INSTALLER_PKGS[@]} installer package names resolve in ${SUITE}"
fi

# Add required+important priority packages for debootstrap
log "Adding required+important Debian base packages..."
mapfile -t PRIORITY_PKGS < <(
    apt-cache dumpavail 2>/dev/null |
        awk '/^Package:/ { pkg=$2 }
               /^Priority: (required|important)/ { print pkg }' |
        sort -u
)
log "Priority packages found: ${#PRIORITY_PKGS[@]}"
PACKAGES+=("${PRIORITY_PKGS[@]}")

# Hardcoded debootstrap essentials
PACKAGES+=(
    gzip zstd xz-utils bzip2 tar
    dash bash coreutils diffutils findutils grep sed gawk
    mount util-linux apt dpkg base-files base-passwd
)

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Packages to download: ${#PKGS_FINAL[@]}"

mkdir -p "$APT_POOL" "$APT_DISTS"

# Resolve full dependency closure
log "Resolving full dependency closure..."
mapfile -t CLOSURE < <(
    apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        "${PKGS_FINAL[@]}" 2>/dev/null |
        grep '^[[:alpha:]]' |
        sort -u
)
log "Dependency closure: ${#CLOSURE[@]} packages"

if [[ "${#CLOSURE[@]}" -eq 0 ]]; then
    log "apt-cache depends returned empty — falling back to direct package list."
    CLOSURE=("${PKGS_FINAL[@]}")
fi

# Blacklist
DARKSITE_BLACKLIST=(
    musescore-general-soundfont musescore-general-soundfont-lossless
    musescore-general-soundfont-small fluid-soundfont-gm
    fluidr3mono-gm-soundfont opl3-soundfont timgm6mb-soundfont
    enlightenment-data libelementary-data mate-backgrounds
    breeze-wallpaper lxqt-themes lomiri-sounds lomiri-wallpapers-16.04
    snapd
)

# WHY chromium is NOT here any more: it arrived in this list with the darksite
# itself, lumped in with soundfonts and wallpapers as a bulk size-saver, back
# when the desktop shipped Firefox. The desktop profile now asks for chromium
# by name on Debian (_browser), and the per-tool dock launchers depend on a
# Chromium-family browser — `--class` sets the Wayland app_id and the
# /app/<tool> paths need chrome-app mode, neither of which Firefox offers.
# Blacklisting it meant the installer asked for a browser the mirror stripped,
# so an offline desktop install got no browser at all and the failure was
# invisible: the retry loop logged "not available - skipping" and moved on.
# (2026-08-18)

if [[ "${#DARKSITE_BLACKLIST[@]}" -gt 0 ]]; then
    declare -A _bl
    for _b in "${DARKSITE_BLACKLIST[@]}"; do _bl["$_b"]=1; done
    _filtered=()
    for _p in "${CLOSURE[@]}"; do
        [[ -z "${_bl[$_p]:-}" ]] && _filtered+=("$_p")
    done
    log "Removed $((${#CLOSURE[@]} - ${#_filtered[@]})) blacklisted packages"
    CLOSURE=("${_filtered[@]}")
fi

# ─── Gate: never blacklist something the installer asks for ──────────────────
#
# These two lists are edited by different people for different reasons, and
# until now nothing compared them. chromium sat in the blacklist while the
# desktop profile asked for it by name, so every offline Debian desktop
# install came up with no browser — and said nothing, because a stripped
# package is indistinguishable from one that was never wanted.
if [[ "${#INSTALLER_PKGS[@]}" -gt 0 && "${#DARKSITE_BLACKLIST[@]}" -gt 0 ]]; then
    declare -a _contradictions=()
    while read -r _p; do
        [[ -n "${_bl[$_p]:-}" ]] && _contradictions+=("$_p")
    done < <(printf '%s\n' "${INSTALLER_PKGS[@]}" | LC_ALL=C sort -u)
    if [[ "${#_contradictions[@]}" -gt 0 ]]; then
        log "FATAL: the installer asks for packages this mirror blacklists:"
        for _p in "${_contradictions[@]}"; do log "         ${_p}"; done
        die "drop it from DARKSITE_BLACKLIST, or stop installing it in lib/profiles.sh"
    fi
fi

# Evict stale stable-pocket copies of the backports-pinned packages.
#
# WHY: the skip check in the download loop below matches on package NAME only
# (`${_pkg}_*.deb`), so a previously cached linux-image-amd64_6.12.101 makes
# the loop skip the 7.1.3 backports build entirely — a cache that silently
# defeats the pin, on a mirror where the pin is the whole point. Only these
# names are evicted; every other package keeps its cache, so an incremental
# rebuild stays incremental.
#
# The versioned kernel packages (linux-image-7.1.3-*) carry the version in the
# NAME, so they never collide and are left alone.
#
# The ZFS libs MUST be listed. An earlier version of this list omitted them on
# the reasoning that they carry a soversion in the name — true for libzfs6→7
# and libzpool6→7, but FALSE for libnvpair3linux and libuutil3linux, which keep
# the same name across 2.3.2→2.4.3. Their stale copies therefore survived the
# skip, and `zfsutils-linux 2.4.3` became unsatisfiable:
#
#   zfsutils-linux : Depends: libnvpair3linux (= 2.4.3-2~bpo13+1)
#                             but 2.3.2-2 is to be installed
#
# which aborted the installer's BATCHED base transaction — taking
# linux-image-amd64 down with it and producing a target with an empty /boot
# and ZBM reporting "no boot environment found" (fiend, 2026-08-13).
if [[ -f /etc/apt/preferences.d/kldload-backports ]]; then
    _evicted=0
    for _glob in linux-image-amd64 linux-headers-amd64 zfs-dkms zfsutils-linux \
        zfs-initramfs zfs-zed libnvpair3linux libuutil3linux \
        'libzfs*linux' 'libzpool*linux'; do
        while IFS= read -r -d '' _old; do
            [[ "$_old" == *bpo* ]] && continue
            rm -f "$_old" && ((_evicted++)) || true
        done < <(find "$APT_POOL" -maxdepth 1 -name "${_glob}_*.deb" -print0 2>/dev/null)
    done
    log "Evicted ${_evicted} stale stable kernel/ZFS debs so backports can replace them"
fi

# ─── What version does the archive serve right now ───────────────────────────
#
# The skip below used to match on NAME alone (`${_pkg}_*.deb`), so any package
# already in the pool was never re-downloaded, at any version. A mirror left
# for two months stayed two months old for everything already in it, and only
# newly-added packages arrived current. The kernel and ZFS were evicted by
# hand further up to defeat exactly this — proof the trap was known, patched
# for two names, and left in place for the other 2800.
#
# In a stable suite the packages that DO move are the security updates, which
# is the worst possible set to freeze. Measured 2026-08-18: libexpat1 sat at
# 2.8.2-1~deb13u1 while the archive served 2.8.3-1~deb13u1.
#
# One batched apt-cache policy is far cheaper than 2800 individual queries.
log "Resolving current archive versions for ${#CLOSURE[@]} packages..."
declare -A _cand=()
while read -r _n _v; do
    [[ -n "$_n" && -n "$_v" && "$_v" != "(none)" ]] && _cand["$_n"]="$_v"
done < <(apt-cache policy "${CLOSURE[@]}" 2>/dev/null | awk '
    /^[^ ]/  { name = $0; sub(/:$/, "", name); next }
    /Candidate:/ { print name" "$2 }
')
log "Archive candidates resolved: ${#_cand[@]}"

# Download packages
log "Downloading ${#CLOSURE[@]} packages..."
_dl_new=0 _dl_skip=0 _dl_fail=0 _dl_idx=0 _dl_stale=0 _dl_total="${#CLOSURE[@]}"
for _pkg in "${CLOSURE[@]}"; do
    ((_dl_idx++)) || true
    ((_dl_idx % 100 == 0)) && log "Progress: ${_dl_idx}/${_dl_total} — ${_dl_new} new, ${_dl_skip} cached, ${_dl_stale} refreshed, ${_dl_fail} skipped"
    _want="${_cand[$_pkg]:-}"
    if [[ -n "$_want" ]]; then
        # Epochs are written %3a on disk by apt and normalised to ':' further
        # down, so a cached file may carry either spelling. Check both.
        if compgen -G "${APT_POOL}/${_pkg}_${_want}_*.deb" >/dev/null 2>&1 ||
            compgen -G "${APT_POOL}/${_pkg}_${_want//:/%3a}_*.deb" >/dev/null 2>&1; then
            # ((x++)) returns non-zero when the pre-increment value is 0, which
            # would trip set -e. Only the counter is being swallowed.
            ((_dl_skip++)) || true
            continue
        fi
        # Present but at another version: drop the superseded copy, or the
        # pool ends up serving two versions of one package and the Packages
        # index becomes ambiguous.
        if compgen -G "${APT_POOL}/${_pkg}_*.deb" >/dev/null 2>&1; then
            rm -f "${APT_POOL}/${_pkg}"_*.deb
            # Counter only — see the ((x++)) note above.
            ((_dl_stale++)) || true
        fi
    elif compgen -G "${APT_POOL}/${_pkg}_*.deb" >/dev/null 2>&1; then
        # No candidate to compare against (virtual or vanished from the
        # archive). Keep what is cached rather than deleting something the
        # install may still need.
        ((_dl_skip++)) || true
        continue
    fi
    (cd "$APT_POOL" && apt-get download "$_pkg" 2>/dev/null) && {
        ((_dl_new++)) || true
    } || {
        ((_dl_fail++)) || true
    }
done
log "Download complete: ${_dl_new} new, ${_dl_skip} cached, ${_dl_stale} refreshed, ${_dl_fail} skipped"

# ─── Evict packages that are no longer part of this mirror ───────────────────
#
# The loop above only ever ADDS. A package dropped from a profile, renamed
# upstream, or withdrawn from the archive stayed in the pool forever, and the
# generated Packages index kept advertising it. That is how a mirror drifts
# into being an archaeological record instead of a build artifact: it still
# carries what the installer wanted months ago, so a rebuild that should have
# been "the darksite as of today" quietly shipped yesterday's decisions too.
#
# The closure IS the definition of this mirror. Anything outside it cannot be
# reached by any install this ISO performs, so removing it is subtraction of
# dead weight, not of function. Every eviction is named in the log, because a
# prune that deletes silently is indistinguishable from one that deletes the
# wrong thing.
log "Pruning packages no longer in the closure..."
declare -A _keep=()
for _pkg in "${CLOSURE[@]}"; do _keep["$_pkg"]=1; done

_pruned=0
while IFS= read -r -d '' _f; do
    # name_version_arch.deb — the name is everything before the first '_'.
    _base="$(basename "$_f")"
    _name="${_base%%_*}"
    if [[ -z "${_keep[$_name]:-}" ]]; then
        log "  evicting (not in closure): ${_base}"
        rm -f "$_f"
        # Counter only — ((x++)) returns non-zero from 0 under set -e.
        ((_pruned++)) || true
    fi
done < <(find "$APT_POOL" -maxdepth 1 -name '*.deb' -print0)
log "Pruned ${_pruned} package(s); the pool is now exactly the closure"

# Normalise epoch filenames
log "Normalising epoch filenames..."
while IFS= read -r -d '' f; do
    mv "$f" "${f//%3a/:}"
done < <(find "$APT_POOL" -maxdepth 1 -name '*%3a*' -print0)

DEB_COUNT=0
while IFS= read -r -d '' _; do
    ((DEB_COUNT++)) || true
done < <(find "$APT_POOL" -maxdepth 1 -name "*.deb" -print0)

log "Darksite pool: ${DEB_COUNT} packages"
[[ "$DEB_COUNT" -gt 0 ]] || die "No packages downloaded"

# Assert the backports kernel and ZFS are really in the pool. This mirror IS
# the offline install — if apt quietly served stable (unreachable backports,
# a renamed pocket, a pin that did not apply), every later step still succeeds
# and the operator boots a frozen 6.12 / 2.3.2 machine. Nothing downstream can
# distinguish that from success, so the check has to be here and fatal.
if [[ -f /etc/apt/preferences.d/kldload-backports ]]; then
    _bpo_missing=()
    for _need in linux-image-amd64 zfs-dkms; do
        compgen -G "${APT_POOL}/${_need}_*bpo*.deb" >/dev/null 2>&1 ||
            _bpo_missing+=("$_need")
    done
    if [[ "${#_bpo_missing[@]}" -gt 0 ]]; then
        die "Backports enabled but no bpo build of [${_bpo_missing[*]}] reached the pool — the offline mirror would install the frozen stable kernel/ZFS. Check the ${SUITE}-backports source and the pin."
    fi
    for _need in linux-image-amd64 zfs-dkms; do
        _found="$(compgen -G "${APT_POOL}/${_need}_*bpo*.deb" | head -1)"
        log "Backports verified in pool: $(basename "${_found}")"
    done
fi

# Generate APT index
log "Generating Packages index..."
(
    cd "$APT_ROOT"
    dpkg-scanpackages --multiversion pool/main 2>/dev/null \
        >"dists/${SUITE}/main/binary-${ARCH}/Packages" ||
        dpkg-scanpackages pool/main \
            >"dists/${SUITE}/main/binary-${ARCH}/Packages"
)
gzip -9c "${APT_DISTS}/Packages" >"${APT_DISTS}/Packages.gz"

# Generate Release file
log "Generating Release file..."
_size() { stat -c%s "$1"; }
_md5() { md5sum "$1" | awk '{print $1}'; }
_sha256() { sha256sum "$1" | awk '{print $1}'; }

PKG_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages"
PKG_GZ_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages.gz"

cat >"${APT_ROOT}/dists/${SUITE}/Release" <<EOF
Origin: kldload Darksite
Label: kldload
Suite: ${SUITE}
Codename: ${SUITE}
Architectures: ${ARCH}
Components: main
Description: kldload offline Debian APT repository
Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')
MD5Sum:
 $(_md5 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_md5 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
SHA256:
 $(_sha256 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_sha256 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
EOF

# ─── Resolvability gate ──────────────────────────────────────────────────────
# Assert the installer's BASE transaction actually resolves against this
# mirror. Presence checks are not enough: on 2026-08-13 every package the
# earlier gate looked for was present, yet the install still failed because a
# stale libnvpair3linux/libuutil3linux made zfsutils-linux unsatisfiable.
#
# Why that is fatal rather than cosmetic: the installer requests the base set
# as ONE apt transaction, and a batched apt-get is all-or-nothing. A single
# unsatisfiable dependency installs NOTHING — including linux-image-amd64 —
# and a failed transaction writes no /var/log/apt/history.log entry, so the
# target ends up with an empty /boot and the only visible symptom is
# ZFSBootMenu saying "no boot environment found" after a full install.
#
# The simulation runs against a scratch apt state with an EMPTY status file,
# so every package counts as not-yet-installed and the resolver sees the same
# problem a fresh target does.
#
# NOTE: this list mirrors the base array in
# lib/bootstrap.sh (k_bootstrap_base). If that list gains a package, add it
# here too — the gate is only as good as its coverage.
#
# DEBIAN ONLY. This same script builds the Ubuntu mirror (SUITE=noble et al),
# where the kernel metapackage is linux-image-generic, not linux-image-amd64 —
# so running this list there fails on package names that were never meant to
# exist. Gate on the same suite test the backports block uses.
# HISTORY: 2026-08-14 — an unconditional gate failed the Ubuntu darksite with
# "linux-image-amd64 has no installation candidate" and aborted the ISO build.
if [[ "${SUITE}" == "noble" || "${SUITE}" == "jammy" || "${SUITE}" == "mantic" ||
    "${SUITE}" == "oracular" ]]; then
    log "Skipping the base-transaction gate: Ubuntu uses a different kernel metapackage"
    log "====================================================="
    log "Debian darksite build complete"
    log "  APT packages: ${DEB_COUNT}"
    log "  Repo:         ${APT_ROOT}"
    log "====================================================="
    exit 0
fi

log "Verifying the installer's base transaction resolves against this mirror..."
_gate_tmp="$(mktemp -d)"
trap 'rm -rf "${_gate_tmp}"' EXIT
mkdir -p "${_gate_tmp}/lists/partial" "${_gate_tmp}/cache/archives/partial"
: >"${_gate_tmp}/status"
printf 'deb [trusted=yes] file://%s %s main\n' "$APT_ROOT" "$SUITE" >"${_gate_tmp}/sources.list"

_apt_scratch=(
    -o "Dir::Etc::SourceList=${_gate_tmp}/sources.list"
    -o "Dir::Etc::SourceParts=/dev/null"
    -o "Dir::State::Lists=${_gate_tmp}/lists"
    -o "Dir::State::Status=${_gate_tmp}/status"
    -o "Dir::Cache=${_gate_tmp}/cache"
    -o "APT::Get::AllowUnauthenticated=true"
)

_base_set=(
    linux-image-amd64 linux-headers-amd64
    efibootmgr mokutil shim-signed grub-efi-amd64-signed sbsigntool
    kexec-tools locales keyboard-configuration console-setup systemd-sysv
    initramfs-tools sudo openssh-server network-manager qemu-guest-agent
    nginx-light novnc websockify
    zfsutils-linux zfs-initramfs zfs-zed zfs-dkms
)

apt-get "${_apt_scratch[@]}" update -qq >/dev/null 2>&1 || true
if _gate_out="$(apt-get "${_apt_scratch[@]}" install -s -y "${_base_set[@]}" 2>&1)"; then
    log "Base transaction resolves cleanly against the darksite mirror"
else
    log "FATAL: the installer's base transaction does NOT resolve against this mirror."
    log "A target installed from this ISO would get an empty /boot and ZFSBootMenu"
    log "would report 'no boot environment found'. Offending dependencies:"
    printf '%s\n' "$_gate_out" | grep -iE '^E:|Depends:|but .* is to be installed|not going to be installed' |
        head -20 | while IFS= read -r _l; do log "    ${_l}"; done
    die "darksite mirror is not installable — refusing to ship it"
fi

log "====================================================="
log "Debian darksite build complete"
log "  APT packages: ${DEB_COUNT}"
log "  Repo:         ${APT_ROOT}"
log "====================================================="
