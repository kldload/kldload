#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kernel-pin.sh — work out which Fedora kernel this ISO may ship.
#
# What it does, in order:
#   1. Asks the zfs repo what the newest zfs-dkms will NOT build against
#      (`Conflicts: kernel-uname-r > X`). That cap is the whole constraint.
#   2. Finds the newest kernel NVR at or below that cap — from the Fedora
#      mirrors if they still carry it, otherwise from koji, which keeps every
#      NVR ever built.
#   3. Verifies every subpackage URL it is about to hand dnf actually exists.
#   4. Prints the resolved pin as shell assignments for the caller to eval.
#
# WHY: this was a hardcoded string. `KOJI_KERNEL_NVR="7.0.14-201.fc44"` had to
# be bumped by hand whenever OpenZFS moved its cap, and nothing failed when it
# was not — the build just kept shipping an older kernel while a comment three
# files away still claimed a value from two pins ago. The operator asked
# "isn't fedora kernel pinning working? it was pinned to 7.0.12 for a long
# time" (2026-08-17); it was working, but nothing about it was legible, and a
# pin nobody can verify at a glance is a pin nobody trusts.
#
# Deriving it means the pin moves ON ITS OWN the day OpenZFS ships a release
# whose cap covers a newer kernel, and it can never silently rot.
#
# WHY a cap exists at all: OpenZFS is an out-of-tree module. Each release
# states the newest kernel it compiles against, and Fedora ships kernels
# faster than OpenZFS blesses them. When F44 moved to 7.1 and pruned 7.0.x
# from the mirrors, "the newest kernel Fedora ships" and "the newest kernel
# ZFS builds against" stopped being the same number. This resolves the
# second one. On Debian the two coincide because zfs-dkms and the kernel come
# from one archive, which is why no equivalent exists on that path.
#
# Inputs:  ARCH (default x86_64), RELEASEVER (default 44), KPIN_ZFS_BASEURL
#          (defaults to the same zfsonlinux URL the build installs from), a
#          working dnf, and network access to kojipkgs. It does NOT require the
#          zfs repo to be configured on the host.
# Outputs: on stdout, four assignments — KPIN_NVR, KPIN_BASE, KPIN_URLS (a
#          bash array literal) and KPIN_EXCLUDES (likewise). Diagnostics go to
#          stderr so `eval "$(kernel-pin.sh)"` is safe.
# Exit:    0 resolved (fresh or fallback), 2 could not resolve at all.
#
# Notes:
#   - It NEVER returns a pin whose RPMs it has not confirmed are fetchable.
#     A pin that 404s at dnf time fails the build 40 minutes in; a pin that
#     fails here fails it in 10 seconds, with a reason.
#   - KPIN_FALLBACK_NVR is the last NVR verified to produce a booting ISO. It
#     is used when the network, koji or the repo query fails, and saying so
#     loudly is the point: a silent fallback is how a stale pin lasts a month.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ARCH="${ARCH:-x86_64}"
RELEASEVER="${RELEASEVER:-44}"
KOJI_ROOT="https://kojipkgs.fedoraproject.org/packages/kernel"

# The zfs repo is declared here rather than assumed to be configured.
#
# WHY: the first build to run this resolver fell straight to the fallback with
# "could not read the zfs-dkms kernel cap". The builder writes zfs.repo into
# the INSTALLROOT (${ROOTFS}/etc/yum.repos.d/zfs.repo), not into its own dnf
# config, so `dnf repoquery --repoid=zfs` in the builder queries a repo that
# does not exist there. It worked when tested on a workstation only because
# that machine has the zfs repo configured system-wide — the classic "works on
# the box you developed it on". Naming the URL makes the query independent of
# whatever dnf happens to be configured with, and of when in the build this
# runs. (2026-08-17, caught by the fallback warning it prints.)
#
# Same URL the build itself installs from — keep them in step.
KPIN_ZFS_BASEURL="${KPIN_ZFS_BASEURL:-http://download.zfsonlinux.org/2.4/fedora/${RELEASEVER}/${ARCH}/}"

# Last NVR verified end-to-end (built, booted, zfs DKMS built against it).
# Only used when resolution fails; update it when a build is blessed.
KPIN_FALLBACK_NVR="${KPIN_FALLBACK_NVR:-7.0.14-201.fc44}"

