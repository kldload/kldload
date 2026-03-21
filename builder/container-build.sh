#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# container-build.sh — runs on HOST; launches builder container for ISO build
# ---------------------------------------------------------------------------

ROOT="${ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
PROFILE="${PROFILE:-desktop}"
EDITION="${EDITION:-free}"
ARCH="${ARCH:-amd64}"
BUILDER_IMAGE="${BUILDER_IMAGE:-kldload-live-builder:latest}"
BUILDER_CONTAINER="${BUILDER_CONTAINER:-kldload-free-build-$$}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"
LOG_DIR="${LOG_DIR:-$ROOT/live-build/logs}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '[%s] [container-build] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
    printf '[%s] [container-build] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# On exit (success or failure): copy latest lb log to /home/todd/logs/
# ---------------------------------------------------------------------------
_copy_log_on_exit() {
    local exit_code=$?
    local todd_log_dir="${TODD_LOG_DIR:-/home/todd/logs}"
    if [[ -d "$todd_log_dir" ]]; then
        local latest
        latest="$(find "${LOG_DIR:-/tmp}" -name "build-${PROFILE:-desktop}-${ARCH:-amd64}-*.log" \
                  2>/dev/null | sort | tail -1 || true)"
        if [[ -n "$latest" ]] && [[ -f "$latest" ]]; then
            local dest_name="${EDITION:-free}-$(basename "$latest")"
            cp "$latest" "${todd_log_dir}/${dest_name}" 2>/dev/null || true
            ln -sf "${todd_log_dir}/${dest_name}" "${todd_log_dir}/${EDITION:-free}-lb-build-latest.log" 2>/dev/null || true
        fi
    fi
    return $exit_code
}
trap _copy_log_on_exit EXIT

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------

detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1; then
        echo "podman"
    else
        die "Neither docker nor podman found."
    fi
}

RUNTIME="$(detect_runtime)"
log "Container runtime: $RUNTIME"
log "Profile:           $PROFILE"
log "Edition:           $EDITION"
log "Arch:              $ARCH"
log "Builder image:     $BUILDER_IMAGE"
log "Container name:    $BUILDER_CONTAINER"
log "Output dir:        $OUTPUT_DIR"
log "Log dir:           $LOG_DIR"
log "Root:              $ROOT"

# ---------------------------------------------------------------------------
# Validate profile
# ---------------------------------------------------------------------------

case "$PROFILE" in
    desktop|server) ;;
    *) die "Invalid PROFILE '$PROFILE'. Must be 'desktop' or 'server'." ;;
esac

# ---------------------------------------------------------------------------
# Validate builder image exists
# ---------------------------------------------------------------------------

if ! "$RUNTIME" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    die "Builder image '$BUILDER_IMAGE' not found. Run 'deploy.sh builder-image' first."
fi

# ---------------------------------------------------------------------------
# Ensure output and log directories exist
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# Run the builder container
# ---------------------------------------------------------------------------

log "Starting builder container '$BUILDER_CONTAINER'..."

"$RUNTIME" run \
    --name "$BUILDER_CONTAINER" \
    --rm \
    --privileged \
    --volume "${ROOT}:/build:z" \
    --env PROFILE="$PROFILE" \
    --env EDITION="$EDITION" \
    --env ARCH="${ARCH:-amd64}" \
    --env SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --env OUTPUT_DIR="/build/live-build/output" \
    --env LOG_DIR="/build/live-build/logs" \
    "$BUILDER_IMAGE" \
    || die "Builder container exited with non-zero status — check logs in $LOG_DIR"

# ---------------------------------------------------------------------------
# Report output ISO path
# ---------------------------------------------------------------------------

log "Build container exited. Scanning for output ISO..."

ISO_PATH=""
while IFS= read -r -d '' f; do
    ISO_PATH="$f"
done < <(find "$OUTPUT_DIR" -name "*.iso" -print0 2>/dev/null | sort -z)

if [[ -z "$ISO_PATH" ]]; then
    die "No ISO found in $OUTPUT_DIR after build."
fi

log "ISO artifact: $ISO_PATH"
log "Size: $(du -sh "$ISO_PATH" 2>/dev/null | cut -f1)"

if [[ -f "${ISO_PATH}.sha256" ]]; then
    log "SHA256: $(cat "${ISO_PATH}.sha256")"
fi

# ---------------------------------------------------------------------------
# Copy the detailed lb build log to TODD_LOG_DIR so it appears alongside
# the deploy log for easy diffing.  The deploy-level exec tee already has
# the full console stream; this is the verbatim lb build transcript.
# ---------------------------------------------------------------------------
TODD_LOG_DIR="${TODD_LOG_DIR:-/home/todd/logs}"
if [[ -d "$TODD_LOG_DIR" ]]; then
    LATEST_LB_LOG="$(find "$LOG_DIR" -name "build-${PROFILE}-${ARCH}-*.log" \
                     -newer "$OUTPUT_DIR" -o \
                     -name "build-${PROFILE}-${ARCH}-*.log" 2>/dev/null \
                     | sort | tail -1 || true)"
    if [[ -n "$LATEST_LB_LOG" ]] && [[ -f "$LATEST_LB_LOG" ]]; then
        cp "$LATEST_LB_LOG" "${TODD_LOG_DIR}/$(basename "$LATEST_LB_LOG")"
        ln -sf "${TODD_LOG_DIR}/$(basename "$LATEST_LB_LOG")" "${TODD_LOG_DIR}/${EDITION}-lb-build-latest.log"
        log "lb build transcript copied to: ${TODD_LOG_DIR}/${EDITION}-lb-build-latest.log"
    fi
fi

echo "$ISO_PATH"
