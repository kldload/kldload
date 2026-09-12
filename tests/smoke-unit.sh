#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-unit.sh — fast, hardware-free behavioural checks for the installer +
#                 security changes that the ISO/VM smoke tests can't reach.
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IT DOES, IN ORDER:
#   1. operator-CA   — runs kldload-gen-operator-ca end to end and proves the
#                      issued client cert verifies against the CA as a TLS
#                      client (the exact check nginx ssl_verify_client does).
#   2. live-disk     — mocks findmnt/lsblk and proves _live_disk resolves the
#                      boot medium to its whole disk (the value that MUST be
#                      excluded from install-target wipe pickers).
#   3. guards        — static assertions that the data-loss / boot fixes are
#                      still wired: disk-exclusion in both auto-pickers, the
#                      fail-loud target wipe, and the visible encrypted prompt.
#
# WHY: these fixes are all "silent until the day they bite" (wipe the wrong
#   disk, hidden passphrase prompt, unauthenticated GUI). The full lifecycle VM
#   can't exercise them cheaply — an encrypted boot needs a passphrase typed at
#   the console, a mis-wipe needs a second disk — so guard them here where the
#   check is a second, not a 30-minute burn. New fixes should add a case.
#
# INPUTS:  run from anywhere; resolves the repo root from its own path.
#          openssl required for check 1 (skips with a warning if absent).
# OUTPUT:  exit 0 all-pass, 1 on any failure. Invoked by smoke-build.sh so it
#          runs as part of `./deploy.sh smoke-build`.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROOT="${ROOT}/live-build/config/includes.chroot"

PASS=0 FAILN=0
_section() { printf "\n\e[1;36m  ── %s ──\e[0m\n" "$1"; }
_pass() {
    PASS=$((PASS + 1))
    printf "  \e[1;32m✓\e[0m %s\n" "$1"
}
_fail() {
    FAILN=$((FAILN + 1))
    printf "  \e[1;31m✗ %s\e[0m — %s\n" "$1" "${2:-}"
}
_warn() { printf "  \e[1;33m!\e[0m %s — %s\n" "$1" "${2:-}"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ─── 1. operator-CA: mint → issue → verify the chain as a TLS client ─────────
_section "mTLS operator CA (kldload-gen-operator-ca)"
gen="${ROOT}/tools/kldload-gen-operator-ca"
if ! command -v openssl >/dev/null 2>&1; then
    _warn "operator-CA" "openssl not installed — skipping (install to cover mTLS)"
elif [[ ! -x "${gen}" ]]; then
    _fail "operator-CA" "tool missing or not executable: ${gen}"
else
    export KLDLOAD_OPERATOR_CA_DIR="${tmp}/op-ca"
    if "${gen}" init >/dev/null 2>&1 &&
        "${gen}" issue testdev --password smoke >/dev/null 2>&1; then
        ca="$("${gen}" ca-path)"
        p12="${KLDLOAD_OPERATOR_CA_DIR}/clients/testdev.p12"
        openssl pkcs12 -in "${p12}" -clcerts -nokeys -passin pass:smoke \
            -out "${tmp}/client.crt" 2>/dev/null || true
        if [[ -s "${tmp}/client.crt" ]] &&
            openssl verify -CAfile "${ca}" -purpose sslclient "${tmp}/client.crt" >/dev/null 2>&1; then
            _pass "issued client cert verifies against the CA as sslclient"
        else
            _fail "client cert verify" "openssl verify -purpose sslclient rejected the issued cert"
        fi
        # The leaf must be clientAuth-scoped, not a general/server cert.
        if openssl x509 -in "${tmp}/client.crt" -noout -ext extendedKeyUsage 2>/dev/null |
            grep -q "TLS Web Client Authentication"; then
            _pass "client cert carries clientAuth EKU"
        else
            _fail "client EKU" "issued cert lacks TLS Web Client Authentication"
        fi
        unset KLDLOAD_OPERATOR_CA_DIR
    else
        _fail "operator-CA" "init/issue failed"
    fi
fi

# ─── 2. live-disk resolution (the value excluded from wipe pickers) ──────────
# Extract the real _whole_disk/_live_disk from kldload-autoinstall (can't source
# the whole script — it has top-level logic) and drive them with mocked
# findmnt/lsblk. Proves a boot medium at /dev/sda1 resolves to whole disk
# /dev/sda — the exact string the auto-picker must skip so it never wipes itself.
_section "boot-medium exclusion (_live_disk)"
autoinstall="${CHROOT}/usr/local/sbin/kldload-autoinstall"
if [[ ! -f "${autoinstall}" ]]; then
    _fail "live-disk" "kldload-autoinstall not found"
else
    fns="${tmp}/fns.sh"
    # Pull each function body: from `^_name() {` to the first line that is `}`.
    awk '/^_whole_disk\(\) \{/,/^\}/' "${autoinstall}" >"${fns}"
    awk '/^_live_disk\(\) \{/,/^\}/' "${autoinstall}" >>"${fns}"
    if ! grep -q '_live_disk' "${fns}"; then
        _fail "live-disk" "could not extract _live_disk from kldload-autoinstall"
    else
        got="$(
            set -Eeuo pipefail
            # Mock the probes: live root is mounted from /dev/sda1, whose parent
            # disk is sda. A correct _live_disk must return /dev/sda.
            findmnt() { [[ "$*" == *"/run/initramfs/live"* ]] && echo "/dev/sda1"; }
            lsblk() { [[ "$*" == *PKNAME* ]] && echo "sda"; }
            export -f findmnt lsblk 2>/dev/null || true
            # shellcheck disable=SC1090
            source "${fns}"
            _live_disk
        )" || got="<error>"
        if [[ "${got}" == "/dev/sda" ]]; then
            _pass "_live_disk resolves boot medium /dev/sda1 → /dev/sda"
        else
            _fail "live-disk" "expected /dev/sda, got '${got}'"
        fi
    fi
