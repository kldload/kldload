#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-console.sh — the operator console's backend, asked over its own socket
#
# What it does, in order:
#   1. Opens wss://localhost:8443/ws the way the page does (Origin header, TLS
#      unchecked on the self-signed cert) and sends one action at a time.
#   2. For each action, asserts the answer's TYPE and the fields the view
#      renders from, with a bound on how long the answer may take.
#   3. Runs the terminal hub, kld, in its --print form for every section and
#      asserts it prints the section's header line.
#
# Why: the console's views were verified by hand on onyx with a python client
# while they were built (2026-09-26). This makes that client a gate, so a
# host whose webui predates a view, or whose collector broke, fails here
# rather than showing "Loading…" forever to the first operator who opens it.
#
# Inputs:  a running kldload-webui on :8443 (installed host); python3 with the
#          websockets module (the webui's own dependency, so it is there).
# Output:  PASS/FAIL/WARN lines (tests/lib-test.sh), a summary, exit 0 only
#          when nothing failed. A missing webui or module is a FAIL, not a
#          skip: a gate that cannot run is not a gate.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

WEBUI_URL="${KLDLOAD_WEBUI_URL:-https://localhost:8443}"

_section "Console backend over ${WEBUI_URL}"

if ! python3 -c 'import websockets' 2>/dev/null; then
    _fail "python websockets module" "not importable — the gate cannot run"
    printf '\n  console: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
    exit 1
fi
# 20 s, not 5: a page reconnecting after a restart fires a burst of polls and
# the older handlers still block the event loop for a few seconds each (the
# VM list's forty virsh calls); the gate is here to catch a console that
# does not answer, not one that is busy for a moment (onyx, 2026-09-26).
if ! curl -fsk --max-time 20 -o /dev/null "${WEBUI_URL}/"; then
    _fail "webui answers ${WEBUI_URL}" "no HTTP answer — the gate cannot run"
    printf '\n  console: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
    exit 1
fi
_pass "webui answers ${WEBUI_URL}"

# One python process, one socket, every action; each line it prints is
# "ok|fail <name> <detail>" and is recorded here, so a stuck action costs its
# own bound and not the suite. The assertions name the fields the SPA reads.
_results="$(
    WEBUI_URL="$WEBUI_URL" python3 - <<'PY'
import asyncio, json, os, ssl, time
import websockets
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
base = os.environ["WEBUI_URL"]
url = base.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
CASES = [
    # action, expected type, bound (s), check(msg) -> detail or "" when fine
    ({"action": "overview_status"}, "overview_status", 60,
     lambda m: "" if all(k in m for k in ("machines", "storage", "mesh", "cluster", "events", "health"))
     else "missing " + ",".join(k for k in ("machines", "storage", "mesh", "cluster", "events", "health") if k not in m)),
    ({"action": "list_vms"}, "vm_list", 60,
     lambda m: "" if isinstance(m.get("vms"), list) and all("estate" in v and "joining" in v for v in m["vms"])
     else "vms without estate/joining fields"),
    ({"action": "estate_status"}, "estate_status", 90,
     lambda m: "" if isinstance(m.get("machines"), list) and isinstance(m.get("drift"), list) and isinstance(m.get("sources"), dict)
     else "machines/drift/sources missing"),
    ({"action": "network_status"}, "network_status", 60,
     lambda m: "" if "planes" in m or "error" in m else "no planes and no error"),
    ({"action": "provision_status"}, "provision_status", 60,
     lambda m: "" if "service" in m or "error" in m else "no service and no error"),
    ({"action": "snapshot_timeline"}, "snapshot_timeline", 150,
     lambda m: "" if isinstance(m.get("datasets"), list) and "total" in m else "datasets/total missing"),
    ({"action": "be_status"}, "be_status", 60,
     lambda m: "" if "running" in m and "bootfs" in m and isinstance(m.get("environments"), list) else "running/bootfs/environments missing"),
    ({"action": "k8s_stack"}, "k8s_stack", 30,
     lambda m: "" if isinstance(m.get("charts"), list) and ("error" in m) else "charts/error missing"),
    ({"action": "snapshot_rollback", "name": "rpool/ROOT/x@y"}, "error", 30,
     lambda m: "" if "refusing" in m.get("msg", "") else "in-place root rollback was not refused: " + m.get("msg", "")),
    ({"action": "vm_delete_full", "vm": "../etc"}, "error", 30,
     lambda m: "" if "invalid" in m.get("msg", "") else "bad VM name not refused: " + m.get("msg", "")),
]
async def main():
    async with websockets.connect(url, ssl=ctx if url.startswith("wss") else None,
                                  origin=base, max_size=None) as ws:
        for action, want, bound, check in CASES:
            name = action["action"]
            t0 = time.monotonic()
            await ws.send(json.dumps(action))
            try:
                while True:
                    m = json.loads(await asyncio.wait_for(ws.recv(), bound - (time.monotonic() - t0)))
                    if m.get("type") == want or (m.get("type") == "error" and want != "error"):
                        break
            except asyncio.TimeoutError:
                print(f"fail {name} no {want} within {bound}s"); continue
            took = time.monotonic() - t0
            if m.get("type") != want:
                print(f"fail {name} got {m.get('type')}: {str(m.get('msg', ''))[:80]}"); continue
            d = check(m)
            print(f"{'fail' if d else 'ok'} {name} {want} in {took:.1f}s {d}")
