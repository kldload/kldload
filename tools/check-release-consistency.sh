#!/usr/bin/env bash
# check-release-consistency.sh — one command that answers "does this release
# agree with itself?", instead of four careful reads that never all happen.
#
# WHAT IT CHECKS, IN ORDER:
#   1. the version in builder/build-iso.sh, which is the source of truth
#   2. the newest heading in CHANGELOG.md says the same version
#   3. the shipped copy of the changelog is byte-identical to the tracked one
#   4. every ISO in live-build/output carries that version in its name, and
#      the editions the website offers all exist
#   5. the website links to releases/<version>.html and that page exists
#   6. (--released only) a tag v<version> exists and points at HEAD
#   7. (--released only, needs rclone) each R2 -latest key resolves to an
#      object whose sidecar names this version
#
# WHY: the release invariant says a release is not done until the tag, the
# changelog, the website, the man pages and the R2 artefacts all name the same
# build. Every one of those is somewhere different, and "stale R2 = wrong
# download" is invisible from the repo. 1.4.2 shipped four editions; if 1.5.0
# publishes two, the core and fedora -latest keys keep serving 1.4.2 behind
# buttons the site presents as current, because every -latest key deliberately
# survives --prune (tools/r2-publish.sh).
#
# Inputs : the repo; optionally the kldload-web checkout beside it
# Outputs: one line per check on stdout, findings on stderr
# Exit   : 0 everything agrees · 1 at least one disagreement · 2 usage
#
# Notes:
#   - Without --released the tag and R2 checks are SKIPPED and say so. A
#     skipped check is never reported as a pass.
#   - A missing rclone is a loud skip, not a silent one.
set -Eeuo pipefail
trap 'echo "check-release-consistency: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

usage() { sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"; }
case "${1:-}" in -h | --help)
    usage
    exit 0
    ;;
esac

RELEASED=0
# swallow: the website checkout beside the repo is optional. Absent, WEB is
# empty and the website checks report SKIP rather than failing.
WEB="${KLDLOAD_WEB:-$(cd "$(dirname "$(realpath "$0")")/../../kldload-web" 2>/dev/null && pwd || true)}"
while (($#)); do
    case "$1" in
    --released) RELEASED=1 ;;
    --web)
        WEB="${2:?--web needs a path}"
        shift
        ;;
    *)
        echo "unknown option: $1 (try --help)" >&2
        exit 2
        ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

FAILED=0
ok() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() {
    printf '  \033[31mBAD\033[0m   %s\n' "$*"
    FAILED=1
}
skip() { printf '  \033[33mSKIP\033[0m  %s — NOT CHECKED\n' "$*"; }

# ── 1. the source of truth ───────────────────────────────────────────────
VERSION="$(sed -n 's/^VERSION="${KLDLOAD_VERSION:-\(.*\)}"$/\1/p' builder/build-iso.sh | head -1)"
[[ -n "$VERSION" ]] || {
    echo "could not read VERSION from builder/build-iso.sh" >&2
    exit 1
}
printf 'release version (builder/build-iso.sh): \033[1m%s\033[0m\n\n' "$VERSION"
case "$VERSION" in
*-rc | *-rc[0-9]* | *-dirty) bad "version is a pre-release ('$VERSION') — bump it before tagging" ;;
*) ok "version is not a pre-release" ;;
esac

# ── 2 & 3. the changelog ─────────────────────────────────────────────────
CL_VER="$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' CHANGELOG.md | head -1)"
if [[ "$CL_VER" == "$VERSION" ]]; then
    ok "CHANGELOG.md's newest section is $CL_VER"
else
    bad "CHANGELOG.md's newest section is '$CL_VER', build-iso says '$VERSION'"
fi
SHIPPED=live-build/config/includes.chroot/usr/local/share/kldload/CHANGELOG.md
if [[ -r "$SHIPPED" ]] && cmp -s CHANGELOG.md "$SHIPPED"; then
    ok "the shipped changelog is identical to the tracked one"
