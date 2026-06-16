#!/usr/bin/env bash
set -euo pipefail

# build-darksite.sh — RPM darksite builder
# Runs inside the builder container. Downloads all RPM packages needed for
# CentOS/RHEL/Rocky/Fedora offline installs and creates a local DNF repo.
# Package lists are in config/package-sets/ (one package name per line).
# Output goes to /root/darksite/rpm/ inside the ISO.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${SCRIPT_DIR}/config/package-sets"
ARCH="${ARCH:-x86_64}"
# EL10 (kernel 6.12, zfs 2.3) is the default EL target — matches RHEL 10 and the
# CentOS Stream / Rocky bootstrap default. NOTE: this builder runs on Fedora 44
# (no CentOS BaseOS/AppStream repos configured), so this pass only captures the
# add-on repos it can reach (zfs el10, k8s, docker). True EL10 base air-gap needs
# CentOS Stream 10 BaseOS/AppStream/CRB repos wired in here first; until then the
# installer's centos/rocky path falls back to network (see bootstrap.sh
# _kld_allow_net). Override with RELEASE=9 for the legacy EL9 set.
RELEASE="${RELEASE:-10}"
DARKSITE_ROOT="${DARKSITE_ROOT:-/build/live-build/config/includes.chroot/root/darksite}"
REPO_DIR="${DARKSITE_ROOT}/rpm"

log() { printf '[%s] [darksite] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

mkdir -p "${REPO_DIR}"

# Add ZFS on Linux repo
if [[ ! -f /etc/yum.repos.d/zfs.repo ]]; then
    log "Adding ZFS on Linux repo..."
    dnf install -y "https://zfsonlinux.org/epel/zfs-release-2-3.el${RELEASE}.noarch.rpm" 2>/dev/null ||
        dnf install -y "https://zfsonlinux.org/epel/zfs-release-2-2.el${RELEASE}.noarch.rpm" 2>/dev/null ||
        log "WARNING: could not add ZFS repo — ZFS packages may be missing"
fi

# Add Kubernetes repo (pkgs.k8s.io)
K8S_MINOR="${K8S_MINOR:-v1.32}"
if [[ ! -f /etc/yum.repos.d/kubernetes.repo ]]; then
    log "Adding Kubernetes repo (${K8S_MINOR})..."
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
EOF
fi

# Add containerd repo (Docker CE for containerd.io)
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    log "Adding Docker CE repo (for containerd.io)..."
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null ||
        log "WARNING: could not add Docker CE repo — containerd.io may be missing"
fi

# Read package sets
declare -a PACKAGES=()
read_package_set() {
    local file="${PKG_SETS_DIR}/${1}.txt"
    [[ -f "$file" ]] || {
        log "Package set not found (skipping): $file"
        return 0
    }
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PACKAGES+=("$line")
    done <"$file"
    log "Loaded package set: $1 ($(wc -l <"$file") entries)"
}

read_package_set "target-base"
read_package_set "target-server"
read_package_set "target-desktop"
read_package_set "target-kubernetes"

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Total unique packages: ${#PKGS_FINAL[@]}"
log "Downloading RPMs to ${REPO_DIR}..."

dnf download --resolve --alldeps --destdir "${REPO_DIR}" \
    --releasever "${RELEASE}" --arch "${ARCH},noarch" \
    --skip-broken \
    "${PKGS_FINAL[@]}" 2>&1 | tail -10 || log "WARNING: some packages could not be downloaded"

log "Creating repo metadata..."
createrepo_c "${REPO_DIR}"

log "Darksite repo ready: ${REPO_DIR}"
log "RPM count: $(find "${REPO_DIR}" -name '*.rpm' | wc -l)"
