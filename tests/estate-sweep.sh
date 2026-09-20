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

EDITIONS=("$@")
((${#EDITIONS[@]})) || EDITIONS=("${DEFAULT_EDITIONS[@]}")

RUN_ID="$(date +%Y%m%d-%H%M)"
RESULTS="${REPO}/estate-results/${RUN_ID}"
mkdir -p "$RESULTS"
SUMMARY="${RESULTS}/SUMMARY.md"
LOG="${RESULTS}/sweep.log"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

ssh_bench() { # ssh_bench <ip> <command...>
    local ip="$1"
    shift
    SSHPASS="$BENCH_PASS" timeout 120 sshpass -e ssh \
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
    echo '| edition | distro/profile | install | verdict | pass | fail | warn | report |'
    echo '|---|---|---|---|---|---|---|---|'
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
        printf '| %s | — | no answers file | SKIP | | | | |\n' "$ed" >>"$SUMMARY"
        continue
    fi
    want_profile="$(sudo -n grep -hE '^KLDLOAD_PROFILE=' "$ANS" | tail -1 | cut -d= -f2 | tr -d '"')"
    want_distro="$(sudo -n grep -hE '^KLDLOAD_DISTRO=' "$ANS" | tail -1 | cut -d= -f2 | tr -d '"')"
    say "=== ${ed} (${want_distro}/${want_profile})"

    # 1. where is the bench machine now? Any profile will do — it is about to
    #    be reinstalled; all that is needed is a way to reboot it.
    cur=""
    for p in "$want_profile" desktop server core kvm storage ai master; do
        cur="$(find_bench "$p" || true)"
        [[ -n "$cur" ]] && break
    done
    if [[ -z "$cur" ]]; then
        say "${ed}: cannot find the bench machine on ${SUBNET}.0/24 — is it powered on?"
        printf '| %s | %s/%s | machine not found | FAIL | | | | |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    fi
    say "${ed}: bench machine at ${cur}"

    # 2. arm, then send it to PXE
    _mark="$(wc -l <"$NGINX_LOG" 2>/dev/null || echo 0)"
    sudo -n "$SERVER" arm-install "$MAC" "$ANS" --netdev "$NETDEV" >>"$LOG" 2>&1 || {
        say "${ed}: arm FAILED"
        printf '| %s | %s/%s | arm failed | FAIL | | | | |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    }
    kick_pxe "$cur" || say "${ed}: could not set BootNext — power-cycle and pick network boot"

    # 3. wait for the answers fetch, then disarm
    fetched=0 t=0
    while ((t < FETCH_WAIT)); do
        if sudo -n tail -n +"$_mark" "$NGINX_LOG" 2>/dev/null | grep -q "GET /answers/"; then
            fetched=1
            break
        fi
        sleep 15
        t=$((t + 15))
    done
    sudo -n "$SERVER" disarm "$MAC" >>"$LOG" 2>&1 || true
    if ((fetched == 0)); then
        say "${ed}: the installer never fetched its answers (${FETCH_WAIT}s) — disarmed"
        printf '| %s | %s/%s | never PXE-booted | FAIL | | | | |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    fi
    say "${ed}: answers fetched after ${t}s; installing"

    # 4. wait for it to come back AS THE PROFILE THAT WAS ASKED FOR
    ip="" t=0
    while ((t < INSTALL_WAIT)); do
        sleep 30
        t=$((t + 30))
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
        printf '| %s | %s/%s | did not boot | FAIL | | | | |\n' "$ed" "$want_distro" "$want_profile" >>"$SUMMARY"
        RC=1
        continue
    fi
    say "${ed}: up at ${ip} after ${t}s"

    # 5. the manifest
    scp_to "$ip" "${REPO}/tests/profile-report.sh" "${REPO}/tests/collect-bundle.sh" /tmp/ || true
    ssh_bench "$ip" 'bash /tmp/profile-report.sh' >"${OUT}/report.md" 2>"${OUT}/report.stderr" || true
    verdict="$(grep -oE '\*\*(PASS|FAIL)[^*]*\*\*' "${OUT}/report.md" | head -1 | tr -d '*' || echo '?')"
    read -r sp sf sw < <(sed -n 's/^PASS \([0-9]*\)   FAIL \([0-9]*\)   WARN \([0-9]*\)$/\1 \2 \3/p' "${OUT}/report.md" | head -1)
    sp="${sp:-}" sf="${sf:-}" sw="${sw:-}"

    # 6. the bundle
    b="$(ssh_bench "$ip" 'bash /tmp/collect-bundle.sh' | tail -1 || true)"
    if [[ -n "$b" ]]; then
        scp_from "$ip" "$b" "${OUT}/bundle.tar.gz" &&
            say "${ed}: bundle $(du -h "${OUT}/bundle.tar.gz" | cut -f1)"
    else
        say "${ed}: no bundle collected"
    fi

    # 7. the row
    printf '| %s | %s/%s | ok | %s | %s | %s | %s | [report](%s/report.md) |\n' \
        "$ed" "$want_distro" "$want_profile" "${verdict:-?}" "$sp" "$sf" "$sw" "$ed" >>"$SUMMARY"
    say "${ed}: ${verdict:-no verdict}"
    [[ "$verdict" == PASS* ]] || RC=1
done

say "sweep finished — ${SUMMARY}"
exit "$RC"
