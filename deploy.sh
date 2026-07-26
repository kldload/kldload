#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — kldloadOS build + deploy pipeline
#
# This is the single entry point for building kldloadOS ISOs and deploying
# them to KVM, Proxmox, or USB. It auto-detects podman or docker and runs
# all heavy work inside containers.
#
# The build pipeline has 5 stages (all containerized):
#   1. Builder image   — CentOS 9 container with lorax, squashfs, xorriso
#   2. Debian darksite — APT mirror for offline Debian installs (cached)
#   3. Ubuntu darksite — APT mirror for offline Ubuntu installs (cached)
#   4. RPM darksite    — built inside the builder container (CentOS/Rocky/RHEL)
#   5. ISO assembly    — rootfs via dnf, ZFS DKMS, darksites, squashfs, EFI, xorriso
#
# Quick reference:
#   ./deploy.sh build                  # incremental build (skips cached darksites)
#   ./deploy.sh clean && ./deploy.sh build   # full rebuild
#   PROFILE=server ./deploy.sh build   # build with a different profile
#
# See "Environment" section in help output for all configurable variables.
# ─────────────────────────────────────────────────────────────────────────────

ROOT="$(dirname "$(realpath "$0")")"

# Source project-level overrides (PROFILE, EDITION, PROXMOX_HOST, etc.)
[[ -f "$ROOT/kldload.env" ]] && source "$ROOT/kldload.env"

# ── Build configuration ──────────────────────────────────────────────────────
# These control what gets built. Override via environment or kldload.env.
PROFILE="${PROFILE:-desktop}"                                   # Install profile: desktop, server, kvm, ai, core
EDITION="${EDITION:-free}"                                      # Edition: free (full) or core (ZFS-only, no tools)
ARCH="${ARCH:-x86_64}"                                          # Target architecture
RELEASE="${RELEASE:-10}"                                        # EL release (CentOS Stream/Rocky/RHEL) — EL10 default
BUILDER_IMAGE="${BUILDER_IMAGE:-kldload-live-builder:latest}"   # Builder container image tag
BUILDER_CONTAINER="${BUILDER_CONTAINER:-kldload-free-build-$$}" # Builder container name (unique per run)
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"             # Where the ISO lands
LOG_DIR="${LOG_DIR:-$ROOT/live-build/logs}"                     # Build logs

# ── Proxmox deployment ───────────────────────────────────────────────────────
# Used by proxmox-deploy. Set in kldload.env or environment.
PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}" # Proxmox host IP
PROXMOX_NODE="${PROXMOX_NODE:-fiend}"         # Proxmox node name
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"      # API token (optional — uses SSH if empty)
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

# ── VM configuration ─────────────────────────────────────────────────────────
# Shared defaults for KVM and Proxmox VMs.
VMID="${VMID:-902}"                # Proxmox VM ID
VM_NAME="${VM_NAME:-kldload-free}" # VM display name
VM_MEMORY="${VM_MEMORY:-16384}"    # RAM in MB
VM_CORES="${VM_CORES:-4}"          # CPU cores
VM_DISK_GB="${VM_DISK_GB:-80}"     # Disk size in GB
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"    # Network bridge
KVM_VMS="${KVM_VMS:-1}"            # Number of KVM test VMs to create

# ── USB burn ─────────────────────────────────────────────────────────────────
USB_DEVICE="${USB_DEVICE:-/dev/sda}"           # Target USB block device
USB_BURN_ON_DEPLOY="${USB_BURN_ON_DEPLOY:-no}" # Auto-burn after full build (yes/no)

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { printf '[%s] [deploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Auto-detect container runtime (podman preferred, docker fallback)
detect_runtime() {
    if command -v podman &>/dev/null; then
        echo podman
    elif command -v docker &>/dev/null; then
        echo docker
    else die "No container runtime found (need docker or podman)"; fi
}

# Find the most recently built ISO in the output directory
latest_iso() {
    find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -1 | cut -d' ' -f2-
}

# ─────────────────────────────────────────────────────────────────────────────
# Build commands
# ─────────────────────────────────────────────────────────────────────────────

# Build the CentOS 9 builder container image.
# This container has all the tools needed to assemble the ISO: lorax,
# squashfs-tools, xorriso, dracut, mtools, dnf, etc.
# Only needs to be rebuilt when builder/Dockerfile changes.
cmd_builder_image() {
    local runtime
    runtime="$(detect_runtime)"
    # aarch64 builds use a separately-tagged builder image so it lives alongside
    # the x86 one in local storage (quay.io/centos/centos:stream9 resolves to
    # whichever arch we pull, but we don't want them clobbering each other).
    local tag="$BUILDER_IMAGE"
    local platform=""
    case "$ARCH" in
    aarch64 | arm64)
        tag="${BUILDER_IMAGE%:*}:aarch64"
        platform="--platform linux/arm64"
        ;;
    *)
        platform="--platform linux/amd64"
        ;;
    esac
    log "Building kldload builder image: $tag (${ARCH})"
    "$runtime" build $platform -t "$tag" -f "$ROOT/builder/Dockerfile" "$ROOT/builder/"
    # Keep BUILDER_IMAGE pointing at the arch-specific tag for the rest of
    # this run so downstream cmd_build picks it up automatically.
    BUILDER_IMAGE="$tag"
    log "Builder image ready: $BUILDER_IMAGE"
}

# Build the Debian APT offline mirror (darksite).
# Runs inside a debian:trixie-slim container to resolve and download all
# packages needed for a Debian 13 install. Cached at live-build/darksite-debian-cache/.
# Slow on first run (~20 min), instant if cache exists.
cmd_build_debian_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    # Darksite cache is arch-scoped — aarch64 and amd64 packages don't mix.
    local darksite_dir
    case "$ARCH" in
    x86_64 | amd64)
        _deb_arch="amd64"
        darksite_dir="$ROOT/live-build/darksite-debian-cache"
        ;;
    aarch64 | arm64)
        _deb_arch="arm64"
        darksite_dir="$ROOT/live-build/darksite-debian-cache-arm64"
        ;;
    *) die "unsupported ARCH=$ARCH" ;;
    esac
    mkdir -p "$darksite_dir"
    log "Building Debian darksite APT mirror (${_deb_arch})..."
    "$runtime" run --rm \
        --platform "linux/${_deb_arch}" \
        -v "$ROOT/build/darksite-debian:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="${_deb_arch}" \
        -e SUITE="trixie" \
        --name "kldload-darksite-deb-$$" \
        debian:trixie-slim \
        bash -c "apt-get update -qq && apt-get install -y -qq dpkg-dev curl >/dev/null 2>&1 && bash /darksite-build/build-darksite-debian.sh"
    log "Debian darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

