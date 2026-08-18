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
    --exclude='kernel*-7.[1-9]*' \
    "${PKGS_AVAILABLE[@]}" >"${_dl_log}" 2>&1; then
    log "WARNING: dnf download exited non-zero — last 40 lines:"
    tail -40 "${_dl_log}" | sed 's/^/    /' >&2
fi
tail -5 "${_dl_log}" | sed 's/^/    /' >&2
rm -f "${_dl_log}"

# ── Boolean/rich-dep closure (what `download --resolve` silently skips) ──────
# `dnf download --resolve --alldeps` follows HARD deps but NOT rich `(X if Y)`
# deps, so the -selinux companions (passt-selinux, smartmontools-selinux,
# swtpm-selinux, container-selinux's chain, ...) get missed — and one such gap
# makes the whole OFFLINE install transaction unsatisfiable (the F44 zfs pass-3
# brick, 2026-06-13). A real install RESOLUTION does follow rich deps, so we
# resolve the realistic desktop install set with `--downloadonly` (auto-pulls
# every boolean companion) and harvest the RPMs into the mirror. Scope = base +
# server + desktop + fedora-extras (+ zfs DKMS trio, kernel, KVM optionals).
# kubernetes and nvidia are separate profiles whose offline closures (grafana-
# selinux, akmod→akmods→rpm-build build chain) are tracked separately — they
# must not block a desktop ISO.
declare -A _avail_map=()
for _a in "${PKGS_AVAILABLE[@]}"; do _avail_map["$_a"]=1; done
declare -a _closure_set=()
for _cs in target-base target-server target-desktop target-fedora-extras; do
    _cf="${PKG_SETS_DIR_FED}/${_cs}.txt"
    [[ -f "$_cf" ]] || _cf="${PKG_SETS_DIR_EL}/${_cs}.txt"
    [[ -f "$_cf" ]] || continue
    while IFS= read -r _cl; do
        [[ "$_cl" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${_cl//[[:space:]]/}" ]] && continue
        [[ -n "${_avail_map[$_cl]:-}" ]] && _closure_set+=("$_cl")
    done <"$_cf"
done
_closure_set+=(kernel-core kernel-devel zfs zfs-dkms zfs-dracut
    qemu-kvm libvirt-daemon-driver-qemu libvirt-daemon swtpm swtpm-tools)
log "Boolean-dep closure: downloadonly-resolving ${#_closure_set[@]} desktop-set packages to pull rich-dep companions..."
_clcache="$(mktemp -d)"
_clroot="$(mktemp -d)"
# --use-host-config: resolve against the BUILDER's repos (fedora/updates/zfs/…),
# not the empty installroot — without it dnf5 finds zero repos and downloads
# nothing ("No matching repositories for *"). That was why the closure harvested
# 0 and the gate kept failing.
dnf install --installroot="${_clroot}" --use-host-config \
    --releasever="${RELEASE}" --forcearch="${ARCH}" \
    --exclude='kernel*-7.[1-9]*' \
    --setopt=cachedir="${_clcache}" --setopt=keepcache=1 --downloadonly --nogpgcheck -y \
    "${_closure_set[@]}" >"${_clcache}.log" 2>&1 || {
    log "WARNING: downloadonly closure exited non-zero — tail:"
    tail -25 "${_clcache}.log" | sed 's/^/    /' >&2
}
_harvested=0
while IFS= read -r _r; do
    cp -n "$_r" "${REPO_DIR}/" 2>/dev/null && _harvested=$((_harvested + 1))
done < <(find "${_clcache}" -name '*.rpm')
log "Boolean-dep closure: harvested ${_harvested} additional RPMs into the mirror"
rm -rf "${_clcache}" "${_clroot}" "${_clcache}.log"

# ─── Koji kernel pin injection ──────────────────────────────────────────────
# F44's updates repo pruned 7.0.x when 7.1.4 landed, and zfs-dkms 2.4.3 caps
# at kernel 7.0.999 — with the 7.[1-9] excludes above, plain resolution would
# capture the GA 6.19 kernel. Inject the boot-verified 7.0.14 NVR from koji
# so the mirror serves the same kernel the live ISO pins (builder/build-iso.sh
# KOJI_KERNEL_NVR — keep these two in lockstep). The 6.19 copies pulled by
# dep-resolution stay in the mirror harmlessly; installs pick the highest.
# Hard-fail on any fetch: a mirror silently missing its kernel is the exact
# ghost-install class the gates below exist to kill.
KOJI_KERNEL_NVR="${KOJI_KERNEL_NVR:-7.0.14-201.fc44}"
_koji_base="https://kojipkgs.fedoraproject.org/packages/kernel/${KOJI_KERNEL_NVR%%-*}/${KOJI_KERNEL_NVR#*-}/${ARCH}"
for _ksub in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched; do
    _krpm="${_ksub}-${KOJI_KERNEL_NVR}.${ARCH}.rpm"
    if [[ ! -f "${REPO_DIR}/${_krpm}" ]]; then
        curl -fsSL -o "${REPO_DIR}/${_krpm}" "${_koji_base}/${_krpm}" ||
            {
                log "FATAL: koji fetch failed for ${_krpm} — mirror would ship without its pinned kernel" >&2
                exit 1
            }
    fi
done
log "Koji kernel pin injected: ${KOJI_KERNEL_NVR} (7 subpackages)"

log "Creating repo metadata..."
# ─── Evict superseded RPM versions ───────────────────────────────────────────
#
# `dnf download --resolve` resolves the CURRENT version and writes it, but it
# leaves whatever was already there, so this pool accumulates every version it
# has ever carried. Measured 2026-08-18: the xorg-x11-drv-nvidia stack, xxd and
# zchunk-libs each sat at two versions. That costs ISO space, makes the repo
# metadata advertise builds nothing should install, and means a rebuild is
# never "the darksite as of today" — it is every previous day stacked up.
#
# Runs BEFORE createrepo_c so the metadata describes what actually remains.
# --keep 1 leaves exactly the newest build of each name; repomanage does the
# RPM version comparison, which is not something to hand-roll in shell.
log "Evicting superseded RPM versions..."
_old_count=0
while IFS= read -r _old; do
    [[ -n "$_old" ]] || continue
    log "  evicting (superseded): $(basename "$_old")"
    rm -f "$_old"
    # Counter only — ((x++)) returns non-zero from 0 under set -e.
    ((_old_count++)) || true
done < <(
    # An empty pool, or a dnf too old for `repomanage`, must not abort the
    # build — there is simply nothing to evict in either case.
    dnf repomanage --old --keep 1 "${REPO_DIR}" 2>/dev/null || true
)
log "Evicted ${_old_count} superseded RPM(s)"

createrepo_c "${REPO_DIR}"

_rpm_count=$(find "${REPO_DIR}" -name '*.rpm' | wc -l)
log "Fedora darksite repo ready: ${REPO_DIR}"
log "RPM count: ${_rpm_count}"
if [[ "${_rpm_count}" -lt 50 ]]; then
    log "ERROR: fedora darksite produced only ${_rpm_count} RPMs — expected ≥50. Investigate dnf output above." >&2
    exit 1
fi

# ── Completeness gate ──────────────────────────────────────────────────────
# `dnf download --resolve --alldeps` does NOT follow rich/boolean deps like
# `Requires: (passt-selinux if selinux-policy-targeted)`. So a mirror can look
# complete (createrepo happy, RPM count high) yet be UNSATISFIABLE at offline
# install time — exactly how the F44 zfs pass-3 install aborted "target will not
# boot" (2026-06-13): qemu→passt→passt-selinux fired but passt-selinux was never
# mirrored, poisoning the whole transaction. Catch that class HERE, at mirror
# time, not on the operator's target: dry-run the FULL offline install set
# (incl. the zfs DKMS trio + kernel) against ONLY this darksite and fail loud
# with the unresolved leaves. --assumeno also exits non-zero on a *successful*
# resolve (it declines the prompt), so we judge by the error text, not $?.
log "Completeness gate: resolving the desktop install set against the darksite alone..."
_gate_root="$(mktemp -d)"
_gate_log="$(mktemp)"
# Gate the realistic desktop install set (same scope as the closure pass above),
# NOT the full PKGS_AVAILABLE union — that union is intentionally un-installable
# in one transaction (nvidia akmods + every profile's packages together), which
# would be a false positive. kubernetes/nvidia get their own validation.
dnf install --installroot="${_gate_root}" --releasever="${RELEASE}" \
    --forcearch="${ARCH}" --disablerepo='*' \
    --repofrompath="dsgate,file://${REPO_DIR}" --enablerepo=dsgate \
    --nogpgcheck --assumeno \
    "${_closure_set[@]}" \
    >"${_gate_log}" 2>&1 || true
if grep -qiE 'nothing provides|none of the providers can be installed|no match for argument|cannot install the best|conflicting requests|unable to resolve' "${_gate_log}"; then
    log "FATAL: darksite INCOMPLETE — offline install would fail. Unresolved dependencies:" >&2
    grep -iE 'nothing provides|none of the providers can be installed|no match for argument|conflicting requests' \
        "${_gate_log}" | sort -u | sed 's/^/    /' >&2
    rm -rf "${_gate_root}" "${_gate_log}"
    exit 1
fi
log "Completeness gate PASSED — the full offline install set resolves against the darksite alone."
rm -rf "${_gate_root}" "${_gate_log}"
