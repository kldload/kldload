# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# netplan.sh — the kldload network plan, for any script that needs a range.
#
#   source /usr/lib/kldload/netplan.sh
#   netplan_load                      # defaults, then /etc overrides
#   svc="$(netplan_get K8S_SVC_CIDR)" # one value; exit 1 if the key is unknown
#   cidr_overlap 10.96.0.0/16 10.100.10.0/24 || echo "no overlap"
#
# WHY: every range kldload creates used to be typed into each script that
# needed it -- the pod range three times, the installer planes twice, one of
# them read by nothing -- and the Kubernetes Services range sat on the bench
# LAN for months without anyone being able to say so (2026-09-29).
# docs/NETWORK-PLAN.md; `kldload-netplan` is the command-line face.
#
# Files, parsed as KEY=VALUE and never sourced (a value is data; an operator's
# typo must not run): /usr/lib/kldload/network-plan.defaults, then
# /etc/kldload/network-plan.env. NETPLAN_DEFAULTS / NETPLAN_FILE override the
# paths (tests).
# ─────────────────────────────────────────────────────────────────────────────

declare -gA NETPLAN=()
declare -ga NETPLAN_ORDER=()
# lines that did not parse, as "file:line: text" -- kept, not dropped, so a
# typo in an override is reported instead of silently falling back to the
# default (kldload-netplan check fails on any)
declare -ga NETPLAN_BAD=()

# netplan_load — (re)read the defaults and the override file into NETPLAN.
# Returns 1 when neither file exists: a caller then keeps its own fallback.
netplan_load() {
    local f line raw k v seen=0 n
    NETPLAN=()
    NETPLAN_ORDER=()
    NETPLAN_BAD=()
    for f in "${NETPLAN_DEFAULTS:-/usr/lib/kldload/network-plan.defaults}" \
        "${NETPLAN_FILE:-/etc/kldload/network-plan.env}"; do
        [[ -r "$f" ]] || continue
        seen=1
        n=0
        while IFS= read -r raw || [[ -n "$raw" ]]; do
            n=$((n + 1))
            line="${raw%%#*}"
            line="${line//[[:space:]]/}"
            [[ -n "$line" ]] || continue
            k="${line%%=*}"
            v="${line#*=}"
            if [[ "$line" != *=* || ! "$k" =~ ^[A-Z][A-Z0-9_]*$ || ! "$v" =~ ^[0-9./-]+$ ]]; then
                NETPLAN_BAD+=("${f}:${n}: ${raw}")
                continue
            fi
            [[ -n "${NETPLAN[$k]+x}" ]] || NETPLAN_ORDER+=("$k")
            NETPLAN["$k"]="$v"
        done <"$f"
    done
    ((seen))
}

# netplan_get KEY — the value on stdout; 1 (and nothing printed) if unknown.
netplan_get() {
    ((${#NETPLAN[@]})) || netplan_load || return 1
    [[ -n "${NETPLAN[$1]+x}" ]] || return 1
    printf '%s\n' "${NETPLAN[$1]}"
}

# ip2int <a.b.c.d> — the address as an integer; 1 if it is not one.
ip2int() {
    local a b c d
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
    ((a < 256 && b < 256 && c < 256 && d < 256)) || return 1
    printf '%d\n' $(((a << 24) | (b << 16) | (c << 8) | d))
}

# cidr_bounds <net/len> — "first last" as integers; 1 if malformed.
cidr_bounds() {
    local n len base size
    [[ "$1" == */* ]] || return 1
    len="${1#*/}"
    [[ "$len" =~ ^[0-9]+$ ]] && ((len <= 32)) || return 1
    n="$(ip2int "${1%/*}")" || return 1
    size=$((1 << (32 - len)))
    base=$((n & ~(size - 1) & 0xFFFFFFFF))
    printf '%d %d\n' "$base" $((base + size - 1))
}

# span_bounds <net/len | a.b.c.d | a.b.c.d-e.f.g.h> — "first last".
span_bounds() {
    local a b
    case "$1" in
    */*) cidr_bounds "$1" ;;
    *-*)
        a="$(ip2int "${1%-*}")" || return 1
        b="$(ip2int "${1#*-}")" || return 1
        ((a <= b)) || return 1
        printf '%d %d\n' "$a" "$b"
        ;;
    *)
        a="$(ip2int "$1")" || return 1
        printf '%d %d\n' "$a" "$a"
        ;;
    esac
}

# cidr_overlap <span> <span> — 0 when the two share any address.
cidr_overlap() {
    local a1 a2 b1 b2
    read -r a1 a2 < <(span_bounds "$1") || return 2
    read -r b1 b2 < <(span_bounds "$2") || return 2
    ((a1 <= b2 && b1 <= a2))
}

# span_within <inner> <outer> — 0 when every address of inner is in outer.
span_within() {
    local a1 a2 b1 b2
    read -r a1 a2 < <(span_bounds "$1") || return 2
    read -r b1 b2 < <(span_bounds "$2") || return 2
    ((a1 >= b1 && a2 <= b2))
}
