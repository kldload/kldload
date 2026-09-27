#!/usr/bin/env bash
# =============================================================================
# fetch-cloud-images.sh — cache and verify the cloud images the goldens boot
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Reads each distro's cloud image URL out of klab's CLOUD_IMAGES table,
#      the one list klab and kube-cluster already download from. Fedora's is
#      re-resolved to the newest build in its release directory, as klab does.
#   2. Fetches the vendor's checksum file for each image.
#   3. Keeps a cached image that still matches its recorded checksum and is
#      younger than CLOUD_IMAGE_MAX_AGE_DAYS; otherwise downloads it again and
#      verifies it against the vendor's checksum before it replaces the cache.
#   4. Writes SHA256SUMS over the whole set, which the installer checks again
#      after copying the images onto a machine.
#
# WHY IT EXISTS (2026-09-27)
#   Every golden, klab's five and the Kubernetes one, started by downloading a
#   cloud image, so an ISO that carried every package, chart and container
#   image still could not build a single VM without the internet. The cloud
#   image was the one download the operator already knew about; this closes it.
#
# INPUT:  $1 cache directory (default live-build/darksite-cloud-cache)
#         CLOUD_DISTROS  which to fetch (default: centos rocky fedora debian ubuntu)
#         CLOUD_IMAGE_MAX_AGE_DAYS  reuse a verified cache this young (default 14)
# OUTPUT: <dir>/<distro>-cloud.qcow2, <dir>/<distro>-cloud.source, <dir>/SHA256SUMS
# EXIT:   0 every distro asked for is cached and verified · 1 one or more are
#         missing or failed verification · 2 usage (no klab table found)
#
# Notes
#   - Debian's image is a daily build and Ubuntu's "current" moves too; the age
#     limit is what stops every ISO build downloading ~3 GB again.
#   - With no network, a cached image that verifies against its own recorded
#     checksum is used whatever its age, with a warning. A distro with no cache
#     and no network is a failure: an offline ISO without its base image is the
#     half-works case this script exists to remove.
#   - Arch is not fetched: it is demoted and its encrypted boot panics. RHEL
#     has no anonymous URL; klab asks the operator for one.
# =============================================================================
set -Eeuo pipefail
trap 'echo "fetch-cloud-images.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

case "${1:-}" in
-h | --help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT="${1:-${ROOT}/live-build/darksite-cloud-cache}"
KLAB="${ROOT}/live-build/config/includes.chroot/usr/local/bin/klab"
MAX_AGE="${CLOUD_IMAGE_MAX_AGE_DAYS:-14}"
read -r -a DISTROS <<<"${CLOUD_DISTROS:-centos rocky fedora debian ubuntu}"

log() { printf '[%s] [cloud-images] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

[[ -r "$KLAB" ]] || {
    log "ERROR: ${KLAB} not found — the image URLs live in klab's CLOUD_IMAGES table"
    exit 2
}
mkdir -p "$OUT"

# ─── URLs from klab's table ──────────────────────────────────────────────────
# Parsed, never sourced or eval'd: klab is a 5,000-line program, and only its
# [distro]="https://..." lines are wanted here.
declare -A URL=()
while IFS='|' read -r _d _u; do
    URL[$_d]="$_u"
done < <(sed -nE 's/^[[:space:]]*\[([a-z]+)\]="(https:[^"]+)"$/\1|\2/p' "$KLAB")

# _fedora_latest <url> — the newest Fedora-Cloud-Base-Generic build in the same
# release directory, and that directory's CHECKSUM file, as "url|sumsurl".
# Asks the Fedora master, not the redirector: the redirector has handed out a
# mirror that refused 443 (fiend 2026-09-13).
_fedora_latest() {
    local dir listing img sums
    dir="${1%/*}/"
    dir="https://dl.fedoraproject.org/${dir#https://download.fedoraproject.org/}"
    listing="$(curl -fsSL --max-time 20 "$dir")" || return 1
    img="$(grep -oE 'Fedora-Cloud-Base-Generic-[0-9]+-[0-9.]+\.x86_64\.qcow2' <<<"$listing" | sort -V -u | tail -1)"
    sums="$(grep -oE 'Fedora-Cloud-[0-9]+-[0-9.]+-x86_64-CHECKSUM' <<<"$listing" | sort -V -u | tail -1)"
    [[ -n "$img" && -n "$sums" ]] || return 1
    printf '%s|%s\n' "${dir}${img}" "${dir}${sums}"
}

# _sums_url <distro> <url> — where that vendor publishes the checksum.
_sums_url() {
    case "$1" in
    centos) printf '%s.SHA256SUM\n' "$2" ;;
    rocky) printf '%s.CHECKSUM\n' "$2" ;;
    debian) printf '%s/SHA512SUMS\n' "${2%/*}" ;;
    ubuntu) printf '%s/SHA256SUMS\n' "${2%/*}" ;;
    *) return 1 ;;
    esac
}

