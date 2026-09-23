#!/usr/bin/env bash
# =============================================================================
# smoke-estate.sh — the VMs are not just LISTED, they are reachable and watched
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Ansible reach   — `ansible all -m ping` against the dynamic inventory,
#                        counting hosts that answered against hosts offered.
#   2. Playbook run    — actually runs system-info.yml and reads its own
#                        reached-vs-inventory line back.
#   3. First-boot proof— the report kldload-ansible-firstboot.service leaves in
#                        /root, checked for a SHORTFALL rather than existence.
#   4. Monitoring      — every running VM has a Prometheus file_sd target, and
#                        Prometheus says that target is up (the API, not the file).
#   5. Mesh            — every running VM is a WireGuard peer with a handshake.
#
# WHY IT EXISTS: the feature ledger already checks that a running VM appears in
# the Ansible inventory and that a golden carries its @golden snapshot. Neither
# is the operator's actual question, which is "can I run a playbook against the
# fleet, and does it show up in monitoring". An inventory entry proves a name
# was written to a file; it says nothing about SSH, the mesh, the key, the
# lease being stale or the scrape failing. Those are exactly the things that
# break, and every one of them leaves the inventory looking perfect.
#
# This is the "a count is not a result" rule applied to the estate: every check
# here compares what answered against what was ASKED, and names the shortfall.
#
# SCOPE: a host with no running VMs has no estate to check. That is reported as
# DID NOT RUN, never as a pass — a gate that cannot run is not a gate.
#
# EXIT: 0 no failures (warnings allowed) · 1 at least one _fail.
# =============================================================================
set -Eeuo pipefail
trap 'echo "smoke-estate.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

have() { command -v "$1" >/dev/null 2>&1; }

# _count <extended regex> — how many lines of stdin match, 0 when none.
#
# grep exits 1 on zero matches, and zero is a RESULT here, not a failure: "no
# host answered" and "no VM is running" are exactly what this suite is trying
# to find out. Named once so the twelve call sites below do not each need their
# own swallow, which is how a file ends up with a dozen unexplained `|| true`.
_count() { grep -cE "$1" || true; }

# _didnotrun — a check that could not run says so in its own voice. It counts
# as a warning so the suite's exit status stays honest, but the wording is what
# stops it being read as a pass three months later.
_didnotrun() { _warn "$1" "DID NOT RUN — $2"; }

PLAYBOOK=/usr/local/share/kldload-ansible/playbooks/system-info.yml
# The dynamic inventory script itself is what -i takes; ansible runs it and
# reads the JSON, which is how a VM that got its lease a minute ago is already
# targetable without anyone editing a hosts file.
INV=/usr/local/bin/kldload-inventory
REPORT=/root/kldload-ansible-report.txt
TARGETS_DIR=/etc/prometheus/targets

# vms_running — names of the domains libvirt currently has up.
vms_running() { virsh list --name 2>/dev/null | grep . || true; }

# inv_hosts — hostnames the dynamic inventory offers right now.
inv_hosts() {
    local _inv
    _inv="$(kldload-inventory --list 2>/dev/null)" || return 0
    [[ -n "$_inv" ]] || return 0
    printf '%s' "$_inv" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for h in sorted(d.get("_meta",{}).get("hostvars",{})): print(h)' 2>/dev/null
}

_vm_count="$(vms_running | _count .)"

# ─── 1. Ansible actually reaches the fleet ──────────────────────────────────
#
# `ansible all -m ping` is the cheapest end-to-end proof there is: it resolves
# the dynamic inventory, opens SSH over the mesh with the key the install
# generated, and runs a module on the other end. If any link in that chain is
# broken it fails here rather than in the middle of a real play.
_section "Ansible reach"

if ((_vm_count == 0)); then
    _didnotrun "ansible reach" "no VMs are running on this host"
elif ! have ansible || ! have kldload-inventory; then
    _didnotrun "ansible reach" "ansible or kldload-inventory is not installed"
