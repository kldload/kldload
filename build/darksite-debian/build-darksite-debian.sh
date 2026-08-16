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

# Enable extra components — Debian needs contrib (ZFS), Ubuntu needs universe (ZFS)
if [[ "${SUITE}" == "noble" || "${SUITE}" == "jammy" || "${SUITE}" == "mantic" || "${SUITE}" == "oracular" ]]; then
    log "Ubuntu detected — enabling universe, restricted, multiverse..."
    sed -i 's/Components: main/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    if [[ -f /etc/apt/sources.list ]]; then
        sed -i 's/main$/main restricted universe multiverse/' /etc/apt/sources.list 2>/dev/null || true
    fi
else
    # i386 multiarch is NOT enabled here — see the Steam fetch far below,
    # where it is enabled for that one step only. Enabling it at this point
    # puts it in scope for the main dependency closure, which is a mistake
    # measured in gigabytes.
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
    chromium chromium-common snapd
)

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

# Download packages
log "Downloading ${#CLOSURE[@]} packages..."
_dl_new=0 _dl_skip=0 _dl_fail=0 _dl_idx=0 _dl_total="${#CLOSURE[@]}"
for _pkg in "${CLOSURE[@]}"; do
    ((_dl_idx++)) || true
    ((_dl_idx % 100 == 0)) && log "Progress: ${_dl_idx}/${_dl_total} — ${_dl_new} new, ${_dl_skip} cached, ${_dl_fail} skipped"
    if compgen -G "${APT_POOL}/${_pkg}_*.deb" >/dev/null 2>&1; then
        ((_dl_skip++)) || true
        continue
    fi
    (cd "$APT_POOL" && apt-get download "$_pkg" 2>/dev/null) && {
        ((_dl_new++)) || true
    } || {
        ((_dl_fail++)) || true
    }
done
log "Download complete: ${_dl_new} new, ${_dl_skip} cached, ${_dl_fail} skipped"

# ─── Steam, fetched on its own terms ─────────────────────────────────────────
#
# WHY SEPARATE FROM THE CLOSURE ABOVE: that closure is resolved with
# `apt-cache depends --recurse`, which yields bare package names. Steam's
# dependencies are arch-qualified (libgl1:i386 and ~120 more), and a bare
# `apt-get download libgl1` fetches the amd64 build — so the i386 half would
# silently never arrive and steam-installer would be unsatisfiable in the
# mirror. Asking apt to plan the install and reading back the URIs it would
# fetch gets the exact closure, i386 included, without touching the resolution
# path that the kernel and ZFS depend on.
#
# NOT FATAL. Steam is the definition of optional, and the rule this project
# paid for in kernels is that optional packages never share a failure with
# boot-critical ones. A miss here costs Steam and nothing else.
if [[ "${SUITE}" != "noble" && "${SUITE}" != "jammy" && "${SUITE}" != "mantic" && "${SUITE}" != "oracular" ]]; then
    # i386 is enabled HERE, and the ordering is the whole point.
    #
    # Steam's Linux client is a 32-bit binary — Valve moved Proton, the
    # runtime and the games to 64-bit, but the client bootstrap is still
    # i386, so steam-installer drags ~120 32-bit libraries and cannot be
    # fetched at all without multiarch.
    #
    # Enabling it before the MAIN closure is resolved, though, makes
    # `apt-cache depends --recurse` return the 32-bit variant of everything:
    # the closure went from ~1500 packages to 3448 and the mirror began
    # fetching i386 builds of accountsservice, acl and the rest of the base
    # system — gigabytes of 32-bit libraries no 64-bit install will ever
    # load (caught mid-build, 2026-08-16). Steam is the only thing in this
    # mirror that needs 32-bit, so only Steam's fetch runs with it enabled.
    dpkg --add-architecture i386
    apt-get update -qq >/dev/null 2>&1 || true
    log "Fetching Steam closure (steam-installer + i386 libraries)..."
    _steam_before="$(find "$APT_POOL" -maxdepth 1 -name '*.deb' | wc -l)"
    if _steam_uris="$(apt-get install -y --print-uris steam-installer 2>/dev/null |
        grep -oE "https?://[^']+" || true)" && [[ -n "$_steam_uris" ]]; then
        _steam_got=0 _steam_miss=0
        while IFS= read -r _u; do
            [[ -n "$_u" ]] || continue
            _f="${_u##*/}"
            _f="${_f//%3a/:}"
            if [[ -f "${APT_POOL}/${_f}" ]]; then
                continue
            fi
            if (cd "$APT_POOL" && curl -fsSL -O "$_u" 2>/dev/null); then
                ((_steam_got++)) || true
            else
                ((_steam_miss++)) || true
            fi
        done <<<"$_steam_uris"
        _steam_after="$(find "$APT_POOL" -maxdepth 1 -name '*.deb' | wc -l)"
        log "Steam closure: ${_steam_got} fetched, ${_steam_miss} missed (pool ${_steam_before} → ${_steam_after})"
        if ((_steam_miss > 0)); then
            log "WARNING: ${_steam_miss} Steam packages did not download — Steam may not install offline"
        fi
    else
        log "WARNING: could not plan the Steam install — is i386 enabled and contrib reachable?"
    fi
fi

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

# The i386 index. apt reads a SEPARATE Packages file per architecture, so the
# i386 half of the Steam closure is invisible without one — the debs would sit
# in the pool and steam-installer would still be unsatisfiable.
#
# The same scan serves both: each stanza carries its own Architecture field and
# apt ignores the ones that are not its own, so one listing published in two
# places is correct and cannot drift from itself.
APT_DISTS_I386="${APT_ROOT}/dists/${SUITE}/main/binary-i386"
mkdir -p "$APT_DISTS_I386"
cp "${APT_DISTS}/Packages" "${APT_DISTS_I386}/Packages"
gzip -9c "${APT_DISTS_I386}/Packages" >"${APT_DISTS_I386}/Packages.gz"

# Generate Release file
log "Generating Release file..."
_size() { stat -c%s "$1"; }
_md5() { md5sum "$1" | awk '{print $1}'; }
_sha256() { sha256sum "$1" | awk '{print $1}'; }

PKG_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages"
PKG_GZ_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages.gz"
PKG_I386_PATH="dists/${SUITE}/main/binary-i386/Packages"
PKG_I386_GZ_PATH="dists/${SUITE}/main/binary-i386/Packages.gz"

cat >"${APT_ROOT}/dists/${SUITE}/Release" <<EOF
Origin: kldload Darksite
Label: kldload
Suite: ${SUITE}
Codename: ${SUITE}
Architectures: ${ARCH} i386
Components: main
Description: kldload offline Debian APT repository
Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')
MD5Sum:
 $(_md5 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_md5 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
 $(_md5 "${APT_ROOT}/${PKG_I386_PATH}") $(_size "${APT_ROOT}/${PKG_I386_PATH}") main/binary-i386/Packages
 $(_md5 "${APT_ROOT}/${PKG_I386_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_I386_GZ_PATH}") main/binary-i386/Packages.gz
SHA256:
 $(_sha256 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_sha256 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
 $(_sha256 "${APT_ROOT}/${PKG_I386_PATH}") $(_size "${APT_ROOT}/${PKG_I386_PATH}") main/binary-i386/Packages
 $(_sha256 "${APT_ROOT}/${PKG_I386_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_I386_GZ_PATH}") main/binary-i386/Packages.gz
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
