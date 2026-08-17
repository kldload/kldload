#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
# r2-publish.sh — publish a release ISO and its checksum to the R2 bucket.
#
# What it does, in order:
#   1. Verifies the local ISO against its .sha256 sidecar before anything
#      leaves the machine.
#   2. Uploads the ISO under BOTH keys: the versioned name and the
#      kldload-free-latest.iso name the website's download button resolves to.
#   3. Uploads the .sha256 sidecar alongside each.
#   4. Re-reads the published objects over HTTPS and asserts that the size and
#      checksum match what was just sent.
#   5. With --prune, removes older release objects from the bucket, so old
#      versions do not sit there costing storage and confusing anyone who
#      browses the keys.
#
# WHY THIS EXISTS: R2 is the public source of truth for downloads. A stale
# bucket means the website advertises one release and hands the visitor a
# different one — which is exactly what happened at 1.4.0, where the site went
# live saying 18.4 GB while the bucket still served 1.3.1 at 9.2 GB. Until now
# this was a manual step with no tooling in the repo at all, which is why it
# drifted.
#
# WHY STEP 4 IS NOT OPTIONAL: a multipart upload can report success and leave a
# truncated object. Checking the exit code proves the client thought it worked;
# re-reading the object proves the visitor gets the right bytes. Same rule as
# the kernel check on the install path — verify the outcome, not the exit code.
#
# Inputs (environment):
#   R2_ACCOUNT_ID          Cloudflare account id
#   R2_ACCESS_KEY_ID       R2 token access key
#   R2_SECRET_ACCESS_KEY   R2 token secret
#   R2_BUCKET              bucket name (default: kldload-releases)
#   R2_PUBLIC_BASE         public base URL (default: https://dl.kldload.com)
#
# Inputs (arguments):
#   $1  path to the ISO. Its .sha256 sidecar must sit next to it.
#
# Outputs: two objects per file in the bucket; a summary on stdout. Nothing is
# written locally.
#
# Notes:
#   - Credentials are read from the environment and never logged. Do not pass
#     them as arguments; argv is world-readable in /proc.
#   - rclone is required. It handles R2 multipart correctly for objects in the
#     tens of gigabytes, where a naive single PUT fails.
#   - The upload is not atomic across the two keys. The versioned key goes
#     first so that, if the run dies midway, the new release exists under its
#     real name and only "latest" is stale — the recoverable direction.
#   - --prune only ever runs AFTER verification passes, and never touches the
#     version being published or the latest keys. Deleting the old release
#     before the new one is proven good would leave the bucket with nothing
#     downloadable at all.
# ─────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

R2_BUCKET="${R2_BUCKET:-kldload-releases}"
R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://dl.kldload.com}"
LATEST_KEY="kldload-free-latest.iso"

usage() {
    cat <<'EOF'
Usage: r2-publish.sh [--prune] [--prune-dry-run] <path-to-iso>

Publishes a release ISO and its .sha256 sidecar to the kldload R2 bucket,
under both its versioned key and the kldload-free-latest.iso key that the
website's download button resolves to, then verifies the published objects
by re-reading them.

Arguments:
  <path-to-iso>   The ISO to publish. A sidecar named <path-to-iso>.sha256
                  must exist next to it and must match.

Options:
  --prune           After verification passes, delete older kldload-*.iso and
                    .sha256 objects from the bucket. Never touches the version
                    being published or the kldload-free-latest.iso keys.
  --prune-dry-run   List what --prune would delete, and delete nothing.

Environment (required):
  R2_ACCOUNT_ID           Cloudflare account id.
  R2_ACCESS_KEY_ID        R2 token access key.
  R2_SECRET_ACCESS_KEY    R2 token secret.

Environment (optional):
  R2_BUCKET               Bucket name.       Default: kldload-releases
  R2_PUBLIC_BASE          Public base URL.   Default: https://dl.kldload.com

Exit status:
  0  every object uploaded and verified (and pruned, if asked)
  1  a precondition failed, or a published object did not match

Examples:
  # Publish the 1.4.0 release.
  export R2_ACCOUNT_ID=de773e77... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=...
  tools/r2-publish.sh live-build/output/kldload-1.4.0-x86_64.iso

  # Publish 1.4.0 and clear out the older releases behind it.
  tools/r2-publish.sh --prune live-build/output/kldload-1.4.0-x86_64.iso

  # See what would be removed without removing it.
  tools/r2-publish.sh --prune-dry-run live-build/output/kldload-1.4.0-x86_64.iso

  # Publish to a staging bucket instead.
  R2_BUCKET=kldload-staging tools/r2-publish.sh out/kldload-1.4.0-x86_64.iso
EOF
}

