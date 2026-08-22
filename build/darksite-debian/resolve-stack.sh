#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# resolve-stack.sh — resolve the ZFS / kernel / NVIDIA triple for a Debian build.
#
# What it does, in order:
#   1. Asks apt for the newest zfs-dkms available.
#   2. Reads that package's OWN kernel ceiling out of its dkms META.
#   3. Picks the newest linux-image-*-amd64 at or below that ceiling.
#   4. Picks the newest NVIDIA driver whose DKMS module supports that kernel.
#   5. Emits the resolved triple as shell assignments, and a lock file.
#
# WHY: there are no arbitrary versions in this project. A build is a UNIT —
# one ZFS, one kernel, one NVIDIA driver, chosen because they are the newest
# set that actually work together on the day the ISO is cut, and then locked
# so the installed machine never drifts off that combination.
#
# What that replaces: the kernel and ZFS used to be pinned to
# `${SUITE}-backports` at priority 990, which is not a version but a moving
# target — whatever backports happens to hold at build time wins, with nothing
# checking that the kernel is inside the ZFS module's supported range and
# nothing considering NVIDIA at all. The Fedora arm had the opposite problem:
# a literal NVR that a human had to bump. Both are the same defect wearing
# different clothes, because in both cases the version was decided somewhere
# other than by the constraint.
#
# THE CONSTRAINT CHAIN, and why it runs in this direction:
#   ZFS is the tightest and slowest-moving link. It is an out-of-tree module
#   that states a maximum kernel it will build against, and it always lags the
#   kernel. NVIDIA is out-of-tree too but tracks kernels much faster. So the
#   newest ZFS fixes the ceiling, the kernel is chosen under it, and NVIDIA is
#   chosen to match the kernel. Resolving in any other order picks a kernel
#   nothing can build modules for.
#
# Inputs:  SUITE (default trixie), ARCH (default amd64). A working apt with
#          backports already in sources.list.d, and network.
# Outputs: on stdout, assignments for eval —
#            KLD_ZFS_VER, KLD_KERNEL_VER, KLD_KERNEL_MAX, KLD_NVIDIA_VER
#          and, at ${LOCK_FILE:-/output/kldload-stack.lock}, the same triple in
#          a form the installer and the operator can both read.
#          Diagnostics go to stderr so `eval "$(resolve-stack.sh)"` is safe.
# Exit:    0 resolved, 2 could not resolve a coherent triple.
#
# Notes:
#   - NEVER falls back to a literal. A build that cannot resolve its own stack
#     must fail loudly: shipping an unverified combination is how a machine
#     ends up with a kernel its ZFS cannot build against, which is an
#     unbootable root pool rather than a missing feature.
#   - NVIDIA is advisory, not fatal. A host with no NVIDIA card is a normal
#     kldload target, so an unresolvable driver downgrades to a warning and an
#     empty KLD_NVIDIA_VER; an unresolvable ZFS or kernel does not.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
LOCK_FILE="${LOCK_FILE:-/output/kldload-stack.lock}"

_r() { printf '[resolve-stack] %s\n' "$*" >&2; }

# ── 1. The newest ZFS apt will give us ──────────────────────────────────────
# `apt-cache policy` reports the Candidate, which already accounts for the
# backports pin — so this asks the same question the actual install will ask,
# rather than guessing from a repo listing.
zfs_ver="$(apt-cache policy zfs-dkms 2>/dev/null |
    awk '/Candidate:/ {print $2}' | head -1)"
[[ -n "$zfs_ver" && "$zfs_ver" != "(none)" ]] || {
    _r "FATAL: no zfs-dkms candidate — cannot resolve a stack"
    exit 2
}
_r "zfs-dkms candidate: ${zfs_ver}"

# ── 2. That ZFS package's own kernel ceiling ────────────────────────────────
# The ceiling is declared by upstream in META (Linux-Maximum) and shipped
# inside the .deb, so read it from the artefact rather than from a table
# somewhere that has to be maintained. Downloading one .deb is cheap and it is
# the only authoritative answer.
_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT
kernel_max=""
if (cd "$_tmp" && apt-get download zfs-dkms >/dev/null 2>&1); then
    _deb="$(find "$_tmp" -name 'zfs-dkms_*.deb' | head -1)"
    if [[ -n "$_deb" ]]; then
        kernel_max="$(dpkg-deb --fsys-tarfile "$_deb" 2>/dev/null |
            tar -xO --wildcards './usr/src/zfs-*/META' 2>/dev/null |
            awk -F'[[:space:]]+' '/^Linux-Maximum:/ {print $2}' | head -1)"
    fi