# The subpackages that must all come from the SAME NVR.
#   kernel-devel-matched: something in the closure requires it, and without a
#     matching provider on the command line dnf pulls the repo's newer one —
#     which drags a SECOND kernel-core/devel in, because kernels are installonly
#     and dnf stacks rather than replaces (verified 2026-07-23).
#   kernel-modules-extra: omitted from the first 7.0.14 build, so the resolver
#     took the repo's 6.19.10 one and produced mixed-NVR modules-extra on a
#     7.0.14 kernel — uncommon drivers quietly missing. Caught on the smoke
#     VM's versionlock list.
KPIN_SUBPKGS=(kernel kernel-core kernel-modules kernel-modules-core
    kernel-modules-extra kernel-devel kernel-devel-matched)

_warn() { printf 'kernel-pin: %s\n' "$*" >&2; }

# ── The cap ────────────────────────────────────────────────────────────────
# `--latest-limit=1` because the repo carries every zfs-dkms it ever shipped
# and each states its own cap; only the newest one's cap is the constraint we
# are actually under. Prints e.g. "7.0.999", or nothing if the query fails.
kpin_zfs_cap() {
    dnf repoquery --repofrompath="kpinzfs,${KPIN_ZFS_BASEURL}" --repoid=kpinzfs \
        --nogpgcheck --latest-limit=1 zfs-dkms --conflicts 2>/dev/null |
        awk '$1 == "kernel-uname-r" && $2 == ">" { print $3 }' |
        sort -V | tail -1
}

# ── Candidate NVRs ─────────────────────────────────────────────────────────
# The mirrors first: if Fedora still serves a kernel under the cap, use it and
# skip koji entirely. Returns the newest matching version-release, or nothing.
kpin_from_mirrors() {
    local line="$1"
    # --releasever pinned for the same reason as the repo above: the builder's
    # own release must not decide which Fedora's kernels we consider.
    dnf repoquery --releasever="$RELEASEVER" --qf '%{version}-%{release}\n' kernel 2>/dev/null |
        grep -E "^${line//./\\.}\." | sort -V | tail -1
}

# koji keeps every NVR forever; the mirrors prune. Two directory listings:
# versions under the kernel package, then releases under the chosen version.
# `grep -o 'href="[^"]*/"'` rather than a parser because this is a generated
# Apache index, not a document — and adding an HTML parser to the builder to
# read two lists of directory names is not a trade worth making.
#
# WARN: strip the wrapper with sed, NOT `tr -d 'href="/'`. tr deletes a SET OF
# CHARACTERS, so that form also eats every f, c, r, e and h inside the value —
# "201.fc44" came back as "201.c44", the .fc44 filter matched nothing, and the
# resolver silently fell back to the hardcoded pin while reporting only "could
# not resolve". Caught 2026-08-17 on the first live run.
kpin_from_koji() {
    local line="$1" ver rel
    ver=$(curl -fsS --max-time 20 "${KOJI_ROOT}/" 2>/dev/null |
        grep -oE 'href="[0-9][^"/]*/"' | sed -E 's|^href="||; s|/"$||' |
        grep -E "^${line//./\\.}\." | sort -V | tail -1) || return 1
    [[ -n "$ver" ]] || return 1
    rel=$(curl -fsS --max-time 20 "${KOJI_ROOT}/${ver}/" 2>/dev/null |
        grep -oE 'href="[0-9][^"/]*/"' | sed -E 's|^href="||; s|/"$||' |
        grep -E "\.fc${RELEASEVER}\$" | sort -V | tail -1) || return 1
    [[ -n "$rel" ]] || return 1
    printf '%s-%s' "$ver" "$rel"
}

# ── Verification ───────────────────────────────────────────────────────────
# Every URL, HEAD, before the caller commits. A missing subpackage here is a
# ten-second failure; the same thing discovered inside dnf is a forty-minute
# one, and discovered after boot it is an unbootable install.
kpin_urls_ok() {
    local nvr="$1" base="$2" sub rc=0
    for sub in "${KPIN_SUBPKGS[@]}"; do
        curl -fsSI --max-time 20 "${base}/${sub}-${nvr}.${ARCH}.rpm" >/dev/null 2>&1 || {
            _warn "missing at koji: ${sub}-${nvr}.${ARCH}.rpm"
            rc=1
        }
    done
    return "$rc"
}

