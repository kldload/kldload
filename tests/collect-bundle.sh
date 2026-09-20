#!/usr/bin/env bash
# =============================================================================
# collect-bundle.sh — everything needed to argue about this machine later
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Makes a staging directory and copies the evidence into it: the install
#      manifest (redacted), kldload's own logs, the full journal for this boot,
#      every unit and its state, the storage and network picture, the estate
#      view, and any smoke report already on disk.
#   2. Tars it to a path it prints on stdout, and nothing else on stdout, so a
#      driver can do BUNDLE="$(collect-bundle.sh)" and then scp it.
#
# WHY: a report says what was wrong; a bundle is what lets somebody work out
# WHY three weeks later, after the machine has been reinstalled four times.
# The estate sweep keeps one per install (operator, 2026-09-19: "start saving
# all of the results and bundles so we have records").
#
# SECRETS: the install manifest and answers carry the account password, and on
# RHEL the subscription login. Every value whose key looks like a credential is
# replaced with a redaction marker before it is copied -- these bundles sit on
# disk for months and get attached to notes. The KEYS are kept, because "this
# install had a RHEL username set" is exactly the sort of thing worth knowing.
#
# EXIT: 0 and the bundle path on stdout · 1 nothing could be collected.
# =============================================================================
set -Euo pipefail
trap 'echo "collect-bundle.sh: line $LINENO: $BASH_COMMAND" >&2' ERR

case "${1:-}" in
-h | --help | help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

if ((EUID != 0)); then
    exec sudo -n bash "$0" "$@"
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
HOST="$(hostname)"
OUT="/tmp/kldload-bundle-${HOST}-${STAMP}"
TAR="${OUT}.tar.gz"
mkdir -p "$OUT"
# The staging dir is removed on every path; the tarball is what survives.
trap 'rm -rf "$OUT"' EXIT

# cap <file> — run a command, put its output in the bundle, never fail the run.
# A command that is not installed leaves a file SAYING it is not installed,
# which is more useful than an absent file that could mean either.
cap() {
    local name="$1"
    shift
    if command -v "${1}" >/dev/null 2>&1; then
        "$@" >"${OUT}/${name}" 2>&1 || echo "[exit $?] $*" >>"${OUT}/${name}"
    else
        echo "not installed: ${1}" >"${OUT}/${name}"
    fi
}

# ── identity and what was asked for ─────────────────────────────────────────
# REDACTION: key kept, value replaced. sed on the VALUE side only, anchored on
# the key names that can carry a credential.
for f in /etc/kldload/install-manifest.env /var/lib/kldload/answers.env; do
    [[ -r "$f" ]] || continue
    sed -E 's/^([A-Z_]*(PASSWORD|PASSPHRASE|SECRET|TOKEN|KEY|RHEL_USERNAME|RHEL_PASSWORD)[A-Z_]*=).*/\1<redacted>/' \
        "$f" >"${OUT}/$(basename "$f")"
done
cap os-release cat /etc/os-release
cap uname uname -a

# ── services: the state of every unit, not just the failed ones ─────────────
# A unit that is missing entirely and one that is loaded-but-dead look the same
# in `--failed`, and they are different bugs.
cap systemd-state systemctl is-system-running
cap units-failed systemctl --failed --all --no-pager
cap units-all systemctl list-units --all --no-pager
cap units-enabled systemctl list-unit-files --no-pager

# ── logs ────────────────────────────────────────────────────────────────────
cap journal-boot journalctl -b --no-pager
cap journal-errors journalctl -p err -b --no-pager
[[ -d /var/log/kldload ]] && cp -a /var/log/kldload "${OUT}/kldload-logs" 2>/dev/null
[[ -d /var/log/installer ]] && cp -a /var/log/installer "${OUT}/installer-logs" 2>/dev/null

# ── storage, boot, network ──────────────────────────────────────────────────
cap zpool-status zpool status -v
cap zpool-list zpool list -o name,size,alloc,free,health,bootfs
cap zfs-list zfs list -o name,used,avail,mountpoint,encryption,keystatus
cap zfs-snapshots zfs list -t snapshot -o name,creation
cap findmnt findmnt --real
cap secureboot mokutil --sb-state
cap efibootmgr efibootmgr -v
cap ip-addr ip -br addr
cap ip-route ip route

# ── estate ──────────────────────────────────────────────────────────────────
cap virsh-list virsh list --all
cap virsh-nets virsh net-list --all
cap inventory kldload-inventory --list
cap estate kldload-estate
cap wg-show wg show all
[[ -d /etc/prometheus/targets ]] &&
    cp -a /etc/prometheus/targets "${OUT}/prometheus-targets" 2>/dev/null

# ── anything the suites already wrote ───────────────────────────────────────
cp /tmp/kldload-smoke-report-*.txt "${OUT}/" 2>/dev/null || true

# Outcome, not exit code: the tar must exist and be non-trivial, or this
# reported success having collected nothing.
tar -C "$(dirname "$OUT")" -czf "$TAR" "$(basename "$OUT")" 2>/dev/null
if [[ ! -s "$TAR" ]]; then
    echo "collect-bundle.sh: produced no bundle" >&2
    exit 1
fi
_files="$(find "$OUT" -type f | wc -l)"
if ((_files < 5)); then
    echo "collect-bundle.sh: only ${_files} file(s) collected — something is very wrong" >&2
fi
printf '%s\n' "$TAR"