else
    # Expect an answer only from hosts that are RUNNING.
    #
    # The inventory lists every machine the estate knows, which is correct and
    # is not the same set as the machines that can answer a ping. autodeploy
    # deliberately powers klab-blue-* and klab-green-* off once their meshes
    # have handshaked, to give the ztest phase back eight VMs' worth of RAM --
    # "nothing later reads from them" is the design. They stay in the inventory
    # because they still exist.
    #
    # Counting those as unreachable made 3-kvm report "1 of 4 answered
    # (3 unreachable): klab-green-fedora klab-green-rocky klab-green-ubuntu"
    # for machines that were off on purpose (fiend, 2026-09-22). The monitoring
    # and mesh sections below already scope themselves to running VMs; this one
    # did not, and was the only one that failed.
    _inv_all="$(inv_hosts)"
    _running="$(vms_running)"
    # grep -xF -f, not a loop: a `grep -q ... && printf` inside a while body
    # returns 1 for every host that is NOT running, and under `set -e` that
    # aborts the loop on the first powered-off machine. The gates were happy
    # with the loop; running it was what showed it stopping early.
    # || true: no overlap is a RESULT here, not an error.
    _inv_live="$(printf '%s\n' "$_inv_all" | grep -xF -f <(printf '%s\n' "$_running") || true)"
    _inv_n="$(printf '%s\n' "$_inv_live" | _count .)"
    _inv_off="$(($(printf '%s\n' "$_inv_all" | _count .) - _inv_n))"
    ((_inv_off == 0)) ||
        echo "    ${_inv_off} inventory host(s) are powered off and are not expected to answer"
    if ((_inv_n == 0)); then
        _fail "ansible reach" "${_vm_count} VM(s) running and no running VM is in the inventory"
    else
        # -o gives one line per host; a host that answers prints SUCCESS.
        # ansible exits non-zero when ANY host is unreachable, which is the
        # case this check exists to measure — so the status is discarded and
        # the output is what gets judged, host by host, below.
        # A comma-separated pattern, not "all": asking ansible for machines
        # that are switched off just manufactures the failure this check was
        # measuring.
        _ping_pat="$(printf '%s\n' "$_inv_live" | paste -sd, -)"
        # swallow: ansible exits non-zero when ANY host is unreachable, which
        # is the case this check exists to measure. The output is judged below,
        # host by host, rather than the status.
        _ping_out="$(timeout 180 ansible "$_ping_pat" -i "$INV" -m ping -o 2>/dev/null || true)"
        _ok="$(printf '%s\n' "$_ping_out" | _count 'SUCCESS')"
        _bad="$(printf '%s\n' "$_ping_out" | _count 'UNREACHABLE|FAILED')"
        if ((_ok == _inv_n)); then
            _pass "ansible ping: all ${_ok} inventory host(s) answered"
        elif ((_ok == 0)); then
            _fail "ansible reach" "0 of ${_inv_n} host(s) answered — $(printf '%s' "$_ping_out" | head -n 1 | cut -c1-120)"
        else
            # The shortfall by NAME. "4 of 6" sends someone hunting; the two
            # names that did not answer are the actual bug report.
            _quiet="$(comm -23 <(inv_hosts | sort) \
                <(printf '%s\n' "$_ping_out" | awk '/SUCCESS/{print $1}' | sort) | tr '\n' ' ')"
            _fail "ansible reach" "${_ok} of ${_inv_n} answered (${_bad} unreachable/failed); silent:${_quiet:- none}"
        fi
    fi
fi

# ─── 2. A real playbook, not just a ping ────────────────────────────────────
#
# ping proves the transport. A play proves fact gathering, the become path and
# the inventory's host vars — the things a real playbook needs and a ping does
# not touch. system-info.yml is read-only and already counts what it reached,
# so the assertion here is its own last line, not a guess about exit status.
_section "Playbook run"

if ((_vm_count == 0)); then
    _didnotrun "playbook run" "no VMs are running on this host"
elif [[ ! -r "$PLAYBOOK" ]]; then
    _fail "playbook run" "${PLAYBOOK} is not installed — the fleet has no shipped play"
elif ! have ansible-playbook; then
    _didnotrun "playbook run" "ansible-playbook is not installed"
else
    # Same as the ping above: a play that fails on one host of six exits
    # non-zero, and "one of six" is the finding. The recap is parsed instead.
    _pb_out="$(timeout 300 ansible-playbook -i "$INV" "$PLAYBOOK" 2>&1 || true)"
    # failed=N appears once per host in the recap; any non-zero is a real failure.
    _pb_failed="$(printf '%s\n' "$_pb_out" | grep -oE 'failed=[0-9]+' | awk -F= '{s+=$2} END{print s+0}')"
    _pb_unreach="$(printf '%s\n' "$_pb_out" | grep -oE 'unreachable=[0-9]+' | awk -F= '{s+=$2} END{print s+0}')"
    _pb_hosts="$(printf '%s\n' "$_pb_out" | _count '^[a-zA-Z0-9_.-]+ +: +ok=')"
    if ((_pb_hosts == 0)); then
        _fail "playbook run" "the play reached NO hosts — $(printf '%s' "$_pb_out" | tail -n 1 | cut -c1-120)"
    elif ((_pb_failed == 0 && _pb_unreach == 0)); then
        _pass "playbook: system-info.yml ran clean on ${_pb_hosts} host(s)"
    else
        _fail "playbook run" "${_pb_hosts} host(s): failed=${_pb_failed} unreachable=${_pb_unreach}"
    fi
