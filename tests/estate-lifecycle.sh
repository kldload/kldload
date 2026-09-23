#!/usr/bin/env bash
# =============================================================================
# estate-lifecycle.sh — a VM joins the estate when made, and LEAVES when deleted
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Picks a source VM (a golden, or --source), and a name of its own.
#   2. Clones it with the shipped verb, `kvm-clone`.
#   3. JOIN: waits, bounded, for the clone to appear in all four systems that
#      are supposed to notice it — libvirt, the state DB / Ansible inventory,
#      the WireGuard mesh, and Prometheus file_sd — and reports how long each
#      took. Those are timer-driven, so "how long" is the interesting number.
#   4. Runs `ansible -m ping` at the clone specifically: in the inventory is
#      not the same as reachable.
#   5. UNJOIN: deletes it with `kvm-delete`, then asserts it is gone from all
#      four, plus its zvol.
#
# WHY IT EXISTS: the estate is four independent registries kept in step by
# timers and sweeps. Every one of them has been wrong at least once — a VM up
# and absent from Ansible, a deleted VM still in the DB, `kvm-delete` returning
# 1 after a successful destroy so the DB row was never touched, a mesh key
# minted and never used. Creating one machine and deleting it again exercises
# all of that in about three minutes, and the UNJOIN half is the half nobody
# tests: a stale entry points a play at an address DHCP has since given to
# somebody else.
#
# SAFETY: it creates and destroys exactly one VM, named by this script, and
# deletes it BY EXACT NAME on every exit path. It never touches a VM it did not
# create — a `destroy --all` in a test once took six of the operator's clones.
#
# USAGE: estate-lifecycle.sh [--source <vm>] [--keep] [--timeout <s>]
# EXIT:  0 join and unjoin both proved · 1 something did not · 2 could not run.
# =============================================================================
set -Eeuo pipefail
trap 'echo "estate-lifecycle.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

have() { command -v "$1" >/dev/null 2>&1; }
_didnotrun() { _warn "$1" "DID NOT RUN — $2"; }

SOURCE_VM=""
KEEP=0
WAIT_MAX=240
# The name carries the PID and the date so two runs cannot collide, and so a
# leftover is obviously this test's and obviously stale.
PROBE="estate-probe-$(date +%m%d%H%M)-$$"

usage() {
    cat <<EOF
Usage: estate-lifecycle.sh [--source <vm>] [--keep] [--timeout <seconds>]

Clones one VM, proves it joins the estate, deletes it, proves it leaves.

  --source <vm>    clone this VM (default: the first sealed golden found)
  --keep           do not delete the clone at the end (debugging)
  --timeout <s>    how long to wait for each registry to notice (default ${WAIT_MAX})

EXIT: 0 both halves proved, 1 a check failed, 2 the test could not run.
EOF
    exit "${1:-1}"
}

while (($#)); do
    case "$1" in
    -h | --help) usage 0 ;;
    --source)
        SOURCE_VM="${2:-}"
        shift 2
        ;;
    --keep)
        KEEP=1
        shift
        ;;
    --timeout)
        WAIT_MAX="${2:-240}"
        shift 2
        ;;
    *)
        echo "estate-lifecycle.sh: unknown argument: $1" >&2
        usage 2
        ;;
    esac
done

# ─── Probes: one function per registry, each answering yes/no for a name ─────
#
# Each is deliberately a separate question. When a clone is in libvirt and not
# in Ansible, the useful output is WHICH registry is behind, not "the estate is
# broken" -- so the join/unjoin loops below report per registry.

in_libvirt() { virsh dominfo "$1" >/dev/null 2>&1; }

# A LIVE row, not any row. `kldload-db vm-delete` is a SOFT delete by design --
# it sets status='deleted' and stamps deleted_at so the history survives while
# the dynamic inventory drops the host. Asking merely whether the name appears
# reported "STILL registered 240s after delete" for a database behaving exactly
# as intended (deb-4-k8s, 2026-09-20).
in_db() {
    kldload-db dump 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for v in d.get("vms",[]):
    if v.get("name")!=sys.argv[1]:
        continue
    if v.get("status")=="deleted" or v.get("deleted_at"):
        continue          # soft-deleted: released, not registered
    sys.exit(0)
sys.exit(1)' "$1" 2>/dev/null
}