# Build the Ubuntu APT offline mirror (darksite).
# Same approach as Debian but runs in ubuntu:noble. Uses the Debian builder
# script with Ubuntu-specific package sets. Needs universe component for ZFS.
# Cached at live-build/darksite-ubuntu-cache/.
cmd_build_ubuntu_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir
    case "$ARCH" in
    x86_64 | amd64)
        _deb_arch="amd64"
        darksite_dir="$ROOT/live-build/darksite-ubuntu-cache"
        ;;
    aarch64 | arm64)
        _deb_arch="arm64"
        darksite_dir="$ROOT/live-build/darksite-ubuntu-cache-arm64"
        ;;
    *) die "unsupported ARCH=$ARCH" ;;
    esac
    mkdir -p "$darksite_dir"
    log "Building Ubuntu darksite APT mirror (${_deb_arch})..."
    "$runtime" run --rm \
        --platform "linux/${_deb_arch}" \
        -v "$ROOT/build/darksite-debian:/darksite-build:z,ro" \
        -v "$ROOT/build/darksite-ubuntu:/darksite-ubuntu:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="${_deb_arch}" \
        -e SUITE="noble" \
        --name "kldload-darksite-ubuntu-$$" \
        ubuntu:noble \
        bash -c "apt-get update -qq && apt-get install -y -qq dpkg-dev curl >/dev/null 2>&1 && PKG_SETS_DIR=/darksite-ubuntu/config/package-sets bash /darksite-build/build-darksite-debian.sh"
    log "Ubuntu darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

# Build the Fedora RPM offline mirror (darksite).
# Runs inside a fedora:<RELEASE> container (default fedora:44) and downloads
# all packages needed for Fedora offline installs. Cached at
# live-build/darksite-fedora-cache/. Slow on first run, incremental after.
cmd_build_fedora_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir
    local _fed_arch
    case "$ARCH" in
    x86_64 | amd64)
        _fed_arch="x86_64"
        darksite_dir="$ROOT/live-build/darksite-fedora-cache"
        ;;
    aarch64 | arm64)
        _fed_arch="aarch64"
        darksite_dir="$ROOT/live-build/darksite-fedora-cache-arm64"
        ;;
    *) die "unsupported ARCH=$ARCH" ;;
    esac
    mkdir -p "$darksite_dir"
    local fed_release="${FEDORA_RELEASE:-44}"
    log "Building Fedora ${fed_release} darksite RPM mirror (${_fed_arch})..."
    "$runtime" run --rm \
        --platform "linux/amd64" \
        -v "$ROOT/build/darksite-fedora:/darksite-build:z,ro" \
        -v "$ROOT/build/darksite:/darksite-el:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e ARCH="${_fed_arch}" \
        -e RELEASE="${fed_release}" \
        -e K8S_MINOR="${K8S_MINOR:-v1.32}" \
        --name "kldload-darksite-fedora-$$" \
        "registry.fedoraproject.org/fedora:${fed_release}" \
        bash /darksite-build/build-darksite-fedora.sh
    log "Fedora darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

# Build the Ollama model darksite. Pulls the LLM weights into a host
# cache so every ISO ships Bob chat-ready without an internet roundtrip.
# Default model set via OLLAMA_MODELS (comma-sep); adds ~5GB per model.
cmd_build_ollama_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-ollama-cache"
    mkdir -p "$darksite_dir"
    # Bake qwen2.5:14b only. It's strictly better than llama3.1:8b at
    # tool calling + reasoning, and one model keeps the ISO ~5 GB smaller.
    # Users with weaker GPUs can manually `ollama pull llama3.1:8b` post-
    # install if they prefer the smaller model. Override with
    # OLLAMA_MODELS=... to bake anything else.
    local models="${OLLAMA_MODELS:-qwen2.5:14b}"
    log "Building Ollama model darksite (models=${models})..."
    "$runtime" run --rm \
        --platform linux/amd64 \
        -v "$ROOT/build/darksite-ollama:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e OLLAMA_MODELS="${models}" \
        --entrypoint bash \
        --name "kldload-darksite-ollama-$$" \
        docker.io/ollama/ollama:latest \
        /darksite-build/build-darksite-ollama.sh
    log "Ollama darksite ready: $(du -sh "$darksite_dir" 2>/dev/null | cut -f1)"
}

# Build the AI knowledge base for the local assistant.
# Scrapes kldload-web HTML pages to text and OCRs the PDF manual.
# Output goes to the ISO at /usr/local/share/kldload-ai/.
cmd_build_ai_docs() {
    local ai_dir="$ROOT/live-build/config/includes.chroot/usr/local/share/kldload-ai"
    local web_dir="${KLDLOAD_WEB_DIR:-/root/kldload-web}"
    mkdir -p "$ai_dir"

    log "Building AI knowledge base..."

    # Scrape kldload-web HTML to plain text
    if [[ -d "$web_dir" ]]; then
        log "Scraping ${web_dir} HTML pages..."
        local _docs="$ai_dir/kldload-docs.txt"
        : >"$_docs"
        find "$web_dir" -name '*.html' -not -path '*node_modules*' -not -path '*.git*' -not -path '*assets*' | sort | while read -r _f; do
            local _rel="${_f#${web_dir}/}"
            echo "=== ${_rel} ===" >>"$_docs"
            perl -0777 -pe 's/<script[^>]*>.*?<\/script>//gsi; s/<style[^>]*>.*?<\/style>//gsi; s/<[^>]+>//g; s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&mdash;/—/g; s/&ndash;/–/g; s/&rsquo;/'"'"'/g; s/&lsquo;/'"'"'/g; s/&rdquo;/"/g; s/&ldquo;/"/g; s/&rarr;/→/g; s/&bull;/•/g; s/&#\d+;//g; s/^\s*$//gm' "$_f" >>"$_docs" 2>/dev/null
            echo "" >>"$_docs"
        done
        local _pages _size
        _pages=$(grep -c '^===' "$_docs")
        _size=$(du -sh "$_docs" | cut -f1)
        log "Site scrape: ${_pages} pages, ${_size}"
    else
        log "WARNING: kldload-web not found at ${web_dir} — skipping site scrape"
    fi

    # OCR the PDF manual if available
    local _pdf
    _pdf=$(ls "$web_dir"/kldloadOS-documentation-*.pdf 2>/dev/null | sort -V | tail -1)
    if [[ -n "$_pdf" ]] && command -v ocrmypdf >/dev/null 2>&1; then
        log "OCR'ing $(basename "$_pdf")..."
        ocrmypdf --force-ocr "$_pdf" /tmp/kldload-docs-ocr.pdf 2>&1 | tail -3
        pdftotext /tmp/kldload-docs-ocr.pdf "$ai_dir/kldload-manual.txt" 2>&1
        rm -f /tmp/kldload-docs-ocr.pdf
        local _lines
        _lines=$(wc -l <"$ai_dir/kldload-manual.txt")
        log "PDF OCR: ${_lines} lines -> kldload-manual.txt"
    elif [[ -n "$_pdf" ]]; then
        log "No ocrmypdf — trying pdftotext directly on $(basename "$_pdf")..."
        pdftotext "$_pdf" "$ai_dir/kldload-manual.txt" 2>&1
        log "PDF text: $(wc -l <"$ai_dir/kldload-manual.txt") lines"
    else
        log "No PDF manual found — skipping"
    fi

    log "AI docs ready: $(du -sh "$ai_dir" | cut -f1)"
    ls -lh "$ai_dir/"
}

