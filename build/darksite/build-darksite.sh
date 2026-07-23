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
# CentOS Stream / Rocky bootstrap default. As of 2026-07-23 this builds a REAL
# EL10 base mirror: explicit CentOS Stream BaseOS/AppStream/CRB + zfs 2.3 EL +
# Docker CE + Kubernetes repo definitions in a private reposdir (the fedora:44
# builder has no EL repos of its own — the old host-repo approach resolved
# --releasever 10 to the 2008 "Fedora 10" archive and shipped 0 RPMs). RHEL
# proper still needs entitled CDN repos at install time; centos/rocky install
# offline from this mirror. Override with RELEASE=9 for the legacy EL9 set
# (NB: the zfs 2.3 line and Stream 9 EOL status are untested there).
RELEASE="${RELEASE:-10}"
DARKSITE_ROOT="${DARKSITE_ROOT:-/build/live-build/config/includes.chroot/root/darksite}"
REPO_DIR="${DARKSITE_ROOT}/rpm"

log() { printf '[%s] [darksite] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

mkdir -p "${REPO_DIR}"

# ─── EL repo definitions (self-contained reposdir) ──────────────────────────
# The builder is Fedora 44 with NO EL repos, and the old approach (install
# zfs-release rpm + dnf config-manager on the HOST) was triply broken: dnf5
# dropped `config-manager --add-repo`, the zfs-release repo file expands
# $releasever to 44, and — fatally — the download below ran against the
# host's Fedora repos, which `--releasever 10` resolves to the 2008 "Fedora
# 10" archive. Result: the EL darksite shipped 0 RPMs behind a WARNING since
# the fedora:44 builder cutover (root-caused 2026-07-23).
# Fix: a private reposdir holding EXPLICIT CentOS Stream ${RELEASE} BaseOS/
# AppStream/CRB + zfs 2.3 EL + Docker CE + Kubernetes definitions; the
# download runs with reposdir= pointed here so the host's repos are never
# consulted. gpgcheck=0: this is a download-only mirror build (dnf download
# does not verify signatures either way); target-side install policy owns
# verification. All six repomd.xml URLs probed 200 on 2026-07-23.
K8S_MINOR="${K8S_MINOR:-v1.32}"
REPO_DEFS="$(mktemp -d)"
trap 'rm -rf "$REPO_DEFS"' EXIT
cat >"${REPO_DEFS}/el-darksite.repo" <<EOF
[el-baseos]
name=CentOS Stream ${RELEASE} - BaseOS
baseurl=https://mirror.stream.centos.org/${RELEASE}-stream/BaseOS/${ARCH}/os/
enabled=1
gpgcheck=0

[el-appstream]
name=CentOS Stream ${RELEASE} - AppStream
baseurl=https://mirror.stream.centos.org/${RELEASE}-stream/AppStream/${ARCH}/os/
enabled=1
gpgcheck=0

[el-crb]
name=CentOS Stream ${RELEASE} - CRB
baseurl=https://mirror.stream.centos.org/${RELEASE}-stream/CRB/${ARCH}/os/
enabled=1
gpgcheck=0

[el-zfs]
name=OpenZFS 2.3 for EL${RELEASE}
baseurl=http://download.zfsonlinux.org/2.3/epel/${RELEASE}/${ARCH}/
enabled=1
gpgcheck=0

[el-docker-ce]
name=Docker CE Stable - EL${RELEASE}
baseurl=https://download.docker.com/linux/centos/${RELEASE}/${ARCH}/stable/
enabled=1
gpgcheck=0

[el-kubernetes]
name=Kubernetes ${K8S_MINOR}
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=0
EOF

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

# ─── Availability pre-filter ─────────────────────────────────────────────────
# dnf5's `download` is all-or-nothing with no --skip-broken: ONE package name
# that doesn't exist in EL (the sets are shared with Fedora; first offender
# found: gnupg2-minimal) zeroes the whole mirror. Same fix as the fedora
# builder: repoquery-test each name against the EL repos and download only
# what exists, logging every skip so a load-bearing miss is visible.
declare -a PKGS_AVAILABLE=()
declare -a PKGS_SKIPPED=()
for _p in "${PKGS_FINAL[@]}"; do
    if dnf -q repoquery --setopt=reposdir="${REPO_DEFS}" \
        --releasever "${RELEASE}" --arch "${ARCH}" --arch noarch \
        --qf '%{name}' "$_p" 2>/dev/null | grep -q .; then
        PKGS_AVAILABLE+=("$_p")
    else
        PKGS_SKIPPED+=("$_p")
    fi
done
if [[ ${#PKGS_SKIPPED[@]} -gt 0 ]]; then
    log "Skipping ${#PKGS_SKIPPED[@]} names not present in EL${RELEASE} repos: ${PKGS_SKIPPED[*]}"
fi
log "Downloading ${#PKGS_AVAILABLE[@]} available packages (with deps) to ${REPO_DIR}..."

# dnf5 rejects the dnf4 comma syntax --arch "x86_64,noarch" outright
# ("Unsupported architecture") — the whole download died and the WARNING
# below made an EMPTY darksite look like a partial one (0 RPMs, found
# 2026-07-23). Pass --arch twice, same fix as build-darksite-fedora.sh.
# NB: no --skip-broken — dnf5's `download` rejects it as an unknown argument
# (exits before downloading anything; second dnf5 incompatibility found here
# 2026-07-23, after the --arch comma syntax). The transaction is
# all-or-nothing: an unresolvable package fails the whole download, which
# the RPM-count gate below turns into a hard build failure.
dnf download --resolve --alldeps --destdir "${REPO_DIR}" \
    --setopt=reposdir="${REPO_DEFS}" \
    --releasever "${RELEASE}" --arch "${ARCH}" --arch noarch \
    "${PKGS_AVAILABLE[@]}" 2>&1 | tail -10 || log "WARNING: download reported errors — count gate below decides"

log "Creating repo metadata..."
createrepo_c "${REPO_DIR}"

# Hard gate: this mirror shipped 0 RPMs behind a WARNING for months (three
# stacked failures, root-caused 2026-07-23). An empty or near-empty EL
# darksite must kill the build, not decorate the log — the 160-package set
# with deps resolves to several hundred RPMs when the repos are healthy.
_el_count=$(find "${REPO_DIR}" -name '*.rpm' | wc -l)
log "Darksite repo ready: ${REPO_DIR}"
log "RPM count: ${_el_count}"
if [[ "${_el_count}" -lt 100 ]]; then
    log "ERROR: EL darksite produced only ${_el_count} RPMs — expected hundreds. See dnf output above." >&2
    exit 1
fi
