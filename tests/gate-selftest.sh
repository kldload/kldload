#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
# gate-selftest.sh — prove the gates can FAIL.
#
# What it does, in order:
#   1. Refuses to run on a dirty tree (restoration is `git checkout --`, which
#      would destroy uncommitted work).
#   2. For each case: breaks one thing on purpose, runs the gate that is
#      supposed to notice, asserts it went RED with the expected message,
#      and restores the file.
#   3. Reports how many gates proved they can fail.
#
# WHY this exists: on 2026-09-02 a full day of auditing turned up roughly
# thirteen defects and exactly ONE was caught by an automated gate. Two gates
# were worse than absent -- they were reporting green on broken systems:
#
#   * audit-full.sh scored 53 passed / 0 failed while printing, in green,
#     `bat -> "bash: line 1: bat: command not found"`. Every probe ended in
#     `| head -1`, so the pipeline returned head's status, and several added
#     `|| echo missing` on top, forcing 0 by construction.
#   * smoke-features.sh passed klab-blue at 5/5 peers with all five VMs
#     `shut off` and the newest handshake 41 minutes old, because it tested
#     "has EVER handshaked" and WireGuard keeps that timestamp forever.
#
# Both had been green for months. A gate nobody has deliberately broken is not
# a gate, it is decoration -- and decoration is worse than nothing, because it
# manufactures confidence. Every case below was verified by hand once, on the
# day its gate was written or fixed; this file is that verification made
# repeatable, so a gate that quietly stops being able to fail becomes a red
# build instead of a comfortable number.
#
# Inputs:  a clean git worktree at $ROOT.
# Outputs: exit 0 when every gate proved it can fail; exit 1 otherwise.
#          Mutations are ALWAYS reverted, including on interrupt or crash.
#
# Notes:
#   * Each case runs the full gate script it targets, so runtime is roughly
#     (cases x 46s) for smoke-build. Run one case with: gate-selftest.sh <name>
#   * A case that fails means the GATE is broken, not the tree. Read it as
#     "this check would not have caught the thing it exists to catch."
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

G='\033[1;32m' R='\033[1;31m' Y='\033[1;33m' C='\033[1;36m' N='\033[0m'

PASS=0 FAIL=0
TOUCHED=()

# Restore every file we mutated, whatever happens. `git checkout --` is safe
# ONLY because we refused to start on a dirty tree.
restore() {
    local f
    for f in "${TOUCHED[@]:-}"; do
        # A file we never got as far as mutating, or one already restored by
        # run_case, is the normal path through here -- restore() runs from the
        # EXIT trap as well as after every case. Only that is swallowed.
        [[ -n "$f" ]] && git checkout -- "$f" 2>/dev/null || true
    done
    TOUCHED=()
}
trap 'restore' EXIT INT TERM

# --untracked-files=no on purpose: restoration is `git checkout --`, which only
# touches TRACKED files, so an untracked file is not at risk and must not block
# the run. (It also unblocks the bootstrap case where this very script is the
# untracked file.)
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo -e "${R}refusing to run on a dirty tree${N}" >&2
    echo "  This script restores by 'git checkout -- <file>', which would" >&2
    echo "  discard your uncommitted work. Commit or stash first." >&2
    git status --short --untracked-files=no >&2
    exit 2
fi

# ─── case runner ─────────────────────────────────────────────────────────────
#
# mutate() applies a python edit to one tracked file and records it for
# restoration. The edit ASSERTS its anchor is present: a mutation that silently
# applies to nothing would leave the tree correct, the gate green, and this
# script reporting a pass it never earned -- the exact failure mode it exists
# to catch, reproduced inside the tool. (That is not hypothetical: three
# defects on 2026-08-22 came from edits anchored on whitespace that matched
# nothing.)
mutate() {
    local file="$1" old="$2" new="$3"
    TOUCHED+=("$file")
    OLD="$old" NEW="$new" python3 - "$file" <<'PY'
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
assert old in s, "mutation anchor not found in %s -- the selftest case is stale" % p
open(p, "w").write(s.replace(old, new, 1))
PY
}

# run_case <name> <gate-command> <expected-substring>
#
# Asserts the gate exits NON-ZERO and says the expected thing. Both halves
# matter: a gate that goes red for an unrelated reason has not proved it
# catches THIS.
run_case() {
    local name="$1" gate="$2" want="$3" out rc
    printf '  %-34s ' "$name"
    # The gate is EXPECTED to exit non-zero here -- that is the whole point --
    # so both errexit and the ERR trap have to stand down for this one command,
    # or the harness dies reporting its own success as a failure.
    set +e
    trap - ERR
    out="$(eval "$gate" 2>&1)"
    rc=$?
    trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR
    set -e
    if ((rc == 0)); then
        echo -e "${R}GATE DID NOT FIRE${N}"
        echo "      broke it on purpose and the gate still passed (exit 0)"
        echo "      -> this check cannot catch what it exists to catch"
        FAIL=$((FAIL + 1))
    elif ! grep -qF "$want" <<<"$out"; then
        echo -e "${Y}FIRED, WRONG REASON${N}"
        echo "      wanted: $want"
        # `|| true`: when the gate produced no FAIL line at all, grep exits 1 and
        # pipefail would fire the ERR trap in the middle of reporting -- the
        # harness crashing while explaining someone else's crash.
        echo "      got:    $(grep -iE '✗|FAIL' <<<"$out" | head -2 | tr '\n' ' ' || true)"
        FAIL=$((FAIL + 1))
    else
        echo -e "${G}fires${N}"
        PASS=$((PASS + 1))
    fi
    restore
}