in_inventory() {
    kldload-inventory --list 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[1] in d.get("_meta",{}).get("hostvars",{}) else 1)' "$1" 2>/dev/null
}

in_prometheus() { grep -rqs "\"vm\"[[:space:]]*:[[:space:]]*\"${1}\"" /etc/prometheus/targets 2>/dev/null; }

# The mesh is keyed by public key, not name, so the question is asked of the
# estate's own view rather than of `wg show` directly.
# on_mesh <name> — 0 when the estate says that machine is on the WireGuard
# mesh, 1 otherwise. Used in BOTH directions: join waits for yes, unjoin for no.
#
# HISTORY: fiend, 2026-09-21. This could not return 0, so "join: WireGuard
# mesh — <probe> never appeared (900s)" failed on all four editions that run
# the lifecycle, across two distributions, and was carried for days as an
# unexplained product defect. The mesh was healthy the whole time: wg-show on
# those same machines had every peer handshaking with keepalives.
#
# Three faults, all in this function:
#   * kldload-estate has no --json. Its options are --table, --drift, --probe,
#     and it already emits JSON by DEFAULT. argparse exited 2 and printed the
#     usage to stderr, which 2>/dev/null discarded, so stdout was empty and
#     json.load raised on every call.
#   * there is no wg_ip and no wg_pubkey. The keys are in_mesh (bool) and
#     mesh_ifaces (string).
#   * so the join check could never pass, and the UNJOIN check -- which waits
#     for this to return 1 -- passed instantly and always, on a machine that
#     was still meshed. It was decoration reporting success.
#
# The lesson is the cheap one: this probe agreed with a failure every single
# time and nobody asked what it prints when the answer is yes.
on_mesh() {
    have kldload-estate || return 1
    kldload-estate 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for m in d.get("machines",[]) if isinstance(d,dict) else []:
    if m.get("name")==sys.argv[1] and (m.get("in_mesh") or m.get("mesh_ifaces")):
        sys.exit(0)
sys.exit(1)' "$1" 2>/dev/null
}

# key_on_mesh — 0 while the probe's WireGuard key is a peer on the RUNNING
# wg-mgmt. This, not on_mesh, is the unjoin question: on_mesh asks the estate
# by NAME, and a deleted VM has no name in the estate, so it answered "gone"
# while the peer stayed on both planes (onyx, 2026-09-22, peer 150). The key
# comes from kldload-enroll's record, read at join time, because the record is
# what kvm-delete removes.
PROBE_PUB=""
key_on_mesh() { [[ -n "$PROBE_PUB" ]] && wg show wg-mgmt peers 2>/dev/null | grep -qxF "$PROBE_PUB"; }

has_zvol() { zfs list -H -o name 2>/dev/null | grep -qx ".*/${1}" || zfs list -H -o name -r rpool/vms 2>/dev/null | grep -q "/${1}\$"; }

# _wait_until <label> <want: yes|no> <fn> — poll until the answer matches, up
# to WAIT_MAX. Prints the seconds it took, which is the number worth having:
# these registries are driven by 30s and 60s timers, so "it got there in 62s"
# and "it never got there" are different findings, and a fixed sleep would
# report the second as the first.
_wait_until() {
    local label="$1" want="$2" fn="$3" t=0
    while ((t < WAIT_MAX)); do
        if "$fn" "$PROBE"; then
            [[ "$want" == yes ]] && {
                echo "$t"
                return 0
            }
        else
            [[ "$want" == no ]] && {
                echo "$t"
                return 0
            }
        fi
        sleep 5
        t=$((t + 5))
    done
    echo "$t"
    return 1
}

