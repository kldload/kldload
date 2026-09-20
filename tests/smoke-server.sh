#!/bin/bash
# smoke-server.sh — verify a kldloadOS SERVER profile install
# Tests everything in core PLUS: k* tools, webui, sanoid, snapshots, wireguard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-test.sh"

DISTRO=$(detect_distro)

export TERM=xterm
clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  kldloadOS Smoke Test — SERVER profile                   ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Distro family: %s\n" "$DISTRO"
printf "  Hostname:      %s\n" "$(cat /etc/hostname 2>/dev/null)"
printf "  Kernel:        %s\n" "$(uname -r)"
echo ""

# ── Run core tests first ─────────────────────────────────────────────────────
# (inline the critical ones, don't recurse to avoid double summary)

_section "ZFS (base)"
test_output_contains "Pool rpool ONLINE" "zpool list -H -o health rpool" "ONLINE"
test_output_contains "Zero errors" "zpool status rpool" "No known data errors"
test_output_contains "bootfs set" "zpool get -H -o value bootfs rpool" "rpool/ROOT/"
test_succeeds "EFI mounted" "mountpoint -q /boot/efi"
test_file "Hostid" "/etc/hostid"

_section "SSH & Network"
test_service_active "sshd" "sshd"
# Captured, not piped: `| grep -q` under pipefail is rc=141 when grep
# exits first (see the SSH check in smoke-core.sh).
test_succeeds "Has IP" '[[ "$(ip -4 addr show 2>/dev/null)" == *"inet "* ]]'
test_succeeds "DNS works" "getent hosts github.com"

# ── k* Tools ─────────────────────────────────────────────────────────────────
_section "kldloadOS Tools"

test_cmd "kst (status)" "kst"
test_cmd "ksnap (snapshots)" "ksnap"
test_cmd "kbe (boot environments)" "kbe"
test_cmd "kclone (CoW cloning)" "kclone"
test_cmd "kdf (disk usage)" "kdf"
test_cmd "kdir (dataset creation)" "kdir"
test_cmd "kpkg (package manager)" "kpkg"
test_cmd "kupgrade (safe upgrade)" "kupgrade"
test_cmd "kexport (image export)" "kexport"
test_cmd "krecovery (disaster recovery)" "krecovery"
test_cmd "kldload-help" "kldload-help"
test_cmd "kldload-overview" "kldload-overview"
test_cmd "kube-demo" "kube-demo"

# Test kst runs without error
test_succeeds "kst executes" "kst >/dev/null 2>&1"

# Test ksnap list works
test_succeeds "ksnap list runs" "ksnap list >/dev/null 2>&1"

# Test kdf runs
test_succeeds "kdf executes" "kdf >/dev/null 2>&1"

# Test kpkg detects package manager
test_succeeds "kpkg detects pkg manager" "kpkg help >/dev/null 2>&1"

# ── Web UI ───────────────────────────────────────────────────────────────────
_section "Web UI"

test_file "kldload-webui binary" "/usr/local/bin/kldload-webui"
test_service_enabled "kldload-webui enabled" "kldload-webui"

# Check if webui responds (may be inactive on server profile but should be enabled)
if systemctl is-active kldload-webui >/dev/null 2>&1; then
    _pass "kldload-webui running"
    # The web UI listens on a unix socket and nginx fronts it on :8443. This check
    # curled :8080 for months after that move and failed on every server edition
    # where the service is active (7-net, fiend 2026-09-13), while both the socket and
    # :8443 answered 200. :8080 is Open WebUI's port, checked further down.
    test_succeeds "WebUI responds on its socket" "curl -sf --max-time 5 --unix-socket /run/kldload/webui.sock http://localhost/ >/dev/null 2>&1"
    test_succeeds "WebUI responds through nginx on :8443" "curl -skf --max-time 5 https://localhost:8443/ >/dev/null 2>&1"
else
    _warn "kldload-webui running" "service not active (may need manual start)"
fi

# ── Sanoid / Automatic Snapshots ─────────────────────────────────────────────
_section "Automatic Snapshots"

test_cmd "sanoid installed" "sanoid"
test_file "sanoid config" "/etc/sanoid/sanoid.conf"
test_service_enabled "sanoid.timer enabled" "sanoid.timer"

if systemctl is-active sanoid.timer >/dev/null 2>&1; then
    _pass "sanoid.timer running"
else
    _warn "sanoid.timer running" "timer not active"
fi

# ── WireGuard ────────────────────────────────────────────────────────────────
_section "WireGuard"

