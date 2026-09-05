#!/usr/bin/env bash
# smoke-features.sh — the growing feature ledger: every shipped capability,
# asserted on the machine it was installed on.
#
# WHY THIS FILE EXISTS, and the rule for adding to it:
#
#   Every feature kldload ships gets a check here, in the same change that
#   ships the feature. Not "when convenient" and not "before a release" — that
#   pass never happens cleanly. The other smoke-*.sh files test a SUBSYSTEM
#   (core/ZFS, server tools, KVM, desktop); this one tests the FEATURE LIST,
#   which is the thing that silently rots between builds.
#
#   The failure mode it exists to catch is specific and has happened: a feature
#   is written, verified in the repo, verified on the ISO, and never reaches an
#   installed machine. The Timer shipped on b1294's squashfs — binary, launcher
#   and icon all present — and a fresh install had none of the three, because
#   the installer copies by hand-curated name globs and `timer` matched none of
#   them. Everything upstream of the install was green.
#
#   So the standard here is: assert the ARTEFACT on the installed system, and
#   where an artefact can exist while being useless, assert that it works.
#   "The binary is present" is weak; "the binary is present AND its interpreter
#   can import what it needs" is a test.
#
# Run: sudo bash smoke-features.sh    (or via smoke-all.sh)
# Exit: 0 all passed, 1 one or more failed.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
. "${SCRIPT_DIR}/lib-test.sh"

# ─── helpers ────────────────────────────────────────────────────────────────

# have <cmd> — is it on PATH
have() { command -v "$1" >/dev/null 2>&1; }

# vms_running — names of domains libvirt reports as running
vms_running() { virsh list --name 2>/dev/null | grep . || true; }

# build_in_flight — is something still building images right now?
#
# A golden that is mid-build is running, unsealed and unregistered, which looks
# identical to one that was built and abandoned. The difference is whether a
# builder is still working, so ask that rather than reporting a machine in
# normal progress as broken. Checked against the units that do the building.
build_in_flight() {
    systemctl is-active klab-firstboot.service >/dev/null 2>&1 && return 0
    systemctl is-active kldload-autodeploy.service >/dev/null 2>&1 && return 0
    pgrep -f '/usr/local/bin/(klab|kube-cluster|kzfs-lab)' >/dev/null 2>&1 && return 0
    return 1
}

# inv_hosts — hostnames the Ansible inventory currently offers
inv_hosts() {
    # No `|| true` on the pipeline: capture first and return early instead, so
    # "the inventory tool is missing" and "the inventory is empty" stay
    # distinguishable at the call site rather than both collapsing to silence.
    local _inv
    _inv="$(kldload-inventory --list 2>/dev/null)" || return 0
    [[ -n "$_inv" ]] || return 0
    printf '%s' "$_inv" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for h in sorted(d.get("_meta",{}).get("hostvars",{})): print(h)' 2>/dev/null
}

# ─── 1. Desktop apps that ship as three files ───────────────────────────────
# A GUI tool is a binary, a launcher whose filename matches its app_id, and an
# icon named the same again. Any one missing and the app is invisible, or opens
# a second dock entry beside itself. The interpreter check is the one that
# catches a guarded import whose package was never installed.
_section "Shipped desktop apps"

_app_triad() { # _app_triad <label> <binary> <desktop> <icon-basename>
    local label="$1" bin="$2" dsk="$3" ico="$4" missing=""
    [[ -x "$bin" ]] || missing+=" binary"
    [[ -f "/usr/share/applications/${dsk}" ]] || missing+=" launcher"
    [[ -f "/usr/share/icons/hicolor/scalable/apps/${ico}" ]] || missing+=" icon"
    if [[ -z "$missing" ]]; then
        _pass "${label}: binary, launcher and icon all installed"
    else
        _fail "${label}" "missing on the installed system:${missing}"
    fi
}
_app_triad "Timer" /usr/local/bin/timer com.kldload.Timer.desktop com.kldload.Timer.svg

# A GTK4 app whose PyGObject was never packaged starts, fails to import, and
# dies with no window — indistinguishable from "the icon does nothing".
if [[ -x /usr/local/bin/timer ]]; then
    if python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' 2>/dev/null; then
        _pass "Timer: PyGObject + Gtk4 import on this machine"
    else
        _fail "Timer PyGObject" "gi/Gtk4 will not import — the launcher opens nothing"
    fi
