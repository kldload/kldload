#!/usr/bin/env bash
set -euo pipefail

# build-darksite-ollama.sh — Ollama model darksite builder.
#
# Pulls the Ollama models we want baked into every ISO (default:
# llama3.1:8b) into a host-shared blob store. `builder/build-iso.sh`
# copies the result into the ISO rootfs at /root/darksite/ollama/,
# and `kldload-firstboot` rsyncs it into /usr/share/ollama/.ollama/
# on first boot so Bob is chat-ready without internet.
#
# Runs inside an `ollama/ollama` container. Output layout matches what
# Ollama expects under $OLLAMA_MODELS (default /root/.ollama):
#     models/blobs/sha256-<hex>
#     models/manifests/registry.ollama.ai/library/<model>/<tag>

# Default bakes qwen3:14b only — the model /etc/bob/Modelfile.bob is
# built FROM and the tier firstboot/autodeploy resolve "recommended" to.
# Baking anything else forces `ollama create bob` into a second ~9 GB
# registry fetch at firstboot — a hard failure on air-gapped installs.
MODELS="${OLLAMA_MODELS:-qwen3:14b}"
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
MODELS_DIR="${DARKSITE_OUT}/models"

log() { printf '[%s] [darksite-ollama] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
    log "FATAL: $*"
    exit 1
}

mkdir -p "${MODELS_DIR}"

# Start ollama serve in the background. The ollama/ollama image does NOT
# ship curl, so we use bash's /dev/tcp builtin to detect "port 11434 is
# listening" — which is the real readiness signal anyway (ollama opens
# the socket before accepting requests). If serve dies, we dump its log
# so the build surfaces the actual reason instead of a generic timeout.
port_listening() {
    exec 3<>/dev/tcp/127.0.0.1/11434 2>/dev/null && {
        exec 3<&-
        exec 3>&-
        return 0
    }
    return 1
}

if ! port_listening; then
    log "Starting ollama serve..."
    # Write blobs directly to the final location so we don't need rsync
    # (not in the ollama/ollama image). ollama writes ${OLLAMA_MODELS}/blobs/
    # and ${OLLAMA_MODELS}/manifests/, which is exactly the layout
    # build-iso.sh expects at /root/darksite/ollama/models/ inside the ISO.
    export OLLAMA_MODELS="${MODELS_DIR}"
    export OLLAMA_HOST="127.0.0.1:11434"
    mkdir -p "$OLLAMA_MODELS"
    ollama serve >/tmp/ollama.log 2>&1 &
    _ollama_pid=$!
    # Wait up to 60s for the port to accept connections
    for i in $(seq 1 60); do
        sleep 1
        port_listening && break
    done
    if ! port_listening; then
        log "FATAL: ollama API port 11434 not listening after 60s"
        log "ollama serve log:"
        sed 's/^/    /' /tmp/ollama.log 2>&1 | tail -40 >&2
        log "ollama serve process state:"
        ps -o pid,stat,cmd -p "$_ollama_pid" 2>&1 >&2 || log "  (process died)"
        exit 1
    fi
    log "ollama API is up"
fi

# Point ollama at our output dir so the pulled models land where we want
# them directly (no post-move needed). OLLAMA_MODELS env is honoured.
export OLLAMA_MODELS="${MODELS_DIR%/models}/.ollama/models"
mkdir -p "$OLLAMA_MODELS"

# Pull every requested model. `ollama pull` is idempotent — if the blob
# is already present it's a no-op.
IFS=',' read -ra _models <<<"$MODELS"
for _m in "${_models[@]}"; do
    _m="${_m// /}"
    [[ -z "$_m" ]] && continue
    log "Pulling ${_m}..."
    ollama pull "${_m}" 2>&1 | tail -5 || die "pull failed: ${_m}"
done

# ollama wrote directly to ${MODELS_DIR} via the OLLAMA_MODELS env var,
# so no post-pull copy is needed. Layout is already what build-iso.sh
# and kldload-firstboot's rehydrate expect: blobs/ + manifests/ under
# /output/models/ on the host (mounted as ${MODELS_DIR} in-container).

# Also copy over pre-existing blobs from a prior partial run (legacy
# layout from earlier builds that wrote to .ollama/models/) so we
# don't re-download them.
if [[ -d "${MODELS_DIR%/models}/.ollama/models" ]]; then
    for d in blobs manifests; do
        if [[ -d "${MODELS_DIR%/models}/.ollama/models/${d}" ]]; then
            mkdir -p "${MODELS_DIR}/${d}"
            cp -a "${MODELS_DIR%/models}/.ollama/models/${d}/." "${MODELS_DIR}/${d}/" 2>/dev/null || true
        fi
    done
fi

_blob_count=$(find "${MODELS_DIR}/blobs" -type f 2>/dev/null | wc -l)
_size=$(du -sh "${MODELS_DIR}" 2>/dev/null | cut -f1)
log "Ollama darksite ready: ${MODELS_DIR} (${_blob_count} blobs, ${_size})"

# Sanity check — require at least 3 blobs (layers) for llama3.1:8b to
# exist. Catches silent failures where pull aborted mid-download.
if [[ "${_blob_count}" -lt 3 ]]; then
    die "too few blobs (${_blob_count}) — model pull likely incomplete"
fi