test_cmd "wg command" "wg"
test_cmd "wg-quick command" "wg-quick"
test_output_contains "WireGuard module available" "modprobe wireguard && lsmod" "wireguard"

# ── Package Snapshot Integration ─────────────────────────────────────────────
_section "Package Snapshot Integration"

check_kpkg_snapshot

# Check if a kpkg snapshot exists
if zfs list -t snapshot -H -o name 2>/dev/null | grep -q "kpkg-"; then
    _pass "kpkg snapshot naming (kpkg-*)"
else
    _warn "kpkg snapshot naming" "no kpkg-* snapshot found"
fi

# ── Boot Environment Test ────────────────────────────────────────────────────
_section "Boot Environment"

BE_NAME="smoketest-be-$(date +%Y%m%d-%H%M%S)"
if kbe create "$BE_NAME" >/dev/null 2>&1; then
    _pass "kbe create works ($BE_NAME)"
else
    _fail "kbe create" "failed to create boot environment"
fi

# Do not throw kbe's stderr away here. This check warned "new BE not visible"
# on install after install with no way to tell WHICH of three very different
# things had happened: kbe list failed outright, kbe create lied about
# succeeding, or the BE exists and only the listing missed it. On fiend .117
# (2026-09-01) the warning fired while the snapshot was demonstrably on disk,
# and the same sequence run by hand a minute later passed -- so the useful
# information was in the stderr this line was discarding.
_be_err="$(mktemp)"
_be_out="$(kbe list 2>"$_be_err")" && _be_rc=0 || _be_rc=$?
# grep -c exits 1 when the count is 0, and 0 is a perfectly valid answer here
# -- it is the answer that distinguishes "kbe create lied" from "listing bug".
_be_ondisk="$(zfs list -t snapshot -H -o name 2>/dev/null | grep -c "$BE_NAME" || true)"
if ((_be_rc != 0)); then
    _fail "kbe list" "exited ${_be_rc}: $(head -1 "$_be_err")"
elif grep -q "$BE_NAME" <<<"$_be_out"; then
    _pass "kbe list shows new BE"
elif [[ "$_be_ondisk" == "0" ]]; then
    _fail "kbe list" "kbe create reported success but ${BE_NAME} is on neither kbe list nor disk"
else
    _warn "kbe list" "${BE_NAME} is on disk but absent from kbe list ($(grep -c . <<<"$_be_out") rows) — listing bug, not data loss"
fi
rm -f "$_be_err"

# Clean up
kbe delete "$BE_NAME" >/dev/null 2>&1 || true

# ── Darksite ─────────────────────────────────────────────────────────────────
# Darksite is intentionally REMOVED on first boot by kldload-firstboot
# (lines 2052-2068 in /usr/sbin/kldload-firstboot) to reclaim ~1.8G —
# only the install phase needs it. ZFSBootMenu binary lives at
# /boot/efi/EFI/zbm/ (signed, MOK-verified), NOT inside the darksite
# tree (that was an old layout). So presence here is a regression.
_section "Darksite (post-firstboot cleanup)"
test_succeeds "darksite repo file removed" \
    "[[ ! -f /etc/yum.repos.d/kldload-darksite.repo ]]"
# LAN mirror opt-in: when /etc/kldload/keep-darksite exists, the admin kept
# darksite at install time as a network-accessible package mirror for other
# machines. In that case it SHOULD still be there and the service active.
#
# Otherwise firstboot reclaims it -- but it reclaims the PACKAGE MIRRORS only
# (5.8G -> 3.3G) and deliberately KEEPS the helm charts for offline k8s
# deploys, so /root/darksite itself survives by design. The old assertion here
# was `[[ ! -d /root/darksite ]]`, unconditionally: it therefore failed on
# every correctly reclaimed install (.101 left /root/darksite/helm-charts,
# 2026-08-21) and, in keep-darksite mode, directly contradicted the test_dir
# three lines below it. Assert what firstboot actually promises instead.
if [[ -f /etc/kldload/keep-darksite ]]; then
    test_dir "LAN mirror mode: darksite kept" "/root/darksite"
    test_service_active "LAN mirror service" "kldload-apt-mirror"
    if [[ "$DISTRO" == "deb" ]]; then
        test_dir "APT darksite" "/root/darksite/debian/apt"
        test_file "APT Release file" "/root/darksite/debian/apt/dists/trixie/Release"
    fi
else
    test_succeeds "darksite package mirrors reclaimed (firstboot)" \
        "[[ ! -d /root/darksite/debian/apt && ! -d /root/darksite/rpms ]]"
