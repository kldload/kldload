#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# offline-proof.sh — cut the VMs on a KVM host off from the internet, and list
# every packet that tried to leave anyway.
#
# WHAT IT DOES, IN ORDER
#   start   adds nft table inet kldoffline: a forward-hook chain that LOGS and
#           DROPS anything arriving from a libvirt NAT bridge (virbr*) that
#           would be routed out of the host; records the journal cursor
#   drops   prints the kernel-log drops since that cursor, one per line, and
#           a count per destination; exit 1 when there were any
#   status  whether the table is loaded, and the drop counter
#   stop    deletes the table
#
# WHY: "the cluster is offline" was a belief until round 1 on fiend
# (2026-09-27) showed containerd, kubeadm, helm and every image coming from
# the internet. The proof is a host where leaving is impossible and every
# attempt is written down. Round 1 blocked by DHCP lease, and kube-cluster's
# VMs have no libvirt lease, so it blocked nothing; round 3 used MACs from
# virsh domiflist, which misses a clone made after start. The bridge catches
# both.
#
# WHAT IT DOES NOT BLOCK: traffic to the host itself (hook input) — the
# darksite tunnel, dnsmasq DNS, NTP from the host — which is the point; and
# VMs bridged straight onto the LAN (br0), which never cross forward. Those
# are named by `status`, so a green run cannot hide them.
#
# INPUTS  root; nft; libvirt NAT bridges named virbr*
# OUTPUTS /run/kldload-offline-proof.cursor (journal position at start)
# EXIT    0 ok / no drops · 1 drops found or a command failed · 2 usage
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

usage() { sed -n '2,/^# ──*$/{/^# ──*$/d; s/^# \{0,1\}//; p}' "$0"; }
case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
start | stop | status | drops) ;;
*)
    usage >&2
    exit 2
    ;;
esac
((EUID == 0)) || exec sudo -n -- "$0" "$@"

TABLE=kldoffline
CURSOR=/run/kldload-offline-proof.cursor
PREFIX="kldoffline: "

case "$1" in
start)
    # WHY a fresh table: a re-run starts from a known rule set, not a second
    # copy of the first one.
    nft delete table inet "$TABLE" 2>/dev/null || : # absent on a first run
    nft -f - <<EOF
table inet $TABLE {
    chain leave {
        type filter hook forward priority -10; policy accept;
        iifname "virbr*" oifname != "virbr*" counter log prefix "$PREFIX" level warn drop
    }
}
EOF
    nft list table inet "$TABLE" | grep -q 'log prefix' ||
        {
            echo "offline-proof: the table did not load" >&2
            exit 1
        }
    journalctl -k -n 0 --show-cursor -q | sed -n 's/^-- cursor: //p' >"$CURSOR"
    [[ -s "$CURSOR" ]] || {
        echo "offline-proof: no journal cursor, drops could not be read back" >&2
        exit 1
    }
    echo "offline-proof: VMs behind virbr* can no longer leave this host"
    ;;
stop)
    nft delete table inet "$TABLE" 2>/dev/null || : # already gone is the goal
    echo "offline-proof: table removed"
    ;;
status)
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
        echo "loaded: $(nft list table inet "$TABLE" | grep -o 'packets [0-9]* bytes [0-9]*')"
    else
        echo "not loaded"
    fi
    # the blind spot, named: bridged VMs never cross the forward hook
    while read -r dom; do
        [[ -n "$dom" ]] || continue
        virsh domiflist "$dom" 2>/dev/null </dev/null | awk -v d="$dom" \
            '$2=="bridge" && $3!~/^virbr/ {print "NOT COVERED (bridged on " $3 "): " d}'
    done < <(virsh list --name 2>/dev/null)
    ;;
drops)
    [[ -s "$CURSOR" ]] || {
        echo "offline-proof: never started on this boot (no $CURSOR)" >&2
        exit 1
    }
    # By position (the cursor), never by clock string: 23:27 sorts after 18:56,
    # so filtering by time let yesterday's lines pass as today's.
    log=$(journalctl -k -q --no-pager --after-cursor "$(cat "$CURSOR")" -g "$PREFIX" -o short-iso || :) # -g exits 1 on no match
    if [[ -z "$log" ]]; then
        echo "0 drops"
        exit 0
    fi
    printf '%s\n' "$log"
    echo "── by destination ──"
    printf '%s\n' "$log" | grep -o 'SRC=[^ ]* DST=[^ ]*.*PROTO=[A-Z]*\( SPT=[0-9]* DPT=[0-9]*\)\?' |
        sed -E 's/SRC=([^ ]*) DST=([^ ]*).*PROTO=([A-Z]*)( SPT=[0-9]* DPT=([0-9]*))?/\1 -> \2 \3 \5/' |
        sort | uniq -c | sort -rn
    echo "$(printf '%s\n' "$log" | wc -l) drops"
    exit 1
    ;;
esac