# _check <label> <want> <fn> [max-seconds]
#
# The fourth argument matters: these registries run on very different clocks.
# file_sd regenerates every 30s and the inventory every 60s, but the enrol
# sweep is OnUnitActiveSec=10min — so a 240s wait reported "never appeared" for
# a mesh that was simply not due yet, and called a healthy machine broken
# (deb-4-k8s, 2026-09-20). Each check now waits as long as its own timer needs.
_check() {
    local label="$1" want="$2" fn="$3" secs rc=0
    local WAIT_MAX="${4:-$WAIT_MAX}"
    secs="$(_wait_until "$label" "$want" "$fn")" || rc=1
    if ((rc == 0)); then
        if [[ "$want" == yes ]]; then
            _pass "join: ${label} picked it up after ${secs}s"
        else
            _pass "unjoin: ${label} released it after ${secs}s"
        fi
    else
        if [[ "$want" == yes ]]; then
            _fail "join: ${label}" "${PROBE} never appeared (${WAIT_MAX}s)"
        else
            _fail "unjoin: ${label}" "${PROBE} is STILL registered ${WAIT_MAX}s after delete"
        fi
    fi
}

# ─── Cleanup: by exact name, on every path ──────────────────────────────────
#
# The name is this script's own and is never a pattern. A cleanup that took a
# wildcard to `destroy` once ate six unrelated clones, and a snapshot pattern
# ate four of the operator's rollback points.
cleanup() {
    ((KEEP == 1)) && return 0
    if virsh dominfo "$PROBE" >/dev/null 2>&1 || has_zvol "$PROBE"; then
        echo "  cleanup: removing ${PROBE}"
        kvm-delete "$PROBE" --force >/dev/null 2>&1 ||
            echo "  cleanup: kvm-delete ${PROBE} failed — remove it by hand" >&2
    fi
}
trap cleanup EXIT

# ─── Preconditions ──────────────────────────────────────────────────────────
_section "Estate lifecycle — preconditions"

for _t in virsh kvm-clone kvm-delete kldload-inventory; do
    have "$_t" || {
        _didnotrun "estate lifecycle" "${_t} is not installed — this is not a hypervisor"
        printf '\n  estate lifecycle: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
        exit 0
    }
done

if [[ -z "$SOURCE_VM" ]]; then
    # A golden is the right source: it is shut off, sealed, and cloning one is
    # what the operator actually does. Prefer one that is defined in libvirt.
    SOURCE_VM="$(virsh list --all --name 2>/dev/null | grep -E 'golden' | head -n 1 || true)"
fi
if [[ -z "$SOURCE_VM" ]]; then
    _didnotrun "estate lifecycle" "no golden to clone — build one first (klab golden) or pass --source"
    printf '\n  estate lifecycle: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
    exit 0
fi
_pass "source VM: ${SOURCE_VM}"
echo "  probe name: ${PROBE}  (created and destroyed by this script, by exact name)"

# ─── 1. Create ──────────────────────────────────────────────────────────────
_section "Clone (kvm-clone)"

if kvm-clone "$SOURCE_VM" "$PROBE" >/dev/null 2>&1; then
    # Outcome, not exit code: the domain must actually exist.
    if in_libvirt "$PROBE"; then
        _pass "kvm-clone created ${PROBE}"
    else
        _fail "kvm-clone" "exited 0 and no domain named ${PROBE} exists"
        printf '\n  estate lifecycle: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
        exit 1
    fi
else
    _fail "kvm-clone" "could not clone ${SOURCE_VM} into ${PROBE}"
    printf '\n  estate lifecycle: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
    exit 1
fi

virsh start "$PROBE" >/dev/null 2>&1 ||
    _warn "clone start" "${PROBE} did not start — the registries below may never see it"

# ─── 2. Join ────────────────────────────────────────────────────────────────
_section "Join"

_check "libvirt" yes in_libvirt
_check "state DB" yes in_db
_check "Ansible inventory" yes in_inventory
# The enrol sweep is a 10-minute timer, and waiting for it cost this test up to
# 900s per clone -- 4-k8s ran out of its edition budget right here (fiend,
# 2026-09-22). Starting the shipped sweep unit runs the SAME code path the timer
# would, now. A oneshot `start` blocks until the sweep has finished.
if systemctl cat kldload-enroll-sweep.service >/dev/null 2>&1; then
    systemctl start kldload-enroll-sweep.service >/dev/null 2>&1 ||
        _warn "enrol sweep" "kldload-enroll-sweep.service failed — see journalctl -u kldload-enroll-sweep"
    _mesh_wait=120