fi
# ZBM EFI lives at the canonical EFI System Partition path, not inside
# /root/darksite (old layout). Verify it's where the bootloader actually
# expects to find it.
test_file "ZFSBootMenu EFI on ESP" "/boot/efi/EFI/zbm/BOOTX64.EFI"

# ── ZFS Console (zxplore) ─────────────────────────────────────────────────────
# zxplore-tui is part of the OS on every tool-bearing profile (static binary,
# built from github.com/zxplore/zxplore at ISO build, copied to the target by
# the zxplore* glob in profiles.sh). A missing binary here means the build's
# bake step or the installer copy regressed.
_section "ZFS Console"
test_cmd "zxplore-tui" "zxplore-tui"
if zxplore-tui --version 2>/dev/null | grep -q '^zxplore'; then
    _pass "zxplore-tui --version reports"
else
    _fail "zxplore-tui --version" "no version output"
fi
test_file "zxplore commit breadcrumb" "/etc/kldload/zxplore-commit"

# ── eBPF / Observability ──────────────────────────────────────────────────────
_section "eBPF / Observability"

# The eBPF tools are installed only when the install asked for them
# (KLDLOAD_ENABLE_EBPF=1); first boot stopped pulling them in regardless on
# 2026-09-14. So check them only then, the same way Secure Boot is checked.
_ebpf_requested=0
grep -qE '^KLDLOAD_ENABLE_EBPF="?1"?$' /etc/kldload/install-manifest.env 2>/dev/null && _ebpf_requested=1
if ((_ebpf_requested)); then
    if [[ "$DISTRO" == "deb" ]]; then
        test_cmd "bpftrace" "bpftrace"
        test_cmd "bpftool" "bpftool"
        if [[ -f /usr/sbin/execsnoop-bpfcc ]] || command -v execsnoop-bpfcc >/dev/null 2>&1; then
            _pass "execsnoop (bpfcc-tools)"
        elif command -v execsnoop >/dev/null 2>&1; then
            _pass "execsnoop"
        else
            _warn "execsnoop" "not found — install bpfcc-tools"
        fi
        test_cmd "perf" "perf"
    else
        if [[ -d /usr/share/bcc/tools ]]; then
            _pass "bcc-tools directory"
            test_file "execsnoop (bcc)" "/usr/share/bcc/tools/execsnoop"
            test_file "tcplife (bcc)" "/usr/share/bcc/tools/tcplife"
            test_file "opensnoop (bcc)" "/usr/share/bcc/tools/opensnoop"
        else
            _warn "bcc-tools" "not found — install bcc-tools"
        fi
        test_cmd "bpftrace" "bpftrace"
    fi
else
    _pass "eBPF tools not expected: this install did not request eBPF"
fi

if [[ -f /sys/kernel/btf/vmlinux ]]; then
    _pass "BTF available (eBPF CO-RE)"
else
    _warn "BTF" "/sys/kernel/btf/vmlinux not found"
fi

if command -v bpftrace >/dev/null 2>&1; then
    # Captured, then searched, with room to start. HISTORY: fiend 2026-09-13
    # (Secure Boot, lockdown=integrity): the same probe as `timeout 3 bpftrace
    # | grep -q ok` passed in one smoke-all run and warned in the next, on a
    # host where bpftrace takes 280 ms idle. Under the full suite's load the
    # BTF parse can outlast 3 s, and under pipefail grep's early exit can turn
    # a match into a failure. Neither says anything about eBPF.
    _bt_out="$(timeout 20 bpftrace -e 'BEGIN { printf("ok\n"); exit(); }' 2>/dev/null)" || _bt_out=""
    if grep -qx "ok" <<<"$_bt_out"; then
        _pass "bpftrace executes"
    else
        _warn "bpftrace execution" "failed — may need root or BTF"
    fi
fi

# ── NVIDIA (optional) ────────────────────────────────────────────────────────
_section "NVIDIA (optional)"

if command -v nvidia-smi >/dev/null 2>&1; then
    _pass "nvidia-smi found"
    if nvidia-smi >/dev/null 2>&1; then
        _pass "nvidia-smi executes (GPU detected)"
    else
        _warn "nvidia-smi" "no GPU detected (expected in VM)"
    fi
else
    _pass "NVIDIA not installed (expected if checkbox not selected)"
fi