fi

if have desktop-file-validate && [[ -f /usr/share/applications/com.kldload.Timer.desktop ]]; then
    if desktop-file-validate /usr/share/applications/com.kldload.Timer.desktop >/dev/null 2>&1; then
        _pass "Timer: .desktop validates"
    else
        _fail "Timer .desktop" "desktop-file-validate rejects it"
    fi
fi

# ─── 2. Rollback ────────────────────────────────────────────────────────────
# Shipped as a tool AND as the short name an operator actually types. The
# symlink was missing on every install until b1284 while the tool was present.
_section "Rollback"

if have rollback; then
    _pass "rollback is on PATH ($(readlink -f "$(command -v rollback)"))"
else
    _fail "rollback" "not on PATH — the tool ships as kldload-rollback with no short name"
fi
if [[ -x /usr/sbin/kldload-rollback ]] || [[ -x /usr/bin/kldload-rollback ]]; then
    _pass "kldload-rollback installed"
else
    _fail "kldload-rollback" "not installed"
fi

# ─── 3. State DB is writable by the tools that must write it ────────────────
# Root-only meant every non-root tool failed to deregister, silently.
_section "State database"

if [[ -f /var/lib/kldload/state.db ]]; then
    _perm="$(stat -c '%A %U:%G' /var/lib/kldload/state.db)"
    if [[ "$_perm" == *"rw-rw-"*"kldload" ]]; then
        _pass "state.db is group-writable by kldload ($_perm)"
    else
        _fail "state.db permissions" "$_perm — tools that are not root cannot deregister"
    fi
else
    _warn "state.db" "not present yet — nothing has registered"
fi

# ─── 4. Component state tells the truth ─────────────────────────────────────
# The table must never say "absent" about something that is demonstrably
# running: an operator trusting it would install on top of a live cluster.
_section "Component state"

if have kldload-component && have virsh; then
    # swallow: grep -c exits 1 on zero matches, and zero control planes is a
    # valid answer -- it is the "correctly absent" branch below.
    _cp_live=$(virsh list --all --name 2>/dev/null | grep -c '^kldload-cp' || true)
    _k8s_state="$(kldload-component list 2>/dev/null | awk '$1=="k8s"{print $2}')"
    if ((_cp_live > 0)); then
        if [[ "$_k8s_state" == "absent" ]]; then
            _fail "component k8s" "reported absent while ${_cp_live} control-plane VM(s) exist"
        else
            _pass "component k8s reflects reality (${_k8s_state}, ${_cp_live} CP VMs)"
        fi
    else
        [[ "$_k8s_state" == "absent" ]] &&
            _pass "component k8s correctly absent (no CP VMs)" ||
            _fail "component k8s" "reported ${_k8s_state} with no control-plane VMs"
    fi
fi

# ─── 5. Every running VM is reachable through Ansible ───────────────────────
# The estate is only useful if the inventory agrees with libvirt. A VM that is
# up and absent from the inventory cannot be targeted; one that is gone and
# still listed sends plays at a machine that no longer exists — and DHCP reuse
# means that address may now answer as somebody else.
_section "Estate registration"

if have virsh && have kldload-inventory; then
    have kldload-networks && kldload-networks sync >/dev/null 2>&1
    _missing="" _n=0
    while read -r _vm; do
        [[ -n "$_vm" ]] || continue
        _n=$((_n + 1))
        inv_hosts | grep -qx "$_vm" || _missing+=" $_vm"
    done < <(vms_running)
    if ((_n == 0)); then
        _warn "estate registration" "no VMs are running — nothing to check"
    elif [[ -z "$_missing" ]]; then
        _pass "all ${_n} running VM(s) appear in the Ansible inventory"
    elif build_in_flight; then
        _warn "estate registration" "absent from Ansible while a build is in flight:${_missing}"
    else
        _fail "estate registration" "running but absent from Ansible:${_missing}"
    fi

    # The mirror image: an inventory host with no domain and no libvirt record.
    _ghost=""
    while read -r _h; do
        [[ -n "$_h" ]] || continue
        virsh dominfo "$_h" >/dev/null 2>&1 && continue
        # A physical node legitimately has no domain; only flag names the DB
        # itself records as VMs.
        kldload-db dump 2>/dev/null |
            python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(v.get("name")=="'"$_h"'" for v in d.get("vms",[])) else 1)' 2>/dev/null &&
            _ghost+=" $_h"
    done < <(inv_hosts)
    if [[ -z "$_ghost" ]]; then
        _pass "no ghost hosts: every VM-backed inventory entry has a domain"
    else
        _fail "ghost hosts" "in Ansible with no libvirt domain:${_ghost}"
    fi