else
    _warn "enrol sweep" "kldload-enroll-sweep.service is not installed — waiting on nothing but luck"
    _mesh_wait=900
fi
have kldload-estate && _check "WireGuard mesh" yes on_mesh "$_mesh_wait" ||
    _didnotrun "join: WireGuard mesh" "kldload-estate is not installed"
PROBE_PUB="$(sed -n 's/^guest_pub=//p' "/var/lib/kldload/mesh/enrolled/${PROBE}" 2>/dev/null || true)"
if [[ -z "$PROBE_PUB" ]]; then
    _fail "join: enrolment record" "no /var/lib/kldload/mesh/enrolled/${PROBE} — kvm-delete will have no way to take it off the mesh"
elif key_on_mesh; then
    _pass "join: ${PROBE}'s key is a live wg-mgmt peer"
else
    _fail "join: WireGuard key" "the recorded key for ${PROBE} is not a peer on wg-mgmt"
fi
# klab-prom-targets generates entries for klab-blue-*, klab-green-* and
# kspawn-* and nothing else, so a probe named anything else is not supposed to
# appear and asserting that it does is a test bug, not a finding. The REAL gap
# — that a VM you create by hand is invisible to monitoring — is reported once,
# as a warning, rather than as a failure on every run.
if [[ ! -d /etc/prometheus/targets ]]; then
    _didnotrun "join: Prometheus file_sd" "/etc/prometheus/targets does not exist"
elif [[ "$PROBE" == klab-blue-* || "$PROBE" == klab-green-* || "$PROBE" == kspawn-* ]]; then
    _check "Prometheus file_sd" yes in_prometheus
else
    _warn "join: Prometheus file_sd" "nothing generates a target for a VM named '${PROBE}' — only klab-blue-*, klab-green-* and kspawn-* are covered, so a hand-made clone is not scraped"
fi

# In the inventory is not reachable. This is the same distinction smoke-estate
# draws for the fleet, asked of the one machine this test owns.
if have ansible && in_inventory "$PROBE"; then
    if timeout 120 ansible "$PROBE" -i /usr/local/bin/kldload-inventory -m ping -o >/dev/null 2>&1; then
        _pass "ansible reaches ${PROBE}"
    else
        _fail "ansible reach" "${PROBE} is in the inventory and does not answer a ping"
    fi
fi

# ─── 3. Delete and unjoin ───────────────────────────────────────────────────
_section "Unjoin (kvm-delete)"

if kvm-delete "$PROBE" --force >/dev/null 2>&1; then
    _pass "kvm-delete returned 0"
else
    # kvm-delete has returned 1 after a successful destroy before (a pipeline
    # under pipefail), which left the DB row untouched. So the status is
    # reported and the real checks below decide.
    _warn "kvm-delete" "returned non-zero — the checks below decide whether it worked"
fi

_check "libvirt" no in_libvirt
_check "state DB" no in_db
_check "Ansible inventory" no in_inventory
if [[ -n "$PROBE_PUB" ]]; then
    _check "WireGuard mesh (running wg-mgmt)" no key_on_mesh 60
else
    _didnotrun "unjoin: WireGuard mesh" "the probe never had a recorded key, so there is nothing to see leave"
fi
if [[ -d /etc/prometheus/targets ]] && [[ "$PROBE" == klab-* || "$PROBE" == kspawn-* ]]; then
    _check "Prometheus file_sd" no in_prometheus
fi

if has_zvol "$PROBE"; then
    _fail "unjoin: storage" "the zvol for ${PROBE} survived kvm-delete"
else
    _pass "unjoin: the zvol is gone"
fi

printf '\n  estate lifecycle: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
# Explicit, so lib-test's ERR trap does not fire on this script's own verdict.
if ((FAIL == 0)); then
    exit 0
fi
exit 1