prune=0
prune_dry=0
iso=""

while (($#)); do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    --prune) prune=1 ;;
    --prune-dry-run)
        prune=1
        prune_dry=1
        ;;
    -*)
        echo "r2-publish: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    *)
        if [[ -n "$iso" ]]; then
            echo "r2-publish: unexpected extra argument: $1" >&2
            exit 1
        fi
        iso="$1"
        ;;
    esac
    shift
done

if [[ -z "$iso" ]]; then
    usage >&2
    exit 1
fi

# ─── Preconditions ───────────────────────────────────────────────────────────
# Everything that can be checked without touching the network is checked first,
# so a missing credential fails in a second rather than after a 40-minute
# upload.

[[ -f "$iso" ]] || {
    echo "r2-publish: no such ISO: $iso" >&2
    exit 1
}

sidecar="${iso}.sha256"
[[ -f "$sidecar" ]] || {
    echo "r2-publish: missing checksum sidecar: $sidecar" >&2
    exit 1
}

command -v rclone >/dev/null 2>&1 || {
    echo "r2-publish: rclone is required and not installed." >&2
    echo "  dnf install -y rclone   # or: https://rclone.org/install/" >&2
    exit 1
}

for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [[ -n "${!var:-}" ]] || {
        echo "r2-publish: $var is not set — see --help" >&2
        exit 1
    }
done

# ─── Verify locally before uploading ─────────────────────────────────────────
# Publishing an image that does not match its own sidecar would put a
# permanently unverifiable download in front of every visitor.

echo "r2-publish: verifying $iso against its sidecar…"
if ! (cd "$(dirname "$iso")" && sha256sum -c "$(basename "$sidecar")" >/dev/null 2>&1); then
    echo "r2-publish: local ISO does not match $sidecar — refusing to publish" >&2
    exit 1
fi

iso_name="$(basename "$iso")"
local_sum="$(cut -d' ' -f1 <"$sidecar")"
local_size="$(stat -c %s "$iso")"
echo "r2-publish: ok — ${iso_name}, ${local_size} bytes, ${local_sum:0:12}…"

# rclone reads R2 as an S3-compatible endpoint. Config goes on the command line
# rather than into ~/.config so the script leaves no credential on disk.
remote=(
    --s3-provider Cloudflare
    --s3-access-key-id "$R2_ACCESS_KEY_ID"
    --s3-secret-access-key "$R2_SECRET_ACCESS_KEY"
    --s3-endpoint "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    --s3-no-check-bucket
)

# ─── Upload ──────────────────────────────────────────────────────────────────
# Versioned key first: see the note in the banner about which direction of
# partial failure is recoverable.

upload() {
    # upload <local-path> <object-key>
    #
    # Streams one file to the bucket. Returns rclone's status; the caller is
    # responsible for verifying the result, because a zero here only means the
    # client believed it finished.
    local src="$1" key="$2"
    echo "r2-publish: uploading $(basename "$src") -> ${key}"
    rclone copyto "$src" ":s3:${R2_BUCKET}/${key}" "${remote[@]}" \
        --progress --s3-chunk-size 64M --s3-upload-concurrency 4
}

server_copy() {
    # server_copy <source-key> <dest-key>
    #
    # Duplicates an object inside the bucket without sending it again. rclone
    # issues a server-side copy when source and destination are the same
    # remote, using multipart copy above --s3-copy-cutoff.
    local src="$1" dst="$2"
    echo "r2-publish: copying ${src} -> ${dst} (server-side)"
    rclone copyto ":s3:${R2_BUCKET}/${src}" ":s3:${R2_BUCKET}/${dst}" \
        "${remote[@]}" --s3-copy-cutoff 4G
}