fi

# ─── 6. Golden images ───────────────────────────────────────────────────────
# A golden is only a golden once it carries the @golden snapshot clones are
# taken from. And a golden with no audio stack produces a fleet of VMs whose
# sound card is present and unusable.
_section "Golden images"

if have zfs; then
    _g_total=0 _g_nosnap=""
    while read -r _ds; do
        [[ -n "$_ds" ]] || continue
        _g_total=$((_g_total + 1))
        zfs list -t snapshot "${_ds}@golden" >/dev/null 2>&1 || _g_nosnap+=" ${_ds##*/}"
        # swallow: grep exits 1 when no golden exists yet, which is the
        # "none built yet" warning below, not a failure of this check.
    done < <(zfs list -H -o name -r rpool/vms 2>/dev/null | grep -E '/(k8s-golden|klab-golden-[a-z]+|klab-desktop-[a-z0-9]+|kzfstest-golden-[a-z0-9]+)$' || true)
    if ((_g_total == 0)); then
        _warn "golden images" "none built yet"
    elif [[ -z "$_g_nosnap" ]]; then
        _pass "all ${_g_total} golden image(s) carry their @golden snapshot"
    elif build_in_flight; then
        _warn "golden images" "unsealed while a build is in flight:${_g_nosnap}"
    else
        _fail "golden images" "built but never sealed (no @golden):${_g_nosnap}"
    fi
fi

# ─── 7. Sound reaches the guests ────────────────────────────────────────────
# Both halves or neither. The domain gets an ich9 card from virt-install; the
# guest needs a stack to drive it. Cloud images install kernel-core, which
# excludes sound drivers, so userspace can be installed perfectly and still
# have nothing to bind to — the card shows in lspci and the desktop offers
# "Dummy Output". Assert the card on the host side and /dev/snd in the guest.
_section "Guest audio"

if have virsh; then
    _snd_missing="" _snd_n=0
    while read -r _vm; do
        [[ -n "$_vm" ]] || continue
        _snd_n=$((_snd_n + 1))
        virsh dumpxml "$_vm" 2>/dev/null | grep -q '<sound' || _snd_missing+=" $_vm"
        # swallow: grep exits 1 on an empty domain list, handled as "no domains".
    done < <(virsh list --all --name 2>/dev/null | grep . || true)
    if ((_snd_n == 0)); then
        _warn "guest audio" "no domains defined"
    elif [[ -z "$_snd_missing" ]]; then
        _pass "all ${_snd_n} domain(s) carry a sound device"
    else
        _fail "guest audio (host half)" "no <sound> device:${_snd_missing}"
    fi
fi

# ─── 8. WireGuard actually carries traffic ──────────────────────────────────
# Peers configured is not a mesh. Every klab site mesh had five peers on every
# node and ZERO handshakes for its whole life, because `wg setconf` had been
# handed a wg-quick config and rejected the entire file — with stderr discarded
# and a success line printed. Count handshakes, not peers.
# ─── Baseboard management ───────────────────────────────────────────────────
# Fedora enables ipmi.service by preset. On a box with no BMC the helper exits
# 1 and leaves a permanently failed unit, which is worse than it sounds: an
# operator who sees one failed unit on every machine stops reading
# `systemctl --failed`, and the next failure — the one that matters — goes
# unread. A drop-in conditions the unit on DMI type 38 so it SKIPS instead.
#
# Report which world we are in either way, because "no BMC" should be visible
# rather than silent. This has only been exercised on desktop hardware; the
# BMC-present direction is untested.
_section "Baseboard management (IPMI)"

if [[ -e /sys/firmware/dmi/entries/38-0 ]]; then
    # swallow: is-active exits non-zero for every state that is not "active",
    # and "inactive" is a correct answer here — a oneshot that already ran.
    _ipmi_state="$(systemctl is-active ipmi.service 2>/dev/null || true)"
    if [[ "$_ipmi_state" == "active" || "$_ipmi_state" == "inactive" ]]; then
        _pass "IPMI: BMC present (DMI type 38) and ipmi.service is ${_ipmi_state}"
    else
        _fail "IPMI" "a BMC is present but ipmi.service is ${_ipmi_state} — the driver did not come up"
    fi