fi

# ─── 3. The first-boot report, read rather than counted ─────────────────────
#
# kldload-ansible-firstboot.service runs the same play on a fresh install and
# leaves its output here. Checking the file EXISTS is the trap: it exists just
# as happily when the play reached one host out of six. The play prints its own
# reached-vs-inventory line for exactly this reason.
_section "First-boot Ansible report"

if [[ ! -f "$REPORT" ]]; then
    if ((_vm_count == 0)); then
        _didnotrun "first-boot ansible report" "no report and no VMs — nothing ran yet"
    else
        _warn "first-boot ansible report" "${REPORT} is absent although ${_vm_count} VM(s) are running"
    fi
else
    # An empty result is handled explicitly below ("says nothing about what it
    # reached"), so grep finding nothing is not an error here.
    _rep_line="$(grep -iE 'reached|inventory' "$REPORT" 2>/dev/null | tail -n 1 || true)"
    # Compare the two NUMBERS, never pattern-match the sentence. The first
    # version of this check looked for "reached 0" and "0 of", and so read
    # "reached 1 of 2 hosts" -- a play that missed half the fleet -- as a pass.
    # Caught by the stub harness before it ever ran on a machine, 2026-09-19.
    _rep_pair="$(grep -oE '[0-9]+ of [0-9]+' <<<"$_rep_line" | tail -n 1 || true)"
    if [[ -z "$_rep_line" ]]; then
        _warn "first-boot ansible report" "present but says nothing about what it reached"
    elif [[ -n "$_rep_pair" ]]; then
        _rep_got="${_rep_pair%% of *}"
        _rep_want="${_rep_pair##* }"
        if ((_rep_want > 0 && _rep_got == _rep_want)); then
            _pass "first-boot ansible report: reached ${_rep_pair} host(s)"
        else
            _fail "first-boot ansible report" "reached only ${_rep_pair} host(s) at first boot"
        fi
    elif grep -qiE 'shortfall|reached 0' <<<"$_rep_line"; then
        _fail "first-boot ansible report" "$(printf '%s' "$_rep_line" | cut -c1-140)"
    else
        _warn "first-boot ansible report" "no reached/inventory counts to compare: $(printf '%s' "$_rep_line" | cut -c1-80)"
    fi
fi

# ─── 4. Monitoring: the file AND the scrape ─────────────────────────────────
#
# Two different failures wear the same face. klab-prom-targets can write a
# perfect file_sd entry for a VM that Prometheus then fails to scrape (node
# exporter absent, firewall, stale lease), and Prometheus can be happily
# scraping a host that no longer exists. So this checks the file for coverage
# and the API for truth, and says which of the two is wrong.
_section "Monitoring"

if ((_vm_count == 0)); then
    _didnotrun "monitoring" "no VMs are running on this host"
elif [[ ! -d "$TARGETS_DIR" ]]; then
    _didnotrun "monitoring" "${TARGETS_DIR} does not exist — Prometheus is not configured here"
