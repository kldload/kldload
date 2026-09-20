#!/usr/bin/env bash
# =============================================================================
# estate-sweep.sh — install every profile on the bench machine, and file the proof
# =============================================================================
#
# WHAT IT DOES, per edition, in order
#   1. Arms the netboot server for that edition's answers file.
#   2. Sets BootNext on the bench machine and reboots it into PXE.
#   3. Waits for the installer to fetch its answers, then DISARMS — so a later
#      reboot cannot loop back into the installer.
#   4. Waits for the machine to come back with the profile that edition asked
#      for, identified by its install manifest rather than by address.
#   5. Runs tests/profile-report.sh on it and saves the manifest.
#   6. Runs tests/collect-bundle.sh and pulls the bundle back.
#   7. Appends one row to SUMMARY.md and moves to the next edition.
#
# WHY: seven profiles times three distros is twenty-one installs, and a human
# reading a terminal for each one is how a desktop with no desktop and a klab
# with no goldens both got called verified. A sweep that files the same
# manifest every time can be diffed (operator, 2026-09-19).
#
# IT NEVER STOPS ON A BAD EDITION. A failed install is a result: it is recorded
# and the sweep moves on, because the alternative is waking up to one failure
# and twenty untested profiles.
#
# INPUT:  the edition names to run, or none for the default list.
#         MAC / NETDEV / BENCH_USER / BENCH_PASS can be overridden.
# OUTPUT: estate-results/<run-id>/<edition>/{report.md,bundle.tar.gz,install.log}
#         estate-results/<run-id>/SUMMARY.md
# EXIT:   0 every edition passed · 1 at least one did not · 2 could not start.
# =============================================================================
set -Eeuo pipefail
trap 'echo "estate-sweep.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC="${MAC:-f0:2f:74:cd:27:50}"
NETDEV="${NETDEV:-a0:36:9f:9f:10:1c}"
BENCH_USER="${BENCH_USER:-admin}"
BENCH_PASS="${BENCH_PASS:-Passw0rd}"
SUBNET="${SUBNET:-10.100.10}"
SERVER=/usr/local/sbin/kldload-netboot-server
NGINX_LOG=/var/lib/kldload/netboot-serve/nginx-access.log
INSTALL_WAIT="${INSTALL_WAIT:-3000}" # 50 min: the full image is 15 GB over 1G
FETCH_WAIT="${FETCH_WAIT:-900}"      # 15 min from PXE to the answers fetch
# 40 min: an edition with BUILD_IMAGES=1 builds five cloud-image goldens on its
# first boot, and measuring it before that finishes reports a machine that does
# not exist yet.
CONVERGE_WAIT="${CONVERGE_WAIT:-2400}"

# The default order is deliberate: kvm first, because it is the only one that
# builds goldens and therefore the only one that exercises the estate at all.
DEFAULT_EDITIONS=(deb-3-kvm 3-kvm deb-4-k8s 4-k8s deb-11-storage 11-storage
    deb-9-ai 9-ai deb-1-core 1-core 2-server 5-desktop)

usage() {
    cat <<EOF
Usage: estate-sweep.sh [edition...]

Installs each edition on the bench machine and files a report and a bundle.
Editions are directory names under live-build/pxe/matrix/.

Default order (kvm first — it is the only one that exercises the estate):
  ${DEFAULT_EDITIONS[*]}

Environment: MAC, NETDEV, BENCH_USER, BENCH_PASS, SUBNET, INSTALL_WAIT, FETCH_WAIT
EXIT: 0 all passed, 1 some did not, 2 could not start.
EOF
    exit "${1:-1}"
}
case "${1:-}" in -h | --help | help) usage 0 ;; esac

# --adopt-first: the first edition is ALREADY installing — armed and PXE-booted
# by hand, or by a run that was interrupted mid-edition. Arming and rebooting
# are skipped for it and it is picked up at "wait for it to come back", so an
# install in flight is adopted rather than restarted, and its report and bundle
# come out of exactly the same code as every other edition's.
ADOPT_FIRST=0
if [[ "${1:-}" == --adopt-first ]]; then
    ADOPT_FIRST=1
    shift
