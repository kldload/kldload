#!/usr/bin/env bash
set -euo pipefail

# build-darksite-ollama.sh — Ollama model darksite builder.
#
# Pulls the Ollama models we want baked into every ISO (default:
# llama3.2:3b + nomic-embed-text) into a host-shared blob store. `builder/build-iso.sh`
# copies the result into the ISO rootfs at /root/darksite/ollama/,
# and `kldload-firstboot` rsyncs it into /usr/share/ollama/.ollama/
# on first boot so Bob is chat-ready without internet.
#
# The store is HOST-SHARED and survives between builds, so this script
# prunes it to exactly MODELS= at the end. Without that prune the store is
# append-only: build-iso.sh copies the whole models/ tree, so every model
# ever pulled ships forever. That is how a 1.4.0-rc6 desktop ISO arrived
# carrying llama3.2:3b (an older default) AND qwen3:14b — 11 GB of models
# for a machine that loads one of them (2026-08-15).
#
# Runs inside an `ollama/ollama` container. Output layout matches what
# Ollama expects under $OLLAMA_MODELS (default /root/.ollama):
#     models/blobs/sha256-<hex>
#     models/manifests/registry.ollama.ai/library/<model>/<tag>

# Default bakes llama3.2:3b (chat, ~2 GB) plus nomic-embed-text (embeddings,
# ~275 MB). Both are required for a fully darksite Bob — chat alone cannot
# answer from the knowledge base without the embedding model.
#
# WHY THE SMALL MODEL IS THE DEFAULT, not qwen3:14b (~9 GB):
#   1. A 3B model runs on CPU. qwen3:14b needs >=8 GB VRAM or the [ai] phase
#      skips Bob entirely (kldload-autodeploy, KLDLOAD_MIN_AI_VRAM_GB) — so
#      the 9 GB payload was dead weight on every machine without a big GPU,
#      i.e. it made "ready to go out of the box" work on FEWER machines.
#   2. It is ~9 GB off the ISO, which is most of a build-and-burn cycle.
# Operators who want a larger model pull it themselves once they have a
# network; that is a deliberate one-command step, not a default cost paid by
# every ISO. Override at build time with OLLAMA_MODELS="...".
MODELS="${OLLAMA_MODELS:-llama3.2:3b nomic-embed-text}"
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
#
# WHY THE IFS INCLUDES A SPACE: deploy.sh passes the list space-separated
# ("qwen3:14b nomic-embed-text"), but this split was comma-only, so the whole
# string arrived as ONE element and the following line stripped its spaces —
# producing the model name "qwen3:14bnomic-embed-text" and failing every build
# with "pull model manifest: file does not exist" (2026-08-14). Accept either
# separator, and never strip characters from inside a name.
IFS=', ' read -ra _models <<<"$MODELS"
for _m in "${_models[@]}"; do
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

# ─── Prune the store down to exactly MODELS= ────────────────────────────────
#
# The store is host-shared and persists between builds, and build-iso.sh
# copies models/ wholesale, so without this every model ever pulled ships in
# every future ISO. Changing MODELS= alone shrinks nothing.
#
# Both trees get pruned. The legacy .ollama tree is copied back into
# MODELS_DIR above, so pruning only MODELS_DIR would let the next build
# resurrect exactly what this one removed.
#
# Args: $1 — a models root holding blobs/ and manifests/
# Returns: nothing; removes files in place. Reads _models from the caller.
_prune_models_tree() {
    local _root="$1"
    local _lib="${_root}/manifests/registry.ollama.ai/library"
    [[ -d "${_lib}" ]] || return 0

    # Wanted manifest paths. `ollama pull name` with no tag means :latest,
    # so an untagged entry in MODELS= has to expand the same way or we would
    # delete the manifest we just pulled.
    local -a _want=()
    local _m _name _tag
    for _m in "${_models[@]}"; do
        [[ -z "$_m" ]] && continue
        _name="${_m%%:*}"
        _tag="${_m#*:}"
        [[ "${_tag}" == "${_m}" ]] && _tag="latest"
        _want+=("${_lib}/${_name}/${_tag}")
    done

    local _f _w _keep _removed=0
    while IFS= read -r -d '' _f; do
        _keep=0
        for _w in "${_want[@]}"; do
            if [[ "${_f}" == "${_w}" ]]; then
                _keep=1
                break
            fi
        done
        if [[ "${_keep}" -eq 0 ]]; then
            log "  prune manifest: ${_f#"${_lib}"/}"
            rm -f "${_f}"
            _removed=$((_removed + 1))
        fi
    done < <(find "${_lib}" -type f -print0 2>/dev/null)

    # Empty model dirs left behind by the manifests we just dropped.
    find "${_lib}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    # Now drop blobs nothing references any more. Digests appear inside the
    # manifest JSON as sha256:<hex>; the blob files are named sha256-<hex>.
    # Derive the keep-set from the manifests that SURVIVED rather than from
    # MODELS=, so a shared blob (two models, same layer) is never orphaned.
    local _refs
    _refs="$(find "${_root}/manifests" -type f -exec cat {} + 2>/dev/null |
        grep -oE 'sha256:[0-9a-f]{64}' | sort -u | tr ':' '-' || true)"

    local _b
    while IFS= read -r -d '' _b; do
        if ! grep -qxF "$(basename "${_b}")" <<<"${_refs}"; then
            log "  prune blob: $(basename "${_b}") ($(du -h "${_b}" | cut -f1))"
            rm -f "${_b}"
            _removed=$((_removed + 1))
        fi
    done < <(find "${_root}/blobs" -type f -name 'sha256-*' -print0 2>/dev/null)

    log "pruned ${_removed} file(s) from ${_root}"
}

_prune_models_tree "${MODELS_DIR}"
_prune_models_tree "${MODELS_DIR%/models}/.ollama/models"

_blob_count=$(find "${MODELS_DIR}/blobs" -type f 2>/dev/null | wc -l)
_size=$(du -sh "${MODELS_DIR}" 2>/dev/null | cut -f1)
log "Ollama darksite ready: ${MODELS_DIR} (${_blob_count} blobs, ${_size})"

# Sanity check — a complete pull leaves several blobs per model. Catches
# silent failures where a pull aborted mid-download and left a manifest
# with no layers behind it.
if [[ "${_blob_count}" -lt 3 ]]; then
    die "too few blobs (${_blob_count}) — model pull likely incomplete"
fi