asyncio.run(main())
PY
)" || _fail "websocket session" "the client died — see above"
_n=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    _n=$((_n + 1))
    case "$line" in
    ok\ *) _pass "${line#ok }" ;;
    fail\ *) _fail "console action" "${line#fail }" ;;
    *) _warn "console client" "unexpected line: $line" ;;
    esac
done <<<"$_results"
# Count what we were given: ten cases went in, ten lines must come out.
if ((_n == 10)); then
    _pass "every console action answered (10/10)"
else
    _fail "console actions answered" "${_n} of 10 cases reported — the rest never answered"
fi

_section "kld, the terminal hub"
if ! command -v kld >/dev/null 2>&1; then
    _fail "kld installed" "not on PATH"
else
    kld --help 2>/dev/null | grep -q 'operator console' && _pass "kld --help" || _fail "kld --help" "no usage text"
    # Every sub-tab of every section prints its rail and its own name; the
    # data under it is the tool's answer or the tool's error, both acceptable
    # to this gate — the tools have their own. The list is the console's:
    # a sub-tab added to kld without a collector fails here.
    _tabs=0
    while read -r s sub; do
        _tabs=$((_tabs + 1))
        # Captured, not piped into grep -q: under pipefail a `grep -q` that
        # matches early closes the pipe, kld dies of SIGPIPE writing its
        # 4,800 snapshot rows, and the pipeline reads as a failure (onyx,
        # 2026-09-26). kld's own exit is 0 even when the tool it asked erred.
        _out="$(timeout 180 kld "$s" "$sub" --print 2>/dev/null)" || _warn "kld $s $sub --print" "exited non-zero or timed out"
        if grep -qiE "^  ${s} / ${sub//envs/ envs}" <<<"$_out"; then
            _pass "kld $s $sub --print"
        else
            _fail "kld $s $sub --print" "no '$s / $sub' line in the output"
        fi
    done <<'TABS'
