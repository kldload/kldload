#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# capture-help.sh — record every shipped tool's `--help`, safely, for the
# website's command reference.
#
#   1. lists the executables the ISO ships (usr/local/bin, usr/local/sbin,
#      usr/sbin under live-build/config/includes.chroot);
#   2. runs each one's `--help` inside a throwaway container: repo read-only,
#      NO network, an unprivileged uid, a stub sudo first on PATH, 10 s each;
#   3. writes <out>/<tool>.help (stdout+stderr), <tool>.rc and, when the tool
#      reached for root, <tool>.sudo; then <out>/tools.tsv (name, dir, rc,
#      sudo, bytes).
#
# WHY A CONTAINER: a tool with no --help handler does its real job when asked
# for help -- `kldload-loadtest --help` started a nine-minute load test on onyx
# (2026-09-16). Inside a sealed container with no network, no ZFS and no
# libvirt, the worst a tool can do is fail.
#
# Usage: tools/cmdref/capture-help.sh <out-dir>     (rootless podman)
# Needs: podman, the image below (built by the same Containerfile if missing).
# Exit:  0 captured (whatever the tools did), 1 could not run.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "capture-help: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: capture-help.sh <out-dir>}"
IMAGE="${CMDREF_IMAGE:-localhost/kldload-helpcap:1}"
command -v podman >/dev/null || {
    echo "capture-help: DID NOT RUN — podman is missing" >&2
    exit 1
}
if ! podman image exists "$IMAGE"; then
    ctx="$(mktemp -d)"
    printf 'FROM registry.fedoraproject.org/fedora:44\nRUN dnf -y -q install python3 python3-websockets python3-gobject-base procps-ng util-linux && dnf clean all\n' >"$ctx/Containerfile"
    podman build -q -t "$IMAGE" "$ctx" >/dev/null
    rm -rf "$ctx"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The loop runs INSIDE the container; its argv is fixed, the tool list comes
# from the read-only tree.
# shellcheck disable=SC2016 # expanded inside the container
# keep-id: the container's user IS the caller, so it can write <out>. A plain
# --user 1000 is a sub-uid on the host and every write failed (2026-09-29).
podman run --rm --network none --userns=keep-id \
    -v "${REPO}:/w:ro,z" -v "${OUT}:/out:z" -e HOME=/tmp \
    "$IMAGE" bash -c '
set -uo pipefail
mkdir -p /tmp/stub
printf "#!/bin/bash\necho \"\$*\" >>/tmp/stub/called\nexit 97\n" >/tmp/stub/sudo
chmod +x /tmp/stub/sudo
cd /w/live-build/config/includes.chroot
printf "name\tdir\trc\tsudo\tbytes\n" >/out/tools.tsv || { echo "cannot write /out" >&2; exit 1; }
for d in usr/local/bin usr/local/sbin usr/sbin; do
    for f in "$d"/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        n="${f##*/}"
        first="$(head -c 200 "$f" | head -n 1)"
        case "$first" in
        *python*) run=(python3 "$f") ;;
        *bash* | *"/sh"*) run=(bash "$f") ;;
        *) printf "%s\t%s\t-\t-\t0\n" "$n" "$d" >>/out/tools.tsv; continue ;; # a binary or unknown: not run
        esac
        rm -f /tmp/stub/called
        rc=0
        PATH=/tmp/stub:/usr/bin:/bin timeout 10 "${run[@]}" --help </dev/null >"/out/${n}.help" 2>&1 || rc=$?
        s=0
        [[ -s /tmp/stub/called ]] && { s=1; cp /tmp/stub/called "/out/${n}.sudo"; }
        echo "$rc" >"/out/${n}.rc"
        printf "%s\t%s\t%s\t%s\t%s\n" "$n" "$d" "$rc" "$s" "$(stat -c %s "/out/${n}.help")" >>/out/tools.tsv
    done
done
'
[[ -s "$OUT/tools.tsv" ]] || {
    echo "capture-help: FAILED — no tools.tsv was written" >&2
    exit 1
}
n="$(($(wc -l <"$OUT/tools.tsv") - 1))"
((n > 0)) || {
    echo "capture-help: FAILED — the list of tools is empty" >&2
    exit 1
}
echo "capture-help: ${n} tools recorded in ${OUT}/tools.tsv" >&2
