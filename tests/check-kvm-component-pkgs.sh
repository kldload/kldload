#!/usr/bin/env bash
# =============================================================================
# check-kvm-component-pkgs.sh — the KVM package list exists twice; keep it one list
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Sources the installer's profiles.sh and CALLS k_profile_optional_packages
#      twice per family — once with KLDLOAD_ENABLE_KVM=0, once with 1. The
#      difference is exactly what ticking the KVM box adds, with no parsing.
#   2. Sources the kvm component and calls _kvm_pkgs for the same family
#      (KLDLOAD_DISTRO_ID overrides its /etc/os-release probe).
#   3. Names every package in one list and not the other, per family.
#
# WHY IT EXISTS: `kldload-component install kvm` used to fail outright on a
# machine whose profile had not shipped libvirt — there was no path to a
# hypervisor short of reinstalling (fiend .120, debian/desktop, 2026-09-19).
# The fix gave the component its own copy of the list, because profiles.sh is
# installer-side and never reaches a target. A copy with nothing watching it
# drifts, and the drift is silent: `component install kvm` quietly builds a
# different hypervisor from the one every other machine got.
#
# Calling the real functions rather than scraping them is deliberate — the
# first version of this gate parsed the file with sed, swept the comment prose
# into the package list, and reported all three families as drifted.
#
# OUTPUT: one line per family on success; the differing names on stderr on failure.
# EXIT:   0 the lists agree · 1 they drifted · 2 the gate could not run
#         (a check that cannot run is not a check — core rules §3).
# =============================================================================
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/profiles.sh"
COMPONENT="${ROOT}/live-build/config/includes.chroot/usr/lib/kldload/components/kvm.component"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

for f in "$PROFILES" "$COMPONENT"; do
    [[ -r "$f" ]] || {
        echo "check-kvm-component-pkgs: cannot read $f" >&2
        exit 2
    }
done

# installer_kvm_set <distro> — what KLDLOAD_ENABLE_KVM=1 ADDS, one per line.
#
# Run in a subshell per call: profiles.sh sets its own shell options and
# defines a great many functions, and the KVM set is the only thing wanted out
# of it. The profile is deliberately 'server' on both sides so the KVM `if` is
# reached by the checkbox arm, not by `profile == kvm`.
installer_kvm_set() {
    local distro="$1" want="$2"
    (
        # common.sh mkdir's its log and state dirs the moment it is sourced,
        # which needs root unless they are pointed somewhere else. Both are
        # overridable, so the gate runs as an ordinary user.
        export KLDLOAD_LOG_DIR="${SCRATCH}/log" KLDLOAD_STATE_DIR="${SCRATCH}/state"
        # shellcheck source=/dev/null
        source "$PROFILES" >/dev/null 2>&1
        KLDLOAD_DISTRO="$distro" KLDLOAD_PROFILE=server \
            KLDLOAD_ENABLE_KVM="$want" KLDLOAD_ENABLE_ZFS=0 KLDLOAD_ENABLE_K8S=0 \
            KLDLOAD_ENABLE_AI=0 KLDLOAD_ENABLE_EBPF=0 KLDLOAD_ENABLE_DEVOPS=0 \
            KLDLOAD_KLAB_ZFS_DEV=0 KLDLOAD_ZFSLAB_MODE=0 \
            k_profile_optional_packages
    ) | tr ' ' '\n' | grep -v '^$' | sort -u
}

# component_kvm_set <distro> — the component's own list for that family.
component_kvm_set() {
    (
        # shellcheck source=/dev/null
        source "$COMPONENT" >/dev/null 2>&1
        KLDLOAD_DISTRO_ID="$1" _kvm_pkgs
    ) | tr ' ' '\n' | grep -v '^$' | sort -u
}

rc=0
compare() { # compare <family label> <distro id>
    local fam="$1" distro="$2" a b only_i only_c
    local full
    a="$(comm -13 <(installer_kvm_set "$distro" 0) <(installer_kvm_set "$distro" 1))"
    b="$(component_kvm_set "$distro")"
    # `full` is every package a KVM install gets, not just the ones KVM ADDS.
    # The two directions are not symmetric: a package the KVM box adds and the
    # component omits is a hypervisor built wrong, while a package the component
    # names that the installer ships on every profile anyway (dnsmasq, jq) is
    # merely belt and braces. Judge each against the list that makes it a defect.
    full="$(installer_kvm_set "$distro" 1)"
    # Both sides must find something. Two empty lists compare equal forever,
    # which is how a gate becomes decoration (core rules §5d.3).
    if [[ -z "$a" || -z "$b" ]]; then
        echo "check-kvm-component-pkgs: ${fam}: extracted nothing (installer=$(wc -w <<<"$a"), component=$(wc -w <<<"$b")) — the gate is broken" >&2
        rc=2
        return
    fi
    only_i="$(comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | tr '\n' ' ')"
    only_c="$(comm -13 <(printf '%s\n' "$full") <(printf '%s\n' "$b") | tr '\n' ' ')"
    if [[ -n "${only_i// /}" || -n "${only_c// /}" ]]; then
        echo "check-kvm-component-pkgs: ${fam} drifted:" >&2
        [[ -n "${only_i// /}" ]] && echo "  installer only : ${only_i}" >&2
        [[ -n "${only_c// /}" ]] && echo "  component only : ${only_c} (in no installer list at all)" >&2
        rc=1
    else
        echo "check-kvm-component-pkgs: ${fam} agrees ($(wc -l <<<"$a") packages)"
    fi
}

compare "debian" debian
compare "arch" arch
compare "fedora/rpm" fedora

# ── k_kvm_wanted's truth table ──────────────────────────────────────────────
#
# One answer decides the package list, the ZFS layout, the units AND the
# manifest. When it lived in four places plus a default inside a function, the
# manifest recorded KVM=1 while the package phase used 0, and a storage install
# came up with no libvirt while its own manifest said it had been asked for
# (fiend, deb-11-storage, 2026-09-20). Executed, not read.
want() { # want <profile> <explicit 0/1 or empty> <expected yes|no>
    local got
    # env with an ARRAY: `${2:+KLDLOAD_ENABLE_KVM="$2"}` as a command prefix is
    # not an assignment after word splitting — bash tried to RUN it and the
    # gate exited 127 (2026-09-20).
    local -a e=(KLDLOAD_LOG_DIR="${SCRATCH}/log" KLDLOAD_STATE_DIR="${SCRATCH}/state"
        KLDLOAD_PROFILE="$1")
    [[ -n "$2" ]] && e+=(KLDLOAD_ENABLE_KVM="$2")
    got="$(
        env "${e[@]}" bash -c \
            'source "'"$ROOT"'/live-build/config/includes.chroot/usr/lib/kldload-installer/lib/common.sh" >/dev/null 2>&1
             k_kvm_wanted && echo yes || echo no'
    )"
    if [[ "$got" != "$3" ]]; then
        echo "check-kvm-component-pkgs: k_kvm_wanted ${1}/${2:-unset} = ${got}, expected ${3}" >&2
        rc=1
    fi
}
want kvm "" yes
want kvm 0 yes # the profile IS the statement; a stray 0 must not disarm it
want kvm 1 yes
want core "" no # core is ZFS on root and nothing else
want core 0 no
want core 1 yes # asked for explicitly: give it
want storage "" yes
want storage 0 no
want desktop "" yes
want desktop 0 no
((rc != 0)) || echo "check-kvm-component-pkgs: k_kvm_wanted agrees with its truth table (10 cases)"

exit "$rc"