# _expected <sumsfile> <basename> — the hash the vendor lists for that file.
# Two formats exist: "SHA256 (name) = hex" (CentOS, Rocky, Fedora) and
# "hex  name" / "hex *name" (Debian, Ubuntu). Either way the hash is the one
# 64- or 128-character hex run on the line that names the file.
_expected() {
    awk -v f="$2" '
        index($0, "(" f ")") || $NF == f || $NF == "*" f {
            for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]+$/ && (length($i) == 64 || length($i) == 128)) { print $i; exit }
        }' "$1"
}

# _hash_of <file> <expected> — the file's hash in the same algorithm.
_hash_of() {
    if ((${#2} == 128)); then
        sha512sum "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

_ok=0
_failed=()
for d in "${DISTROS[@]}"; do
    url="${URL[$d]:-}"
    dest="${OUT}/${d}-cloud.qcow2"
    src="${OUT}/${d}-cloud.source"
    if [[ -z "$url" ]]; then
        log "FAIL ${d}: no URL in klab's CLOUD_IMAGES table"
        _failed+=("$d")
        continue
    fi
    sums_url=""
    if [[ "$d" == fedora ]]; then
        if _pair="$(_fedora_latest "$url")"; then
            url="${_pair%%|*}"
            sums_url="${_pair#*|}"
        fi
    else
        sums_url="$(_sums_url "$d" "$url")"
    fi

    # The cache first. A .source file records the URL and hash it was verified
    # against, so a cached image can be re-checked with no network at all.
    cached_ok=0
    if [[ -s "$dest" && -s "$src" ]]; then
        _rec="$(sed -n 's/^hash=//p' "$src")"
        if [[ -n "$_rec" && "$(_hash_of "$dest" "$_rec")" == "$_rec" ]]; then
            cached_ok=1
        else
            log "${d}: cached image no longer matches its recorded hash — refetching"
        fi
    fi
    if ((cached_ok)) && [[ -z "$(find "$dest" -mtime +"$MAX_AGE" -print)" ]]; then
        log "CACHED ${d}: $(du -h "$dest" | cut -f1), verified, under ${MAX_AGE} days old"
        _ok=$((_ok + 1))
        continue
    fi

    sums="$(mktemp -p "$OUT" .sums.XXXXXX)"
    if [[ -z "$sums_url" ]] || ! curl -fsSL --retry 3 --max-time 60 -o "$sums" "$sums_url"; then
        rm -f "$sums"
        if ((cached_ok)); then
            log "WARN ${d}: cannot reach the vendor; using the cached image (older than ${MAX_AGE} days, still verified)"
            _ok=$((_ok + 1))
        else
            log "FAIL ${d}: no checksum from ${sums_url:-<unresolved>} and no usable cache"
            _failed+=("$d")
        fi
        continue
    fi
    want="$(_expected "$sums" "${url##*/}")"
    rm -f "$sums"
    if [[ -z "$want" ]]; then
        log "FAIL ${d}: ${sums_url} does not list ${url##*/}"
        _failed+=("$d")
        continue
    fi
    if ((cached_ok)) && [[ "$(sed -n 's/^hash=//p' "$src")" == "$want" ]]; then
        touch "$dest"
        log "CURRENT ${d}: the vendor still publishes the cached build"
        _ok=$((_ok + 1))
        continue
    fi

    log "FETCH ${d}: ${url}"
    if ! curl -fSL --retry 5 --retry-delay 10 --retry-all-errors -C - \
        -o "${dest}.part" "$url"; then
        log "FAIL ${d}: download failed"
        _failed+=("$d")
        continue
    fi
    got="$(_hash_of "${dest}.part" "$want")"
    if [[ "$got" != "$want" ]]; then
        rm -f "${dest}.part"
        log "FAIL ${d}: checksum mismatch (vendor ${want:0:16}…, got ${got:0:16}…)"
        _failed+=("$d")
        continue
    fi
    mv -f "${dest}.part" "$dest"
    printf 'url=%s\nhash=%s\nfetched=%s\n' "$url" "$want" "$(date -u +%FT%TZ)" >"${src}.new"
    mv -f "${src}.new" "$src"
    log "SAVED ${d}: $(du -h "$dest" | cut -f1), verified against ${sums_url##*/}"
    _ok=$((_ok + 1))
done

# One SHA256SUMS over the set, whatever each vendor used. The installer checks
# the copies against it, because a 3 GB copy onto a new disk can go wrong too.
(
    cd "$OUT"
    _have=()
    for d in "${DISTROS[@]}"; do [[ -s "${d}-cloud.qcow2" ]] && _have+=("${d}-cloud.qcow2"); done
    if ((${#_have[@]})); then
        sha256sum "${_have[@]}" >SHA256SUMS.new
        mv -f SHA256SUMS.new SHA256SUMS
    fi
)

log "cloud images: ${_ok} of ${#DISTROS[@]} cached and verified${_failed[*]:+; FAILED: ${_failed[*]}}"
((${#_failed[@]} == 0)) || exit 1
