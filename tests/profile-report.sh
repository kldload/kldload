#!/usr/bin/env bash
# =============================================================================
# profile-report.sh — everything true about THIS installed machine, as markdown
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Identity      — distro, profile, ISO build commit, kernel, ZFS, uptime.
#   2. Asked vs got  — every feature the answers file requested, against what is
#                      actually on the disk. This is the section that catches a
#                      silent install: requested and absent is a FAIL, not a note.
#   3. Boot posture  — Secure Boot, encryption, module signer, bootfs.
#   4. Services      — failed units, degraded state, and the units kldload owns.
#   5. Estate        — goldens, VMs, inventory, mesh, Prometheus targets.
#   6. Test suites   — the shipped smoke suite, tallied.
#   7. Doctor        — kldload-doctor, tallied by severity.
#   8. Logs          — first-boot warnings and journal errors, counted and sampled.
#   9. Verdict       — one line, and the reason.
#
# WHY IT EXISTS: a profile install has been "verified" by someone reading a
# terminal and seeing no red. That has passed a desktop with no desktop, a klab
# with no goldens, and a cluster with no exporters behind its Metrics menu.
# A run that produces the same manifest every time can be diffed, filed, and
# compared across distros — which is the only way seven profiles times three
# distros stays honest (operator, 2026-09-19).
#
# OUTPUT: markdown on stdout. Diagnostics on stderr. Nothing else on stdout, so
# the driver can redirect it straight into a results file.
# EXIT: 0 the report was produced (its VERDICT says whether the machine is
#       good) · 2 this is not a kldload machine.
# =============================================================================
set -Eeuo pipefail
trap 'echo "profile-report.sh: line $LINENO: $BASH_COMMAND" >&2' ERR
# Every probe below is wrapped (S, cap, _count, or an explicit fallback), so
# -e reports a BUG in this script rather than a machine that answered "no".

export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# --help answers before the re-exec and before any side effect (tool rule 9).
case "${1:-}" in
-h | --help | help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

# Most of what this reads is root-only: the manifest is 0640 root:root, the
# journal is restricted, and kldload-test wants root. Re-exec rather than
# degrade -- the first run of this script asked `[[ -r ]]` as admin, got
# "not a kldload install" on a perfectly good machine, and reported nothing.
# A wrong probe returns empty, and empty reads as "not there" (2026-09-19).
if ((EUID != 0)); then
    exec sudo -n bash "$0" "$@"
fi