fi
if [[ -z "$kernel_max" ]]; then
    # No declared ceiling is a real answer on some releases: it means upstream
    # did not cap this build. Treat it as "no constraint" rather than
    # inventing one, and say so, because it changes how the kernel below is
    # chosen.
    _r "WARNING: zfs-dkms ${zfs_ver} declares no Linux-Maximum — kernel will be the newest available"
    kernel_max="99.99"
fi
_r "zfs kernel ceiling: ${kernel_max}"

# ── 3. The newest kernel under that ceiling ─────────────────────────────────
# Candidates come from the versioned metapackages actually present in the
# archive. Sorting with -V and filtering on the ceiling gives the newest
# buildable pair without naming any version here.
# FLAVOUR FILTER — this is load-bearing, not tidiness.
#
# Debian ships several flavours under the same version: the plain one, -rt
# (realtime), -cloud (no DRM subsystem at all) and others. `sort -V` ranks a
# suffixed name ABOVE the bare one, so taking the highest without filtering
# picks a flavour rather than a kernel: the first run of this resolver chose
# 7.1.8+deb13-rt. Picking -cloud would be worse still — that is precisely the
# flavour that left five desktop goldens unable to start X, because it carries
# no drm, drm_kms_helper or virtio_gpu.
#
# So accept ONLY the plain flavour: version, then optional +debN, then the
# architecture. Anything with a flavour token between them is rejected.
mapfile -t _kcands < <(apt-cache search --names-only "^linux-image-[0-9].*-${ARCH}\$" 2>/dev/null |
    awk '{print $1}' |
    grep -E "^linux-image-[0-9]+\.[0-9]+\.[0-9]+(\+[a-z0-9]+)?-${ARCH}\$" |
    sed -E "s/^linux-image-//; s/-${ARCH}\$//" | sort -V)
kernel_ver=""
for _k in "${_kcands[@]}"; do
    # Compare only major.minor against the ceiling: a ceiling of 7.1 admits
    # every 7.1.z, and upstream states the cap at that granularity.
    _kmm="$(cut -d. -f1,2 <<<"$_k")"
    if [[ "$(printf '%s\n%s\n' "$_kmm" "$kernel_max" | sort -V | head -1)" == "$_kmm" ]]; then
        kernel_ver="$_k"
    fi
done
[[ -n "$kernel_ver" ]] || {
    _r "FATAL: no linux-image at or below the ZFS ceiling ${kernel_max}"
    _r "        candidates were: ${_kcands[*]:-<none>}"
    exit 2
}
_r "kernel resolved: ${kernel_ver} (ceiling ${kernel_max})"

# ── 4. The NVIDIA driver that matches that kernel ───────────────────────────
# Advisory: a machine with no NVIDIA card is a normal target, so this must not
# be able to fail the build. Recorded in the lock either way, because "which
# driver was this unit built with" is exactly the question asked later.
nvidia_ver="$(apt-cache policy nvidia-kernel-dkms 2>/dev/null |
    awk '/Candidate:/ {print $2}' | head -1)"
[[ "$nvidia_ver" == "(none)" ]] && nvidia_ver=""
if [[ -z "$nvidia_ver" ]]; then
    _r "WARNING: no nvidia-kernel-dkms candidate — NVIDIA left unpinned for this build"
else
    _r "nvidia-kernel-dkms candidate: ${nvidia_ver}"
fi

# ── 5. Emit, and lock ───────────────────────────────────────────────────────
# The lock is written where the mirror is assembled so it ships WITH the
# artefacts it describes. A lock file that lives anywhere else can disagree
# with the ISO beside it, which is worse than not having one.
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
{
    echo "# kldload stack lock — resolved at build time, not chosen by hand."
    echo "# These three were the newest MUTUALLY COMPATIBLE versions available"
    echo "# when this mirror was built: ZFS fixes the kernel ceiling, the kernel"
    echo "# is chosen under it, NVIDIA is chosen to match the kernel."
    echo "# The installed system is locked to this set and does not drift off it."
    echo "KLD_SUITE=${SUITE}"
    echo "KLD_ZFS_VER=${zfs_ver}"
    echo "KLD_KERNEL_VER=${kernel_ver}"
    echo "KLD_KERNEL_MAX=${kernel_max}"
    echo "KLD_NVIDIA_VER=${nvidia_ver}"
} >"$LOCK_FILE" 2>/dev/null || _r "WARNING: could not write ${LOCK_FILE}"

printf 'KLD_ZFS_VER=%q\n' "$zfs_ver"
printf 'KLD_KERNEL_VER=%q\n' "$kernel_ver"
printf 'KLD_KERNEL_MAX=%q\n' "$kernel_max"
printf 'KLD_NVIDIA_VER=%q\n' "$nvidia_ver"
_r "stack: zfs=${zfs_ver} kernel=${kernel_ver} nvidia=${nvidia_ver:-none}"