else
    bad "live-build copy of CHANGELOG.md differs from the tracked one"
fi

# ── 4. the ISOs ──────────────────────────────────────────────────────────
# Every edition the download page offers must exist at this version. Checking
# the files rather than the build log: a build can succeed and still leave the
# previous release's ISO as the newest one on disk.
shopt -s nullglob
declare -A WANT=([full]="kldload-${VERSION}-x86_64.iso" [net]="kldload-${VERSION}-x86_64-net.iso"
    [core]="kldload-${VERSION}-x86_64-core.iso" [fedora]="kldload-${VERSION}-x86_64-fedora.iso")
for ed in full net core fedora; do
    if [[ -f "live-build/output/${WANT[$ed]}" ]]; then
        ok "$ed ISO present: ${WANT[$ed]} ($(du -h "live-build/output/${WANT[$ed]}" | cut -f1))"
    else
        bad "$ed ISO missing: live-build/output/${WANT[$ed]}"
    fi
done
for f in live-build/output/kldload-*.iso; do
    b="$(basename "$f")"
    [[ "$b" == *"$VERSION"* ]] || printf '  \033[33mnote\033[0m  older ISO still on disk: %s\n' "$b"
done
shopt -u nullglob

# ── 5. the website ───────────────────────────────────────────────────────
if [[ -z "$WEB" || ! -d "$WEB" ]]; then
    skip "website (set --web PATH or KLDLOAD_WEB)"
else
    if [[ -f "$WEB/releases/${VERSION}.html" ]]; then
        ok "website has releases/${VERSION}.html"
    else
        bad "website is missing releases/${VERSION}.html"
    fi
    if grep -q "releases/${VERSION}.html" "$WEB/download.html" 2>/dev/null; then
        ok "download.html links to releases/${VERSION}.html"
    else
        bad "download.html does not link to releases/${VERSION}.html ($(grep -o 'releases/[0-9.]*\.html' "$WEB/download.html" 2>/dev/null | sort -u | tr '\n' ' '))"
    fi
fi

# ── 6. the tag ───────────────────────────────────────────────────────────
if ((RELEASED)); then
    if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        if [[ "$(git rev-parse "v${VERSION}^{commit}")" == "$(git rev-parse HEAD)" ]]; then
            ok "tag v${VERSION} exists and points at HEAD"
        else
            bad "tag v${VERSION} does not point at HEAD"
        fi
    else
        bad "tag v${VERSION} does not exist"
    fi
else
    skip "git tag v${VERSION} (pass --released once tagged)"
fi

# ── 7. R2 ────────────────────────────────────────────────────────────────
if ! ((RELEASED)); then
    skip "R2 -latest keys (pass --released once published)"
elif ! command -v rclone >/dev/null 2>&1; then
    skip "R2 -latest keys — rclone is not installed"
elif [[ -z "${R2_ACCESS_KEY_ID:-}" ]]; then
    skip "R2 -latest keys — R2 credentials are not in the environment"
else
    for key in kldload-free-latest.iso kldload-free-net-latest.iso \
        kldload-free-core-latest.iso kldload-free-fedora-latest.iso; do
        # swallow: a key with no sidecar is exactly what this loop reports as
        # BAD two lines down; rclone's own exit status would abort the loop
        # before the other three keys were ever looked at.
        sum="$(rclone cat "r2:kldload-releases/${key}.sha256" 2>/dev/null || true)"
        if [[ -z "$sum" ]]; then
            bad "R2 $key has no readable .sha256 sidecar"
        elif [[ "$sum" == *"$VERSION"* ]]; then
            ok "R2 $key names $VERSION"
        else
            bad "R2 $key is STALE — its sidecar names $(printf '%s' "$sum" | grep -oE 'kldload-[0-9][^ ]*' | head -1)"
        fi
    done
fi

echo
if ((FAILED)); then
    echo "release is NOT self-consistent — see BAD above" >&2
    exit 1
fi
echo "every checked surface names ${VERSION}"