ONLY="${1:-}"
want_case() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

echo -e "${C}══ gate self-test — breaking things on purpose ══${N}"
echo ""

PROFILES=live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh
VICTIM=live-build/config/includes.chroot/usr/local/bin/kvm-mesh

# ── 1. vendor systemd drop-ins reaching the installed target ─────────────────
# The bug: the installer's carry loop read /etc/systemd/system/*.d only, so
# every drop-in shipped in /usr/lib rode the ISO and stopped at the squashfs.
# fiend installed 2026-09-02 from an ISO containing the IPMI guard and still
# had `ipmi.service failed`. The ISO-side gate was green the whole time.
if want_case dropin-target; then
    mutate "$PROFILES" \
        'for _droproot in /usr/lib/systemd/system /etc/systemd/system; do' \
        'for _droproot in /etc/systemd/system; do'
    run_case "drop-ins reach the target" \
        "bash tests/smoke-build.sh" \
        "systemd drop-ins (target)"
fi

# ── 2. shipped launchers reaching the installed target ───────────────────────
# The bug: the Timer's .desktop, icon and binary were absent from an installed
# system because the copy globs were hand-curated and nobody had added them.
if want_case copy-paths; then
    mutate "$PROFILES" \
        '/usr/share/applications/com.kldload.*.desktop;' \
        '/usr/share/applications/__no_such_glob__.desktop;'
    run_case "launchers reach the target" \
        "bash tests/smoke-build.sh" \
        "installer copy paths"
fi

# ── 3. the silent-failure ratchet ────────────────────────────────────────────
# The ratchet is the only thing standing between the tree and another 1,400
# unexplained swallows. If it stops counting, nothing else notices.
if want_case ratchet; then
    # The probe is ASSEMBLED rather than written out. The ratchet greps the
    # tracked sources for the literal string, so spelling it here would make
    # this test case count itself: the gate under test would fail on its own
    # tester, permanently, and the only fix would be to stop testing it.
    _or_true='|'"| true"
    mutate "$VICTIM" \
        '# ─── commands ─' \
        "gate_selftest_probe() { false ${_or_true}; }

# ─── commands ─"
    run_case "silent-failure ratchet counts" \
        "bash tests/smoke-build.sh" \
        "silent-failure ratchet"
fi

# ── 4. shfmt drift ───────────────────────────────────────────────────────────
if want_case shfmt; then
    mutate "$VICTIM" \
        'count_lines() {' \
        'count_lines() {
          	 '
    run_case "shfmt drift is caught" \
        "bash tests/smoke-build.sh" \
        "shfmt -w -i 4"
fi

# ── 5. bash -n syntax ────────────────────────────────────────────────────────
if want_case syntax; then
    mutate "$VICTIM" \
        'count_lines() {' \
        'count_lines() { if then fi;'
    run_case "broken syntax is caught" \
        "bash tests/smoke-build.sh" \
        "syntax"
fi

# ── 6. the Go gate ───────────────────────────────────────────────────────────
# kldload tracks FOUR Go modules (buildmon, tools/sysdiag, wg, ztxplore) and
# until 2026-09-02 not one had ever been linted: smoke-build gated shell and
# python, and there are no GitHub Actions here. Three of the four had dead code
# in a shipped binary the first time staticcheck was pointed at them. This case
# exists so that gate cannot quietly stop looking.
if want_case go-deadcode; then
    mutate wg/estate.go \
        'package main' \
        'package main

// injected by gate-selftest: unreferenced, staticcheck U1000
func gateSelftestDeadFunc() int { return 0 }'
    run_case "go dead code is caught" \
        "bash tests/smoke-build.sh" \
        "staticcheck"
fi

echo ""
echo -e "${C}══════════════════════════════════════════════════${N}"
if ((FAIL == 0)); then
    echo -e "  ${G}${PASS} gate(s) proved they can fail${N}"
else
    echo -e "  ${G}${PASS} proved${N}, ${R}${FAIL} did NOT${N}"
    echo -e "  ${R}A gate that cannot fail is decoration.${N}"
fi
echo -e "${C}══════════════════════════════════════════════════${N}"
# Explicit exit, not `((FAIL == 0))`: the arithmetic form returns 1 on failure,
# which is the status we want but also trips the ERR trap on the way out and
# prints a spurious "FAIL at line N" after the report.
[[ $FAIL -eq 0 ]] && exit 0
exit 1