fi

# ─── 3. Static guards — the fixes must stay wired ────────────────────────────
_section "regression guards (data-loss + boot fixes)"
inst="${CHROOT}/usr/sbin/kldload-install-target"
stor="${CHROOT}/usr/lib/kldload-installer/lib/storage-zfs.sh"
boot="${CHROOT}/usr/lib/kldload-installer/lib/bootloader.sh"

_guard() { # _guard <label> <file> <grep-ere>
    if grep -Eq "$3" "$2" 2>/dev/null; then
        _pass "$1"
    else
        _fail "$1" "pattern not found in $(basename "$2"): $3"
    fi
}

# install-target auto-pick must exclude the live disk
_guard "install-target excludes live disk in auto-pick" "${inst}" '!= "\$live"'
# autoinstall loop must skip both live medium and seed disk
_guard "autoinstall skips live medium" "${autoinstall}" '== "\$_live"'
_guard "autoinstall skips seed disk" "${autoinstall}" '== "\$_seed"'
# target-disk wipe must be fail-loud (verify + k_die), not swallowed
_guard "target wipe verifies and aborts if dirty" "${stor}" 'Refusing to install: could not clear'
# encrypted installs must use the visible-prompt kernel args (not hardcoded quiet)
_guard "direct menuentry uses \${_direct_bootargs}" "${boot}" 'ro \$\{_direct_bootargs\}'
if grep -Eq 'ro rhgb quiet spl_hostid' "${boot}" 2>/dev/null; then
    _fail "encrypted prompt" "direct menuentry re-hardcodes 'rhgb quiet' — encrypted prompt would be hidden"
else
    _pass "direct menuentry no longer hardcodes 'rhgb quiet'"
fi

# ─── the netboot unit and its tool must agree on the payload path ───────────
# A failed ConditionPathExists is SILENT: systemd skips the unit, `systemctl
# start` reports success, and is-active says inactive with no error anywhere.
#
# They disagreed. The tool moved its payload to /var/lib/kldload-netboot
# because rpool/kldload/state mounts at /var/lib/kldload and shadowed 5.1G
# written during the install (fiend, 2026-09-11), and the unit was left
# pointing at the old path. So the netboot server could never have started,
# on any machine, and nothing would have said why (found 2026-09-12).
_nb_tool="${CHROOT}/usr/local/sbin/kldload-netboot-server"
_nb_unit="${CHROOT}/usr/lib/systemd/system/kldload-netboot.service"
if [[ ! -r "$_nb_tool" || ! -r "$_nb_unit" ]]; then
    _fail "netboot unit/tool agreement" "tool or unit missing — this check DID NOT RUN"