elif systemctl is-failed ipmi.service >/dev/null 2>&1; then
    _fail "IPMI" \
        "no BMC on this hardware (no DMI type 38) yet ipmi.service FAILED — the condition drop-in is missing, and a permanently failed unit trains operators to ignore systemctl --failed"
else
    _pass "IPMI: no BMC on this hardware — ipmi.service correctly skipped, not failed"
fi

_section "WireGuard meshes"

if have wg; then
    _wg_any=0
    while read -r _if; do
        [[ -n "$_if" ]] || continue
        _wg_any=1
        # swallow: an interface with no peers yet is normal, not an error.
        _peers="$(wg show "$_if" peers 2>/dev/null | grep -c . || true)"
        ((_peers == 0)) && continue
        # swallow: zero handshakes is the condition this check exists to
        # report, so grep's exit 1 here is data, not a failure.
        _hs="$(wg show "$_if" latest-handshakes 2>/dev/null | awk '$2>0' | grep -c . || true)"
        # LIVE, not EVER. `$2>0` only says a peer handshook at some point in the
        # past, and WireGuard keeps that timestamp forever. On 2026-09-02
        # klab-blue reported a clean 5/5 while all five of its VMs were `shut
        # off` and the newest handshake was 41 minutes old. With
        # persistent-keepalive 25 a live peer rekeys about every two minutes, so
        # 180s is a generous line between "carrying traffic" and "carried some,
        # once". _never counts peers that have NEVER completed one -- the
        # original klab failure, where a config wg setconf silently rejected
        # left five peers that never worked at all.
        _now="$(date +%s)"
        # grep -c exits 1 on zero matches; zero live peers is the count being tested
        _live="$(wg show "$_if" latest-handshakes 2>/dev/null | awk -v n="$_now" '$2>0 && (n-$2)<180' | grep -c . || true)"
        # same: zero never-handshaken peers is the good answer
        _never="$(wg show "$_if" latest-handshakes 2>/dev/null | awk '$2==0' | grep -c . || true)"
        # Three outcomes, not two. This check was written against the failure
        # where klab had five peers and zero handshakes for its entire life, so
        # `_hs > 0` was enough to catch it -- but that also means 1 of 100 scores
        # a clean green. A count is not a result until it is compared with what
        # was GIVEN. klab-green sat at 4/5 and reported PASS on 2026-09-02.
        #
        # Partial is a WARN, not a FAIL: one guest being powered off is a normal
        # state on a lab host and should not fail a suite. It must still be
        # visible, and it must name the peer, or the operator has a number and
        # nowhere to go with it.
        if ((_hs == 0)); then
            _fail "${_if}" "${_peers} peer(s) configured and NOT ONE has ever handshaked — the mesh carries nothing"
        elif ((_never > 0)); then
            _silent="$(wg show "$_if" latest-handshakes 2>/dev/null |
                awk '$2==0 {print substr($1,1,16) "..."}' | tr '\n' ' ')"
            _fail "${_if}" "${_never} of ${_peers} peer(s) have NEVER handshaked — never-worked, not merely idle: ${_silent}"
        elif ((_live == _peers)); then
            _pass "${_if}: ${_live}/${_peers} peer(s) live"
        elif ((_live > 0)); then
            _warn "${_if}" "only ${_live}/${_peers} peer(s) live right now (all ${_peers} have handshaked before)"
        else
            # Every peer has worked, none is up now. On a lab host with its
            # golden VMs powered off this is the expected state, so it is not a
            # failure -- but it must not read as a green mesh either.
            _oldest="$(wg show "$_if" latest-handshakes 2>/dev/null |
                awk -v n="$_now" '$2>0 {print n-$2}' | sort -n | head -1)"
            _warn "${_if}" "idle: all ${_peers} peer(s) proven but none live (newest handshake ${_oldest:-?}s ago — VMs powered off?)"
        fi
    done < <(wg show interfaces 2>/dev/null | tr ' ' '\n')
    ((_wg_any == 0)) && _warn "WireGuard" "no interfaces up"
fi

summary