S() { "$@" 2>/dev/null || return 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# _count <extended regex> — matching lines of stdin, 0 when none.
#
# grep exits 1 on no matches and zero is an ANSWER here ("no failures", "no
# errors in the journal"), not a failure. One explained swallow instead of six.
_count() { grep -cE "$1" || true; }

# iso_build — "<version> <commit> lock <digest>" from the build's own stamp.
#
# The build writes /etc/kldload/VERSION into the rootfs (build-iso.sh,
# "Build provenance") and the installer carries it to the target. This used to
# grep install-manifest.env for KLDLOAD_ISO_COMMIT / BUILD_COMMIT / ISO_VERSION,
# keys nothing has ever written: every report in every sweep up to 2026-09-22
# said "?", and "?" read as "old image" rather than "wrong probe".
iso_build() {
    local v="${KLDLOAD_VERSION_FILE:-/etc/kldload/VERSION}" out
    [[ -r "$v" ]] || {
        echo "? (no $v)"
        return 0
    }
    out="$(awk -F'[[:space:]]*=[[:space:]]*' '
        $1 == "kldload_version" { ver = $2 }
        $1 == "commit" { c = $2 }
        $1 == "k8s_stack_lock" { l = $2 }
        END { printf "%s %s lock %s", (ver ? ver : "?"), (c ? c : "?"), (l ? l : "?") }
    ' "$v" </dev/null)"
    printf '%s\n' "$out"
}

# KLDLOAD_MANIFEST overrides the path, so this script can be exercised against
# a fixture instead of only on a freshly installed machine.
MANIFEST="${KLDLOAD_MANIFEST:-/etc/kldload/install-manifest.env}"
[[ -r "$MANIFEST" ]] || {
    echo "profile-report.sh: ${MANIFEST} is not readable as root — not a kldload install?" >&2
    exit 2
}

# mval <KEY> — a value from the install manifest, unquoted.
mval() { S grep -hE "^${1}=" "$MANIFEST" | tail -1 | cut -d= -f2- | tr -d '"' || true; }

DISTRO="$(mval KLDLOAD_DISTRO)"
PROFILE="$(mval KLDLOAD_PROFILE)"
FAILS=0
WARNS=0
note_fail() {
    FAILS=$((FAILS + 1))
    echo "- **FAIL** $*"
}
note_warn() {
    WARNS=$((WARNS + 1))
    echo "- WARN $*"
}

echo "# ${DISTRO:-unknown}/${PROFILE:-unknown} — $(hostname) — $(date -Is)"
echo

# ─── 1. Identity ────────────────────────────────────────────────────────────
echo "## Identity"
echo
echo '```'
printf '%-18s %s\n' \
    "distro" "$(. /etc/os-release && echo "${PRETTY_NAME:-?}")" \
    "profile" "${PROFILE:-?}" \
    "kernel" "$(uname -r)" \
    "zfs module" "$(S modinfo -F version zfs || echo '?')" \
    "zfs userland" "$(zfs --version 2>/dev/null | head -1 || echo '?')" \
    "ISO build" "$(iso_build)" \
    "installed at" "$(S stat -c %y "$MANIFEST" | cut -d. -f1 || echo '?')" \
    "uptime" "$(uptime -p)"
echo '```'
echo

# ─── 2. Asked vs got ────────────────────────────────────────────────────────
#
# Each row is a feature the answers file can request, the probe that proves it
# landed, and the artefact the probe looks at. The probe is deliberately the
# ARTEFACT (a binary, a unit, a dataset) rather than the package database:
# package databases record intent, files record fact.
echo "## Asked for, versus what is on the disk"
echo
echo '| feature | asked | present | probe |'
echo '|---|---|---|---|'
check_feature() { # check_feature <label> <manifest key> <probe cmd...>
    local label="$1" key="$2" asked got probe
    shift 2
    asked="$(mval "$key")"
    [[ -z "$asked" ]] && asked="unset"
    probe="$*"
    if "$@" >/dev/null 2>&1; then got="yes"; else got="no"; fi
    printf '| %s | %s | %s | `%s` |\n' "$label" "$asked" "$got" "${probe:0:52}"
    # Only a REQUESTED feature that is absent is a defect. An unrequested one
    # that is present is normal (profiles imply features).
    if [[ "$asked" == 1 && "$got" == no ]]; then
        echo "$label" >>/tmp/.pr_missing.$$
    fi
}
: >/tmp/.pr_missing.$$
check_feature "KVM / libvirt" KLDLOAD_ENABLE_KVM command -v virsh
check_feature "Kubernetes" KLDLOAD_ENABLE_K8S command -v kubectl
# NOT `test -d /etc/kubernetes` on the host: kldload builds the cluster INSIDE
# VMs, so the host never has that directory and the probe reported "absent" on
# a machine running six healthy cluster nodes (4-k8s, 2026-09-20). Ask the
# cluster: kubeconfig on the host, and the API answering.
check_feature "K8s bootstrap" KLDLOAD_K8S_BOOTSTRAP \
    bash -c 'test -r /root/.kube/config && timeout 20 kubectl --kubeconfig /root/.kube/config get nodes >/dev/null 2>&1'
check_feature "AI (ollama)" KLDLOAD_ENABLE_AI command -v ollama
check_feature "WireGuard" KLDLOAD_WIREGUARD command -v wg
check_feature "eBPF tools" KLDLOAD_ENABLE_EBPF command -v bpftrace
check_feature "Metrics (devops)" KLDLOAD_ENABLE_DEVOPS test -d /etc/prometheus
check_feature "Web console" KLDLOAD_ENABLE_WEBUI test -x /usr/local/bin/kldload-webui
check_feature "ZFS dev lab" KLDLOAD_KLAB_ZFS_DEV command -v klab
# NOT `test -d /rpool/vms`: that dataset is created with mountpoint=none, so
# the directory never exists and the probe reported "absent" on a machine that
# had five sealed goldens (deb-3-kvm, 2026-09-20). Ask ZFS, and ask about the
# thing that matters — a golden is only built once it carries its @golden snap.
check_feature "Build images" KLDLOAD_BUILD_IMAGES \
    bash -c 'zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null | grep -q "@golden"'
echo
if [[ -s /tmp/.pr_missing.$$ ]]; then
    while read -r _m; do note_fail "requested but ABSENT: ${_m}"; done </tmp/.pr_missing.$$
    echo
fi
rm -f /tmp/.pr_missing.$$

# Every golden the plan asked for, not "some golden exists". The row above
# passes on ONE @golden snapshot; ci/kldload-netboot-run's "requested goldens
# sealed" check exists because 3-kvm (fiend, 2026-09-14) had the fedora lean
# golden powered off mid-build and never sealed while the nine others passed
# it. Same rule here: expected = each golden phase autodeploy declared under
# /var/lib/kldload/phases, times klab's own DISTROS list.
if [[ "$(mval KLDLOAD_BUILD_IMAGES)" == 1 ]]; then
    _sealed="$(S zfs list -H -t snapshot -o name -r rpool/vms | grep -E '@golden$' | sed 's/@golden$//; s#.*/##' | sort | tr '\n' ' ' || true)"
    _ds="$(sed -n 's/^DISTROS=(\(.*\))$/\1/p' /usr/local/bin/klab 2>/dev/null | head -n 1)"
    _gmiss="" _gwant=0
    for _ph in klab-goldens:golden klab-desktop-goldens:desktop klab-ztest-goldens:ztest; do
        compgen -G "/var/lib/kldload/phases/[0-9][0-9]-${_ph%%:*}" >/dev/null || continue
        for _d in $_ds; do
            _gwant=$((_gwant + 1))
            grep -qw -- "klab-${_ph##*:}-${_d}" <<<"$_sealed" || _gmiss+=" klab-${_ph##*:}-${_d}"
        done
    done
    if [[ -z "$_ds" ]]; then
        note_fail "requested goldens: could not read DISTROS from /usr/local/bin/klab — the requested set is unknown"
    elif ((_gwant == 0)); then
        note_fail "requested goldens: BUILD_IMAGES=1 but no golden phase is declared under /var/lib/kldload/phases — first boot never planned them"
    elif [[ -n "$_gmiss" ]]; then
        note_fail "requested goldens: ${_gwant} planned, not sealed:${_gmiss}"
    else
        echo "- all ${_gwant} requested golden(s) sealed: ${_sealed}"
    fi
    echo
fi

# ─── 3. Boot posture ────────────────────────────────────────────────────────
echo "## Boot posture"
echo
_sb="$(mokutil --sb-state 2>/dev/null | head -1 || echo 'unknown')"
_enc="$(S zfs get -H -o value encryption rpool || echo '?')"
_signer="$(S modinfo -F signer zfs | head -1 || echo 'unsigned')"
echo '```'
printf '%-18s %s\n' \
    "secure boot" "${_sb}" \
    "asked for SB" "$(mval KLDLOAD_ENABLE_SECURE_BOOT)" \
    "rpool encryption" "${_enc}" \
    "asked for enc" "$(mval KLDLOAD_ZFS_ENCRYPT)" \
    "zfs signed by" "${_signer:-unsigned}" \
    "bootfs" "$(S zpool get -H -o value bootfs rpool || echo '?')" \
    "root dataset" "$(findmnt -no SOURCE / 2>/dev/null)"
echo '```'
echo
# The two that matter: asked for and not got.
[[ "$(mval KLDLOAD_ZFS_ENCRYPT)" == 1 && "$_enc" == off ]] &&
    note_fail "encryption was requested and rpool is NOT encrypted"
# Requested and not got is the section's definition of a defect, and Secure
# Boot is the one that decides whether the signed ZFS module is enforced at
# all; a warning here let an edition with SB off pass as "with warnings".
[[ "$(mval KLDLOAD_ENABLE_SECURE_BOOT)" == 1 && "$_sb" != *enabled* ]] &&
    note_fail "Secure Boot was requested and firmware reports: ${_sb}"
[[ "$_signer" == "" || "$_signer" == unsigned ]] &&
    note_warn "the ZFS module is not signed — Secure Boot cannot be turned on later"
echo

# ─── 4. Services ────────────────────────────────────────────────────────────
echo "## Services"
echo
# `is-system-running` exits non-zero for "degraded", which is precisely the
# answer worth printing here.
_state="$(systemctl is-system-running 2>/dev/null || true)"
_failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo '```'
printf '%-18s %s\n' "systemd" "${_state}" "failed units" "${_failed:-none}"
echo '```'
echo
if [[ -n "${_failed// /}" ]]; then
    for _u in $_failed; do
        # kldload-smoke-firstboot runs the smoke suite at first boot, so it
        # fails exactly when the suite found failures. Counting it as its own
        # defect double-counts the same news and sends the reader hunting for a
        # second problem that does not exist (fedora/storage, 2026-09-20).
        if [[ "$_u" == kldload-smoke-firstboot.service ]]; then
            note_warn "kldload-smoke-firstboot failed — it runs the smoke suite, so this reflects the suite failures below, not a separate fault"
            continue
        fi
        note_fail "failed unit: ${_u} — $(S systemctl show -p Result --value "$_u" || echo '?')"
    done
    echo
fi

# ─── 5. Estate ──────────────────────────────────────────────────────────────
# `grep -c X || echo 0` prints TWO lines when there are no matches — grep's own
# "0" and then the echo — which shifted every printf argument after it and put
# stray zeroes through the middle of this table (3-kvm, 2026-09-20). It is the
# same shape the engineering rules already record. _count says it once.
echo "## Estate"
echo
echo '```'
if have virsh; then
    printf '%-18s %s\n' \
        "VMs defined" "$(S virsh list --all --name | _count .)" \
        "VMs running" "$(S virsh list --name | _count .)" \
        "goldens sealed" "$(S zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null | _count '@golden')" \
        "inventory hosts" "$(kldload-inventory --list 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("_meta",{}).get("hostvars",{})))
except Exception: print("?")' || echo '?')" \
        "prom targets" "$(S bash -c 'cat /etc/prometheus/targets/*.json 2>/dev/null' | grep -o '"vm"' | _count .)" \
        "wg peers" "$(S wg show all peers 2>/dev/null | _count .)"
else
    echo "no hypervisor on this machine (virsh absent)"
fi
echo '```'
echo

# ─── 5b. Workloads answer ───────────────────────────────────────────────────
#
# The cluster checks prove nodes are Ready and a pod schedules; nothing sent a
# request to what the cluster actually serves. A workload deployed and not
# answering passed every check. (Operator, 2026-09-23: "are you getting a 200
# when sending a test to the running workload?" -- we were not asking.)
#
# Two paths, because they fail differently:
#   * every LoadBalancer service, from THIS host, through its MetalLB address
#     -- the path an operator uses; exercises MetalLB, L2 and the backends
#   * every other ClusterIP service outside the system namespaces, through the
#     API server's service proxy -- a real HTTP request with no pod created
#     and nothing left behind on the cluster
# Any HTTP status is an answer; 000 (nothing answered) and 5xx are failures.
# Services whose first port is not HTTP (redis, dex's gRPC) are skipped by name
# of the port where the chart says so, otherwise probed and reported as such.
if have kubectl && [[ -r /root/.kube/config ]]; then
    export KUBECONFIG=/root/.kube/config
    echo "## Workloads"
    echo
    echo '```'
    # ns/name=ip:port for LoadBalancers with an address
    mapfile -t _lbs < <(S timeout 20 kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}={.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}{"\n"}{end}')
    _wl_n=0
    _wl_bad=()
    _wl_np=()
    # _netpol_for <namespace> <service> — the NetworkPolicy (name) that selects
    # the service's pods, on stdout; empty when none does. A policy applies
    # when every one of its podSelector matchLabels is in the service selector;
    # an empty podSelector selects every pod in the namespace.
    _netpol_for() {
        S timeout 15 kubectl get networkpolicy,service -n "$1" -o json | python3 -c '
import json, sys
svc = sys.argv[1]
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    sys.exit(0)
sel = next((i.get("spec", {}).get("selector") or {} for i in items
            if i.get("kind") == "Service" and i["metadata"]["name"] == svc), None)
if not sel:
    sys.exit(0)
for i in items:
    if i.get("kind") != "NetworkPolicy":
        continue
    ml = (i.get("spec", {}).get("podSelector") or {}).get("matchLabels") or {}
    if all(sel.get(k) == v for k, v in ml.items()):
        print(i["metadata"]["name"])
        break' "$2" || true # no kubectl answer means no policy found; the service is then judged on its own
    }
    for _row in "${_lbs[@]}"; do
        [[ -n "$_row" ]] || continue
        _svc="${_row%%=*}"
        _hp="${_row#*=}"
        _wl_n=$((_wl_n + 1))
        if [[ "$_hp" == :* ]]; then
            printf '%-40s %s\n' "$_svc" "LoadBalancer with NO address (MetalLB did not assign one)"
            _wl_bad+=("${_svc}(no-address)")
            continue
        fi
        _code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "http://${_hp}/" 2>/dev/null || true)"
        [[ "$_code" == 000 ]] &&
            _code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${_hp}/" 2>/dev/null || true)"
        printf '%-40s %-24s -> %s\n' "$_svc" "LB ${_hp}" "${_code:-000}"
        [[ "${_code:-000}" == 000 || "${_code:-000}" == 5* ]] && _wl_bad+=("${_svc}(${_code:-000})")
    done
    # ns/name:port for app ClusterIP services (not LoadBalancer, not headless)
    mapfile -t _cips < <(S timeout 20 kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="ClusterIP")]}{.metadata.namespace}/{.metadata.name}:{.spec.ports[0].port}:{.spec.clusterIP}:{.spec.ports[0].name}{"\n"}{end}' |
        grep -vE '^(kube-system|kube-public|metallb-system|local-path-storage|cilium-secrets|openebs)/' |
        grep -vE '^default/kubernetes:' | grep -vE ':None:')
    for _row in "${_cips[@]}"; do
        [[ -n "$_row" ]] || continue
        IFS=: read -r _svc _port _cip _pname <<<"$_row"
        # Not HTTP by declaration: skip rather than report a protocol mismatch.
        case "$_pname" in
        *grpc* | *redis* | tcp-* | metrics*) continue ;;
        esac
        _ns="${_svc%%/*}"
        _name="${_svc#*/}"
        _wl_n=$((_wl_n + 1))
        # https: as well as plain: a TLS backend reached over http through the
        # proxy just hangs until the timeout. argocd-dex-server serves TLS on
        # 5556 and was reported "NO ANSWER: no error text" on 4-k8s, build 60
        # (2026-09-23) while it was up. Either scheme answering is an answer.
        if S timeout 15 kubectl get --raw "/api/v1/namespaces/${_ns}/services/${_name}:${_port}/proxy/" >/dev/null; then
            printf '%-40s %-24s -> %s\n' "$_svc" "proxy :${_port}" "answered"
        elif S timeout 15 kubectl get --raw "/api/v1/namespaces/${_ns}/services/https:${_name}:${_port}/proxy/" >/dev/null; then
            printf '%-40s %-24s -> %s\n' "$_svc" "proxy :${_port}" "answered (https)"
        else
            _err="$(timeout 15 kubectl get --raw "/api/v1/namespaces/${_ns}/services/${_name}:${_port}/proxy/" 2>&1 >/dev/null | head -1 | cut -c1-80 || true)"
            # A 4xx through the proxy is still the backend answering.
            if [[ "$_err" =~ \((NotFound|Forbidden|Unauthorized|BadRequest|MethodNotAllowed)\) ]]; then
                printf '%-40s %-24s -> %s\n' "$_svc" "proxy :${_port}" "answered (${BASH_REMATCH[1]})"
            else
                # A NetworkPolicy that selects the service's pods can refuse the
                # API server by design: Argo CD admits only argocd-server to
                # dex, and 4-k8s on build 62 reported dex "NO ANSWER" for a
                # deployment doing exactly what it was told. Name the policy
                # and warn; fail only what no policy explains.
                _np="$(_netpol_for "$_ns" "$_name")"
                if [[ -n "$_np" ]]; then
                    printf '%-40s %-24s -> %s\n' "$_svc" "proxy :${_port}" "no answer from the API server — NetworkPolicy ${_np} admits only its own peers"
                    _wl_np+=("${_svc}")
                else
                    printf '%-40s %-24s -> %s\n' "$_svc" "proxy :${_port}" "NO ANSWER: ${_err:-no error text}"
                    _wl_bad+=("${_svc}")
                fi
            fi
        fi
    done
    echo "probed ${_wl_n} service(s), ${#_wl_bad[@]} not answering, ${#_wl_np[@]} closed to the API server by a NetworkPolicy"
    echo '```'
    echo
    ((${#_wl_np[@]} > 0)) && note_warn "workloads closed to the API server by a NetworkPolicy (by design, not probed further): ${_wl_np[*]}"
    if ((_wl_n == 0)); then
        note_warn "workloads: the cluster serves nothing to probe (no LoadBalancer or app ClusterIP service)"
    elif ((${#_wl_bad[@]} > 0)); then
        note_fail "workloads not answering: ${_wl_bad[*]}"
    fi
fi

# ─── 6. Shipped test suite ──────────────────────────────────────────────────
#
# kldload-test IS smoke-all. Driving the shipped verb rather than a copy is the
# rule: a harness that re-implements what it tests has reproduced a fixed bug
# and blamed a healthy machine for it before.
echo "## Smoke suite"
echo
if have kldload-test; then
    # The suite exits 1 when the machine has failures, and that output is the
    # thing being tallied — so the status is discarded and the counts below
    # decide. (Since 2026-09-19 it also exits 1 when it ran nothing, which the
    # zero-pass check further down catches.)
    #
    # But a KILLED suite is not a result. Fedora AI on fiend (2026-09-23) hung
    # on an unkillable nvidia-smi, the timeout below ended it after 1800s, and
    # the 50 passes it had reached so far were reported as a PASS edition --
    # against 196 on every earlier run. So: the timeout's own status, and the
    # suite's last line ("Report saved:"), which only a finished run prints.
    _smoke="$(timeout 1800 kldload-test 2>&1)" && _src=0 || _src=$?
    _sp="$(_count '✓ PASS' <<<"$_smoke")"
    _sf="$(_count '✗ FAIL' <<<"$_smoke")"
    _sw="$(_count '⚠ WARN' <<<"$_smoke")"
    echo '```'
    printf 'PASS %s   FAIL %s   WARN %s\n' "$_sp" "$_sf" "$_sw"
    echo '```'
    if ((_sf > 0)); then
        echo
        echo "Failures:"
        echo '```'
        grep -E '✗ FAIL' <<<"$_smoke" | sed 's/\x1b\[[0-9;]*m//g' | head -25
        echo '```'
        note_fail "smoke suite: ${_sf} failure(s)"
    fi
    # A suite that ran nothing is not a pass.
    ((_sp == 0)) && note_fail "smoke suite produced NO passes — it did not really run"
    if ((_src == 124)); then
        note_fail "smoke suite TIMED OUT after 1800s and was killed — the counts above are partial; last line: $(sed 's/\x1b\[[0-9;]*m//g' <<<"$_smoke" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-120)"
    elif ! grep -q 'Report saved:' <<<"$_smoke"; then
        note_fail "smoke suite did not finish (no 'Report saved:' line, exit ${_src}) — the counts above are partial"
    fi
elif [[ "$PROFILE" == core ]]; then
    # core ships no kldload tools at all (/usr/local/bin is empty by design;
    # estate-sweep's converge comment records it), so no suite is the expected
    # state there and nothing was skipped.
    note_warn "core ships no smoke suite by design — kldload-test is not installed, nothing was checked here"
else
    # A suite that did not run is a failure, not a note: the sweep reads the
    # verdict line, and "PASS (with warnings)" over a machine where nothing
    # ran is the "verified on zero checks" defect again (2026-09-19).
    note_fail "kldload-test is not installed — the smoke suite DID NOT RUN, and this profile ships it"
fi
echo

# ─── 7. Doctor ──────────────────────────────────────────────────────────────
echo "## Doctor"
echo
if have kldload-doctor; then
    # Same shape as the suite: the doctor's exit status reflects the machine,
    # and its output is what gets summarised.
    _doc="$(S timeout 600 kldload-doctor 2>&1 || true)"

    # READ THE DOCTOR'S OWN COUNT, not a line grep for the word "fail".
    #
    # This used to be `_count '(^|[^a-z])(error|fail)'` over the lowercased
    # output, reported as "doctor mentions error/fail on N line(s)". The
    # doctor emits JSON whose summary ALWAYS contains a "fail": key, so
    # `"fail": 0` on a perfectly healthy machine matched it too — the warning
    # fired identically whether the doctor found two problems or none, and the
    # number it printed was a line count, not a failure count. A warning that
    # cannot tell the two states apart is not a check.
    # HISTORY: fiend, 2026-09-21. 11-storage reported "fail": 2 and still came
    # out PASS, because two real doctor failures arrived as the same warning a
    # clean machine gets.
    #
    # The structured count is authoritative; the grep is only a fallback for a
    # doctor that is not emitting JSON, and it is reported as unparseable
    # rather than as a health verdict.
    _dfail="$(sed -n 's/.*"fail"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$_doc" | tail -1)"

    # NAME the failing checks, do not just count them.
    #
    # This block printed `tail -20` of the doctor's output, which is the JSON
    # summary and nothing else, and then reported "doctor reports N failing
    # check(s)". The count was right and the identity was thrown away by the
    # very block that counted it -- a count is not a result. fiend,
    # 2026-09-21: deb-4-k8s and 5-desktop both came back FAIL on "1 failing
    # check" and the report did not say which, on either, so the sweep found
    # two defects and recorded neither.
    #
    # Two traps in parsing this, both hit on the first attempt:
    #   * the doctor emits results[] AND a subsystems{} grouping that repeats
    #     every check, so scanning the whole document double-counts. results[]
    #     is printed first (sort_keys), so stop at "subsystems".
    #   * it uses sort_keys=True, so within one object "subsystem" sorts AFTER
    #     "status" -- reading it when status is seen yields the PREVIOUS
    #     check's subsystem. Print once subsystem arrives instead.
    # Verified against a real 42-check report with three failures: this names
    # the same three, with the same subsystems, as a JSON parser does.
    # actual/expected ride along: "metallb failed" twice with no numbers left
    # nothing to go on once the machine was reinstalled (2026-09-23). Both keys
    # sort BEFORE "name", so they are captured as they pass, like remediation.
    _dnames="$(awk '
        /^  "subsystems"[[:space:]]*:/ { exit }
        /"actual"[[:space:]]*:/      { a=$0; sub(/.*"actual"[[:space:]]*:[[:space:]]*"?/,"",a); sub(/"?,?[[:space:]]*$/,"",a) }
        /"expected"[[:space:]]*:/    { e=$0; sub(/.*"expected"[[:space:]]*:[[:space:]]*"?/,"",e); sub(/"?,?[[:space:]]*$/,"",e) }
        /"name"[[:space:]]*:/        { n=$0; sub(/.*"name"[[:space:]]*:[[:space:]]*"/,"",n); sub(/".*/,"",n) }
        /"remediation"[[:space:]]*:/ { r=$0; sub(/.*"remediation"[[:space:]]*:[[:space:]]*"/,"",r); sub(/".*/,"",r) }
        /"status"[[:space:]]*:[[:space:]]*"fail"/ { p=1 }
        /"subsystem"[[:space:]]*:/ {
            if (p) { s=$0; sub(/.*"subsystem"[[:space:]]*:[[:space:]]*"/,"",s); sub(/".*/,"",s)
                     printf "%s/%s [got %s, want %s]%s\n", s, n, a, e, (r==""?"":" -> " r); p=0 }
        }' <<<"$_doc")"

    echo '```'
    if [[ -n "$_dnames" ]]; then
        echo "failing checks:"
        sed 's/^/  /' <<<"$_dnames"
        echo
    fi
    sed 's/\x1b\[[0-9;]*m//g' <<<"$_doc" | tail -20
    echo '```'
    if [[ -n "$_dfail" ]]; then
        if ((_dfail > 0)); then
            if [[ -n "$_dnames" ]]; then
                # Strip each line's remediation, then join. Two things got
                # this wrong before it was run: ${x%%" -> "*} cuts at the
                # FIRST arrow in the WHOLE string, reducing three findings to
                # one; and paste -sd'; ' cycles through a delimiter LIST, so
                # it alternated ';' and ' ' between fields.
                note_fail "kldload-doctor reports ${_dfail} failing check(s): $(sed 's/ -> .*//' <<<"$_dnames" | paste -sd';' - | sed 's/;/; /g')"
            else
                note_fail "kldload-doctor reports ${_dfail} failing check(s) — and the report could not name them"
            fi
        fi
    else
        # Not assessed is not healthy. A doctor whose summary cannot be read
        # has told this report nothing, and the verdict must not read as if
        # it had.
        note_fail "kldload-doctor output carried no machine-readable summary — health NOT assessed"
    fi
elif [[ "$PROFILE" == core ]]; then
    note_warn "core ships no doctor by design — kldload-doctor is not installed, health not assessed here"
else
    note_fail "kldload-doctor is not installed — DID NOT RUN, and this profile ships it"
fi
echo

# ─── 8. Logs ────────────────────────────────────────────────────────────────
echo "## Logs"
echo
_fb=/var/log/kldload/firstboot.log
_fbw="$(S grep -ciE 'warning|fatal|error' "$_fb" || echo 0)"
_jerr="$(S journalctl -p err -b --no-pager -q | grep -c . || echo 0)"
echo '```'
printf '%-24s %s\n' \
    "firstboot warn/error" "${_fbw}" \
    "journal priority<=err" "${_jerr}"
echo '```'
if ((_jerr > 0)); then
    echo
    echo "Journal errors (most recent 12):"
    echo '```'
    S journalctl -p err -b --no-pager -q | tail -12 | cut -c1-160
    echo '```'
fi
if ((_fbw > 0)); then
    echo
    echo "First-boot warnings (most recent 10):"
    echo '```'
    S grep -iE 'warning|fatal|error' "$_fb" | tail -10 | cut -c1-160
    echo '```'
fi
echo

# ─── 9. Verdict ─────────────────────────────────────────────────────────────
echo "## Verdict"
echo
if ((FAILS == 0 && WARNS == 0)); then
    echo "**PASS** — ${DISTRO}/${PROFILE}: everything requested is present, no failed units, no suite failures."
elif ((FAILS == 0)); then
    echo "**PASS (with ${WARNS} warning(s))** — ${DISTRO}/${PROFILE}. Nothing requested is missing; see the warnings above."
else
    echo "**FAIL** — ${DISTRO}/${PROFILE}: ${FAILS} defect(s), ${WARNS} warning(s). Every one is listed above."
fi
echo
echo "_Generated by tests/profile-report.sh on $(hostname) at $(date -Is)._"
# Explicit, so the ERR trap does not fire on the script's own verdict: a
# machine with defects is a RESULT of this report, not a bug in it.
if ((FAILS == 0)); then
    exit 0
fi
exit 1