overview summary
machines vms
machines snapshots
machines microvms
machines appliances
machines factory
machines networks
machines pools
storage pools
storage pool
storage topology
storage datasets
storage snapshots
storage explorer
storage versions
storage bootenvs
storage shares
storage arc
network planes
network peers
network enrolled
network fleet
network check
cluster nodes
cluster pods
cluster deployments
cluster services
cluster events
cluster logs
cluster describe
ansible hosts
ansible groups
ansible plays
helm releases
helm examples
metrics host
metrics storage
metrics machines
metrics mesh
metrics targets
estate drift
estate units
estate events
provision armed
provision feed
provision goldens
provision answers
TABS
    ((_tabs == 47)) && _pass "every sub-tab tried (47/47)" || _fail "sub-tabs tried" "${_tabs} of 47"

    # ── the video console, against a running VM's display ─────────────────
    # The wire client (vnc.go) is exercised by its live test: it dials the
    # first running domain's VNC port, taps Shift (harmless at any prompt,
    # and it wakes a blanked console) and wants a lit pixel back. Then the
    # TUI's screen on that VM must draw more than one colour: the first
    # cut cached the first frame and drew black forever (2026-09-26).
    # View-only apart from the Shift tap; the VM is selected by NAME.
    _live_vm=""
    while read -r _d; do
        [[ -n "$_d" ]] || continue
        if sudo -n virsh dumpxml "$_d" 2>/dev/null | grep -q "<graphics type='vnc' port='[0-9]"; then
            _live_vm="$_d"
            break
        fi
    done < <(sudo -n virsh list --name 2>/dev/null)
    if [[ -z "$_live_vm" ]]; then
        _warn "video console" "no running VM with a VNC display: the console checks DID NOT RUN"
    elif ! command -v go >/dev/null || ! command -v tmux >/dev/null; then
        _warn "video console" "go or tmux missing: the console checks DID NOT RUN"
    else
        # the digits alone: a "[0-9]*$" after the closing quote matched empty
        _port="$(sudo -n virsh dumpxml "$_live_vm" | grep -o "<graphics type='vnc' port='[0-9]*'" | head -1 | tr -dc '0-9')"
        if (cd "${SCRIPT_DIR}/../kld" && KLD_VNC_LIVE="127.0.0.1:${_port}" GOTMPDIR="${SCRIPT_DIR}/../kld/.gotmp" go test -run TestRFBLive . >/dev/null 2>&1); then
            _pass "vnc wire client: lit frame from ${_live_vm} :${_port}"
        else
            _fail "vnc wire client" "no lit frame from ${_live_vm} :${_port}"
        fi
        _t="console-probe-$$"
        tmux new-session -d -s "$_t" -x 160 -y 45 "kld machines vms --tui"
        for _i in $(seq 40); do
            tmux capture-pane -t "$_t" -p | grep -q -- "$_live_vm" && break
            sleep 0.5
        done
        tmux send-keys -t "$_t" '/'
        sleep 0.3
        tmux send-keys -t "$_t" -l "$_live_vm"
        sleep 0.3
        tmux send-keys -t "$_t" Enter
        sleep 2
        _sel="$(tmux capture-pane -t "$_t" -p | grep -c -- "$_live_vm" || true)"
        if ((_sel == 0)); then
            _fail "video console" "could not select ${_live_vm} in the VMs table"
        else
            tmux send-keys -t "$_t" w
            sleep 5
            _cap="$(tmux capture-pane -t "$_t" -p -e)"
            _blocks="$(grep -o '▀' <<<"$_cap" | wc -l)"
            _colours="$(grep -o '38;2;[0-9;]*m' <<<"$_cap" | sort -u | wc -l)"
            if ((_blocks > 100 && _colours > 1)); then
                _pass "video console in the TUI: ${_blocks} cells, ${_colours} colours from ${_live_vm}"
            else
                _fail "video console in the TUI" "${_blocks} cells, ${_colours} colours from ${_live_vm}"
            fi
            tmux send-keys -t "$_t" C-]
            sleep 0.3
            tmux send-keys -t "$_t" d
            sleep 1
            if tmux capture-pane -t "$_t" -p | grep -q 'screen .* detached'; then
                _pass "video console detaches on ctrl+] d"
            else
                _fail "video console" "ctrl+] d did not return to the table"
            fi
        fi
        tmux kill-session -t "$_t" 2>/dev/null || true # already gone if kld exited
    fi
fi

printf '\n  console: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
# exit, not a bare arithmetic test: the latter trips the ERR trap and prints a
# "FAIL at line" for the summary itself.
exit $((FAIL > 0))
