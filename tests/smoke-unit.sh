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
    # PAYLOAD is overridable now, so it reads PAYLOAD="${NETBOOT_PAYLOAD:-/path}".
    # Take the DEFAULT out of the parameter expansion; that is the path the unit
    # has to agree with, since the unit's condition cannot see an env override.
    _nb_payload="$(sed -n 's/^PAYLOAD=//p' "$_nb_tool" | head -1 |
        sed -e 's/^"//' -e 's/"$//' -e 's/^\${[A-Z_]*:-//' -e 's/}$//')"
    _nb_cond="$(sed -n 's/^ConditionPathExists=//p' "$_nb_unit" | head -1)"
    _nb_exec="$(sed -n 's/^ExecStart=//p' "$_nb_unit" | head -1 | awk '{print $1}')"
    if [[ -z "$_nb_payload" ]]; then
        _fail "netboot unit/tool agreement" "could not read PAYLOAD from the tool"
    elif [[ -z "$_nb_cond" ]]; then
        # No static condition is the CORRECT state: PAYLOAD is overridable, so
        # only the tool can check it, and it dies loudly when it is missing.
        _pass "netboot: unit carries no static payload condition (the tool checks, and can fail loudly)"
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

    # The LIVE image needs dnsmasq and the iPXE images too, or the key boots
    # carrying a netboot server it cannot run: serve dies staging the images.
    # That was the state until 2026-09-12 — the deps were on the TARGET list
    # only, so "burn one USB, provision the rack" needed a machine installed
    # first, which is the step nobody wants.
    # Matches the packages on an install line, not one exact command form: the
    # form changed once already (chroot+dnf could not resolve a mirror, so it
    # became dnf --installroot) and the gate went quiet rather than failing.
    if grep -qE 'dnsmasq ipxe-bootimgs-x86' "${ROOT}/builder/build-iso.sh"; then
        _pass "netboot: the Fedora live image installs dnsmasq + iPXE images"
    else
        _fail "netboot live deps (fedora)" "build-iso.sh does not install dnsmasq/ipxe-bootimgs-x86 — a booted key cannot serve PXE"
    fi
    # ...and in their OWN transaction, because the package set that carries the
    # kernel is all-or-nothing (steam-installer took linux-image with it,
    # fiend 2026-08-15).
    if grep -nE '^\s*(dnsmasq|ipxe-bootimgs-x86)\s*$' "${ROOT}/builder/build-iso.sh" >/dev/null 2>&1; then
        _fail "netboot live deps (fedora)" "dnsmasq/ipxe are in the PKGS array, which installs with the kernel — one unavailable package would abort the kernel too"
    else
        _pass "netboot: live deps stay out of the kernel's transaction"
    fi
    _nb_deb="${ROOT}/live-build/config/package-lists/live-base.list.chroot"
    if grep -qx 'dnsmasq' "$_nb_deb" && grep -qx 'ipxe' "$_nb_deb"; then
        _pass "netboot: the Debian live image lists dnsmasq + ipxe"
    else
        _fail "netboot live deps (debian)" "live-base.list.chroot is missing dnsmasq and/or ipxe"
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