else
    # Split by whether anything is SUPPOSED to generate a target for the name.
    # klab-prom-targets covers klab-blue-*, klab-green-* and kspawn-*; a
    # hand-made clone matches none of them. Missing where it is generated is a
    # FAILURE; missing where nothing generates one is a WARNING that names the
    # gap, because "these VMs are running and nothing scrapes them" is still
    # worth knowing.
    #
    # BOTH label spellings count as covered, and that is the point. klab VMs are
    # written as "vm":"<name>"; k8s nodes are written by the same generator as
    # "node":"<name>" (kubelet on :10250, plus cilium-agent, hubble-metrics and
    # tetragon). Grepping only for "vm" reported "no generator covers the name"
    # for all six cluster nodes on a host where every one of those targets was
    # UP in Prometheus -- a warning that says nothing scrapes them, about
    # machines that are scraped four ways. It recurred in three sweeps, which is
    # how a real warning gets trained into noise.
    # HISTORY: fiend, 2026-09-21, checked against the Prometheus API rather than
    # the target files. What IS missing there is host-level metrics: no
    # node_exporter answers on :9100 on a cluster node. That is a gap in the
    # golden, not in target generation, and it is not what this check measures.
    _untargeted="" _uncovered=""
    while read -r _vm; do
        [[ -n "$_vm" ]] || continue
        grep -rqsE "\"(vm|node)\"[[:space:]]*:[[:space:]]*\"${_vm}\"" "$TARGETS_DIR" && continue
        case "$_vm" in
        klab-blue-* | klab-green-* | kspawn-*) _untargeted+=" ${_vm}" ;;
        *) _uncovered+=" ${_vm}" ;;
        esac
    done < <(vms_running)
    if [[ -z "$_untargeted" && -z "$_uncovered" ]]; then
        _pass "file_sd: all ${_vm_count} running VM(s) have a Prometheus target"
    elif [[ -z "$_untargeted" ]]; then
        _pass "file_sd: every VM a generator covers has a target"
        _warn "monitoring coverage" "running, and no generator covers the name:${_uncovered}"
    else
        _fail "monitoring targets" "klab/kspawn VMs running and absent from ${TARGETS_DIR}:${_untargeted}"
        [[ -n "$_uncovered" ]] &&
            _warn "monitoring coverage" "also running, and no generator covers the name:${_uncovered}"
    fi

    # The scrape itself. Prometheus is local; a machine where it is not
    # listening has a monitoring problem of its own, which is a warning here
    # rather than a failure of the estate.
    _api="$(timeout 20 curl -sf 'http://127.0.0.1:9090/api/v1/query?query=up' 2>/dev/null || true)"
    if [[ -z "$_api" ]]; then
        _warn "monitoring scrape" "Prometheus did not answer on 127.0.0.1:9090"
    else
        _down="$(printf '%s' "$_api" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for r in d.get("data",{}).get("result",[]):
    m=r.get("metric",{})
    if m.get("vm") and r.get("value",["",""])[1]=="0":
        print(m["vm"])' 2>/dev/null | sort -u | tr '\n' ' ')"
        # DOWN is only a defect for a machine that is supposed to be up.
        #
        # A target file outlives the VM it names: autodeploy powers klab-blue-*
        # and klab-green-* off once their meshes handshake, the file stays, and
        # Prometheus goes on scraping an address with nothing behind it. up=0
        # is then the correct reading of a machine that is correctly off.
        # 3-kvm failed "targeted but DOWN: klab-green-fedora klab-green-rocky"
        # for exactly that (fiend, 2026-09-22). Split the two so a real
        # scrape failure is still a failure and an idle clone is a note.
        _down_live="" _down_off=""
        for _d in ${_down}; do
            if printf '%s\n' "$(vms_running)" | grep -qxF "$_d"; then
                _down_live+=" ${_d}"
            else
                _down_off+=" ${_d}"
            fi
        done
        [[ -z "${_down_off// /}" ]] ||
            echo "    targeted and DOWN, but powered off, which is expected:${_down_off}"
        if [[ -z "${_down_live// /}" ]]; then
            _pass "scrape: every VM target for a RUNNING VM is up"
        else
            _fail "monitoring scrape" "running and targeted, but DOWN in Prometheus:${_down_live}"
        fi
    fi
fi

# ─── 5. Mesh: attached, and recently ────────────────────────────────────────
#
# A peer entry with no handshake is a key that was minted and never used —
# which is what a half-finished enrol looks like, and it is invisible unless
# the handshake age is what gets checked rather than the peer count.
_section "Mesh attachment"

if ((_vm_count == 0)); then
    _didnotrun "mesh attachment" "no VMs are running on this host"
elif ! have wg; then
    _didnotrun "mesh attachment" "wg is not installed"
else
    # No interface at all is a legitimate state (no mesh on this host) and is
    # reported as DID NOT RUN two lines down.
    _if="$(wg show interfaces 2>/dev/null | tr ' ' '\n' | head -n 1 || true)"
    if [[ -z "$_if" ]]; then
        _didnotrun "mesh attachment" "no WireGuard interface is up on this host"
    else
        _peers="$(wg show "$_if" peers 2>/dev/null | _count .)"
        _now="$(date +%s)"
        # 15 minutes: the mesh keepalive is well under that, so anything older
        # is a peer that is not actually talking.
        _live="$(wg show "$_if" latest-handshakes 2>/dev/null |
            awk -v n="$_now" '$2>0 && (n-$2)<900' | _count .)"
        if ((_peers == 0)); then
            _warn "mesh attachment" "${_if} is up with no peers — nothing has enrolled"
        elif ((_live == _peers)); then
            _pass "mesh: all ${_peers} peer(s) on ${_if} handshook within 15 min"
        elif ((_live == 0)); then
            _fail "mesh attachment" "${_peers} peer(s) on ${_if} and NOT ONE has handshaken"
        else
            _warn "mesh attachment" "${_live} of ${_peers} peer(s) on ${_if} handshook recently"
        fi
    fi
fi

printf '\n  estate: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
# Explicit, so lib-test's ERR trap does not fire on this suite's own verdict.
if ((FAIL == 0)); then
    exit 0
fi
exit 1