fi

EDITIONS=("$@")
((${#EDITIONS[@]})) || EDITIONS=("${DEFAULT_EDITIONS[@]}")

RUN_ID="$(date +%Y%m%d-%H%M)"
RESULTS="${REPO}/estate-results/${RUN_ID}"
mkdir -p "$RESULTS"
SUMMARY="${RESULTS}/SUMMARY.md"
LOG="${RESULTS}/sweep.log"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ssh_bench <ip> <command...> — run a command on the bench machine.
#
# SSH_T sets the timeout for one call. The default of 120s is right for the
# probes this script makes constantly (what profile are you, are you up), and
# WRONG for the two calls that run a test suite: profile-report.sh takes as
# long as the smoke suite does, and at 120s it was killed mid-write, leaving a
# report that stopped after the "## Smoke suite" heading with no verdict at all
# (3-kvm, 2026-09-20). A truncated report is worse than none, because the
# summary row still says the edition ran.
ssh_bench() { # ssh_bench <ip> <command...>
    local ip="$1"
    shift
    SSHPASS="$BENCH_PASS" timeout "${SSH_T:-120}" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error \
        -o ConnectTimeout=6 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "${BENCH_USER}@${ip}" "$@" 2>/dev/null
}

scp_from() { # scp_from <ip> <remote> <local>
    SSHPASS="$BENCH_PASS" timeout 600 sshpass -e scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error \
        "${BENCH_USER}@${1}:${2}" "$3" >/dev/null 2>&1
}

scp_to() { # scp_to <ip> <local...> <remote dir>
    SSHPASS="$BENCH_PASS" timeout 600 sshpass -e scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error \
        "${@:2:$#-2}" "${BENCH_USER}@${1}:${!#}" >/dev/null 2>&1
}

# find_bench <profile> — the address of a machine whose install manifest says
# it is running <profile>, or empty.
#
# Identified by what the machine SAYS IT IS, never by a remembered address: the
# bench machine takes a new lease on most installs, and the previous occupant
# of an address answers ssh just as happily (fiend has moved seven times).
find_bench() {
    local want="$1" ip got
    for ip in $(seq 100 200); do
        ip="${SUBNET}.${ip}"
        timeout 1 ping -c1 -W1 "$ip" >/dev/null 2>&1 || continue
        # Most addresses on this subnet are not the bench machine, and an
        # address that does not answer ssh is the normal case, not an error.
        got="$(ssh_bench "$ip" 'sudo -n grep -hE "^KLDLOAD_PROFILE=" /etc/kldload/install-manifest.env 2>/dev/null | cut -d= -f2 | tr -d "\""' || true)"
        [[ "$got" == "$want" ]] || continue
        printf '%s\n' "$ip"
        return 0
    done
    return 1
}

# kick_pxe <ip> — one-time PXE boot. Returns 1 if the machine could not be told.
kick_pxe() {
    local ip="$1" macre
    macre="$(tr -d ':' <<<"$MAC")"
    # shellcheck disable=SC2016 # expanded on the bench machine, not here
    ssh_bench "$ip" 'e=$(sudo -n efibootmgr -v | grep -i "MAC('"$macre"'" | grep -i IPv4 | head -n1 | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p"); [ -n "$e" ] || exit 3; sudo -n efibootmgr -n "$e" >/dev/null && (sleep 2; sudo -n systemctl reboot) >/dev/null 2>&1 &'
}

# ── Preconditions ───────────────────────────────────────────────────────────
[[ -x "$SERVER" ]] || {
    echo "estate-sweep: ${SERVER} is not installed" >&2
    exit 2
}
command -v sshpass >/dev/null || {
    echo "estate-sweep: sshpass is required" >&2
    exit 2
}

{
    echo "# Estate sweep ${RUN_ID}"
    echo
    echo "Image: \`$(sudo -n "$SERVER" status 2>/dev/null | sed -n 's/.*commit *= *//p' | head -1 || echo unknown)\`"
    echo
    echo '| edition | distro/profile | install | verdict | pass | fail | warn | lifecycle | report |'
    echo '|---|---|---|---|---|---|---|---|---|'
} >"$SUMMARY"

say "sweep ${RUN_ID}: ${#EDITIONS[@]} edition(s) — ${EDITIONS[*]}"
say "results: ${RESULTS}"

RC=0
for ed in "${EDITIONS[@]}"; do
    ANS="${REPO}/live-build/pxe/matrix/${ed}/$(tr ':' '-' <<<"$MAC").env"
    OUT="${RESULTS}/${ed}"
    mkdir -p "$OUT"
    if [[ ! -r "$ANS" ]]; then
        say "${ed}: SKIP — no answers file at ${ANS}"
        printf '| %s | — | no answers file | SKIP | | | |  |\n' "$ed" >>"$SUMMARY"
        continue
    fi
    want_profile="$(sudo -n grep -hE '^KLDLOAD_PROFILE=' "$ANS" | tail -1 | cut -d= -f2 | tr -d '"')"
    want_distro="$(sudo -n grep -hE '^KLDLOAD_DISTRO=' "$ANS" | tail -1 | cut -d= -f2 | tr -d '"')"
    say "=== ${ed} (${want_distro}/${want_profile})"

    # 0. Is this edition already installing? Decided BEFORE the scan below,
    #    because a machine that is mid-install answers nothing and the scan
    #    would abandon the edition before reaching the adopt path.
    _adopt=0
    if ((ADOPT_FIRST == 1)); then
        ADOPT_FIRST=0
        _adopt=1
        say "${ed}: adopting an install already in flight — not scanning, not arming, not rebooting"
        # It was armed by whoever started it; disarm so a later reboot cannot
        # loop back into the installer. Already disarmed is the wanted state.
        sudo -n "$SERVER" disarm "$MAC" >>"$LOG" 2>&1 || true
    fi

    # 1. where is the bench machine now? Any profile will do — it is about to
    #    be reinstalled; all that is needed is a way to reboot it.
    cur=""
    for p in "$want_profile" desktop server core kvm storage ai master; do
        ((_adopt == 1)) && break
        # find_bench returns 1 when that profile is not on the subnet, which
        # is expected for all but one of the profiles tried here.
        cur="$(find_bench "$p" || true)"
        [[ -n "$cur" ]] && break
    done
    if [[ -z "$cur" && "$_adopt" == 0 ]]; then
        say "${ed}: cannot find the bench machine on ${SUBNET}.0/24 — is it powered on?"
        printf '| %s | %s/%s | machine not found | FAIL | | | |  |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    fi
    ((_adopt == 0)) && say "${ed}: bench machine at ${cur}"

    # 2. arm, then send it to PXE — unless this one is already under way.
    # Byte offset, not a line number. The first version took `wc -l` and then
    # read from `tail -n +$_mark`, which re-reads the LAST EXISTING line -- and
    # that line was already an /answers/ GET from the previous edition. So the
    # fetch "completed" in 0 s, the sweep disarmed before the machine had even
    # PXE-booted, and fiend got a 404 for its armed menu and fell back to local
    # boot (23:09:38, 2026-09-19). An offset in bytes cannot re-read anything.
    _mark="$(stat -c %s "$NGINX_LOG" 2>/dev/null || echo 0)"
    if ((_adopt == 0)); then
        sudo -n "$SERVER" arm-install "$MAC" "$ANS" --netdev "$NETDEV" >>"$LOG" 2>&1 || {
            say "${ed}: arm FAILED"
            printf '| %s | %s/%s | arm failed | FAIL | | | |  |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
            RC=1
            continue
        }
        kick_pxe "$cur" || say "${ed}: could not set BootNext — power-cycle and pick network boot"

        # 3. wait for the answers fetch, then disarm
        fetched=0 t=0
        while ((t < FETCH_WAIT)); do
            if sudo -n tail -c "+$((_mark + 1))" "$NGINX_LOG" 2>/dev/null | grep -q "GET /answers/"; then
                fetched=1
                break
            fi
            sleep 15
            t=$((t + 15))
        done
        # Disarming a MAC that is already disarmed is the wanted end state, and
        # the server says so rather than failing; either way it must not stop the
        # sweep, because leaving a machine armed loops it back into the installer.
        sudo -n "$SERVER" disarm "$MAC" >>"$LOG" 2>&1 || true
        if ((fetched == 0)); then
            say "${ed}: the installer never fetched its answers (${FETCH_WAIT}s) — disarmed"
            printf '| %s | %s/%s | never PXE-booted | FAIL | | | |  |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
            RC=1
            continue
        fi
        say "${ed}: answers fetched after ${t}s; installing"
    fi

    # 4. wait for it to come back AS THE PROFILE THAT WAS ASKED FOR
    ip="" t=0
    while ((t < INSTALL_WAIT)); do
        sleep 30
        t=$((t + 30))
        # Still installing: not found yet is the expected answer here for
        # twenty-odd minutes.
        ip="$(find_bench "$want_profile" || true)"
        [[ -n "$ip" ]] || continue
        # Freshly installed, not the machine that was there before: uptime has
        # to be smaller than the time this install has been running.
        up="$(ssh_bench "$ip" 'cut -d. -f1 /proc/uptime' || echo 999999)"
        ((up < t + 600)) && break
        ip=""
    done
    if [[ -z "$ip" ]]; then
        say "${ed}: did not come back as ${want_profile} within ${INSTALL_WAIT}s"
        printf '| %s | %s/%s | did not boot | FAIL | | | |  |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    fi
    say "${ed}: up at ${ip} after ${t}s"

    # 4b. Let first boot FINISH before measuring the machine.
    #
    # An edition with BUILD_IMAGES=1 spends twenty minutes after its first
    # login building goldens. Reporting the moment ssh answers files "0
    # goldens" for every one of them and calls it a defect — the same false
    # verdict the feature ledger guards against with its build-in-flight check.
    # Bounded, and what it waited for is recorded.
    conv=0
    while ((conv < CONVERGE_WAIT)); do
        if ssh_bench "$ip" 'test -e /var/lib/kldload/firstboot-done' &&
            ! ssh_bench "$ip" 'systemctl is-active --quiet kldload-autodeploy'; then
            break
        fi
        sleep 60
        conv=$((conv + 60))
    done
    if ((conv >= CONVERGE_WAIT)); then
        say "${ed}: first boot had NOT finished after ${conv}s — reporting anyway; treat golden counts with suspicion"
    else
        say "${ed}: first boot settled after ${conv}s"
    fi

    # 5. the manifest
    scp_to "$ip" "${REPO}/tests/profile-report.sh" "${REPO}/tests/collect-bundle.sh" /tmp/ || true
    # profile-report exits 1 when the machine has defects — which is a result
    # to be filed, not a reason to abandon the sweep. The report is judged by
    # its VERDICT line below.
    SSH_T=2400 ssh_bench "$ip" 'bash /tmp/profile-report.sh' >"${OUT}/report.md" 2>"${OUT}/report.stderr" || true
    verdict="$(grep -oE '\*\*(PASS|FAIL)[^*]*\*\*' "${OUT}/report.md" | head -1 | tr -d '*' || echo '?')"
    # No verdict line means the report did not finish — killed by a timeout, or
    # it died. Say TRUNCATED rather than leaving an empty cell that reads like
    # a pass at a glance.
    if [[ -z "$verdict" ]]; then
        verdict="TRUNCATED ($(wc -l <"${OUT}/report.md") lines)"
        RC=1
    fi
    sp="" sf="" sw=""
    # `|| true`: a core install ships no smoke suite, so its report carries no
    # tally line and read returns 1 — which under set -e killed the whole sweep
    # after nine successful editions, with the last one never run (08:07:54,
    # 2026-09-20). An absent tally is a legitimate state, not a failure.
    read -r sp sf sw < <(sed -n 's/^PASS \([0-9]*\)   FAIL \([0-9]*\)   WARN \([0-9]*\)$/\1 \2 \3/p' "${OUT}/report.md" | head -1) || true
    sp="${sp:-n/a}" sf="${sf:-n/a}" sw="${sw:-n/a}"

    # 5b. The ACTIVE estate test, where there is a hypervisor to run it on.
    #
    # profile-report covers the static picture (are the VMs in the inventory,
    # are they up in Prometheus). This is the half that only a real create and
    # delete can answer: does a new machine JOIN all four registries, and does
    # deleting it make it LEAVE them. It ships in the image, so the shipped
    # copy is what runs -- a harness that re-implements the thing it tests has
    # blamed a healthy machine before.
    if ssh_bench "$ip" 'command -v virsh >/dev/null 2>&1'; then
        say "${ed}: estate lifecycle (clone -> join -> delete -> unjoin)"
        # 1800s, not the 120s default: this test creates a VM and then waits,
        # bounded, for four registries to notice it and four to release it.
        # At 120s it was killed after the third check and the file stopped
        # mid-run (deb-4-k8s, 2026-09-20) — the same truncation the report
        # call had, one call site later.
        SSH_T=1800 ssh_bench "$ip" 'sudo -n bash /usr/local/share/kldload/tests/estate-lifecycle.sh' \
            >"${OUT}/estate-lifecycle.txt" 2>&1 ||
            true # its verdict is in the file; a failed lifecycle is a result, not a reason to stop
        # grep -c exits 1 when there are no failures, which is the GOOD case.
        _lc="$(grep -cE '✗ FAIL' "${OUT}/estate-lifecycle.txt" 2>/dev/null || true)"
        # ...and likewise none of the other kind on a run that died early.
        _lp="$(grep -cE '✓ PASS' "${OUT}/estate-lifecycle.txt" 2>/dev/null || true)"
        # The script prints a summary line last. Without it the run did not
        # finish, and counting only its passes would report a killed test as a
        # clean one.
        if ! grep -q 'estate lifecycle:' "${OUT}/estate-lifecycle.txt" 2>/dev/null; then
            say "${ed}: lifecycle did NOT finish — recorded as truncated"
            _lifecycle="lifecycle TRUNCATED (${_lp} before it stopped)"
            RC=1
            _lc=truncated
        fi
        say "${ed}: lifecycle ${_lp} passed, ${_lc} failed"
        if [[ "$_lc" == truncated ]]; then
            : # already recorded above
        elif [[ "${_lc:-0}" != 0 ]]; then
            RC=1
            # Surface it in the summary row rather than only in a side file.
            _lifecycle="lifecycle ${_lp} passed / ${_lc} failed"
        else
            _lifecycle="lifecycle ok (${_lp})"
        fi
    else
        _lifecycle="no hypervisor"
    fi

    # 6. the bundle
    b="$(SSH_T=900 ssh_bench "$ip" 'bash /tmp/collect-bundle.sh' | tail -1 || true)"
    if [[ -n "$b" ]]; then
        # stat, not du: on ZFS du reports allocated blocks, and a file written
        # seconds ago has not been flushed, so it reported a 165 MB bundle as
        # "1.0K" (onyx, 2026-09-19).
        scp_from "$ip" "$b" "${OUT}/bundle.tar.gz" &&
            say "${ed}: bundle $(stat -c %s "${OUT}/bundle.tar.gz" 2>/dev/null || echo 0) bytes"
    else
        say "${ed}: no bundle collected"
    fi

    # 7. the row
    printf '| %s | %s/%s | ok | %s | %s | %s | %s | %s | [report](%s/report.md) |\n' \
        "$ed" "$want_distro" "$want_profile" "${verdict:-?}" "$sp" "$sf" "$sw" \
        "${_lifecycle:-not run}" "$ed" >>"$SUMMARY"
    say "${ed}: ${verdict:-no verdict}"
    [[ "$verdict" == PASS* ]] || RC=1
done

say "sweep finished — ${SUMMARY}"
exit "$RC"