_section "per-family package names (k_profile_optional_packages)"
# dnf matches names exactly. The diagnostics list carried only Debian spellings
# (openipmi, sg3-utils), so every RPM install shipped without OpenIPMI and
# sg3_utils (fiend 2026-09-14, 3-kvm). Run the real function per distro and
# check the spelling each family's repos resolve.
_pop_fn="$(sed -n '/^k_profile_optional_packages() {/,/^}/p' "${CHROOT}/usr/lib/kldload-installer/lib/profiles.sh")"
for _pd in fedora:OpenIPMI,sg3_utils,iotop-c:openipmi,sg3-utils \
    rocky:OpenIPMI,sg3_utils,iotop-c:openipmi,sg3-utils \
    debian:openipmi,sg3-utils,iotop-c:OpenIPMI,sg3_utils; do
    IFS=: read -r _d _want _never <<<"${_pd}"
    _got=" $(bash -c 'eval "$1"; KLDLOAD_DISTRO=$2 KLDLOAD_PROFILE=server k_profile_optional_packages' _ "${_pop_fn}" "${_d}" 2>/dev/null | tr -s ' \n' ' ') "
    _miss="" _wrong=""
    for _n in ${_want//,/ }; do [[ "${_got}" == *" ${_n} "* ]] || _miss+=" ${_n}"; done
    for _n in ${_never//,/ }; do [[ "${_got}" == *" ${_n} "* ]] && _wrong+=" ${_n}"; done
    if [[ -z "${_miss}${_wrong}" ]]; then
        _pass "${_d}: diagnostics use this family's package names"
    else
        _fail "${_d} package names" "missing:${_miss:- none}; other family's spelling:${_wrong:- none}"
    fi
done

_section "first-boot build screen (kldload-firstboot-show)"
# The operator's rule (fiend 2026-09-14): an install that builds Kubernetes or
# images keeps the show until the build settles; core/server/plain desktop come
# straight up. Exercise the real script: the decision, every settle outcome, and
# that log text reaching the console is stripped of control sequences and
# credentials.
_fbs="${CHROOT}/usr/local/sbin/kldload-firstboot-show"
if [[ ! -f "${_fbs}" ]]; then
    _fail "kldload-firstboot-show" "script missing from includes.chroot/usr/local/sbin"
else
    # /var/tmp, not /tmp: the kiosk probe asks `[[ -x ]]` of fake binaries, and
    # onyx mounts /tmp noexec, where access(X_OK) fails on any file (2026-09-14).
    _ft="$(mktemp -d -p /var/tmp)"
    mkdir -p "${_ft}/state/phases" "${_ft}/log" "${_ft}/root"
    echo 'root=zfs:rpool/ROOT/x quiet' >"${_ft}/cmdline"
    _fenv=(KLDLOAD_FBSHOW_STATE="${_ft}/state" KLDLOAD_FBSHOW_LOGDIR="${_ft}/log"
        KLDLOAD_FBSHOW_CMDLINE="${_ft}/cmdline" KLDLOAD_FBSHOW_ROOT="${_ft}/root"
        KLDLOAD_FBSHOW_VT=none KLDLOAD_FBSHOW_TTY="${_ft}/tty"
        KLDLOAD_FBSHOW_UNITSTATE='echo active' KLDLOAD_FBSHOW_COLS=100 KLDLOAD_FBSHOW_ROWS=30
        KLDLOAD_FBSHOW_JOURNAL=true)
    _fcheck() { env "${_fenv[@]}" KLDLOAD_FBSHOW_WANT="$1" bash "${_fbs}" check 2>/dev/null; }
    _fbad=""
    _fcheck 'echo k8s=1 klab=0 ai=0' || _fbad+=" k8s-install-not-shown"
    _fcheck 'echo k8s=0 klab=1 ai=0' || _fbad+=" klab-install-not-shown"
    # AI models count as build work since 2026-09-14 ("unless it's core, server or
    # a desktop with no options").
    _fcheck 'echo k8s=0 klab=0 ai=1' || _fbad+=" ai-install-not-shown"
    _fcheck 'echo k8s=0 klab=0 ai=0' && _fbad+=" plain-install-shown"
    _fcheck 'exit 3' && _fbad+=" shown-when-want-failed"
    echo 'root=zfs kldload.firstboot_show=0' >"${_ft}/cmdline"
    _fcheck 'echo k8s=1 klab=1 ai=0' && _fbad+=" escape-hatch-ignored"
    echo 'root=zfs quiet' >"${_ft}/cmdline"
    mkdir -p "${_ft}/root/run/live/medium"
    _fcheck 'echo k8s=1 klab=1 ai=0' && _fbad+=" shown-on-live"
    rm -r "${_ft}/root/run"
    if [[ -z "${_fbad}" ]]; then
        _pass "kldload-firstboot-show check: shows for k8s/klab/ai, not for plain installs, live or kldload.firstboot_show=0"
    else
        _fail "kldload-firstboot-show check" "wrong decision:${_fbad}"
    fi

    _fstatus() { env "${_fenv[@]}" bash "${_fbs}" status 2>/dev/null; }
    _fbad=""
    [[ "$(_fstatus)" == building ]] || _fbad+=" fresh!=building"
    printf 'done 1\n' >"${_ft}/state/phases/10-prereqs"
    printf 'running 2' >"${_ft}/state/phases/20-k8s"
    [[ "$(_fstatus)" == building ]] || _fbad+=" running!=building"
    printf 'failed 3\n' >"${_ft}/state/phases/20-k8s"
    [[ "$(_fstatus)" == problem ]] || _fbad+=" failed-phase!=problem"
    # partial on its own, with nothing failed on disk, or the failed-phase rule
    # above would answer for it.
    printf 'done 3\n' >"${_ft}/state/phases/20-k8s"
    printf 'pending 0\n' >"${_ft}/state/phases/30-ready"
    echo partial >"${_ft}/state/current-phase"
    [[ "$(_fstatus)" == problem ]] || _fbad+=" partial!=problem"
    echo ready >"${_ft}/state/current-phase"
    [[ "$(_fstatus)" == ok ]] || _fbad+=" ready!=ok"
    rm -f "${_ft}/state/current-phase" "${_ft}/state/phases/"*
    touch "${_ft}/state/firstboot-done" "${_ft}/state/autodeploy-skipped"
    [[ "$(_fstatus)" == ok ]] || _fbad+=" skipped!=ok"
    if [[ -z "${_fbad}" ]]; then
        _pass "kldload-firstboot-show status: building / problem / ok for each settle case"
    else
        _fail "kldload-firstboot-show status" "wrong outcome:${_fbad}"
    fi

    # The key header is assembled at run time. Written out literally, this file
    # carries a PEM private-key header, the image's private-key scan finds it in
    # /usr/local/share/kldload/tests and refuses to pack the ISO (build 17,
    # 2026-09-14) — which is the scan doing its job.
    _pkw="PRIVATE KEY"
    printf 'meter 10%%\e[A\e[1Gmeter 90%%\e[K\nreset \ec\e]2;owned\a here\npassword=Passw0rd token: abc123\n-----BEGIN OPENSSH %s-----\nAAAAsecret\n-----END OPENSSH %s-----\n' "${_pkw}" "${_pkw}" >"${_ft}/log/autodeploy.log"
    env "${_fenv[@]}" bash "${_fbs}" frame 2>/dev/null
    if grep -q 'Passw0rd\|abc123\|AAAAsecret\|owned' "${_ft}/tty"; then
        _fail "kldload-firstboot-show log panel" "a credential or an injected title reached the console"
    elif grep -q $'\ec' "${_ft}/tty"; then
        _fail "kldload-firstboot-show log panel" "a terminal reset from the log reached the console"
    elif ! grep -q 'meter 90%' "${_ft}/tty" || grep -q 'meter 10%' "${_ft}/tty"; then
        _fail "kldload-firstboot-show log panel" "a progress meter was not flattened to its last frame"
    else
        _pass "kldload-firstboot-show log panel: meters flattened, control sequences and credentials removed"
    fi
    # logtail: the output window follows the log being written NOW. 4-k8s, fiend
    # 2026-09-14: following autodeploy.log alone showed "waiting for
    # klab-firstboot" for 36 minutes while three goldens built in klab's logs.
    mkdir -p "${_ft}/inst" "${_ft}/klab" "${_ft}/run"
    _ftail() { # KLDLOAD_FBSHOW_JOURNAL defaults to an empty journal: the file fallback
        env "${_fenv[@]}" KLDLOAD_FBSHOW_INSTLOGDIR="${_ft}/inst" KLDLOAD_FBSHOW_INSTPHASE="${_ft}/run/install-phase" \
            KLDLOAD_FBSHOW_KLABLOGDIR="${_ft}/klab" KLDLOAD_FBSHOW_JOURNAL="${_fjournal:-true}" bash "${_fbs}" logtail 5 2>/dev/null
    }
    echo storage >"${_ft}/inst/storage.log"
    touch -d '-5 min' "${_ft}/inst/storage.log"
    echo 'installing kernel' >"${_ft}/inst/bootstrap.log"
    echo Storage >"${_ft}/run/install-phase"
    _fbad=""
    [[ "$(_ftail | head -1)" == "${_ft}/inst/bootstrap.log" ]] || _fbad+=" part1-not-newest-installer-log"
    rm -f "${_ft}/run/install-phase"
    touch -d '-8 min' "${_ft}/log/autodeploy.log"
    printf 'building fedora\nguest login: admin / kldload\n' >"${_ft}/klab/fedora-1.log"
    ln -s "${_ft}/klab/fedora-1.log" "${_ft}/klab/fedora-latest.log"
    touch -d '+1 min' "${_ft}/klab/fedora-latest.log" 2>/dev/null
    [[ "$(_ftail | head -1)" == "${_ft}/klab/fedora-1.log" ]] || _fbad+=" part2-not-klab-log"
    _ftail | grep -q 'admin / kldload' && _fbad+=" guest-login-shown"
    # Part 2 reads the build units' journal first: klab's log files hold only a
    # banner while the real output goes to stdout (fiend, 3-kvm on build 18).
    _fjout="$(_fjournal="printf 'Downloading debian cloud image\\nStarting install...\\npassword=hunter2\\n'" _ftail)"
    [[ "$(head -1 <<<"${_fjout}")" == "journal: first boot, autodeploy, klab" ]] || _fbad+=" part2-not-journal"
    grep -q 'Starting install' <<<"${_fjout}" || _fbad+=" journal-lines-missing"
    grep -q hunter2 <<<"${_fjout}" && _fbad+=" journal-not-redacted"
    echo Storage >"${_ft}/run/install-phase"
    _fjout="$(_fjournal="printf 'journal line\\n'" _ftail)"
    [[ "$(head -1 <<<"${_fjout}")" == "${_ft}/inst/bootstrap.log" ]] || _fbad+=" part1-read-the-journal"
    rm -f "${_ft}/run/install-phase"
    if [[ -z "${_fbad}" ]]; then
        _pass "kldload-firstboot-show logtail: installer log in part 1, build journal in part 2, redacted"
    else
        _fail "kldload-firstboot-show logtail" "${_fbad}"
    fi

    # Part 2 in a kiosk: run starts kldload-firstboot-kiosk.service only where it
    # can draw, falls back to the console screen when the unit gives up, and hands
    # tty1 back (a login prompt, unless a display manager takes it). systemctl is
    # a fake that records its calls.
    mkdir -p "${_ft}/root/usr/bin" "${_ft}/root/usr/lib/systemd/system" "${_ft}/root/dev/dri" "${_ft}/root/usr/lib64/security"
    touch "${_ft}/root/usr/bin/cage" "${_ft}/root/usr/bin/firefox" "${_ft}/root/dev/dri/card0" \
        "${_ft}/root/usr/lib64/security/pam_systemd.so" \
        "${_ft}/root/usr/lib/systemd/system/kldload-firstboot-kiosk.service"
    chmod +x "${_ft}/root/usr/bin/cage" "${_ft}/root/usr/bin/firefox"
    # rm -f on the glob hits the phases/ directory and set -e ends the suite
    # without a word (first run, 2026-09-14); delete the plain files only.
    find "${_ft}/state" -maxdepth 1 -type f -delete
    rm -rf "${_ft}/state/phases" && mkdir -p "${_ft}/state/phases"
    _frun() { # $1 = exit code of `systemctl is-enabled display-manager`, $2 = kiosk ActiveState
        : >"${_ft}/sysctl"
        rm -f "${_ft}/state/firstboot-show-done"
        env "${_fenv[@]}" KLDLOAD_FBSHOW_INTERVAL=0 KLDLOAD_FBSHOW_HOLD_OK=0 KLDLOAD_FBSHOW_MAXSEC=2 \
            KLDLOAD_FBSHOW_SYSTEMCTL="echo \"\$*\" >>'${_ft}/sysctl'; [[ \$1 == is-enabled ]] && exit $1; exit 0" \
            KLDLOAD_FBSHOW_UNITSTATE="[[ \$1 == kldload-firstboot-kiosk.service ]] && echo $2 || echo active" \
            KLDLOAD_FBSHOW_PAGEUP="${_fpage:-false}" \
            bash "${_fbs}" run 2>&1
    }
    _fbad=""
    touch "${_ft}/state/all-ready"
    _frun 1 active >/dev/null
    grep -qx 'start --no-block kldload-firstboot-kiosk.service' "${_ft}/sysctl" || _fbad+=" kiosk-not-started"
    grep -qx 'stop kldload-firstboot-kiosk.service' "${_ft}/sysctl" || _fbad+=" kiosk-not-stopped"
    grep -qx 'start --no-block getty@tty1.service' "${_ft}/sysctl" || _fbad+=" no-login-after-kiosk"
    [[ -e "${_ft}/state/firstboot-show-done" ]] || _fbad+=" done-marker-missing"
    _frun 0 active >/dev/null
    grep -q 'getty@tty1' "${_ft}/sysctl" && _fbad+=" getty-started-over-display-manager"
    rm -f "${_ft}/state/all-ready"
    # tty1 is handed to the kiosk only once its unit is active and the page answers.
    # Captured, not piped into grep -q: grep exits at the first match, the run
    # dies of SIGPIPE, and pipefail reports that as the test failing.
    _fout="$(_fpage=true _frun 1 active)"
    grep -q 'handing tty1 to the kiosk' <<<"${_fout}" || _fbad+=" tty1-not-handed-when-page-up"
    _fout="$(_fpage=false _frun 1 active)"
    grep -q 'handing tty1' <<<"${_fout}" && _fbad+=" tty1-handed-before-page"
    _fout="$(_frun 1 failed)"
    grep -q 'gave up' <<<"${_fout}" || _fbad+=" no-fallback-when-kiosk-failed"
    touch "${_ft}/state/all-ready"
    rm "${_ft}/root/dev/dri/card0"
    _frun 1 active >/dev/null
    grep -q firstboot-kiosk "${_ft}/sysctl" && _fbad+=" kiosk-started-without-drm"
    touch "${_ft}/root/dev/dri/card0"
    echo 'root=zfs kldload.firstboot_show=console' >"${_ft}/cmdline"
    _frun 1 active >/dev/null
    grep -q firstboot-kiosk "${_ft}/sysctl" && _fbad+=" console-cmdline-ignored"
    echo 'root=zfs quiet' >"${_ft}/cmdline"
    rm "${_ft}/root/usr/bin/firefox"
    _frun 1 active >/dev/null
    grep -q firstboot-kiosk "${_ft}/sysctl" && _fbad+=" kiosk-started-without-firefox"
    touch "${_ft}/root/usr/bin/firefox"
    rm "${_ft}/root/usr/lib64/security/pam_systemd.so"
    _frun 1 active >/dev/null
    grep -q firstboot-kiosk "${_ft}/sysctl" && _fbad+=" kiosk-started-without-pam_systemd"
    rm -f "${_ft}/state/all-ready"
    if [[ -z "${_fbad}" ]]; then
        _pass "kldload-firstboot-show run: kiosk only where it can draw, console fallback, tty1 handed back"
    else
        _fail "kldload-firstboot-show kiosk" "${_fbad}"
    fi

    # The installer carries the kiosk's packages only for installs that build, and
    # only for families whose offline mirror has cage and a real firefox package.
    _fpk() { # $1 want line, $2 distro
        KLDLOAD_LOG_DIR="${_ft}" KLDLOAD_STATE_DIR="${_ft}" KLDLOAD_FBSHOW_WANT="echo $1" \
            KLDLOAD_DISTRO="$2" KLDLOAD_PROFILE=kvm \
            bash -c 'source "$1" 2>/dev/null; k_profile_optional_packages' _ \
            "${CHROOT}/usr/lib/kldload-installer/lib/profiles.sh" 2>/dev/null | tr ' ' '\n'
    }
    _fbad=""
    _fpk "k8s=0 klab=1 ai=0" fedora | grep -qx cage || _fbad+=" fedora-build-no-cage"
    _fpk "k8s=0 klab=1 ai=0" fedora | grep -qx firefox || _fbad+=" fedora-build-no-firefox"
    _fpk "k8s=0 klab=0 ai=1" debian | grep -qx firefox-esr || _fbad+=" debian-ai-no-firefox-esr"
    _fpk "k8s=0 klab=1 ai=0" fedora | grep -qx systemd-pam || _fbad+=" fedora-build-no-systemd-pam"
    _fpk "k8s=0 klab=1 ai=0" debian | grep -qx libpam-systemd || _fbad+=" debian-build-no-libpam-systemd"
    _fpk "k8s=0 klab=0 ai=0" fedora | grep -qx cage && _fbad+=" plain-install-got-cage"
    _fpk "k8s=1 klab=1 ai=0" rocky | grep -qx cage && _fbad+=" el-claimed-cage"
    _fpk "k8s=1 klab=1 ai=0" ubuntu | grep -qxE 'cage|firefox' && _fbad+=" ubuntu-claimed-kiosk"
    if [[ -z "${_fbad}" ]]; then
        _pass "installer: kiosk packages (cage, firefox) only for installs that build, on Fedora and Debian"
    else
        _fail "installer kiosk packages" "${_fbad}"
    fi

    # The decision's input: autodeploy --want, run against fixture manifests.
    # It must answer from autodeploy's own rules and do none of the work.
    _fad="${CHROOT}/usr/sbin/kldload-autodeploy"
    _fwant() {
        printf '%s\n' "$@" >"${_ft}/m.env"
        AUTODEPLOY_TEST_MANIFEST="${_ft}/m.env" AUTODEPLOY_TEST_EFFECTIVE="${_ft}/none" bash "${_fad}" --want 2>/dev/null
    }
    _fbad=""
    [[ "$(_fwant KLDLOAD_PROFILE=server)" == "k8s=0 klab=0 ai=0" ]] || _fbad+=" server"
    [[ "$(_fwant KLDLOAD_PROFILE=kvm)" == "k8s=0 klab=1 ai=0" ]] || _fbad+=" kvm"
    [[ "$(_fwant KLDLOAD_TEMPLATE=k8s KLDLOAD_BUILD_IMAGES=1)" == "k8s=1 klab=1 ai=0" ]] || _fbad+=" k8s+images"
    [[ "$(_fwant KLDLOAD_PROFILE=desktop KLDLOAD_ENABLE_AI=1)" == "k8s=0 klab=0 ai=1" ]] || _fbad+=" desktop+ai"
    [[ "$(_fwant KLDLOAD_TEMPLATE=zfslab KLDLOAD_BUILD_IMAGES=0)" == "k8s=1 klab=0 ai=0" ]] || _fbad+=" zfslab-no-images"
    if [[ -z "${_fbad}" ]]; then
        _pass "kldload-autodeploy --want: answers from its own rules for server, kvm, k8s, desktop+AI, zfslab"
    else
        _fail "kldload-autodeploy --want" "wrong answer for:${_fbad}"
    fi
    rm -rf "${_ft}"
fi

# ─── a failed install reports itself ─────────────────────────────────────────
# kldload-install-target's EXIT trap was silently replaced in main, so a failed
# install neither cleaned up nor told anyone, and the install show played on over
# a dead installer for an hour (fiend, 2026-09-18). Run the real functions, taken
# from the script, through a failure, a success and a TERM.
_section "installer exit trap"
_it="${ROOT}/live-build/config/includes.chroot/usr/sbin/kldload-install-target"
_xt="$(mktemp -d)"
{
    sed -n '/^_emergency_cleanup() {/,/^}/p' "$_it"
    sed -n '/^k_publish_result() {/,/^}/p' "$_it"
    sed -n '/^_install_exit() {/,/^}/p' "$_it"
} >"${_xt}/funcs.sh"
if [[ "$(grep -c '() {' "${_xt}/funcs.sh")" -ne 3 ]]; then
    _fail "installer exit trap" "could not find _emergency_cleanup, k_publish_result and _install_exit in kldload-install-target"
elif ! grep -q "^    trap '_install_exit' EXIT" "$_it"; then
    _fail "installer exit trap" "main does not set trap '_install_exit' EXIT -- a failed install would not report"
else
    _xbad=""
    for _case in fail ok term; do
        rm -rf "${_xt}/run" "${_xt}/log" && mkdir -p "${_xt}/run" "${_xt}/log"
        printf '[t] ERROR: first\n[t] ERROR: the last error\n' >"${_xt}/log/kldload-installer.log"
        # swallow: the child is SUPPOSED to exit non-zero in two of the three cases
        bash -c 'set -Eeuo pipefail; K_PROGRESS_DIR=$1/run KLDLOAD_LOG_DIR=$1/log KLDLOAD_TARGET_MNT=$1/none
            umount() { :; }; zpool() { :; }; source "$1/funcs.sh"
            trap _install_exit EXIT; trap "exit 143" TERM
            case $2 in fail) exit 1 ;; ok) exit 0 ;; term) kill -TERM $$; sleep 5; echo carried-on >"$1/run/carried-on" ;; esac' \
            _ "$_xt" "$_case" >/dev/null 2>&1 || true
        _r="$(cat "${_xt}/run/install-result" 2>/dev/null || true)" # absent is the success case
        case "$_case" in
        fail) [[ "$_r" == $'failed\t1\t'*$'\tthe last error' ]] || _xbad+=" fail" ;;
        ok) [[ -z "$_r" ]] || _xbad+=" ok" ;;
        term) [[ "$_r" == $'failed\t143\t'* && ! -e "${_xt}/run/carried-on" ]] || _xbad+=" term" ;;
        esac
    done
    if [[ -z "$_xbad" ]]; then
        _pass "installer exit trap: failure writes install-result with the last ERROR, success writes none, TERM ends and reports"
    else
        _fail "installer exit trap" "wrong outcome for:${_xbad}"
    fi
fi
rm -rf "${_xt}"

# ─── summary ─────────────────────────────────────────────────────────────────
printf "\n  \e[1m%d passed\e[0m, %s\n" "${PASS}" \
    "$([[ ${FAILN} -gt 0 ]] && printf '\e[1;31m%d failed\e[0m' "${FAILN}" || printf '0 failed')"
[[ ${FAILN} -eq 0 ]]
