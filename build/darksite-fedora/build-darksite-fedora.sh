#!/usr/bin/env bash
set -euo pipefail

# build-darksite-fedora.sh — Fedora RPM darksite builder
# Runs inside a fedora:RELEASE container (default: fedora:44). Downloads all
# RPMs needed for Fedora offline installs + creates a createrepo repo.
# Output goes to /output/rpm/, which the caller mounts to
# live-build/darksite-fedora-cache/rpm/ on the host.
#
# Package lists: fedora-specific sets override EL sets with the same basename.
# If a fedora-specific set is missing, we fall back to the EL set — the two
# RPM ecosystems share most package names, and --skip-broken handles divergence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR_FED="${PKG_SETS_DIR_FED:-${SCRIPT_DIR}/config/package-sets}"
PKG_SETS_DIR_EL="${PKG_SETS_DIR_EL:-/darksite-el/config/package-sets}"

ARCH="${ARCH:-x86_64}"
RELEASE="${RELEASE:-44}"
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
REPO_DIR="${DARKSITE_OUT}/rpm"

log() { printf '[%s] [darksite-fed] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

mkdir -p "${REPO_DIR}"

# Core tooling — fedora base image doesn't ship createrepo_c or dnf-plugins-core.
log "Installing build tooling (createrepo_c, dnf-plugins-core)..."
dnf install -y --setopt=install_weak_deps=False createrepo_c dnf-plugins-core >/dev/null 2>&1 ||
    log "WARNING: could not install createrepo_c — repo metadata step will fail"

# Enable RPMFusion free + nonfree.
#   free    — ZFS-adjacent, multimedia codecs, ffmpeg with full codec list
#   nonfree — akmod-nvidia (the canonical Fedora NVIDIA driver path; NVIDIA's
#             own CUDA repo lags Fedora releases by 6-12 months and serves
#             404 for fedora44 as of 2026-05-13. RPM Fusion is the only
#             reliable source of akmod-nvidia for current Fedora.)
if ! rpm -q rpmfusion-free-release 2>/dev/null >/dev/null; then
    log "Adding RPMFusion free repo..."
    dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${RELEASE}.noarch.rpm" 2>/dev/null ||
        log "NOTE: RPMFusion free release for fc${RELEASE} not available — may limit package coverage"
fi
if ! rpm -q rpmfusion-nonfree-release 2>/dev/null >/dev/null; then
    log "Adding RPMFusion nonfree repo (for akmod-nvidia)..."
    dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${RELEASE}.noarch.rpm" 2>/dev/null ||
        log "NOTE: RPMFusion nonfree release for fc${RELEASE} not available — NVIDIA darksite path unavailable"
fi

# NVIDIA container toolkit repo (distro-agnostic, always current, no version lag).
# Used for GPU passthrough into pods on the K8s template. Separate from the
# CUDA driver repo (which is the unreliable one). This one just ships
# userspace tooling: nvidia-container-runtime + libnvidia-container, both
# of which CRI-O / containerd hook into to mount /dev/nvidia* into containers.
if [[ ! -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then
    log "Adding NVIDIA Container Toolkit repo (distro-agnostic)..."
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        >/etc/yum.repos.d/nvidia-container-toolkit.repo 2>/dev/null ||
        log "NOTE: could not fetch nvidia-container-toolkit.repo — GPU-in-container path will fall back to internet at install time"
fi

# Add OpenZFS for Fedora. As of 2026-06-12 the 2.4 line ships OpenZFS 2.4.3
# for both fc43 and fc44 (cap raised to kernel-uname-r > 7.0.999), so the
# mirror now carries a ZFS that builds against F44's native 7.0.x kernel — no
# more 6.19 cap. The zfs-release *config* RPM is still only published for fc43
# (none for fc44 yet), so we try fc${RELEASE} first then fall back to fc43;
# its repo path resolves to the 2.4.3 packages either way. zfs-dkms is noarch
# source — DKMS rebuilds the kmod against whatever target kernel is installed.
if ! rpm -q zfs-release 2>/dev/null >/dev/null; then
    log "Adding OpenZFS repo for Fedora ${RELEASE} (with fc43 bridge fallback)..."
    _zfsrel_ok=0
    for _rel in "${RELEASE}" 43; do
        for _rev in 3-0 2-10 2-9 2-8 2-7 2-5 2-4 2-3; do
            # IMPORTANT: --setopt=install_weak_deps=False is load-bearing.
            # zfs-release-2-3.fc43 has a `Recommends: zfs` that triggers
            # autoinstall of zfs+zfs-dkms when weak deps are on (default).
            # zfs-dkms-2.4.1.fc43 carries `Conflicts: kernel-uname-r > 6.19.999`
            # so when Fedora 44 updates to kernel 7.0.x (which it did 2026-05-07,
            # right when matrix #4 went red), this dnf invocation fails the
            # whole build — even though we only wanted the repo metadata, not
            # the packages. We pull zfs at darksite-download time via the
            # explicit PKGS_AVAILABLE list, not via Recommends from the repo
            # config RPM. Without this flag, every fresh F44 build fails.
            if dnf install -y --setopt=install_weak_deps=False \
                "https://zfsonlinux.org/fedora/zfs-release-${_rev}.fc${_rel}.noarch.rpm" 2>/dev/null; then
                log "OpenZFS repo enabled via zfs-release-${_rev}.fc${_rel}"
                _zfsrel_ok=1
                break 2
            fi
        done
    done
    [[ "$_zfsrel_ok" == "1" ]] ||
        log "NOTE: no zfs-release RPM available for fc${RELEASE} or fc43 — target will DKMS-build ZFS from source"
fi

# Add Kubernetes repo (pkgs.k8s.io)
K8S_MINOR="${K8S_MINOR:-v1.32}"
cat >/etc/yum.repos.d/kubernetes.repo <<REPOEOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
REPOEOF

# Add Docker CE (for containerd.io) — fedora-specific repo file
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    log "Adding Docker CE repo..."
    dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null ||
        dnf config-manager --add-repo=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null ||
        log "WARNING: could not add Docker CE repo — containerd.io may be missing"
fi

# ---------------------------------------------------------------------------
# Read package sets. Prefer fedora-specific, fall back to EL-shared.
# ---------------------------------------------------------------------------
declare -a PACKAGES=()

read_package_set() {
    local name="$1"
    local file="${PKG_SETS_DIR_FED}/${name}.txt"
    if [[ ! -f "$file" ]]; then
        file="${PKG_SETS_DIR_EL}/${name}.txt"
    fi
    if [[ ! -f "$file" ]]; then
        log "Package set not found (skipping): $name"
        return 0
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PACKAGES+=("$line")
    done <"$file"
    log "Loaded package set: $name (from $(dirname "$file" | xargs basename))"
}

read_package_set "target-base"
read_package_set "target-server"
read_package_set "target-desktop"
read_package_set "target-kubernetes"
read_package_set "target-nvidia"

# Fedora-specific additions (DKMS toolchain + ZFS build deps + Fedora-
# namespace replacements for EL-only names). This set is only looked up
# in the fedora-specific dir — no EL fallback, it's a fedora add-on.
_fed_extras_file="${PKG_SETS_DIR_FED}/target-fedora-extras.txt"
if [[ -f "$_fed_extras_file" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PACKAGES+=("$line")
    done <"$_fed_extras_file"
    log "Loaded fedora extras: target-fedora-extras ($(grep -cvE '^\s*(#|$)' "$_fed_extras_file") entries)"
fi

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Total unique packages (requested): ${#PKGS_FINAL[@]}"

# Prime metadata caches — dnf5 (Fedora 40+) doesn't auto-cache on first
# download the way dnf4 does.
dnf makecache --refresh 2>&1 | tail -5 || log "WARNING: dnf makecache had issues (continuing)"

# Filter to packages that actually exist in the enabled repos. dnf5 dropped
# --skip-broken from the `download` subcommand, so we pre-filter instead.
# Any names that don't resolve (e.g. EL-only packages like gnupg2-minimal
# or grub2-efi-x64 vs Fedora's grub2-efi-x64-modules) are dropped here.
log "Pre-filtering package list against available repos..."
declare -a PKGS_AVAILABLE=()
declare -a PKGS_MISSING=()
for _p in "${PKGS_FINAL[@]}"; do
    if dnf repoquery --latest-limit=1 --releasever="${RELEASE}" \
        --arch="${ARCH},noarch" --qf '%{name}' "$_p" 2>/dev/null | grep -q .; then
        PKGS_AVAILABLE+=("$_p")
    else
        PKGS_MISSING+=("$_p")
    fi
done
log "Available: ${#PKGS_AVAILABLE[@]}   Missing: ${#PKGS_MISSING[@]}"
if [[ "${#PKGS_MISSING[@]}" -gt 0 ]]; then
    log "Missing from Fedora ${RELEASE} repos (skipping):"
    printf '    %s\n' "${PKGS_MISSING[@]}" >&2
fi

if [[ "${#PKGS_AVAILABLE[@]}" -eq 0 ]]; then
    log "ERROR: no packages resolved — something is wrong with repo config" >&2
    exit 1
fi

log "Downloading ${#PKGS_AVAILABLE[@]} packages (with deps) for Fedora ${RELEASE} to ${REPO_DIR}..."

# dnf5 rejects comma syntax; pass --arch twice. Capture stderr so failures
# surface in the build log instead of being swallowed.
_dl_log="$(mktemp)"
if ! dnf download --resolve --alldeps --destdir "${REPO_DIR}" \
    --releasever "${RELEASE}" --arch "${ARCH}" --arch noarch \
    "${PKGS_AVAILABLE[@]}" >"${_dl_log}" 2>&1; then
    log "WARNING: dnf download exited non-zero — last 40 lines:"
    tail -40 "${_dl_log}" | sed 's/^/    /' >&2
fi
tail -5 "${_dl_log}" | sed 's/^/    /' >&2
rm -f "${_dl_log}"

log "Creating repo metadata..."
createrepo_c "${REPO_DIR}"

_rpm_count=$(find "${REPO_DIR}" -name '*.rpm' | wc -l)
log "Fedora darksite repo ready: ${REPO_DIR}"
log "RPM count: ${_rpm_count}"
if [[ "${_rpm_count}" -lt 50 ]]; then
    log "ERROR: fedora darksite produced only ${_rpm_count} RPMs — expected ≥50. Investigate dnf output above." >&2
    exit 1
fi