# Build the Bob AI appliance ISO.
# Self-contained live USB: boots into Ollama + Open WebUI + local LLM.
# No install step — just boot and chat.
cmd_build_ai_appliance() {
    log "Bob live mode: AI assistant starts on boot"
    log "  Boot USB → Ollama + Bob + Open WebUI → Firefox opens → ready to chat"
    BOB_LIVE=1 ISO_NAME_OVERRIDE="bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso" PROFILE=desktop cmd_build
    log "Bob ISO ready: $ROOT/live-build/output/bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso"
}

# Build the kldloadOS ISO.
# This is the main build command. It:
#   1. Builds APT darksites if not cached (Debian + Ubuntu)
#   2. Pre-pulls Kubernetes container images for offline K8s deployment
#   3. Caches the Cilium Helm chart
#   4. Runs build-iso.sh inside the builder container (privileged, for loopback/squashfs)
#   5. Outputs the ISO to live-build/output/
#
# The builder container runs detached to avoid SIGPIPE when stdout fills.
# On completion, the ISO and its SHA256 checksum are written to OUTPUT_DIR.
cmd_build() {
    local runtime
    runtime="$(detect_runtime)"
    # Switch to the arch-specific builder tag if we're not building x86_64,
    # so `./deploy.sh build` "just works" after the builder image is present.
    case "$ARCH" in
    aarch64 | arm64)
        BUILDER_IMAGE="${BUILDER_IMAGE%:*}:aarch64"
        ;;
    esac
    log "Building kldload ISO (PROFILE=$PROFILE EDITION=$EDITION ARCH=$ARCH RELEASE=$RELEASE)"

    # ── Stage 1: APT darksites (Debian + Ubuntu) ─────────────────────────
    # Skip for core edition (no darksites needed — stock distro only)
    if [[ "$EDITION" != "core" ]]; then
        local debian_darksite="$ROOT/live-build/darksite-debian-cache"
        if [[ ! -f "$debian_darksite/apt/dists/trixie/Release" ]]; then
            cmd_build_debian_darksite
        else
            log "Debian darksite cached: $(du -sh "$debian_darksite" | cut -f1)"
        fi

        local ubuntu_darksite="$ROOT/live-build/darksite-ubuntu-cache"
        if [[ ! -f "$ubuntu_darksite/apt/dists/noble/Release" ]]; then
            cmd_build_ubuntu_darksite
        else
            log "Ubuntu darksite cached: $(du -sh "$ubuntu_darksite" | cut -f1)"
        fi

        # Fedora RPM darksite — built in a fedora:<RELEASE> container, cached
        # at live-build/darksite-fedora-cache/. Marker file is the createrepo
        # repomd.xml — its presence means the repo was built successfully.
        local fedora_darksite="$ROOT/live-build/darksite-fedora-cache"
        if [[ ! -f "$fedora_darksite/rpm/repodata/repomd.xml" ]]; then
            cmd_build_fedora_darksite
        else
            log "Fedora darksite cached: $(du -sh "$fedora_darksite" | cut -f1)"
        fi

        # Ollama model darksite — opt-IN as of 1.0.5. By default the ISO
        # ships WITHOUT baked-in LLM weights (saves ~9 GB / ~46% of the
        # ISO). On first boot with Bob enabled, kldload-firstboot falls
        # back to pulling qwen2.5:14b from ollama.com — same model,
        # ~5 min on a typical home connection. Users who need offline
        # AI (air-gapped labs, classified networks) have two options:
        #
        #   1. Build the darksite in: KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1
        #      on the deploy.sh build command — rebuilds the ISO with
        #      the weights embedded (~17 GB total).
        #
        #   2. BYOM (Bring Your Own Models) after install — drop the
        #      Ollama model tree into /root/darksite/ollama/models/ on
        #      the installed target (rsync from a box that already
        #      pulled it, or copy from a pre-populated USB). On next
        #      boot kldload-firstboot detects the directory and
        #      rsyncs it into /srv/ollama/models/ before starting
        #      Ollama — same offline behaviour, no rebuild.
        if [[ "${KLDLOAD_INCLUDE_OLLAMA_DARKSITE:-0}" == "1" ]]; then
            local ollama_darksite="$ROOT/live-build/darksite-ollama-cache"
            if ! ls "$ollama_darksite"/models/manifests/registry.ollama.ai/library/*/* >/dev/null 2>&1; then
                cmd_build_ollama_darksite
            else
                log "Ollama darksite cached: $(du -sh "$ollama_darksite" | cut -f1)"
            fi
        else
            log "Skipping Ollama darksite (opt-in: KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1)"
        fi

        # Arch has no darksite — rolling release, not worth caching.
        log "Note: Arch installs require internet (rolling release, no darksite)"
    else
        log "Core edition — skipping darksites."
    fi

    # ── Stage 2: Kubernetes container images (offline K8s deployment) ─────
    # Pre-pulls all images needed by kubeadm, Cilium, MetalLB, etc.
    # so kube-cluster bootstrap works without internet.
    local k8s_images_dir="$ROOT/live-build/config/includes.chroot/root/darksite/k8s-images"
    local k8s_images_list="$ROOT/build/darksite/k8s-images.txt"
    if [[ -f "$k8s_images_list" ]] && [[ "$EDITION" != "core" ]]; then
        if [[ ! -d "$k8s_images_dir" ]] || [[ "$(find "$k8s_images_dir" -name '*.tar' 2>/dev/null | wc -l)" -eq 0 ]]; then
            log "Pre-pulling Kubernetes + Cilium container images for offline deploy..."
            bash "$ROOT/build/darksite/pull-k8s-images.sh" "$k8s_images_dir"
        else
            log "K8s images cached: $(du -sh "$k8s_images_dir" | cut -f1) ($(ls "$k8s_images_dir"/*.tar 2>/dev/null | wc -l) images)"
        fi
    fi

    # ── Stage 3: Helm charts + Grafana dashboards (all darksite-baked) ───
    # Every helm chart + dashboard the autodeploy path needs has to live
    # on the ISO so first boot works fully offline. Downloads happen HERE
    # at build time, files ship inside /root/darksite/ on the live ISO.
    local helm_cache="$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts"
    local dash_cache="$ROOT/live-build/config/includes.chroot/usr/local/share/klab/grafana-dashboards"
    local k8s_manifests="$ROOT/live-build/config/includes.chroot/root/darksite/k8s-manifests"
    if [[ "$EDITION" != "core" ]]; then
        mkdir -p "$helm_cache" "$dash_cache" "$k8s_manifests"
        # metrics-server YAML — feeds `kubectl top` and the web UI's
        # live CPU/memory overlay on the K8s tab. kube-init applies this
        # after Cilium is up. Offline-first; falls back to upstream URL.
        if [[ ! -f "$k8s_manifests/metrics-server.yaml" ]] && command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" \
                -o "$k8s_manifests/metrics-server.yaml" 2>/dev/null &&
                log "metrics-server manifest cached" ||
                log "WARNING: could not cache metrics-server manifest"
        fi
        # Cilium chart
        if [[ ! -f "$helm_cache/cilium.tgz" ]]; then
            log "Caching Cilium Helm chart..."
            if command -v helm >/dev/null 2>&1; then
                helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
                helm repo update >/dev/null 2>&1 || true
                helm pull cilium/cilium --version "${CILIUM_VERSION:-1.16.5}" -d "$helm_cache" 2>/dev/null &&
                    mv "$helm_cache"/cilium-*.tgz "$helm_cache/cilium.tgz" 2>/dev/null || true
            elif command -v curl >/dev/null 2>&1; then
                curl -fsSL "https://helm.cilium.io/cilium-${CILIUM_VERSION:-1.16.5}.tgz" \
                    -o "$helm_cache/cilium.tgz" 2>/dev/null || log "WARNING: Could not cache Cilium chart"
            fi
            [[ -f "$helm_cache/cilium.tgz" ]] && log "Cilium chart cached: $(du -h "$helm_cache/cilium.tgz" | cut -f1)"
        fi
        # Tetragon chart — Cilium's syscall/process/file eBPF observability.
        # Autodeploy + kube-cluster both install this once the cluster is up.
        # Must be offline-available or the prom scrape + Grafana dashboards
        # sit empty. The build host often has no helm binary (CentOS Stream 9
        # doesn't ship one) so the pre-existing `helm pull` path silently
        # skipped and shipped a broken ISO — prefer curl against the chart's
        # direct URL so this works out of the box.
        if [[ ! -f "$helm_cache/tetragon.tgz" ]]; then
            log "Caching Tetragon Helm chart..."
            if command -v helm >/dev/null 2>&1; then
                helm pull cilium/tetragon -d "$helm_cache" 2>/dev/null &&
                    mv "$helm_cache"/tetragon-*.tgz "$helm_cache/tetragon.tgz" 2>/dev/null || true
            fi
            if [[ ! -f "$helm_cache/tetragon.tgz" ]] && command -v curl >/dev/null 2>&1; then
                # Resolve the latest chart version from the Cilium helm repo
                # index and download the tgz directly — no helm CLI required.
                local _tg_ver
                _tg_ver="$(curl -fsSL --max-time 10 https://helm.cilium.io/index.yaml 2>/dev/null |
                    awk '/^  - name: tetragon$/{f=1;next} f && /version: /{print $2; exit}' |
                    tr -d '\r')"
                if [[ -n "$_tg_ver" ]]; then
                    curl -fsSL --max-time 60 \
                        -o "$helm_cache/tetragon.tgz" \
                        "https://helm.cilium.io/tetragon-${_tg_ver}.tgz" 2>/dev/null ||
                        log "WARNING: Could not download Tetragon chart via curl"
                else
                    log "WARNING: Could not resolve Tetragon chart version from helm.cilium.io"
                fi
            fi
            [[ -f "$helm_cache/tetragon.tgz" ]] &&
                log "Tetragon chart cached: $(du -h "$helm_cache/tetragon.tgz" | cut -f1)" ||
                log "WARNING: Tetragon chart not cached — autodeploy will fall back to online install"
        fi
        # Grafana dashboards (pre-fetched so firstboot never needs internet)
        # 1860  = Node Exporter Full
        # 16611 = Cilium Metrics
        # 16612 = Cilium Policy Verdict
        # 16613 = Hubble Flows
        # Tetragon ships as a bundled JSON at
        # includes.chroot/usr/local/share/klab/grafana-dashboards/tetragon.json
        # — Grafana.com has no Tetragon dashboard under a stable ID.
        for id in 1860 16611 16612 16613; do
            local dash_file="$dash_cache/grafana-${id}.json"
            if [[ ! -f "$dash_file" ]] && command -v curl >/dev/null 2>&1; then
                curl -fsSL "https://grafana.com/api/dashboards/${id}/revisions/latest/download" \
                    -o "$dash_file" 2>/dev/null &&
                    log "Grafana dashboard ${id} cached" ||
                    log "WARNING: Could not cache Grafana dashboard ${id}"
            fi
        done
    fi

    # ── Stage 3.5: Builder image (auto-build if missing) ─────────────────
    # `cmd_build` previously assumed the kldload-live-builder image was
    # already in local storage — a hangover from when the only sensible
    # `./deploy.sh build` invocation came after `builder-image` or `full`.
    # On a clean podman storage (CI, fresh dev host, after `clean`),
    # cmd_build would try `podman run kldload-live-builder:latest`,
    # podman couldn't resolve the bare name (short-name-mode=enforcing,
    # RHEL 10 default), and the run died with:
    #   Error: short-name resolution enforced but cannot prompt without a TTY
    # before the ISO step even started. Build the image inline if it's
    # missing so `./deploy.sh build` works standalone.
    if ! "$runtime" image exists "$BUILDER_IMAGE" 2>/dev/null; then
        log "Builder image $BUILDER_IMAGE not found — building it now"
        cmd_builder_image
    fi

    # ── Stage 4: ISO assembly (runs inside builder container) ────────────
    # The builder container runs build-iso.sh which:
    #   - Bootstraps a CentOS 9 rootfs via dnf --installroot
    #   - Builds ZFS kernel modules via DKMS
    #   - Embeds all darksites (RPM, APT, K8s images, Helm charts)
    #   - Creates squashfs, EFI boot image, and final ISO via xorriso
    #
    # Runs detached to avoid SIGPIPE when stdout pipe fills up.
    # On non-native architectures, pass --platform so podman/docker uses the
    # right container variant. Relies on qemu-user-static + binfmt_misc being
    # registered on the host for cross-arch execution (ships with most distros
    # as qemu-user-binfmt or qemu-user-static packages).
    local _platform=""
    case "$ARCH" in
    x86_64 | amd64) _platform="linux/amd64" ;;
    aarch64 | arm64) _platform="linux/arm64" ;;
    esac
    "$runtime" run -d --privileged \
        --platform "$_platform" \
        -v "$ROOT:/build:z" \
        -e PROFILE="$PROFILE" \
        -e EDITION="$EDITION" \
        -e ARCH="$ARCH" \
        -e RELEASE="$RELEASE" \
        -e ISO_NAME_OVERRIDE="${ISO_NAME_OVERRIDE:-}" \
        -e BOB_LIVE="${BOB_LIVE:-}" \
        -e KLDLOAD_INCLUDE_OLLAMA_DARKSITE="${KLDLOAD_INCLUDE_OLLAMA_DARKSITE:-0}" \
        -e KLDLOAD_ZFS_GIT="${KLDLOAD_ZFS_GIT:-}" \
        -e KLDLOAD_DEBUG_ALLOW="${KLDLOAD_DEBUG_ALLOW:-}" \
        -e KLDLOAD_VERSION="${KLDLOAD_VERSION:-}" \
        --name "$BUILDER_CONTAINER" \
        "$BUILDER_IMAGE" \
        bash /build/builder/build-iso.sh

    log "Build container started — waiting for completion..."
    local _build_start_epoch
    _build_start_epoch="$(date +%s)"
    "$runtime" wait "$BUILDER_CONTAINER" || true
    local _rc
    _rc="$("$runtime" inspect "$BUILDER_CONTAINER" --format '{{.State.ExitCode}}' 2>/dev/null || echo 1)"
    "$runtime" rm "$BUILDER_CONTAINER" 2>/dev/null || true

    local iso
    iso="$(latest_iso)"
    # Stale-ISO guard: previously we accepted ANY iso in output/ as success
    # even when the container exited non-zero — a build that failed in the
    # darksite phase would silently get rebranded as "ISO built" using last
    # week's file. Now we require the ISO mtime to be >= when this build
    # started. Without this, real failures (matrix #4 nightly regression,
    # 2026-05-07) look green and ship broken bits.
    if [[ -n "$iso" ]]; then
        local _iso_mtime
        _iso_mtime="$(stat -c %Y "$iso" 2>/dev/null || echo 0)"
        if ((_iso_mtime < _build_start_epoch)); then
            log "ERROR: build container exited ${_rc} and no fresh ISO produced"
            log "       latest ISO (${iso}) is older than build start — refusing to claim success"
            die "Build failed — see live-build/logs/build-${PROFILE}-${ARCH}-*.log"
        fi
        if [[ "$_rc" != "0" ]]; then
            log "WARNING: build container exited with code ${_rc} but ISO is fresh — continuing"
        fi
        log "ISO built: $iso ($(du -sh "$iso" | cut -f1))"
        sha256sum "$iso" >"${iso}.sha256"
    else
        die "No ISO found after build (container exit code ${_rc})"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Remove build artifacts (chroot, binary staging, ISOs).
# Does NOT remove darksite caches — those are expensive to rebuild.
# To force a full darksite rebuild: rm -rf live-build/darksite-*-cache/
cmd_clean() {
    log "Cleaning build artifacts..."
    rm -rf "$ROOT/live-build/chroot" "$ROOT/live-build/binary" "$ROOT/live-build/.build"
    rm -rf "$OUTPUT_DIR"
    log "Clean complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy commands
# ─────────────────────────────────────────────────────────────────────────────

# Write the latest ISO to a USB drive.
# If USB_DEVICE is not set, auto-detects removable drives.
# Refuses to auto-detect if multiple removable drives are found.
cmd_burn() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found"

    if [[ -z "$USB_DEVICE" ]]; then
        local candidates=()
        # -type b filters to block devices only — without it, a stale regular
        # file at /dev/sda (left by a prior dd when the stick was unplugged)
        # gets picked as a "candidate" and the next burn silently writes 9 GB
        # to a regular file. Real incident, b649 2026-06-08.
        while IFS= read -r dev; do
            local rm_flag
            rm_flag="$(cat "/sys/block/$(basename "$dev")/removable" 2>/dev/null || echo 0)"
            [[ "$rm_flag" == "1" ]] && candidates+=("$dev")
        done < <(find /dev -maxdepth 1 -type b -name 'sd[a-z]' | sort)
        [[ "${#candidates[@]}" -eq 1 ]] || die "Set USB_DEVICE explicitly"
        USB_DEVICE="${candidates[0]}"
    fi

    # HARD GUARD: refuse to write unless the target is a real block device.
    # `oflag=direct` below would also fail for a regular file, but the explicit
    # check makes the failure mode loud and obvious (and protects callers that
    # passed USB_DEVICE in explicitly and bypassed the candidate search).
    [[ -b "$USB_DEVICE" ]] || die "$USB_DEVICE is not a block device — refusing to burn (was the stick unplugged?)"

    log "Burning $iso to $USB_DEVICE..."
    dd if="$iso" of="$USB_DEVICE" bs=4M status=progress oflag=direct conv=fsync
    sync
    log "USB burn complete: $USB_DEVICE"
}

# =============================================================================
# cmd_ship — build → burn → notify, the default release loop.
#
# WHAT IT DOES, IN ORDER:
#   1. Builds the ISO using the standard cmd_build path (honours PROFILE,
#      EDITION, ARCH, RELEASE env vars same as `./deploy.sh build`).
#   2. On build success, burns the resulting ISO to ${USB_DEVICE} via
#      cmd_burn — which itself enforces the block-device guard added after
#      the b649 file-write incident.
#   3. Writes a per-run log under /var/log/kldload-ship/ship-<utc>.log so
#      the build phase, exit code, burn phase, exit code, and notify
#      attempt are all timestamped in one file. Symlinked to
#      /var/log/kldload-ship/latest so `tail -f` always points at the
#      current run.
#   4. Fires a desktop notification when done — notify-send if a session
#      bus is available, else `wall` to broadcast to logged-in users,
#      else stderr + terminal bell. Whichever fires logs which one fired.
#
# WHY:
#   Every interactive cycle today was "build, wait, burn, wait, did it
#   work?" assembled by hand. Encoding that loop as one subcommand
#   removes the room for "I forgot to burn after the build finished" and
#   gives an operator-visible signal when the USB is actually ready.
#
# USAGE:
#   ./deploy.sh ship                  # uses USB_DEVICE (defaults to /dev/sda)
#   USB_DEVICE=/dev/sdb ./deploy.sh ship
#   PROFILE=server ./deploy.sh ship   # ships a server-profile ISO
#
# EXIT STATUS:
#   0   build + burn + notify all succeeded
#   1   build failed (no burn attempted)
#   2   burn failed after a successful build
#
# FILES:
#   /var/log/kldload-ship/ship-<utc>.log  per-run combined log
#   /var/log/kldload-ship/latest          symlink to most recent log
# =============================================================================
cmd_ship() {
    local log_dir=/var/log/kldload-ship
    sudo mkdir -p "$log_dir"
    sudo chown "$(id -un):$(id -gn)" "$log_dir" 2>/dev/null || true

    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local ship_log="${log_dir}/ship-${ts}.log"
    ln -sfn "$ship_log" "${log_dir}/latest"

    log "=== ship start ${ts} ==="
    log "  USB_DEVICE: ${USB_DEVICE}"
    log "  log:        ${ship_log}"
    {
        echo "=== ship start $(date -Is) ==="
        echo "  PROFILE=${PROFILE} EDITION=${EDITION} ARCH=${ARCH} RELEASE=${RELEASE}"
        echo "  USB_DEVICE=${USB_DEVICE}"
    } | tee -a "$ship_log"

    # ── Phase 1: build ──────────────────────────────────────────────────────
    # cmd_build writes its own log via the build container; we tee the
    # deploy-side messages here so the ship log captures the full story
    # without having to chase multiple files.
    {
        echo "=== build phase $(date -Is) ==="
        cmd_build 2>&1
        echo "=== build exit: $? ==="
    } | tee -a "$ship_log"
    local build_rc=${PIPESTATUS[0]}

    if [[ $build_rc -ne 0 ]]; then
        log "ship: build failed (rc=${build_rc}); skipping burn."
        _ship_notify "kldload ship FAILED" "Build returned ${build_rc}. See ${ship_log}." "critical"
        return 1
    fi

    # ── Phase 2: burn ───────────────────────────────────────────────────────
    # cmd_burn enforces the [[ -b "$USB_DEVICE" ]] guard so a missing
    # stick gets a loud refusal rather than a silent file-write (b649).
    {
        echo "=== burn phase $(date -Is) ==="
        sudo "$0" burn 2>&1
        echo "=== burn exit: $? ==="
    } | tee -a "$ship_log"
    local burn_rc=${PIPESTATUS[0]}

    if [[ $burn_rc -ne 0 ]]; then
        log "ship: burn failed (rc=${burn_rc})."
        _ship_notify "kldload ship FAILED at burn" \
            "Build succeeded but burn returned ${burn_rc}. See ${ship_log}." "critical"
        return 2
    fi

    # ── Phase 3: notify + summary ───────────────────────────────────────────
    {
        echo "=== all done $(date -Is) ==="
    } | tee -a "$ship_log"
    log "ship: DONE — ISO built and burned to ${USB_DEVICE}."
    _ship_notify "kldload ship DONE" \
        "USB ${USB_DEVICE} is ready. Build+burn log: ${ship_log}." "normal"
    return 0
}

# _ship_notify — layered notification with graceful fallback.
#
# Tries (in order): notify-send via DBUS, wall broadcast, terminal bell +
# stderr. Whichever path actually fires is logged via log() so a tail of
# the ship log says exactly how the operator was notified.
#
# Args:
#   $1  summary  (one-line title)
#   $2  body     (longer description)
#   $3  urgency  (low|normal|critical) — passed to notify-send when used
_ship_notify() {
    local summary="$1" body="$2" urgency="${3:-normal}"

    # Path 1 — desktop notify-send if we have a session bus AND the binary.
    # Catches the common "operator launched ship from their own terminal"
    # case; notify-send returns 0 when the daemon accepts the toast.
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v notify-send >/dev/null 2>&1; then
        if notify-send -u "$urgency" "$summary" "$body" 2>/dev/null; then
            log "ship: notified via notify-send (urgency=${urgency})"
            return 0
        fi
    fi

    # Path 2 — `wall` broadcasts to all logged-in users. Less polished
    # but works on headless servers, over SSH, and inside a tmux from a
    # systemd one-shot.
    if command -v wall >/dev/null 2>&1; then
        printf '%s\n\n%s\n' "$summary" "$body" | wall 2>/dev/null && {
            log "ship: notified via wall"
            return 0
        }
    fi

    # Path 3 — terminal bell + stderr. Always succeeds; the bell only
    # rings if the terminal's audible-bell is on, but the message is
    # always visible at the end of the log.
    printf '\a' >&2
    echo "NOTIFY: ${summary}: ${body}" >&2
    log "ship: notified via stderr (no notify-send or wall available)"
    return 0
}

# Full rebuild: clean everything, rebuild the builder image, build ISO.
cmd_full() {
    local runtime
    runtime="$(detect_runtime)"
    log "=== FULL: clean + rebuild + build ISO ==="
    cmd_clean
    if "$runtime" image inspect "$BUILDER_IMAGE" &>/dev/null; then
        "$runtime" rmi "$BUILDER_IMAGE" || true
    fi
    cmd_builder_image
    cmd_build
    if [[ "$USB_BURN_ON_DEPLOY" == "yes" ]]; then
        cmd_burn
    fi
    local iso
    iso="$(latest_iso)"
    if [[ -n "$iso" ]]; then
        log ""
        log "USB burn command:"
        log "  dd if=$iso of=/dev/sda bs=4M status=progress oflag=sync conv=fsync && sync"
    fi
    log "=== FULL complete ==="
}

# Deploy ISO to local KVM via virt-install.
# Creates UEFI VMs with virtio disk/network on the default libvirt network.
# Secure Boot is disabled (ZFS modules need MOK enrollment first).
# VNC is enabled for console access.
cmd_kvm_deploy() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run build first"

    cp "$iso" /var/lib/libvirt/images/kldload-free-latest.iso
    chown qemu:qemu /var/lib/libvirt/images/kldload-free-latest.iso

    # Shut down any existing kldload-test VMs first
    for _i in $(seq 1 10); do
        local _existing="kldload-test-${_i}"
        if virsh domstate "$_existing" 2>/dev/null | grep -q running; then
            log "Shutting down ${_existing}..."
            virsh destroy "$_existing" 2>/dev/null || true
        fi
    done

    for _i in $(seq 1 "$KVM_VMS"); do
        local _name="kldload-test-${_i}"
        local _disk="/var/lib/libvirt/images/${_name}.qcow2"

        log "Deploying ${_name}..."
        virsh undefine "$_name" --nvram --remove-all-storage 2>/dev/null || true
        rm -f "$_disk" 2>/dev/null || true

        qemu-img create -f qcow2 "$_disk" "${VM_DISK_GB}G"
        chown qemu:qemu "$_disk"

        # os-variant matches the LIVE env (Fedora 44 since the cutover from
        # CentOS Stream 9). osinfo-db doesn't ship a fedora44 entry yet, so
        # use fedora-unknown — picks correct virtio drivers, clock policy,
        # and memory ballooning defaults for a recent Fedora kernel.
        virt-install --name "$_name" --ram "$VM_MEMORY" --vcpus "$VM_CORES" \
            --disk "path=${_disk},format=qcow2,bus=virtio" \
            --cdrom /var/lib/libvirt/images/kldload-free-latest.iso \
            --os-variant fedora-unknown --network network=default,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
            --noautoconsole

        log "${_name} ready — VNC $(virsh vncdisplay "$_name" 2>/dev/null || echo '?') — DHCP"
    done
}

# Deploy Bob AI appliance to KVM. Creates VM but doesn't start it (--noreboot).
cmd_kvm_deploy_bob() {
    local iso="$ROOT/live-build/output/bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso"
    [[ -f "$iso" ]] || die "Bob ISO not found at $iso — run build-ai-appliance first"

    cp "$iso" /var/lib/libvirt/images/kldload-bob.iso
    chown qemu:qemu /var/lib/libvirt/images/kldload-bob.iso

    local _name="bob-1"
    local _disk="/var/lib/libvirt/images/${_name}.qcow2"

    if virsh domstate "$_name" 2>/dev/null | grep -q running; then
        log "Shutting down ${_name}..."
        virsh destroy "$_name" 2>/dev/null || true
    fi

    log "Deploying ${_name}..."
    virsh undefine "$_name" --nvram --remove-all-storage 2>/dev/null || true
    rm -f "$_disk" 2>/dev/null || true

    qemu-img create -f qcow2 "$_disk" "${VM_DISK_GB}G"
    chown qemu:qemu "$_disk"

    virt-install --name "$_name" --ram "$VM_MEMORY" --vcpus "$VM_CORES" \
        --disk "path=${_disk},format=qcow2,bus=virtio" \
        --cdrom /var/lib/libvirt/images/kldload-bob.iso \
        --os-variant centos-stream9 --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --noautoconsole --noreboot

    log "${_name} ready (off) — VNC $(virsh vncdisplay "$_name" 2>/dev/null || echo '?')"
}

# Deploy ISO to Proxmox via SSH + qm API.
# Uploads ISO, destroys any existing VM with the same VMID, creates a new one.
# VM config: q35 machine, host CPU, TPM 2.0, virtio-scsi, serial console,
# OVMF UEFI, IDE CDROM. Matches the hardware profile that kldloadOS expects.
cmd_proxmox_deploy() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run build first"
    [[ -n "$PROXMOX_HOST" ]] || die "PROXMOX_HOST not set"
    log "Deploying to Proxmox ($PROXMOX_HOST VMID=$VMID)..."
    scp "$iso" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/kldload-free-latest.iso"
    ssh "root@${PROXMOX_HOST}" bash -s "$VMID" "$VM_MEMORY" "$VM_CORES" "$VM_DISK_GB" <<'PVESH'
        VMID="$1" VMEM="$2" VCORES="$3" VDISK="$4"
        qm stop "$VMID" 2>/dev/null; sleep 1
        qm destroy "$VMID" --purge 2>/dev/null; sleep 1
        qm create "$VMID" --name kldload-free --memory "$VMEM" --cores "$VCORES" \
            --sockets 1 --cpu host --machine q35 --ostype l26 --bios ovmf \
            --efidisk0 local-zfs:4,efitype=4m,pre-enrolled-keys=0 \
            --scsihw virtio-scsi-single --scsi0 "local-zfs:${VDISK}" \
            --net0 virtio,bridge=vmbr0 --serial0 socket --agent 1 --vga std \
            --ide2 local:iso/kldload-free-latest.iso,media=cdrom \
            --boot 'order=ide2;scsi0'
        qm set "$VMID" --tpmstate0 local-zfs:4,version=v2.0
        qm start "$VMID"
PVESH
    log "Proxmox VM $VMID started on $PROXMOX_HOST"
}

# Deploy to all targets: KVM + Proxmox, then print USB burn command.
cmd_deploy_all() {
    cmd_kvm_deploy
    cmd_proxmox_deploy
    log ""
    log "Both VMs deployed. USB burn command:"
    local iso
    iso="$(latest_iso)"
    log "  dd if=$iso of=/dev/sda bs=4M status=progress oflag=sync conv=fsync && sync"
}

# ─────────────────────────────────────────────────────────────────────────────
# Command dispatch
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
build) cmd_build ;;
build-ai-appliance) cmd_build_ai_appliance ;;
build-debian-darksite) cmd_build_debian_darksite ;;
build-ubuntu-darksite) cmd_build_ubuntu_darksite ;;
build-fedora-darksite) cmd_build_fedora_darksite ;;
build-ollama-darksite) cmd_build_ollama_darksite ;;
build-k8s-darksite)
    # Build Kubernetes + Cilium offline image cache separately.
    # Normally this runs as part of `build`, but can be triggered
    # independently to pre-cache images before a full build.
    log "Building Kubernetes + Cilium offline darksite..."
    bash "$ROOT/build/darksite/pull-k8s-images.sh" "$ROOT/live-build/config/includes.chroot/root/darksite/k8s-images"
    mkdir -p "$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts"
    if command -v helm >/dev/null 2>&1; then
        helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
        helm repo update >/dev/null 2>&1 || true
        helm pull cilium/cilium --version "${CILIUM_VERSION:-1.16.5}" -d "/tmp/cilium-chart" 2>/dev/null
        mv /tmp/cilium-chart/cilium-*.tgz "$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts/cilium.tgz" 2>/dev/null || true
        rm -rf /tmp/cilium-chart
    fi
    log "K8s darksite ready"
    ;;
build-ai-docs) cmd_build_ai_docs ;;
builder-image) cmd_builder_image ;;
clean) cmd_clean ;;
burn) cmd_burn ;;
ship) cmd_ship ;;
full) cmd_full ;;
kvm-deploy) cmd_kvm_deploy ;;
kvm-deploy-bob) cmd_kvm_deploy_bob ;;
proxmox-deploy) cmd_proxmox_deploy ;;
deploy-all) cmd_deploy_all ;;
smoke-test)
    # Full-loop install smoke test in KVM (boot ISO → headless install
    # → reboot → run tests/smoke-auto.sh on the installed target).
    # Closes the gap between `build` and `tests/smoke-*.sh`.
    shift
    [[ $# -eq 2 ]] || {
        echo "usage: $0 smoke-test <distro> <profile>" >&2
        exit 64
    }
    bash "$ROOT/tests/lifecycle.sh" "$@"
    ;;
smoke-build)
    # Static checks on the just-built ISO (file exists, fresh, sane size).
    bash "$ROOT/tests/smoke-build.sh"
    ;;
help | *)
    cat <<EOF
kldload deploy.sh — build + deploy pipeline for kldloadOS

Usage: ./deploy.sh <command>

Build:
  build                  Build ISO (incremental — uses cached darksites)
  full                   Clean + rebuild builder image + build ISO from scratch
  builder-image          Rebuild the CentOS 9 builder container image
  build-debian-darksite  Rebuild the Debian APT offline mirror cache
  build-ubuntu-darksite  Rebuild the Ubuntu APT offline mirror cache
  build-fedora-darksite  Rebuild the Fedora RPM offline mirror cache
  build-ollama-darksite  Pre-pull Ollama LLM models (llama3.1:8b by default) for offline Bob
  build-k8s-darksite     Pre-pull Kubernetes + Cilium container images
  build-ai-docs          Scrape website + OCR PDF for AI knowledge base
  build-ai-appliance     Build self-contained Bob AI appliance ISO
  clean                  Remove build artifacts (preserves darksite caches)

Deploy:
  kvm-deploy             Deploy ISO to local KVM (virt-install, UEFI, VNC)
  kvm-deploy-bob         Deploy Bob AI appliance to KVM (created off)
  proxmox-deploy         Deploy ISO to remote Proxmox (SSH + qm API)
  deploy-all             Deploy to KVM + Proxmox + print USB command
  burn                   Write ISO to USB drive
  ship                   build → burn → notify in one shot. The default
                         iteration loop. Honours PROFILE/EDITION/USB_DEVICE
                         same as their individual subcommands. Per-run log
                         at /var/log/kldload-ship/ship-<utc>.log; notify-send
                         fires on completion (falls back to wall, then
                         stderr). Exit 1 = build failed, 2 = burn failed.

Test:
  smoke-build            Validate the just-built ISO (size, freshness, structure)
  smoke-test <distro> <profile>
                         End-to-end install smoke in KVM: boot ISO →
                         headless install → reboot → run smoke-auto.sh on
                         the installed system. Distros: centos|debian|
                         ubuntu|fedora|rocky|rhel|arch|alpine. Profiles:
                         core|server|desktop|kvm. Set KEEP_VM=1 to leave
                         the VM around on success for inspection.

Environment (override via env vars or kldload.env):
  PROFILE         Install profile: desktop, server, kvm, ai, core (default: desktop)
  EDITION         Edition: free (full) or core (ZFS-only) (default: free)
  ARCH            Target architecture (default: x86_64)
  RELEASE         EL release version for CentOS/Rocky/RHEL targets (default: 10)
  KLDLOAD_ZFS_GIT Build OpenZFS from git instead of the release repo
                  (1 = master, else a branch/tag) and UNPIN the live-ISO
                  kernel to newest F44. Unsupported — test builds only.
  VMID            Proxmox VM ID (default: 902)
  VM_MEMORY       VM RAM in MB (default: 16384)
  VM_CORES        VM CPU cores (default: 4)
  VM_DISK_GB      VM disk size in GB (default: 80)
  KVM_VMS         Number of KVM test VMs (default: 1)
  USB_DEVICE      USB block device for burn (default: /dev/sda)
  PROXMOX_HOST    Proxmox host IP (default: 10.100.10.225)
  CILIUM_VERSION  Cilium Helm chart version (default: 1.16.5)

Examples:
  ./deploy.sh build                          # Build with defaults
  PROFILE=server ./deploy.sh build           # Server profile
  PROFILE=kvm ./deploy.sh build              # KVM hypervisor + K8s
  ./deploy.sh clean && ./deploy.sh build     # Full rebuild
  ./deploy.sh kvm-deploy                     # Test in local KVM
  ./deploy.sh burn                           # Write to USB
  ./deploy.sh ship                           # build + burn + notify (default loop)
  USB_DEVICE=/dev/sdb ./deploy.sh ship       # Ship to a specific USB
EOF
    ;;
esac