# ── Excludes ───────────────────────────────────────────────────────────────
# Keep the repo's newer kernels out of the transaction. dnf globs cannot do
# numeric comparison, so the set is enumerated: every minor above the pinned
# line, then the next two majors. Two is not arbitrary — Fedora has never
# advanced the kernel major more than once within a release, so this is one
# clear step beyond anything that has happened, and the globs cost nothing
# when they match nothing. These do NOT match the pinned NVR handed to dnf as
# a URL, which is what makes the pair work.
kpin_excludes() {
    local line="$1" major="${1%%.*}" minor="${1#*.}"
    printf -- "--exclude=kernel*-%s.[%d-9]*\n" "$major" "$((minor + 1))"
    printf -- "--exclude=kernel*-%d.*\n" "$((major + 1))"
    printf -- "--exclude=kernel*-%d.*\n" "$((major + 2))"
}

main() {
    local cap line nvr base source="derived"

    # An unreadable cap (offline, or the repo moved) is handled below as a
    # fallback with a warning — it must not abort under set -e first.
    cap=$(kpin_zfs_cap || true)
    if [[ -z "$cap" ]]; then
        _warn "could not read the zfs-dkms kernel cap from the zfs repo"
        nvr="$KPIN_FALLBACK_NVR"
        source="FALLBACK (no cap)"
        line="${nvr%%-*}"
        line="${line%.*}"
    else
        # "7.0.999" is a cap on the 7.0 line: the newest thing zfs will build
        # against is a 7.0.x. Drop the patch component to get the line.
        line="${cap%.*}"
        _warn "zfs-dkms caps at kernel-uname-r > ${cap} → pinning the ${line} line"

        # The mirrors NOT carrying this line is the normal case once Fedora
        # prunes it; koji is asked next.
        nvr=$(kpin_from_mirrors "$line" || true)
        if [[ -n "$nvr" ]]; then
            _warn "mirrors still carry ${line}: ${nvr}"
        else
            # koji unreachable leaves nvr empty, which the fallback below reports.
            nvr=$(kpin_from_koji "$line" || true)
            [[ -n "$nvr" ]] && _warn "mirrors pruned ${line}; koji has ${nvr}"
        fi
    fi

    if [[ -z "$nvr" ]]; then
        _warn "could not resolve any kernel on the ${line} line"
        nvr="$KPIN_FALLBACK_NVR"
        source="FALLBACK (unresolved)"
    fi

    base="${KOJI_ROOT}/${nvr%%-*}/${nvr#*-}/${ARCH}"

    if ! kpin_urls_ok "$nvr" "$base"; then
        if [[ "$nvr" == "$KPIN_FALLBACK_NVR" ]]; then
            _warn "FATAL: even the fallback ${KPIN_FALLBACK_NVR} is not fetchable"
            return 2
        fi
        _warn "resolved ${nvr} but its RPMs are not all present — using fallback"
        nvr="$KPIN_FALLBACK_NVR"
        source="FALLBACK (incomplete NVR)"
        base="${KOJI_ROOT}/${nvr%%-*}/${nvr#*-}/${ARCH}"
        kpin_urls_ok "$nvr" "$base" || {
            _warn "FATAL: fallback ${nvr} is not fetchable either"
            return 2
        }
    fi

    # A fallback is a defect, not a mode. Say so where a build log gets read.
    case "$source" in
    FALLBACK*) _warn "WARNING: using ${source} pin ${nvr} — resolution failed, check the network and the zfs repo" ;;
    *) _warn "resolved kernel pin: ${nvr} (${source})" ;;
    esac

    printf 'KPIN_NVR=%q\n' "$nvr"
    printf 'KPIN_BASE=%q\n' "$base"

    local sub urls=()
    for sub in "${KPIN_SUBPKGS[@]}"; do
        urls+=("${base}/${sub}-${nvr}.${ARCH}.rpm")
    done
    printf 'KPIN_URLS=('
    printf '%q ' "${urls[@]}"
    printf ')\n'

    local ex exl=()
    while read -r ex; do exl+=("$ex"); done < <(kpin_excludes "$line")
    printf 'KPIN_EXCLUDES=('
    printf '%q ' "${exl[@]}"
    printf ')\n'
}

main "$@"