# ── AI (Open WebUI) ────────────────────────────────────────────
# Open WebUI IS the AI surface. There is no kldload-side assistant layer on
# top of it: the `bob` CLI and the standalone RAG service on :8400 were
# removed in 6dd32240 (docs/bob-deprecation.md), and the later attempt to
# recreate Bob as a workspace model inside Open WebUI was backed out too —
# Open WebUI's own chat, model picker and retrieval cover it, and a second
# assistant layer was one more thing to keep working for no gain.
#
# WHY THIS SECTION WAS REWRITTEN: it asserted that whole deleted stack —
# /usr/local/bin/bob, /usr/local/lib/kldload-rag/*.py, chromadb, the four
# kldload-rag-* units and their enable symlinks, and a health endpoint on
# :8400. All gone by design, so a correctly built machine failed twelve
# checks here. .101 reported 14 smoke failures on 2026-08-21 and every one
# was this section plus the darksite check above — noise that trains an
# operator to stop reading the report, which is how a real failure gets
# missed.
_section "AI (Open WebUI)"

# Ollama backs the chat models Open WebUI serves.
if command -v ollama >/dev/null 2>&1; then
    _pass "Ollama CLI"
    # An ollama that is not up yet answers nothing; the empty case is handled
    # explicitly below as a warning rather than a failure.
    _tags="$(curl -sf --max-time 3 http://localhost:11434/api/tags 2>/dev/null || true)"
    if [[ -n "$_tags" ]]; then
        _pass "Ollama API responds"
        # Answering /api/tags with an empty model list is a chat box that
        # cannot chat. Count the models, and where there is one, make it
        # actually generate: "the API responds" and "the model works" are
        # different claims, and only the second is what a user needs
        # (2026-09-20). No model is the NORMAL state on an install that did
        # not pull one -- said plainly rather than passed over in silence.
        _models="$(printf '%s' "$_tags" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(len(d.get("models",[])))' 2>/dev/null || echo 0)"
        if [[ "${_models:-0}" == 0 ]]; then
            _warn "Ollama model" "no model pulled — the chat box has nothing to answer with (expected unless KLDLOAD_AI_PULL_MODEL=1)"
        else
            # Malformed JSON here means no name to test with, handled as an
            # empty _first by the generate call below.
            # Malformed JSON leaves _first empty, which the generate call treats
            # as "no model to test" rather than erroring.
            _first="$(printf '%s' "$_tags" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models"][0]["name"])' 2>/dev/null || true)"
            # 120s: a first generation loads the weights from disk.
            _payload="$(printf '{"model":"%s","prompt":"Reply with the single word: ok","stream":false}' "$_first")"
            # A model that cannot answer returns nothing or an error body, and
            # both are judged by the grep below rather than by curl's status.
            _gen="$(curl -sf --max-time 120 http://localhost:11434/api/generate -d "$_payload" 2>/dev/null || true)"
            if printf '%s' "$_gen" | grep -q '"response"'; then
                _pass "Ollama generates: ${_models} model(s), ${_first} answered a prompt"
            else
                _fail "Ollama generate" "${_models} model(s) installed and ${_first} did not answer a prompt"
            fi
        fi
    else
        _warn "Ollama API responds" "ollama service may not be running yet"
    fi
else
    _warn "Ollama CLI" "not installed -- Open WebUI will have no models to serve"
fi

# Open WebUI runs as a podman container with --network host, so it binds the
# host's 127.0.0.1:8080 directly and `podman port` lists nothing published —
# that is expected, not a fault. Operators reach it through nginx at /ai/ on
# 8443; the box has no listener on 443, so probing 443 yields a connection
# refused that looks exactly like a broken proxy.
if curl -sf --max-time 4 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    _pass "Open WebUI responds (127.0.0.1:8080)"
    if [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost:8443/ai/ 2>/dev/null)" == "200" ]]; then
        _pass "Open WebUI proxied at https://<host>:8443/ai/"
    else
        _fail "Open WebUI proxied at /ai/" "nginx is not serving the /ai/ route on 8443"
    fi
else
    _warn "Open WebUI responds" "container not up yet -- it starts on demand"
fi

# ── System Files ─────────────────────────────────────────────────────────────
_section "System Files"

test_file "Edition marker" "/etc/kldload/edition"
test_file "Profile marker" "/etc/kldload/profile"
test_file "Build ID" "/etc/kldload-build-id"
test_file "Build SHA" "/etc/kldload-build-sha"
test_file "Boot environment marker" "/etc/kldload/boot-environment"

# ── Summary ──────────────────────────────────────────────────────────────────
summary
