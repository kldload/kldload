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
PROFILE="${PROFILE:-desktop}" # Install profile: desktop, server, kvm, ai, core
EDITION="${EDITION:-free}"    # Edition: free (full) or core (ZFS-only, no tools)
# PAYLOAD decides what the ISO CARRIES, EDITION what the installed system IS.
# full: the offline mirrors, k8s images and Ollama baked in (~15 GB, installs
# with no network). net: the same tools and installer, no payload (~3 GB,
# installs from the distribution's own mirrors). EDITION=net is shorthand
# for EDITION=free PAYLOAD=net, since that is the one people will type.
PAYLOAD="${PAYLOAD:-full}" # Payload: full (offline mirrors baked in) or net (fetch at install)
if [[ "$EDITION" == "net" ]]; then
    EDITION=free
    PAYLOAD=net
fi
case "$PAYLOAD" in full | net) ;; *)
    echo "PAYLOAD must be full or net (got '$PAYLOAD')" >&2
    exit 2
    ;;
esac
# The payload, piece by piece — so "Fedora desktop with ZFS and NVIDIA and
# nothing else" is a build and not a fork. DARKSITES lists the offline
# mirrors to carry (debian ~2.8 GB, fedora ~3.6 GB, el ~1.9 GB for CentOS
# Stream/Rocky); K8S_IMAGES the Kubernetes container images (~1.5 GB);
# OLLAMA the engine and Open WebUI (~3.4 GB; weights stay opt-in via
# KLDLOAD_INCLUDE_OLLAMA_DARKSITE). PAYLOAD=net switches all of it off.
# ./deploy.sh menu writes these into kldload.env from a checklist.
DARKSITES="${DARKSITES:-debian fedora el}" # offline mirrors to carry: any of debian fedora el
K8S_IMAGES="${K8S_IMAGES:-yes}"            # bake the Kubernetes container images (yes/no)
OLLAMA="${OLLAMA:-yes}"                    # bake the Ollama engine + Open WebUI (yes/no)
if [[ "$PAYLOAD" == "net" ]]; then
    DARKSITES=""
    K8S_IMAGES=no
    OLLAMA=no
fi
for _ds in $DARKSITES; do
    case "$_ds" in debian | fedora | el) ;; *)
        echo "DARKSITES: unknown mirror '$_ds' (debian, fedora, el)" >&2
        exit 2
        ;;
    esac
done
case "$K8S_IMAGES$OLLAMA" in yesyes | yesno | noyes | nono) ;; *)
    echo "K8S_IMAGES and OLLAMA must be yes or no" >&2
    exit 2
    ;;