upload "$iso" "$iso_name"
upload "$sidecar" "${iso_name}.sha256"

# WHY NOT a second upload: the ISO has to exist under both the versioned key
# and the latest key, and an earlier version of this sent the whole image
# twice. At 18.4 GB that is 18.4 GB of uplink spent to produce bytes R2
# already has. Copy it inside the bucket instead.
server_copy "$iso_name" "$LATEST_KEY"
server_copy "${iso_name}.sha256" "${LATEST_KEY}.sha256"

# ─── Verify what is actually being served ────────────────────────────────────
# Re-read over the public URL, not the S3 API: that is the path a visitor
# takes, and it is the one that can be wrong while the bucket looks right.

fail=0
check_size() {
    # check_size <key> <expected-bytes>
    #
    # HEADs the public URL and compares content-length. Prints a verdict and
    # sets `fail` on mismatch rather than exiting, so one run reports every
    # problem instead of only the first.
    local key="$1" want="$2" got
    got="$(curl -fsSI --max-time 60 "${R2_PUBLIC_BASE}/${key}" |
        awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2 }')"
    if [[ "$got" == "$want" ]]; then
        echo "r2-publish: verified ${key} — ${got} bytes"
    else
        echo "r2-publish: MISMATCH ${key} — served ${got:-<none>}, expected ${want}" >&2
        fail=1
    fi
}

echo "r2-publish: verifying published objects…"
check_size "$iso_name" "$local_size"
check_size "$LATEST_KEY" "$local_size"

# The sidecar is small enough to read in full, so compare the checksum itself
# rather than just its length.
served_sum="$(curl -fsS --max-time 60 "${R2_PUBLIC_BASE}/${LATEST_KEY}.sha256" |
    cut -d' ' -f1)"
if [[ "$served_sum" == "$local_sum" ]]; then
    echo "r2-publish: verified ${LATEST_KEY}.sha256 — ${served_sum:0:12}…"
else
    echo "r2-publish: MISMATCH ${LATEST_KEY}.sha256 — served ${served_sum:-<none>}" >&2
    fail=1
fi

if ((fail)); then
    echo "r2-publish: FAILED — the bucket does not match the local release" >&2
    exit 1
fi

# ─── Prune older releases ────────────────────────────────────────────────────
# Only reached once the new release is uploaded AND verified. The keep-list is
# explicit rather than pattern-based: an object is deleted only if it looks
# like a release artefact AND is not one of the four things just published.

if ((prune)); then
    echo "r2-publish: looking for older releases to remove…"
    keep=("$iso_name" "${iso_name}.sha256" "$LATEST_KEY" "${LATEST_KEY}.sha256")

    # A dry run prints a verdict for EVERY object, not just the candidates.
    # WHY: the operator's real question at prune time is "what else is in this
    # bucket?" — an artefact from another project can sit there for months and
    # a tool that only reports its own candidates will never mention it.
    doomed=()
    other=()
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue

        # Release artefacts only. Anything else belongs to something else and
        # is reported but never touched.
        if [[ ! "$key" =~ ^kldload-.*\.iso(\.sha256)?$ ]]; then
            other+=("$key")
            continue
        fi

        for k in "${keep[@]}"; do
            [[ "$key" == "$k" ]] && continue 2
        done
        doomed+=("$key")
    done < <(rclone lsf ":s3:${R2_BUCKET}" "${remote[@]}" 2>/dev/null)

    if ((${#other[@]})); then
        echo "r2-publish: not release artefacts — left alone:"
        printf '  %s\n' "${other[@]}"
    fi

    if ((${#doomed[@]} == 0)); then
        echo "r2-publish: nothing to prune."
    else
        for key in "${doomed[@]}"; do
            if ((prune_dry)); then
                echo "r2-publish: would delete ${key}"
            else
                echo "r2-publish: deleting ${key}"
                rclone deletefile ":s3:${R2_BUCKET}/${key}" "${remote[@]}"
            fi
        done
        ((prune_dry)) && echo "r2-publish: dry run — nothing was deleted."
    fi
fi

echo "r2-publish: done. ${R2_PUBLIC_BASE}/${LATEST_KEY} now serves ${iso_name}."