else
    _nb_payload="$(sed -n 's/^PAYLOAD=//p' "$_nb_tool" | head -1)"
    _nb_cond="$(sed -n 's/^ConditionPathExists=//p' "$_nb_unit" | head -1)"
    _nb_exec="$(sed -n 's/^ExecStart=//p' "$_nb_unit" | head -1 | awk '{print $1}')"
    if [[ -z "$_nb_payload" || -z "$_nb_cond" ]]; then
        _fail "netboot unit/tool agreement" "could not read PAYLOAD ('${_nb_payload}') or ConditionPathExists ('${_nb_cond}')"
    elif [[ "${_nb_cond}" != "${_nb_payload}"/* ]]; then
        _fail "netboot unit/tool agreement" \
            "unit waits on ${_nb_cond} but the tool serves ${_nb_payload} — the unit will be SKIPPED silently"
    else
        _pass "netboot: unit condition (${_nb_cond}) sits under the tool's payload (${_nb_payload})"
    fi
    # The unit has to point at a tool that actually ships in the image.
    if [[ -x "${CHROOT}${_nb_exec}" ]]; then
        _pass "netboot: ExecStart ${_nb_exec} ships and is executable"
    else
        _fail "netboot ExecStart" "${_nb_exec} is not an executable in includes.chroot"
    fi
    # And build-iso has to carry the unit into the rootfs: the copy loop is a
    # `[[ -f ]] && cp`, which skips in silence.
    if grep -q 'kldload-netboot.service' "${ROOT}/builder/build-iso.sh"; then
        _pass "netboot: build-iso carries the unit into the image"
    else
        _fail "netboot unit" "build-iso.sh never copies kldload-netboot.service — it would not reach the ISO"
    fi
fi

# ─── kldload-hba: the report has to be USABLE, not just present ──────────────
# Two defects, both of which produced output that looked fine:
#   - the device column was a fixed 26 while a real by-id name runs 31-45, so
#     every row printed a path that does not exist, and fiend's five identical
#     8TB Seagates all rendered as the same string (2026-09-12);
#   - `json` emitted host and controllers only. `.drives` was NULL, and
#     `null|length` is 0 in jq, so a consumer counting drives got a plausible
#     number instead of an error.
# Both are checked here against THIS machine's real disks.
hba="${CHROOT}/usr/local/sbin/kldload-hba"
if [[ ! -x "$hba" ]]; then
    _fail "kldload-hba" "not executable at $hba"
elif ! command -v jq >/dev/null 2>&1; then
    _fail "kldload-hba json" "jq is missing — this check DID NOT RUN"
else
    _hba_json="$(mktemp)"
    if ! "$hba" json >"${_hba_json}" 2>/dev/null; then
        _fail "kldload-hba json" "exited non-zero"
    elif ! jq -e . "${_hba_json}" >/dev/null 2>&1; then
        _fail "kldload-hba json" "not valid JSON"
    else
        _pass "kldload-hba json: valid"
        # Arrays, not null: `jq .drives|length` must fail loudly when the key
        # is absent rather than answering 0.
        for _k in controllers drives enclosures; do
            if jq -e "has(\"${_k}\") and (.${_k}|type == \"array\")" "${_hba_json}" >/dev/null 2>&1; then
                _pass "kldload-hba json: .${_k} is an array"
            else
                _fail "kldload-hba json" ".${_k} is missing or not an array"
            fi
        done
        # Every by_id must name a link that EXISTS. This is the truncation
        # guard: a clipped path still looks like a path, which is what made the
        # old output dangerous rather than merely ugly.
        _bad=0
        while IFS= read -r _id; do
            [[ -z "$_id" || "$_id" == "-" ]] && continue
            [[ "$_id" == *-part* ]] && continue
            # A kernel name (sda, nvme0n1) is the documented fallback when the
            # disk has no by-id link at all, so accept /dev/<name> too.
            [[ -e "/dev/disk/by-id/${_id}" || -e "/dev/${_id}" ]] || {
                _bad=$((_bad + 1))
                printf '      truncated or bogus device id: %s\n' "$_id" >&2
            }
        done < <(jq -r '.drives[].by_id' "${_hba_json}" 2>/dev/null)
        if [[ ${_bad} -eq 0 ]]; then
            _pass "kldload-hba: every device id resolves to a real path"
        else
            _fail "kldload-hba device ids" "${_bad} id(s) name nothing on this machine"
        fi
        # The table and the JSON must agree on how many drives there are.
        _tbl="$("$hba" drives 2>/dev/null | sed -n 's/^\([0-9]\+\) drive(s)$/\1/p')"
        _jsn="$(jq '.drives|length' "${_hba_json}" 2>/dev/null)"
        if [[ -n "${_tbl}" && "${_tbl}" == "${_jsn}" ]]; then
            _pass "kldload-hba: table and json agree (${_jsn} drives)"
        else
            _fail "kldload-hba" "table says '${_tbl}' drives, json says '${_jsn}'"
        fi
    fi
    rm -f "${_hba_json}"
fi

# ─── summary ─────────────────────────────────────────────────────────────────
printf "\n  \e[1m%d passed\e[0m, %s\n" "${PASS}" \
    "$([[ ${FAILN} -gt 0 ]] && printf '\e[1;31m%d failed\e[0m' "${FAILN}" || printf '0 failed')"
[[ ${FAILN} -eq 0 ]]