esac
# has_darksite NAME — is that mirror in DARKSITES?
has_darksite() { [[ " $DARKSITES " == *" $1 "* ]]; }
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
        -v "$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib:/installer-lib:z,ro" \
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
        -v "$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib:/installer-lib:z,ro" \
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
        -v "$ROOT/builder:/builder:z,ro" \
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
# _pkgset_hash — sha256 of every package list in a darksite config dir.
#
# Args:    $1 — directory of *.txt package sets.
# Returns: the hash on stdout; empty string when the directory is absent.
#
# WHY: a darksite marker file says a repo was BUILT, not that it was built from
# the current package list. Stamping the cache with this and comparing on each
# build is what makes "add a package to a set" actually reach an install.
#
# HISTORY: 2026-08-13. Fonts were added to the Fedora set on 08-12 against a
# cache built on 07-24; the marker existed, so the build logged "cached" and
# mirrored none of them. The install then dropped every one silently through
# --skip-unavailable. Debian and Ubuntu had the identical check and identical
# three-week-old caches — Debian's from 07-23 — so any package added to those
# sets since had never been mirrored either.
_pkgset_hash() {
    local dir="${1:?}"
    shift
    [[ -d "$dir" ]] || return 0
    # Extra files are hashed alongside the sets because the mirror's contents
    # now depend on them too: build-darksite-debian.sh derives its package list
    # from the installer's own k_profile_packages, so a package added THERE has
    # to invalidate this cache exactly as a package added to a .txt does.
    # Without this the 2026-08-13 failure returns in a new costume — the cache
    # looks current, the mirror never learns the package, and the install drops
    # it in silence.
    cat "$dir"/*.txt "$@" 2>/dev/null | sha256sum | cut -d' ' -f1
}

cmd_build_ollama_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-ollama-cache"
    mkdir -p "$darksite_dir"
    # Bake the SMALL chat model — llama3.2:3b, ~2 GB — plus the embedder.
    #
    # 100% darksite is still the goal: a fresh install must reach a working
    # assistant with the network unplugged. The size of the model is what
    # changed, not the ambition.
    #
    # WHY SMALL BEAT BIG (operator decision 2026-08-15, superseding the
    # 2026-08-14 "bite the bullet and add the 9 gig llm" call):
    #   * qwen3:14b needs >=8 GB VRAM or kldload-autodeploy's [ai] phase skips
    #     the assistant entirely (KLDLOAD_MIN_AI_VRAM_GB). So the 9 GB payload
    #     did nothing at all on any machine without a big GPU — it made
    #     out-of-the-box work on FEWER machines, not more.
    #   * llama3.2:3b runs on CPU, so every machine gets a working assistant.
    #   * ~9 GB off the ISO is most of a build-and-burn cycle.
    # An operator who wants a 14b pulls it in one command once they have a
    # network; that beats every ISO paying for it.
    #
    # This value is load-bearing in two other places — keep them in step:
    #   * build/darksite-ollama/build-darksite-ollama.sh (MODELS=)
    #   * the build-ollama-darksite line in usage() below
    # HISTORY: 2026-08-14 — these three had drifted to THREE different models
    # (llama3.2:3b here, qwen2.5:14b in the darksite builder, llama3.1:8b in
    # --help) while kldload-autodeploy pulled a fourth (qwen3:14b). The shipped
    # weights could therefore never satisfy the runtime, so every install
    # downloaded ~9 GB regardless of what the ISO carried.
    # kldload-autodeploy now prefers ANY model already present over its own
    # tier choice, so the exact name here no longer has to match its tiers.
    local models="${OLLAMA_MODELS:-llama3.2:3b nomic-embed-text}"

    # ── The RUNTIME, not just the weights ────────────────────────────────
    # Without this the darksite ships ~2-9 GB of model weights to a machine
    # that then cannot install ollama without internet: firstboot ran
    # `curl -fsSL https://ollama.com/install.sh | sh`. So AI was the ONE
    # part of kldload that could not come up air-gapped — the exact claim
    # the darksite exists to make good on.
    #
    # The official release tarball is used rather than the install script:
    # a fixed artifact we can verify and cache, instead of piping a remote
    # shell script into sh at first boot on a machine we just built. Same
    # approach bob-ai's builder uses, which is where it is proven.
    local rt="${darksite_dir}/runtime"
    local rt_tar="${rt}/ollama-linux-amd64.tar.zst"
    mkdir -p "$rt"
    if [[ -s "$rt_tar" ]]; then
        log "Ollama runtime already cached ($(du -sh "$rt_tar" | cut -f1))"
    else
        log "Fetching Ollama runtime (~1.7 GB, includes CUDA libs)..."
        curl -fL --connect-timeout 30 -o "${rt_tar}.part" \
            "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst" ||
            die "could not fetch the Ollama runtime — the darksite would ship weights with no way to run them"
        mv "${rt_tar}.part" "$rt_tar"
        log "Ollama runtime cached: $(du -sh "$rt_tar" | cut -f1)"
    fi

    # ── Open WebUI: the front end people actually recognize ──────────────
    #
    # WHY a second artifact instead of shipping our own UI: there is no
    # official Ollama desktop app for Linux. Upstream's release carries
    # Ollama.dmg and OllamaSetup.exe for macOS and Windows; every Linux
    # asset is ollama-linux-*.tar.zst, which is bin/ollama plus inference
    # libraries and nothing else. So "ship the official client" has no
    # Linux target, and a bespoke UI means every operator has to learn a
    # one-off. Open WebUI is the de-facto standard front end for Ollama,
    # and it already implements the pieces that mattered — hands-free
    # voice/video call with local Whisper, RAG over your own documents,
    # and pulling models from the UI.
    #
    # The :main tag, NOT :cuda. Inference happens in Ollama, which ships
    # its own CUDA libraries in the runtime tarball above; :cuda only
    # GPU-accelerates Open WebUI's OWN workloads (Whisper and embeddings)
    # and costs ~3.9 GB more. Whisper on CPU is fine for dictation, and
    # embeddings are pointed at Ollama below, so the extra CUDA stack
    # would be a duplicate that never earns its size.
    #
    # oci-archive preserves the layer compression the registry already
    # applied; docker-archive would rewrite them uncompressed and roughly
    # double what lands on the ISO.
    local owui_img="${OWUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
    local webui="${darksite_dir}/webui"
    local owui_tar="${webui}/open-webui.oci.tar"
    mkdir -p "$webui"
    if [[ -s "$owui_tar" ]]; then
        log "Open WebUI image already cached ($(du -sh "$owui_tar" | cut -f1))"
    else
        log "Pulling Open WebUI (${owui_img}, ~1.8 GB)..."
        "$runtime" pull "$owui_img" ||
            die "could not pull ${owui_img} — the ISO would ship an AI stack with no interface"
        "$runtime" save --format oci-archive -o "${owui_tar}.part" "$owui_img" ||
            die "could not export ${owui_img} to an OCI archive"
        mv "${owui_tar}.part" "$owui_tar"
        log "Open WebUI cached: $(du -sh "$owui_tar" | cut -f1)"
    fi

    # ── Whisper weights, or voice chat is a button that fails offline ────
    #
    # Open WebUI transcribes with faster-whisper, which lazily downloads
    # its weights from HuggingFace the first time someone presses the mic.
    # On a darksite box that download is the one thing guaranteed not to
    # work, and the failure surfaces as a mic button that does nothing —
    # so the weights are packed here and OFFLINE_MODE is set at firstboot.
    # 'base' is the default WHISPER_MODEL and ~145 MB; large-v3 is ~3 GB
    # and not worth it for dictation.
    local wsp="${webui}/whisper/base"
    if [[ -s "${wsp}/model.bin" ]]; then
        log "Whisper weights already cached ($(du -sh "$wsp" | cut -f1))"
    else
        log "Fetching Whisper 'base' weights for offline speech-to-text..."
        mkdir -p "$wsp"
        local _f
        for _f in config.json model.bin tokenizer.json vocabulary.txt; do
            curl -fL --connect-timeout 30 -o "${wsp}/${_f}.part" \
                "https://huggingface.co/Systran/faster-whisper-base/resolve/main/${_f}" ||
                die "could not fetch Whisper ${_f} — voice chat would fail offline"
            mv "${wsp}/${_f}.part" "${wsp}/${_f}"
        done
        log "Whisper weights cached: $(du -sh "$wsp" | cut -f1)"
    fi

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
    log "Building kldload ISO (PROFILE=$PROFILE EDITION=$EDITION PAYLOAD=$PAYLOAD ARCH=$ARCH RELEASE=$RELEASE)"

    # ── Stage 1: APT darksites (Debian + Ubuntu) ─────────────────────────
    # Skip for core edition (no darksites needed — stock distro only) and for
    # PAYLOAD=net (the installer fetches from the distro's mirrors instead)
    if [[ "$EDITION" != "core" && "$PAYLOAD" != "net" ]]; then
        if has_darksite debian; then
            local debian_darksite="$ROOT/live-build/darksite-debian-cache"
            # Everything that decides what ends up in the mirror has to be hashed,
            # or the cache looks current while the contents are stale. The builder
            # itself counts: DARKSITE_BLACKLIST lives in it, and an edit there
            # changes the pool just as surely as adding a package does.
            local _deb_profiles="$ROOT/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
            local _deb_builder="$ROOT/build/darksite-debian/build-darksite-debian.sh"
            if [[ ! -f "$debian_darksite/apt/dists/trixie/Release" ]]; then
                cmd_build_debian_darksite
                printf '%s\n' "$(_pkgset_hash "$ROOT/build/darksite-debian/config/package-sets" "$_deb_profiles" "$_deb_builder")" \
                    >"$debian_darksite/.pkgset-sha256"
            elif [[ "$(cat "$debian_darksite/.pkgset-sha256" 2>/dev/null)" != "$(_pkgset_hash "$ROOT/build/darksite-debian/config/package-sets" "$_deb_profiles" "$_deb_builder")" ]]; then
                log "Debian package sets changed since the darksite was built — rebuilding the mirror"
                cmd_build_debian_darksite
                printf '%s\n' "$(_pkgset_hash "$ROOT/build/darksite-debian/config/package-sets" "$_deb_profiles" "$_deb_builder")" \
                    >"$debian_darksite/.pkgset-sha256"
            else
                log "Debian darksite cached: $(du -sh "$debian_darksite" | cut -f1)"
            fi
        else
            log "Debian mirror not carried (DARKSITES=$DARKSITES) — Debian installs need a network"
        fi

        # ── Ubuntu darksite: RETIRED 2026-08-14 ──────────────────────────
        # Ubuntu is deprecated as a substrate (see docs/substrate-matrix.md).
        # It was the only deprecated target carrying real weight: a SECOND full
        # APT mirror (~2.6 GB in the ISO) built and gated on every single build,
        # for a distro that is a Debian variant. CentOS/Rocky/Arch cost zero ISO
        # bytes because they were never darksited at all.
        #
        # Dropping it frees ~2.6 GB — more than the entire baked model set now
        # costs (~2.2 GB) — and removes the leg that aborted an ISO build on
        # 2026-08-14 (a Debian-shaped resolvability gate run against an Ubuntu
        # mirror).
        #
        # Ubuntu still INSTALLS — it simply requires a network, the same posture
        # Arch has always had. builder/build-iso.sh already handles the absent
        # cache and logs "No Ubuntu darksite found — Ubuntu installs will
        # require internet".
        # Set KLDLOAD_INCLUDE_UBUNTU_DARKSITE=1 to build it anyway.
        if [[ "${KLDLOAD_INCLUDE_UBUNTU_DARKSITE:-0}" == "1" ]]; then
            local ubuntu_darksite="$ROOT/live-build/darksite-ubuntu-cache"
            if [[ ! -f "$ubuntu_darksite/apt/dists/noble/Release" ]]; then
                cmd_build_ubuntu_darksite
            else
                log "Ubuntu darksite cached: $(du -sh "$ubuntu_darksite" | cut -f1)"
            fi
        else
            log "Ubuntu darksite retired — Ubuntu installs require a network (KLDLOAD_INCLUDE_UBUNTU_DARKSITE=1 to restore)"
        fi

        if has_darksite fedora; then
            # Fedora RPM darksite — built in a fedora:<RELEASE> container, cached
            # at live-build/darksite-fedora-cache/. Marker file is the createrepo
            # repomd.xml — its presence means the repo was built successfully.
            local fedora_darksite="$ROOT/live-build/darksite-fedora-cache"
            # The marker alone is not enough: it says a repo was built, not that it
            # was built from the CURRENT package list. Stamp the cache with a hash
            # of the package sets and rebuild when they diverge.
            #
            # HISTORY: 2026-08-13. 22 font packages were added to
            # target-fedora-extras.txt on 08-12; the cache had been built on 07-24
            # and repomd.xml existed, so the build reported "Fedora darksite
            # cached: 2.7G" and mirrored none of them. The install then ran dnf
            # with --skip-unavailable against that mirror, dropped every font
            # without a word, and shipped a desktop with ZERO emoji fonts — the
            # tofu boxes the fonts were declared to fix. Declaring a package has to
            # be enough; remembering to hand-rebuild a mirror is not a contract.
            local _fed_stamp="$fedora_darksite/.pkgset-sha256"
            local _fed_hash
            # The builder is hashed for the same reason as Debian's: it decides what
            # ends up in the pool, so an edit there must invalidate the cache.
            _fed_hash="$(_pkgset_hash "$ROOT/build/darksite-fedora/config/package-sets" \
                "$ROOT/build/darksite-fedora/build-darksite-fedora.sh")"
            if [[ ! -f "$fedora_darksite/rpm/repodata/repomd.xml" ]]; then
                cmd_build_fedora_darksite
                printf '%s\n' "$_fed_hash" >"$_fed_stamp"
            elif [[ "$(cat "$_fed_stamp" 2>/dev/null)" != "$_fed_hash" ]]; then
                log "Fedora package sets changed since the darksite was built — rebuilding the mirror"
                cmd_build_fedora_darksite
                printf '%s\n' "$_fed_hash" >"$_fed_stamp"
            else
                log "Fedora darksite cached: $(du -sh "$fedora_darksite" | cut -f1)"
            fi
        else
            log "Fedora mirror not carried (DARKSITES=$DARKSITES) — Fedora installs need a network"
        fi

        if [[ "$OLLAMA" == "yes" ]]; then
            # Ollama model darksite — OPT-IN. No model weights ship by default.
            #
            # THE SHAPE OF THE DECISION (operator, 2026-08-15):
            #   default build   → Ollama + Open WebUI installed, set up and running,
            #                     with an EMPTY model list. The operator pulls the
            #                     model they want: `ollama pull <name>`, or straight
            #                     from the model picker in the Open WebUI window.
            #   =1 at build time → the model is downloaded during the ISO build,
            #                     baked into the image, and installs offline. This
            #                     is the air-gapped path and it costs ISO size.
            #
            # WHY THIS IS THE RIGHT DEFAULT: the interface needs no model to work.
            # Open WebUI is a frontend — it starts with zero models and offers a
            # picker. So "everything set up and ready to go" is fully delivered
            # without shipping weights, and shipping weights only pre-answers a
            # question (WHICH model) that the operator is better placed to answer.
            # Most people are not air-gapped and would rather have the smaller ISO
            # and their own choice of model.
            #
            # WARN: with this at 0 an AIR-GAPPED install gets the interface and no
            # model, and no way to fetch one. Air-gapped builds must set
            # KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1. That is the whole point of the flag.
            #
            # kldload-autodeploy sets Ollama and Open WebUI up BEFORE it looks at
            # models or VRAM, precisely so this default cannot produce a machine
            # with no interface.
            #
            # BYOM (Bring Your Own Models) after install — drop the Ollama model
            # tree into /root/darksite/ollama/models/ on the installed target
            # (rsync from a box that already pulled it, or copy from a
            # pre-populated USB). On next boot kldload-firstboot detects the
            # directory and rsyncs it into /srv/ollama/models/ before starting
            # Ollama — same offline behaviour, no rebuild.
            if [[ "${KLDLOAD_INCLUDE_OLLAMA_DARKSITE:-0}" == "1" ]]; then
                local ollama_darksite="$ROOT/live-build/darksite-ollama-cache"
                # Verify the REQUESTED models are present, not merely that the
                # cache holds something. The old test (`library/*/*`) passed on any
                # model at all, so after the default changed the build happily
                # shipped the previous model while the runtime asked for the new
                # one — the same presence-vs-correctness trap that shipped a broken
                # Debian mirror on 2026-08-14.
                _ol_want="${OLLAMA_MODELS:-llama3.2:3b nomic-embed-text}"
                _ol_missing=0
                for _m in $_ol_want; do
                    _mn="${_m%%:*}"
                    _mt="${_m##*:}"
                    [[ "$_mt" == "$_mn" ]] && _mt=latest
                    [[ -f "$ollama_darksite/models/manifests/registry.ollama.ai/library/${_mn}/${_mt}" ]] ||
                        _ol_missing=1
                done
                if ((_ol_missing == 1)); then
                    log "Ollama darksite missing one of: ${_ol_want} — rebuilding"
                    cmd_build_ollama_darksite
                else
                    log "Ollama darksite cached: $(du -sh "$ollama_darksite" | cut -f1)"
                fi
            else
                # The ENGINE and INTERFACE ship even when the weights do not, so an
                # offline install lands a working Ollama + Open WebUI with an empty
                # model picker rather than no AI at all. Only the model tree is
                # opt-in — it is the multi-GB part and the only part that is an
                # opinion about which model someone wants.
                #
                # Building the cache here also pulls the weights; they simply are
                # not copied into the ISO. The cache lives on the build host, the
                # size that matters is the ISO's.
                local ollama_darksite="$ROOT/live-build/darksite-ollama-cache"
                if [[ ! -f "$ollama_darksite/runtime/ollama-linux-amd64.tar.zst" ]] ||
                    [[ ! -s "$ollama_darksite/webui/open-webui.oci.tar" ]]; then
                    log "Ollama engine/interface not cached — building them (weights cached but NOT baked into the ISO)"
                    cmd_build_ollama_darksite
                else
                    log "Ollama engine + interface cached: runtime $(du -sh "$ollama_darksite/runtime" 2>/dev/null | cut -f1), webui $(du -sh "$ollama_darksite/webui" 2>/dev/null | cut -f1)"
                fi
                log "Ollama model weights NOT baked in (opt-in via KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1) — picker starts empty"
            fi
        else
            log "Ollama not carried (OLLAMA=no) — the AI stack installs from the network or not at all"
        fi

        # Arch has no darksite — rolling release, not worth caching.
        log "Note: Arch installs require internet (rolling release, no darksite)"
    else
        log "No payload carried (EDITION=$EDITION PAYLOAD=$PAYLOAD) — installs fetch from the distributions' own mirrors."
    fi

    # ── Stage 2: Kubernetes container images (offline K8s deployment) ─────
    # Pre-pulls all images needed by kubeadm, Cilium, MetalLB, etc.
    # so kube-cluster bootstrap works without internet.
    local k8s_images_dir="$ROOT/live-build/config/includes.chroot/root/darksite/k8s-images"
    local k8s_images_list="$ROOT/build/darksite/k8s-images.txt"
    if [[ -f "$k8s_images_list" ]] && [[ "$EDITION" != "core" && "$PAYLOAD" != "net" && "$K8S_IMAGES" == "yes" ]]; then
        # Always run the puller. It skips images it already has, one at a
        # time, so this is cheap on a warm cache and — unlike the old
        # "directory is non-empty, therefore done" test — it actually notices
        # when k8s-images.txt gains entries. That test is why adding nine
        # images to the list changed nothing: fourteen tarballs were already
        # on disk, so the build logged "K8s images cached: 763M (14 images)"
        # and pulled none of the new ones (2026-08-16).
        local _want _have
        # mkdir FIRST. `find` on a missing directory exits 1; 2>/dev/null hides
        # the message but not the status, pipefail promotes it out of the
        # pipeline, and set -e then kills the build with no diagnostic at all —
        # deploy.sh has no ERR trap, so the log simply stops mid-stage.
        # This made `./deploy.sh build` fail on ANY clean checkout, because
        # nothing else creates this directory: the puller below would have, but
        # the build died two lines before reaching it.
        # HISTORY: onyx 2026-08-29 — ship exited 1 right after "Note: Arch
        # installs require internet", no error printed, no ISO, no burn.
        mkdir -p "$k8s_images_dir"
        _want="$(grep -cvE '^\s*(#|$)' "$k8s_images_list")"
        _have="$(find "$k8s_images_dir" -name '*.tar' 2>/dev/null | wc -l)"
        if [[ "$_have" -lt "$_want" ]]; then
            log "Pre-pulling Kubernetes container images for offline deploy (${_have}/${_want} cached)..."
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
    # --cpu-shares: builds are batch work on a dev box that also runs the
    # operator's desktop (and games). ~512 shares ≈ cgroup CPUWeight 20, so
    # the build takes every idle core at full speed but yields instantly
    # under contention — a build should never make the foreground lag.
    "$runtime" run -d --privileged \
        --cpu-shares=512 \
        --platform "$_platform" \
        -v "$ROOT:/build:z" \
        -e PROFILE="$PROFILE" \
        -e EDITION="$EDITION" \
        -e PAYLOAD="$PAYLOAD" \
        -e DARKSITES="$DARKSITES" \
        -e K8S_IMAGES="$K8S_IMAGES" \
        -e OLLAMA="$OLLAMA" \
        -e ARCH="$ARCH" \
        -e RELEASE="$RELEASE" \
        -e ISO_NAME_OVERRIDE="${ISO_NAME_OVERRIDE:-}" \
        -e BOB_LIVE="${BOB_LIVE:-}" \
        -e KLDLOAD_INCLUDE_OLLAMA_DARKSITE="${KLDLOAD_INCLUDE_OLLAMA_DARKSITE:-0}" \
        -e KLDLOAD_INCLUDE_UBUNTU_DARKSITE="${KLDLOAD_INCLUDE_UBUNTU_DARKSITE:-0}" \
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
# ─── menu — pick what the ISO carries, write kldload.env, offer to build ─────
# The knobs above are the interface; this is the same interface with the
# sizes written next to the choices, for the person who knows they want "a
# Fedora desktop with ZFS and NVIDIA" and does not want to learn six variable
# names first. Sizes are from the 2026-09-06 desktop ISO: ~3 GB of live
# system, tools and consoles, and the payload pieces on top. Writes
# kldload.env (backing up the old one) so the choice sticks for every later
# ./deploy.sh build, and prints the equivalent one-line command.
cmd_menu() {
    local ui=""
    command -v whiptail >/dev/null 2>&1 && ui=whiptail
    [[ -z "$ui" ]] && command -v dialog >/dev/null 2>&1 && ui=dialog
    [[ -t 0 && -n "$ui" ]] || die "menu needs a terminal and whiptail or dialog (dnf install newt · apt install whiptail)"
    # whiptail's stock palette is the 1990s blue-and-red newt theme ("those
    # are miserable colors", operator, 2026-09-06). newt reads NEWT_COLORS;
    # this is a dark scheme in the site's tones: near-black ground, grey
    # chrome, green for the thing that has focus. dialog reads DIALOGRC
    # instead; the same scheme is written there for the fallback.
    # One line, colon-separated: newt ignores the newline-separated form
    # (checked under a pty on 2026-09-06 — the stock blue came back).
    export NEWT_COLORS='root=white,black:roottext=white,black:window=white,black:border=brightblack,black:shadow=black,black:title=brightgreen,black:textbox=white,black:button=black,green:actbutton=black,brightgreen:compactbutton=white,black:checkbox=white,black:actcheckbox=black,green:listbox=white,black:actlistbox=black,green:sellistbox=brightgreen,black:actsellistbox=black,brightgreen:entry=white,brightblack:label=white,black:emptyscale=,black:fullscale=,green:helpline=brightblack,black'
    if [[ "$ui" == "dialog" ]]; then
        DIALOGRC="$(mktemp)"
        export DIALOGRC
        cat >"$DIALOGRC" <<'RC'
use_shadow = OFF
screen_color = (WHITE,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (GREEN,BLACK,ON)
border_color = (BLACK,BLACK,ON)
button_active_color = (BLACK,GREEN,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_label_active_color = (BLACK,GREEN,ON)
button_label_inactive_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,GREEN,ON)
tag_selected_color = (BLACK,GREEN,ON)
tag_key_selected_color = (BLACK,GREEN,ON)
check_selected_color = (BLACK,GREEN,ON)
RC
    fi
    local profile payload picks size=3
    profile=$("$ui" --title "kldload — what to build" --radiolist \
        "Install profile (what the installer offers on the target)" 16 74 5 \
        desktop "GNOME desktop, every console, KVM, the appliance catalog" ON \
        server "headless: ZFS, KVM, mesh, consoles over the web UI" OFF \
        kvm "hypervisor: KVM + Kubernetes lab" OFF \
        ai "desktop plus the local AI stack on first boot" OFF \
        core "ZFS on root and the boot menu, nothing else (EDITION=core)" OFF \
        3>&1 1>&2 2>&3) || return 1
    payload=$("$ui" --title "kldload — what the ISO carries" --radiolist \
        "Full installs with no network at all. Net is the same tools and installer,\npackages fetched from the distributions' mirrors at install time." 14 74 3 \
        full "everything baked in — about 15 GB" ON \
        net "tools only — about 3 GB, needs a network to install" OFF \
        custom "pick the pieces" OFF \
        3>&1 1>&2 2>&3) || return 1
    local darksites="debian fedora el" k8s=yes ollama=yes weights=0
    case "$payload" in
    net)
        darksites=""
        k8s=no
        ollama=no
        ;;
    custom)
        picks=$("$ui" --title "kldload — payload" --checklist \
            "Space toggles. NVIDIA is always built and signed; the installer offers it per machine." 18 78 6 \
            debian "Debian 13 offline mirror (~2.8 GB)" ON \
            fedora "Fedora 44 offline mirror (~3.6 GB)" ON \
            el "EL10 mirror for CentOS Stream / Rocky (~1.9 GB)" ON \
            k8s "Kubernetes container images (~1.5 GB)" ON \
            ollama "Ollama engine + Open WebUI (~3.4 GB)" ON \
            weights "Ollama model weights, air-gapped AI (~9 GB)" OFF \
            3>&1 1>&2 2>&3) || return 1
        picks=${picks//\"/}
        darksites=""
        k8s=no
        ollama=no
        for _p in $picks; do
            case "$_p" in
            debian | fedora | el) darksites="${darksites:+$darksites }$_p" ;;
            k8s) k8s=yes ;;
            ollama) ollama=yes ;;
            weights) weights=1 ;;
            esac
        done
        ;;
    esac
    local edition=free
    [[ "$profile" == "core" ]] && edition=core
    # the estimate: base plus what is ticked (a core image drops the tools too)
    [[ "$edition" == "core" ]] && size=1.5
    for _p in $darksites; do
        case "$_p" in
        debian) size=$(awk "BEGIN{print $size+2.8}") ;;
        fedora) size=$(awk "BEGIN{print $size+3.6}") ;;
        el) size=$(awk "BEGIN{print $size+1.9}") ;;
        esac
    done
    [[ "$k8s" == "yes" ]] && size=$(awk "BEGIN{print $size+1.5}")
    [[ "$ollama" == "yes" ]] && size=$(awk "BEGIN{print $size+3.4}")
    [[ "$weights" == "1" ]] && size=$(awk "BEGIN{print $size+9}")
    local pay=full
    [[ -z "$darksites" && "$k8s" == "no" && "$ollama" == "no" ]] && pay=net
    local envf="$ROOT/kldload.env"
    [[ -f "$envf" ]] && cp -f "$envf" "$envf.bak"
    {
        echo "# written by ./deploy.sh menu on $(date -Is) — edit freely, or run the menu again"
        echo "PROFILE=$profile"
        echo "EDITION=$edition"
        echo "PAYLOAD=$pay"
        echo "DARKSITES=\"$darksites\""
        echo "K8S_IMAGES=$k8s"
        echo "OLLAMA=$ollama"
        [[ "$weights" == "1" ]] && echo "KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1"
    } >"$envf"
    local cmd="PROFILE=$profile EDITION=$edition PAYLOAD=$pay DARKSITES=\"$darksites\" K8S_IMAGES=$k8s OLLAMA=$ollama"
    [[ "$weights" == "1" ]] && cmd="$cmd KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1"
    cmd="$cmd ./deploy.sh build"
    "$ui" --title "kldload — ready" --msgbox \
        "Written to kldload.env, so a plain ./deploy.sh build now means this.\n\nEstimated ISO: about ${size} GB\n\nThe same as one line:\n$cmd" 16 78
    if "$ui" --title "kldload" --yesno "Build it now? (30–60 min with cached mirrors; the first darksite build is longer)" 9 70; then
        PROFILE=$profile EDITION=$edition PAYLOAD=$pay DARKSITES=$darksites K8S_IMAGES=$k8s OLLAMA=$ollama \
            KLDLOAD_INCLUDE_OLLAMA_DARKSITE=$weights cmd_build
    else
        log "Not building. Later: ./deploy.sh build   (reads kldload.env)"
    fi
}

# ── Netboot ──────────────────────────────────────────────────────────────────
# pxe-serve lays out an HTTP tree from a built ISO; pxe-arm drops one answers
# file into it. Nothing here starts a daemon or needs root -- serving and DHCP
# are the operator's choice and are printed at the end.
#
# The safety model is the arming file. A machine only installs when
# answers/<mac>.env exists, so an unarmed box that netboots by accident
# downloads 200 bytes, gets a 404 and carries on down its boot order. That
# replaces the consent a USB seed disk carried by being physically plugged in.
PXE_ROOT_DEFAULT="${PXE_ROOT:-$ROOT/live-build/pxe}"

# _pxe_mac_file <mac> — normalise aa:bb:.. or AA-BB-.. to the aa-bb-.. form
# iPXE produces with ${net0/mac:hexhyp}. Echoes the bare name, no directory.
_pxe_mac_file() {
    local m="${1//:/-}"
    m="${m,,}"
    [[ "$m" =~ ^([0-9a-f]{2}-){5}[0-9a-f]{2}$ ]] || die "pxe: not a MAC address: $1"
    printf '%s.env\n' "$m"
}

cmd_pxe_serve() {
    local iso="" root="$PXE_ROOT_DEFAULT" base="" _a sanboot=0 menu=0 golden=""
    local _livenet_hits=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --iso)
            iso="${2:?--iso needs a path}"
            shift 2
            ;;
        --root)
            root="${2:?--root needs a path}"
            shift 2
            ;;
        --url)
            base="${2:?--url needs a URL}"
            shift 2
            ;;
        --sanboot)
            sanboot=1
            shift
            ;;
        --menu)
            menu=1
            shift
            ;;
        --golden)
            # host:dataset of a prepared root to RECEIVE instead of installing.
            # Only meaningful with --menu; without it the Deploy entry is simply
            # not offered, because an entry that cannot work is worse than an
            # absent one.
            golden="${2:?--golden needs host:dataset}"
            shift 2
            ;;
        *) die "pxe-serve: unknown argument: $1" ;;
        esac
    done

    if [[ -z "$iso" ]]; then
        iso="$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null |
            sort -rn | head -1 | cut -d' ' -f2-)"
    fi
    [[ -n "$iso" && -f "$iso" ]] || die "pxe-serve: no ISO found — build one, or pass --iso"
    if [[ -n "$golden" ]]; then
        [[ "$golden" =~ ^[a-zA-Z0-9._-]+:[a-zA-Z0-9._/-]+$ ]] ||
            die "pxe-serve: --golden must be host:dataset (e.g. onyx:rpool/backup/fedora-desktop)"
    fi
    command -v xorriso >/dev/null || die "pxe-serve: xorriso is required to read the ISO"

    if [[ -z "$base" ]]; then
        local _ip
        _ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
        [[ -n "$_ip" ]] || die "pxe-serve: could not determine this host's address — pass --url"
        base="http://${_ip}:8080"
    fi

    log "pxe-serve: ISO $(basename "$iso")"
    log "pxe-serve: tree $root"
    log "pxe-serve: clients will fetch from $base"

    mkdir -p "$root/kldload" "$root/answers" "$root/ipxe"

    # A tree outlives the ISO that seeded it: --menu and --sanboot share one
    # directory, and a rebuild renames the image underneath both. A link left
    # by an earlier --sanboot run then points at nothing, and because only
    # --sanboot re-creates it, every other mode leaves it there to 404. Drop it
    # here, where it is cheap, rather than at a machine (fiend, 2026-09-09).
    if [[ -L "$root/iso/kldload.iso" && ! -e "$root/iso/kldload.iso" ]]; then
        log "  dropping a stale ISO link: $(readlink "$root/iso/kldload.iso") is gone"
        rm -f "$root/iso/kldload.iso"
    fi

    # Extract only the three files a netboot needs. lorax puts the kernel and
    # initrd under /images/pxeboot; the live rootfs is /LiveOS/squashfs.img.
    local f
    for f in /images/pxeboot/vmlinuz /images/pxeboot/initrd.img /LiveOS/squashfs.img; do
        xorriso -osirrox on -indev "$iso" -extract "$f" "$root/kldload/$(basename "$f")" \
            >/dev/null 2>&1 || die "pxe-serve: could not extract $f from the ISO"
    done
    # Outcome, not exit code: a truncated squashfs netboots into a kernel panic
    # halfway across the room.
    for f in vmlinuz initrd.img squashfs.img; do
        [[ -s "$root/kldload/$f" ]] || die "pxe-serve: $f came out empty"
        # xorriso preserves the ISO's modes, and initrd.img comes out 0600.
        # A web server running as its own user then 403s on it, so the client
        # fetches the kernel and stops — which looks like a boot failure, not a
        # permissions problem (nginx, 2026-09-09). These are public boot
        # artefacts by definition; they are served to anything that PXE-boots.
        chmod 0644 "$root/kldload/$f"
        log "  $(printf '%-12s %s' "$f" "$(numfmt --to=iec "$(stat -c%s "$root/kldload/$f")")")"
    done

    # Can this initrd actually netboot? The generated cmdline says
    # root=live:http://..., which only the dracut "livenet" module understands.
    # kldload ISOs boot themselves with root=live:CDLABEL=KLDLOAD and ship
    # dmsquash-live WITHOUT livenet, so the machine loads the kernel and initrd,
    # then dies with "dracut: FATAL: Don't know how to handle
    # 'root=live:http://...'" and powers off about six seconds in. It looks like
    # a hardware fault and is not one (fiend, 2026-09-09).
    #
    # Refuse loudly rather than hand back a config that bricks a boot: a netboot
    # that cannot work must not look identical to one that can.
    if ((sanboot)); then
        log "  sanboot mode: the ISO is chainloaded whole, so livenet is not needed"
    elif command -v lsinitrd >/dev/null 2>&1; then
        # grep -c, not grep -q, and the count captured rather than tested in a
        # pipeline: grep -q exits the instant it matches, lsinitrd then dies of
        # SIGPIPE with 141, and under `set -o pipefail` the pipeline reports
        # THAT — so this gate refused an initrd that genuinely had livenet.
        # A gate with a false positive is worse than no gate: it blocks the
        # good case and teaches you to bypass it (2026-09-09).
        _livenet_hits="$(lsinitrd "$root/kldload/initrd.img" 2>/dev/null | grep -c 'livenet' || true)"
        if [[ "${_livenet_hits:-0}" -eq 0 ]]; then
            log "  FATAL: this initrd has no dracut 'livenet' module, so it cannot fetch"
            log "         root=live:http://... . It would load, then refuse to continue and"
            log "         power the machine off a few seconds in."
            log "         Fix: rebuild the ISO's initramfs with --add livenet, or chainload"
            log "         the ISO itself with iPXE sanboot so it boots by CDLABEL as designed."
            die "pxe-serve: initrd cannot netboot (no livenet)"
        fi
        log "  initrd has livenet (${_livenet_hits} entries): it can fetch the rootfs over HTTP"
    else
        log "  WARN: no lsinitrd, so the initrd's netboot capability WAS NOT CHECKED"
    fi

    # iPXE binary, if the distro ships one. Not fatal: an operator may already
    # have one on their TFTP server.
    local _ipxe
    for _ipxe in /usr/share/ipxe/ipxe-x86_64.efi /usr/share/ipxe/ipxe.efi \
        /usr/lib/ipxe/ipxe.efi /usr/share/ipxe/undionly.kpxe; do
        [[ -f "$_ipxe" ]] && { cp -f "$_ipxe" "$root/ipxe/" && log "  ipxe: $(basename "$_ipxe")"; }
    done
    compgen -G "$root/ipxe/*" >/dev/null ||
        log "  WARN: no iPXE binary found locally — install ipxe-bootimgs, or supply your own"

    # Take the ISO's OWN kernel command line and adapt it, rather than
    # composing one. The ISO's line carries flags that were each learned the
    # hard way — selinux=0, lockdown=none, module.sig_enforce=0,
    # rd.live.overlay.size, rootdelay, USB blacklists. Composing a minimal one
    # dropped selinux=0, and the live system booted to "Welcome to Fedora 44"
    # and then died with "Failed to allocate manager object" and a wall of
    # SELinux denials: systemd PID 1 cannot start when the squashfs labels do
    # not match an enforcing policy (fiend, 2026-09-09).
    #
    # Only two things change: the root moves from a CDLABEL to our URL, and the
    # netboot additions are appended.
    local _iso_args="" _grubcfg="$root/.iso-grub.cfg"
    if xorriso -osirrox on -indev "$iso" -extract /EFI/BOOT/grub.cfg "$_grubcfg" >/dev/null 2>&1; then
        _iso_args="$(grep -m1 -E '^[[:space:]]*linuxefi' "$_grubcfg" |
            sed -E 's|^[[:space:]]*linuxefi[[:space:]]+[^[:space:]]+[[:space:]]*||; s|root=live:[^[:space:]]+[[:space:]]*||')"
        rm -f "$_grubcfg"
    fi
    if [[ -z "$_iso_args" ]]; then
        log "  WARN: could not read the ISO's own kernel cmdline — falling back to a minimal one."
        log "        If the live system dies with 'Failed to allocate manager object', it is missing selinux=0."
        _iso_args="rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0"
    fi
    log "  cmdline from the ISO: $(printf '%.72s…' "$_iso_args")"

    if ((menu)); then
        # A cascading console configurator, not a frozen answers file per MAC.
        #
        # The per-MAC arming model is right for unattended rebuilds: a machine
        # either has answers waiting or it does not. It is wrong when somebody
        # is standing at a console choosing what to build, because every change
        # means editing a file on the server.
        #
        # Nothing is pregenerated here. The menu composes kldload.* keys onto
        # the kernel command line and kldload-autoinstall builds its own answers
        # from them. That matters: distro x profile x timezone x four booleans
        # is thousands of combinations, and one answers file per combination is
        # not a thing anyone can maintain.
        #
        # Consent still holds by the same route as before. The DEFAULT entry is
        # the local disk and it selects itself after 30 seconds, so a machine
        # that netboots unattended carries on booting as it would have.
        # Installing requires a person to choose it, twice.
        #
        # SECRETS ARE ABSENT ON PURPOSE. There is no password prompt here and
        # there will not be one, because everything this menu collects ends up
        # on /proc/cmdline, which is world-readable on the installed system for
        # the rest of its life. kldload-autoinstall REFUSES kldload.password=
        # outright. Passwords come from a per-MAC seed file (readable on the server; see pxe-arm), or
        # get set after first boot.
        #
        # iPXE has no checkbox widget, so the toggles are a menu that rewrites
        # its own labels and jumps back to itself. It also has no params/param
        # in Fedora's build -- verified in a VM, 2026-09-11 -- so posting a form
        # back to the server is not available and the command line is the only
        # transport.
        {
            printf '#!ipxe\n'
            printf '# Generated by deploy.sh pxe-serve --menu. Edit the tree, not this file.\n'
            printf 'set base %s\n' "$base"
            printf 'set isoargs %s\n\n' "${_iso_args}"

            # Defaults. Hostname derives from the MAC so that two machines
            # choosing the same menu entry do not collide -- the old menu
            # hardcoded kldload-<distro> and every node installed with the same
            # name.
            printf 'set distro fedora\n'
            printf 'set profile server\n'
            printf 'set tz America/Los_Angeles\n'
            printf 'set user admin\n'
            printf 'set host kld-${net0/mac:hexhyp}\n'
            printf 'set sb 0\n'
            printf 'set zfs 1\n'
            printf 'set enc 0\n'
            printf 'set bimg 0\n'
            printf 'set knb 0\n'
            printf 'set rbpool rpool\n\n'

            printf ':top\n'
            printf 'menu kldload netboot — %s\n' "$(basename "$iso")"
            printf 'item --gap Choose an action:\n'
            printf 'item cfg    Install — configure and build from packages (WIPES the disk)\n'
            if [[ -n "$golden" ]]; then
                printf 'item deploy Deploy — receive a prepared image, no package install (WIPES the disk)\n'
            fi
            printf 'item rback  Roll back — list this machine'"'"'s boot environments\n'
            printf 'item rescue Rescue shell — no install, restore from a backup\n'
            printf 'item local  Boot from the local disk (default)\n'
            printf 'choose --timeout 30000 --default local t || goto local\n'
            printf 'goto ${t}\n\n'

            # ── distro ──
            printf ':cfg\n'
            printf 'menu Distribution\n'
            local _d
            for _d in fedora rocky centos debian ubuntu arch; do
                printf 'item %s   %s\n' "$_d" "$_d"
            done
            printf 'choose --default ${distro} d || goto top\n'
            printf 'set distro ${d}\n'
            printf 'goto profilemenu\n\n'

            # ── profile ──
            printf ':profilemenu\n'
            printf 'menu Profile\n'
            local _p
            for _p in server desktop kvm core ai; do
                printf 'item %s   %s\n' "$_p" "$_p"
            done
            printf 'choose --default ${profile} p || goto top\n'
            printf 'set profile ${p}\n'
            printf 'goto tzmenu\n\n'

            # ── timezone ──
            # A short list, not free text. Typing an IANA zone blind at a PXE
            # prompt gets it wrong, and a bad zone is only noticed weeks later
            # in somebody's logs.
            printf ':tzmenu\n'
            printf 'menu Timezone\n'
            local _z
            for _z in America/Los_Angeles America/Denver America/Chicago America/New_York UTC Europe/London Europe/Berlin; do
                printf 'item %s   %s\n' "$_z" "$_z"
            done
            printf 'choose --default ${tz} z || goto top\n'
            printf 'set tz ${z}\n'
            printf 'goto opts\n\n'

            # ── toggles ──
            printf ':opts\n'
            printf 'set sblbl no\n'
            printf 'iseq ${sb} 1 && set sblbl YES ||\n'
            printf 'set zfslbl no\n'
            printf 'iseq ${zfs} 1 && set zfslbl YES ||\n'
            printf 'set enclbl no\n'
            printf 'iseq ${enc} 1 && set enclbl YES ||\n'
            printf 'set bimglbl no\n'
            printf 'iseq ${bimg} 1 && set bimglbl YES ||\n'
            printf 'set knblbl no\n'
            printf 'iseq ${knb} 1 && set knblbl YES ||\n'
            printf 'menu Options — ${distro}/${profile}, ${tz}, host ${host}\n'
            printf 'item tsb    Secure Boot .......... ${sblbl}\n'
            printf 'item tzfs   ZFS root ............. ${zfslbl}\n'
            printf 'item tenc   Encrypt pool ......... ${enclbl}\n'
            printf 'item tbimg  Build golden images .. ${bimglbl}\n'
            printf 'item tknb   Keep netboot payload . ${knblbl}  (this box can then serve PXE)\n'
            printf 'item --gap \n'
            printf 'item go     START INSTALL — wipes ${distro}/${profile} onto this machine\n'
            printf 'item top    Back\n'
            printf 'choose o || goto top\n'
            printf 'goto ${o}\n\n'

            local _t
            for _t in "tsb:sb" "tzfs:zfs" "tenc:enc" "tbimg:bimg" "tknb:knb"; do
                printf ':%s\n' "${_t%%:*}"
                printf 'iseq ${%s} 1 && set %s 0 || set %s 1\n' "${_t##*:}" "${_t##*:}" "${_t##*:}"
                printf 'goto opts\n\n'
            done

            # ── go ──
            # KLDLOAD_DISK is deliberately NOT set: iPXE cannot enumerate this
            # machine's disks, so choosing one here means typing a device name
            # blind. The installer picks it, skipping the live medium and any
            # disk carrying somebody else's pool.
            printf ':go\n'
            printf 'echo Installing ${distro}/${profile} as ${host} — this WIPES a disk\n'
            printf 'echo NO PASSWORD is set by this menu. admin gets a temporary one and MUST\n'
            printf 'echo change it at first login. Use a per-MAC seed file for a real password.\n'
            printf 'kernel ${base}/kldload/vmlinuz initrd=initrd.img root=live:${base}/kldload/squashfs.img ${isoargs} ip=dhcp rd.neednet=1 console=tty0 '
            printf 'kldload.distro=${distro} kldload.profile=${profile} kldload.hostname=${host} '
            printf 'kldload.username=${user} kldload.timezone=${tz} kldload.zfs=${zfs} '
            printf 'kldload.encrypt=${enc} kldload.secureboot=${sb} kldload.buildimages=${bimg} kldload.keepnetboot=${knb}\n'
            printf 'initrd ${base}/kldload/initrd.img\n'
            printf 'boot\n\n'

            # Rescue: the SAME live environment with NO kldload.* keys. With
            # nothing on the cmdline and no KLDLOADSEED volume, autoinstall has
            # nothing to act on and does not touch the disk. What you get is a
            # working root with zfs, syncoid and the kldload-restore-* tools,
            # which is what a rebuild-from-archive needs -- and it avoids the
            # installer entirely, so an upstream gap that blocks an INSTALL
            # cannot block a RESTORE.
            # Deploy: a ZFS receive instead of N package transactions. No
            # upstream to fail and no per-machine DKMS build, which is the
            # slowest and most fragile part of an install. The disk is NOT
            # chosen here for the same reason it is not chosen for an install:
            # iPXE cannot enumerate this machine'"'"'s disks. kldload.disk= is
            # required by the deploy path and the operator supplies it, because
            # a receive repartitions whatever it is pointed at.
            if [[ -n "$golden" ]]; then
                printf ':deploy\n'
                printf 'echo Deploy from %s\n' "$golden"
                printf 'echo This RECEIVES a prepared root and REPARTITIONS the disk you name.\n'
                printf 'echo Enter the target disk (e.g. /dev/nvme0n1), or Ctrl-C to abort:\n'
                printf 'read dtgt\n'
                printf 'kernel ${base}/kldload/vmlinuz initrd=initrd.img root=live:${base}/kldload/squashfs.img ${isoargs} ip=dhcp rd.neednet=1 console=tty0 '
                printf 'kldload.action=deploy kldload.source=%s kldload.disk=${dtgt} kldload.hostname=${host}\n' "$golden"
                printf 'initrd ${base}/kldload/initrd.img\n'
                printf 'boot\n\n'
            fi

            # Roll back: LISTS the boot environments and stops. It does not pick
            # one, because a netboot server cannot know which of them is the one
            # you want, and rolling a machine past the change you were trying to
            # keep is not recoverable by guessing again.
            printf ':rback\n'
            printf 'echo Listing boot environments on ${rbpool}. NOTHING will be changed.\n'
            printf 'kernel ${base}/kldload/vmlinuz initrd=initrd.img root=live:${base}/kldload/squashfs.img ${isoargs} ip=dhcp rd.neednet=1 console=tty0 '
            printf 'kldload.action=rollback kldload.pool=${rbpool}\n'
            printf 'initrd ${base}/kldload/initrd.img\n'
            printf 'boot\n\n'

            printf ':rescue\n'
            printf 'echo kldload: rescue shell - nothing will be installed. Log in as live/live.\n'
            printf 'kernel ${base}/kldload/vmlinuz initrd=initrd.img root=live:${base}/kldload/squashfs.img ${isoargs} ip=dhcp rd.neednet=1 console=tty0\n'
            printf 'initrd ${base}/kldload/initrd.img\n'
            printf 'boot\n\n'

            printf ':local\n'
            printf 'echo kldload: continuing the local boot order\n'
            printf 'exit\n'
        } >"$root/boot.ipxe"
        [[ -s "$root/boot.ipxe" ]] || die "pxe-serve: boot.ipxe did not land in $root"
        log "  menu: cascading configurator written (default is the LOCAL disk after 30s)"
        log "         distro · profile · timezone · secureboot/zfs/encrypt/buildimages"
        log "         no secrets collected: passwords come from a 0600 seed, never the cmdline"
    elif ((sanboot)); then
        # SANBOOT: iPXE presents the ISO as a virtual disk and the machine boots
        # it exactly as it would from USB, so root=live:CDLABEL=KLDLOAD works
        # unchanged. This is the mode to use when the initrd has no livenet —
        # which is every kldload ISO — because nothing about the image has to
        # change (fiend, 2026-09-09).
        #
        # The cmdline then comes from the ISO's own grub.cfg, so kldload.seed=
        # cannot be injected. The SEED IMAGE carries the answers instead: it is
        # a 32 MB FAT volume labelled KLDLOADSEED, which kldload-autoinstall
        # already looks for as its second source. sanhook attaches it as a
        # second disk without booting it.
        #
        # That also keeps the consent model intact: no seed image for this MAC
        # means sanhook 404s, and the machine carries on down its boot order
        # having downloaded a few hundred bytes.
        #
        # --drive 0x81 is load-bearing. Without it sanhook claims 0x80, the
        # FIRST boot drive, so the firmware tries to boot the 32 MB seed volume
        # instead of the ISO: iPXE probes it in 512-byte reads, finds nothing
        # bootable, and the screen stays black with the ISO never requested at
        # all. Measured on fiend, 2026-09-09: eight range reads of the 32 MB
        # seed image and not one request for the ISO, then the ISO fetched on
        # the very next attempt once the drive number moved. The ISO owns 0x80.
        #
        # Byte-range requests are REQUIRED here: iPXE reads the ISO in pieces.
        # python3 -m http.server answers every Range with the whole file, so
        # serve this tree with nginx.
        mkdir -p "$root/iso" "$root/seeds"
        ln -sf "$(readlink -f "$iso")" "$root/iso/kldload.iso"
        # Outcome, not exit code. ln -sf cheerfully creates a link to a path
        # that does not exist, and a dangling one is invisible from here: the
        # symptom arrives later, at a machine, as sanboot getting 404 on every
        # read and iPXE retrying forever. The console sits black and the server
        # log fills with thousands of identical 404s.
        #
        # That is how 2026-09-09 ended. The ISO was renamed to carry its
        # edition suffix while a boot was in flight, and this link had named
        # the old path since the previous run. Nothing noticed for an hour.
        [[ -e "$root/iso/kldload.iso" ]] ||
            die "pxe-serve: $root/iso/kldload.iso does not resolve — the ISO moved or was renamed"
        log "  sanboot: ISO linked at $root/iso/kldload.iso → $(readlink "$root/iso/kldload.iso")"

        cat >"$root/boot.ipxe" <<IPXESAN
#!ipxe
# Generated by deploy.sh pxe-serve --sanboot. Edit the tree, not this file.
set base ${base}
set seedimg \${net0/mac:hexhyp}.img

# The seed image IS the arming token. Attach it FIRST: if this machine has no
# seed the fetch 404s, we never touch the ISO, and the firmware moves on.
sanhook --drive 0x81 \${base}/seeds/\${seedimg} || goto notarmed

echo kldload: \${net0/mac:hexhyp} is armed — booting the installer ISO
sanboot \${base}/iso/kldload.iso

:notarmed
echo kldload: no interface of this machine is armed — continuing boot order
exit
IPXESAN
        log "  sanboot: boot.ipxe written (sanhook seed + sanboot ISO)"
    else
        cat >"$root/boot.ipxe" <<IPXE
#!ipxe
# Generated by deploy.sh pxe-serve. Edit the tree, not this file.
set base ${base}
# iPXE numbers interfaces in enumeration order, and net0 is NOT necessarily the
# one that netbooted. fiend, 2026-09-11: dnsmasq saw the PXE request from
# f0:2f:74 while the script asked for the a0:36:9f seed, because that NIC
# enumerated first. Arming both MACs was the workaround; probing is the fix.
# \${netX/...} is empty in Fedora's build unless DHCP ran on it (checked in
# qemu), so it is not relied on. Four NICs covers every board I have met.
# iPXE does NOT short-circuit a chain of && / || across lines the way a shell
# does. The first cut of this probe chained them; on fiend (2026-09-11) it
# probed net1 after net0 had already matched, then probed net2 and net3 which
# do not exist -- \${net2/mac:hexhyp} expands EMPTY, so it fetched
# /answers/.env, took a 404, and printed an ipxe.org error at the console.
# Explicit labels, one per interface, every failure routed by goto.
set seedfile
isset \${net0/mac} || goto try1
imgfetch --name probe \${base}/answers/\${net0/mac:hexhyp}.env || goto try1
imgfree probe
set seedfile \${net0/mac:hexhyp}.env
set bootmac \${net0/mac:hexhyp}
goto armed
:try1
isset \${net1/mac} || goto try2
imgfetch --name probe \${base}/answers/\${net1/mac:hexhyp}.env || goto try2
imgfree probe
set seedfile \${net1/mac:hexhyp}.env
set bootmac \${net1/mac:hexhyp}
goto armed
:try2
isset \${net2/mac} || goto try3
imgfetch --name probe \${base}/answers/\${net2/mac:hexhyp}.env || goto try3
imgfree probe
set seedfile \${net2/mac:hexhyp}.env
set bootmac \${net2/mac:hexhyp}
goto armed
:try3
isset \${net3/mac} || goto notarmed
imgfetch --name probe \${base}/answers/\${net3/mac:hexhyp}.env || goto notarmed
imgfree probe
set seedfile \${net3/mac:hexhyp}.env
set bootmac \${net3/mac:hexhyp}
goto armed
:armed
imgfree probe ||

# ip=dhcp rd.neednet=1: root=live:http://... is fetched by dracut from INSIDE
# the initramfs, which has no network unless asked. Without these the kernel
# and initrd load fine, the screen goes blank, and nothing is ever requested —
# the server sees the kernel fetched and then silence (fiend, 2026-09-09).
#
# Ask for this machine's answers FIRST. A 404 means it is not armed, and we
# must neither download the rootfs nor let the installer near its disk. iPXE
# treats a failed imgfetch as an error, so || sends us to :notarmed and the
# firmware moves on to the next boot device.
# --name, not a trailing word: "imgfetch URL armed" passes "armed" as an
# ARGUMENT to the fetched image rather than naming it, so the image ends up
# named after the URL and the imgfree below fails on a name that does not
# exist. iPXE aborts the script there, which reads as "could not boot image"
# on the console and drops the machine back to its local disk — after
# successfully fetching the answers file, so the logs look like it worked.
# (fiend, 2026-09-09)
isset \${seedfile} || goto notarmed

echo kldload: \${bootmac} is armed — installing
kernel \${base}/kldload/vmlinuz initrd=initrd.img root=live:\${base}/kldload/squashfs.img ${_iso_args} ip=dhcp rd.neednet=1 kldload.seed=\${base}/answers/\${seedfile} console=tty0
initrd \${base}/kldload/initrd.img
boot

:notarmed
echo kldload: no interface of this machine is armed — continuing boot order
exit
IPXE
    fi

    # Which interface carries the address clients will fetch from.
    local _pxe_ip _pxe_iface
    _pxe_ip="$(sed -n 's|http://\([0-9.]*\):.*|\1|p' <<<"$base")"
    _pxe_iface="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$_pxe_ip" '$4 ~ "^"ip"/" {print $2; exit}')"
    if [[ -z "$_pxe_iface" ]]; then
        _pxe_iface="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
        log "  WARN: could not match $_pxe_ip to an interface; using ${_pxe_iface:-none}"
    fi
    log "  dnsmasq will bind interface $_pxe_iface"

    cat >"$root/dnsmasq.conf" <<DNS
# kldload netboot — proxyDHCP, so this answers PXE alongside the network's
# existing DHCP server rather than replacing it. Nothing here hands out
# addresses.
#
#   sudo dnsmasq --conf-file=$root/dnsmasq.conf --no-daemon
#
port=0
log-dhcp
# Bind to the ONE interface that serves this subnet, not to every address.
# A kldload host runs libvirt, whose own dnsmasq already holds :67 on virbr0,
# so an unbound instance dies with "failed to bind DHCP server socket: Address
# already in use" and the netboot silently never answers (onyx, 2026-09-09).
interface=${_pxe_iface}
bind-interfaces
enable-tftp
tftp-root=$root/ipxe
# Chain: firmware loads ipxe.efi over TFTP, iPXE then loads boot.ipxe over
# HTTP. The tag test stops iPXE chainloading itself in a loop.
dhcp-range=$(sed -n 's|http://\([0-9.]*\):.*|\1|p' <<<"$base"),proxy
dhcp-match=set:ipxe,175
# proxyDHCP advertises boot options with pxe-service, NOT dhcp-boot alone.
# With only dhcp-boot a proxy sees the client's PXEClient vendor class, logs
# it, and offers nothing back — the machine retries forever and never fetches
# anything. Measured against fiend's UEFI client (Arch:00007) on 2026-09-09.
# Both architectures are advertised: 00000 is legacy BIOS, 00007/00009 are
# x64 UEFI.
pxe-service=tag:!ipxe,x86PC,"kldload netboot (BIOS)",undionly.kpxe
pxe-service=tag:!ipxe,x86-64_EFI,"kldload netboot (UEFI)",ipxe-x86_64.efi
pxe-service=tag:!ipxe,BC_EFI,"kldload netboot (UEFI)",ipxe-x86_64.efi
# Once iPXE itself is running it identifies as option 175 and is handed the
# script over HTTP instead of another chainload, which is what stops a loop.
dhcp-boot=tag:ipxe,$base/boot.ipxe
DNS

    # The port comes from $base, not a literal: pxe-serve regenerates
    # boot.ipxe and dnsmasq.conf for whatever --url says, and printing 8080
    # here sent the operator to start the server on a port nothing referenced.
    local _port
    _port="$(sed -n 's|.*:\([0-9]\{1,5\}\)$|\1|p' <<<"$base")"
    [[ -n "$_port" ]] || _port=80

    # The web server is part of the netboot, so it is generated here rather
    # than left to the operator. It used to be a hint that said
    # "python3 -m http.server", and that hint was wrong in two ways that both
    # fail quietly rather than erroring:
    #
    #   * No Range support. http.server ignores a byte-range request and
    #     answers 200 with the entire file. --sanboot hands the ISO to the
    #     firmware as a virtual disk and iPXE reads it in small pieces, so a
    #     2 GB ISO becomes a 2 GB transfer per read and the boot never moves.
    #   * Directory listings. Every armed machine's answers file lives under
    #     answers/ with KLDLOAD_PASSWORD in clear, and http.server lists a
    #     directory on request. A GET of /answers/ was served as a full listing
    #     on 2026-09-09 before anybody thought to look at it. autoindex off
    #     below is that fix, and it is the reason this file is generated
    #     instead of described in a sentence somebody has to read.
    cat >"$root/nginx.conf" <<NGINX
# kldload netboot tree — generated by deploy.sh pxe-serve.
# Edit the tree, not this file: the next pxe-serve overwrites it.
#
#   sudo nginx -c $root/nginx.conf
#
# nginx rather than python3 -m http.server because iPXE needs byte-range
# requests for --sanboot, and because this tree must never be listable: the
# answers files under answers/ carry the install password in clear.
worker_processes 1;
error_log $root/nginx-error.log warn;
pid $root/nginx.pid;
events { worker_connections 256; }
http {
    default_type application/octet-stream;
    access_log $root/nginx-access.log;
    sendfile on;
    # The clients here are firmware and an initramfs curl pulling a 2 GB
    # squashfs. A slow one is not a stalled one, so do not cut it off.
    send_timeout 300s;
    server {
        listen $_port;
        root $root;
        # Not tidiness. See the note above: a listing of answers/ hands out
        # every armed machine's password.
        autoindex off;
    }
}
NGINX
    [[ -s "$root/nginx.conf" ]] || die "pxe-serve: nginx.conf did not land in $root"

    log "pxe-serve: tree ready"
    printf '\n  Serve it:      sudo nginx -c %s/nginx.conf\n' "$root" >&2
    printf '  PXE/DHCP:      sudo dnsmasq --conf-file=%s/dnsmasq.conf --no-daemon\n' "$root" >&2
    printf '  Arm a machine: ./deploy.sh pxe-arm <mac> --answers <file>\n\n' >&2
}

cmd_pxe_arm() {
    local mac="" answers="" root="$PXE_ROOT_DEFAULT"
    [[ $# -gt 0 ]] || die "pxe-arm: usage: pxe-arm <mac> --answers <file> [--root DIR]"
    mac="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --answers)
            answers="${2:?--answers needs a path}"
            shift 2
            ;;
        --root)
            root="${2:?--root needs a path}"
            shift 2
            ;;
        *) die "pxe-arm: unknown argument: $1" ;;
        esac
    done
    [[ -n "$answers" ]] || die "pxe-arm: --answers <file> is required"
    [[ -f "$answers" ]] || die "pxe-arm: no such answers file: $answers"
    bash -n "$answers" || die "pxe-arm: $answers is not valid shell"
    grep -q '^KLDLOAD_DISTRO=' "$answers" || die "pxe-arm: $answers sets no KLDLOAD_DISTRO"
    [[ -d "$root/answers" ]] || die "pxe-arm: $root/answers does not exist — run pxe-serve first"

    local name
    name="$(_pxe_mac_file "$mac")"
    # 0644, not 0600: nginx's worker runs as its own user and must read this,
    # and iPXE cannot authenticate, so on-disk mode buys nothing anyway. The
    # real protections are that the serving host is trusted and the file is
    # removed once the machine is installed. Say so when a password is inside.
    if grep -qE '^KLDLOAD_(PASSWORD|ZFS_PASSPHRASE)=CHANGE-ME' "$answers"; then
        die "pxe-arm: $answers still has the CHANGE-ME placeholder password — set a real one"
    fi
    install -m 0644 "$answers" "$root/answers/$name"
    [[ -s "$root/answers/$name" ]] || die "pxe-arm: $root/answers/$name did not land"
    if grep -qE '^KLDLOAD_(PASSWORD|ZFS_PASSPHRASE)=.+' "$answers"; then
        log "  WARN: this answers file carries a password. It is served unauthenticated to"
        log "        the LAN until you disarm: rm $root/answers/$name — do so after the install."
    fi
    log "pxe-arm: ARMED $mac — next netboot installs $(sed -n 's/^KLDLOAD_DISTRO=//p' "$answers")/$(sed -n 's/^KLDLOAD_PROFILE=//p' "$answers")"
    log "  disarm with: rm $root/answers/$name"
}

# ── Seed disk ────────────────────────────────────────────────────────────────
# Writes the FAT32 volume kldload-autoinstall looks for by label. mtools does
# the copy, so building an image needs no root and no loop mount; only writing
# to a real device does.
#
# HISTORY: this subcommand was named in kldload-autoinstall's header from the
# day it was written and never existed, so the unattended path could not be
# driven end to end by anyone. It went unnoticed because the unit was not
# starting either -- its enablement symlink pointed at a debz-* name left over
# from the project's earlier identity. Both fixed 2026-09-07.
cmd_seed_disk() {
    local answers="" device="" image="" assume_yes="no" _a
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --answers)
            answers="${2:?--answers needs a path}"
            shift 2
            ;;
        --device)
            device="${2:?--device needs a path}"
            shift 2
            ;;
        --image)
            image="${2:?--image needs a path}"
            shift 2
            ;;
        --yes | -y)
            assume_yes=yes
            shift
            ;;
        *) die "seed-disk: unknown argument: $1" ;;
        esac
    done

    [[ -n "$answers" ]] || die "seed-disk: --answers <file> is required (see /etc/kldload/answers/)"
    [[ -f "$answers" ]] || die "seed-disk: no such answers file: $answers"
    # An answers file that is not valid shell would be sourced by the installer
    # under `set -a` and fail halfway through a wipe. Check it here, on a
    # machine with a keyboard attached.
    bash -n "$answers" || die "seed-disk: $answers is not valid shell"
    grep -q '^KLDLOAD_DISTRO=' "$answers" ||
        die "seed-disk: $answers sets no KLDLOAD_DISTRO — the installer would have nothing to install"

    [[ -n "$device" || -n "$image" ]] || die "seed-disk: one of --device or --image is required"
    [[ -z "$device" || -z "$image" ]] || die "seed-disk: --device and --image are mutually exclusive"

    local target
    if [[ -n "$image" ]]; then
        target="$image"
        rm -f "$target"
        truncate -s 32M "$target"
    else
        [[ -b "$device" ]] || die "seed-disk: not a block device: $device"
        # Refuse anything currently carrying a mounted filesystem. A seed disk
        # is a throwaway 32 MB stick; a running system's disk is not.
        if lsblk -no MOUNTPOINTS "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
            die "seed-disk: $device has mounted filesystems — refusing"
        fi
        local _size _model
        _size="$(lsblk -bdno SIZE "$device" 2>/dev/null || echo 0)"
        _model="$(lsblk -dno MODEL "$device" 2>/dev/null | tr -s ' ' || echo unknown)"
        if [[ "$assume_yes" != yes ]]; then
            printf '\n  About to ERASE %s (%s, %s)\n  Answers: %s\n\n  Type ERASE to continue: ' \
                "$device" "$_model" "$(numfmt --to=iec "${_size:-0}")" "$answers" >&2
            local _reply=""
            # read exits non-zero at EOF -- no tty, or stdin closed by a
            # wrapper. That is "not confirmed", which the compare below
            # already treats as a refusal, so the swallow costs nothing.
            read -r _reply || true
            [[ "$_reply" == "ERASE" ]] || die "seed-disk: not confirmed"
        fi
        target="$device"
    fi

    mkfs.vfat -n KLDLOADSEED "$target" >/dev/null || die "seed-disk: mkfs.vfat failed on $target"
    MTOOLS_SKIP_CHECK=1 mcopy -i "$target" "$answers" ::answers.env ||
        die "seed-disk: could not copy answers onto $target"

    # Outcome, not exit code: read the file back off the volume we just wrote
    # and compare it to the source. A seed that is subtly truncated installs a
    # machine wrong and says nothing.
    local _back
    _back="$(mktemp)"
    MTOOLS_SKIP_CHECK=1 mtype -i "$target" ::answers.env >"$_back" 2>/dev/null ||
        die "seed-disk: wrote $target but could not read answers.env back"
    if ! diff -q <(tr -d '\r' <"$_back") <(tr -d '\r' <"$answers") >/dev/null; then
        rm -f "$_back"
        die "seed-disk: answers.env on $target does not match $answers"
    fi
    rm -f "$_back"

    log "seed-disk: wrote $(basename "$answers") to $target (label KLDLOADSEED), verified byte-for-byte"
    log "  distro=$(sed -n 's/^KLDLOAD_DISTRO=//p' "$answers") profile=$(sed -n 's/^KLDLOAD_PROFILE=//p' "$answers")"
}

cmd_burn() {
    local iso requested="" assume_yes="${BURN_ASSUME_YES:-no}"
    # --yes travels as an ARGUMENT, not an environment variable, because
    # cmd_ship re-execs this through sudo and env_reset drops anything not in
    # env_keep. An unattended loop that silently regained a prompt would hang
    # forever behind a tee.
    local _a
    for _a in "$@"; do
        case "$_a" in
        --yes | -y) assume_yes="yes" ;;
        *) requested="$_a" ;;
        esac
    done
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found"

    # An explicitly named device wins over USB_DEVICE and over auto-detect.
    # HISTORY: `./deploy.sh burn /dev/sdX` was documented and accepted but the
    # argument was never passed to this function (dispatch called cmd_burn
    # with no args), so naming a disk silently burned to whatever auto-detect
    # picked instead — or died telling you to set USB_DEVICE. Naming a target
    # and writing 9 GB somewhere else is the worst shape a burn can have.
    if [[ -n "$requested" ]]; then
        USB_DEVICE="$requested"
    fi

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

    # Say what is about to be destroyed, and require agreement.
    #
    # WHY: this is an unrecoverable 9 GB overwrite of a whole block device,
    # chosen by auto-detect in the common case. The documented interface has
    # always claimed it "asks first" and it never did. Model and size are
    # printed because /dev/sdb means nothing to a human — "SanDisk 57.3G" is
    # what tells you whether it is the stick or the backup drive.
    #
    # Skipped when stdin is not a terminal (CI, scripts) or when
    # BURN_ASSUME_YES=yes, which is how cmd_ship keeps its unattended
    # build → burn → notify loop.
    if [[ -t 0 && "$assume_yes" != "yes" ]]; then
        local _model _size
        _model="$(lsblk -ndo MODEL "$USB_DEVICE" 2>/dev/null | tr -s ' ')"
        _size="$(lsblk -ndo SIZE "$USB_DEVICE" 2>/dev/null)"
        printf '\n  About to ERASE %s  [%s %s]\n  and write: %s\n\n' \
            "$USB_DEVICE" "${_model:-unknown}" "${_size:-?}" "$(basename "$iso")"
        local _reply
        read -r -p "  Type the device name to confirm: " _reply
        [[ "$_reply" == "$USB_DEVICE" ]] ||
            die "confirmation did not match — nothing was written"
    fi

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
        sudo "$0" burn --yes 2>&1
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
        # Setting USB_BURN_ON_DEPLOY=yes IS the consent; do not ask again
        # in the middle of an unattended build.
        cmd_burn --yes
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
menu) cmd_menu ;;
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
zfs-pin)
    # The kernel pin is DERIVED from ZFS, never remembered: newest release ->
    # its Linux-Maximum -> highest koji kernel at or below it. See
    # tools/zfs-kernel-pin for why the number must not be hand-maintained.
    exec "$ROOT/tools/zfs-kernel-pin" "${2:-report}"
    ;;
build-ai-docs) cmd_build_ai_docs ;;
builder-image) cmd_builder_image ;;
clean) cmd_clean ;;
burn) cmd_burn "${@:2}" ;;
seed-disk) cmd_seed_disk "${@:2}" ;;
pxe-serve) cmd_pxe_serve "${@:2}" ;;
pxe-arm) cmd_pxe_arm "${@:2}" ;;
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
  build-ollama-darksite  Pre-pull the Ollama models (llama3.2:3b + nomic-embed-text, ~2.2GB) for offline AI
                         OPT-IN: build with KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1 to bake them into
                         the ISO for an air-gapped install. By default no weights ship — Ollama
                         and Open WebUI are still installed and running, with an empty model list.
  build-k8s-darksite     Pre-pull Kubernetes + Cilium container images
  build-ai-docs          Scrape website + OCR PDF for AI knowledge base
  build-ai-appliance     Build self-contained Bob AI appliance ISO
  clean                  Remove build artifacts (preserves darksite caches)

Deploy:
  kvm-deploy             Deploy ISO to local KVM (virt-install, UEFI, VNC)
  kvm-deploy-bob         Deploy Bob AI appliance to KVM (created off)
  proxmox-deploy         Deploy ISO to remote Proxmox (SSH + qm API)
  deploy-all             Deploy to KVM + Proxmox + print USB command
  burn [/dev/sdX] [--yes]
                         Write ISO to USB drive. Names the target device;
                         falls back to USB_DEVICE, then to auto-detect of a
                         single removable drive. Asks for confirmation when
                         interactive; --yes skips the prompt.
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
  EDITION         Edition: free (full) or core (ZFS-only) (default: free);
                  net = shorthand for EDITION=free PAYLOAD=net
  PAYLOAD         full = offline mirrors, k8s images and Ollama baked in
                  (~15 GB, installs with no network); net = the same tools and
                  installer with no payload (~3 GB, installs from the distro's
                  own mirrors). The ISO name carries -net. (default: full)
  DARKSITES       which offline mirrors to carry, any of: debian fedora el
                  (default: all three; one alone names the ISO, e.g. -fedora)
  K8S_IMAGES      yes/no — bake the Kubernetes container images (~1.5 GB)
  OLLAMA          yes/no — bake the Ollama engine + Open WebUI (~3.4 GB)
                  ./deploy.sh menu picks all of these from a checklist.
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
