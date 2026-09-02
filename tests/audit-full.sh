#!/usr/bin/env bash
# audit-full.sh — comprehensive post-install audit
# Usage: audit-full.sh <ip> <password>
set -uo pipefail

IP="${1:?Usage: audit-full.sh <ip> [password]}"

# The password goes to sshpass through the ENVIRONMENT, never argv. `sshpass -p`
# puts the credential in the process table, where any local user's `ps` reads it
# -- and this script forks one sshpass per check, so a full audit sprays it a
# hundred times. `-e` reads $SSHPASS instead.
#
# Precedence: $SSHPASS if the caller already exported one, else $2, else the
# documented default install password. Passing it as $2 still exposes it in this
# script's OWN argv and in shell history, so prefer:
#     SSHPASS=... ./audit-full.sh 10.100.10.106
export SSHPASS="${SSHPASS:-${2:-Passw0rd}}"
SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no admin@${IP}"

pass=0
fail=0
skip=0
ok() {
    printf '\e[32m  ✓ %-35s %s\e[0m\n' "$1" "$2"
    ((pass++))
}
bad() {
    printf '\e[31m  ✗ %-35s %s\e[0m\n' "$1" "$2"
    ((fail++))
}
skp() {
    printf '\e[33m  ○ %-35s %s\e[0m\n' "$1" "$2"
    ((skip++))
}

# Output that means "this did not work" no matter what the exit status claims.
#
# WHY this exists: nearly every probe here ends in `| head -1`, and a pipeline's
# status is the LAST command's. `nosuchtool --version | head -1` therefore exits
# 0 with bash's own error message as its output. Several probes then made it
# worse with `|| echo missing`, which forces 0 by construction. The 2026-09-02
# run on fiend scored 53/53 while reporting, verbatim and in green:
#     btop -> "missing"
#     bat  -> "bash: line 1: bat: command not found"
#     kdir -> "kdir: error: unknown option: --"
# A gate that cannot fail is decoration. Where the exit status has been thrown
# away by a pipe, the CONTENT is the only honest signal left.
_BROKEN_RE='command not found|No such file or directory|not installed|^missing$|not in EPEL|unknown option|error:'

check() {
    local name="$1" cmd="$2"
    local out rc
    out="$(
        set +e
        $SSH "$cmd" 2>&1
        echo "RC:$?"
    )"
    rc="${out##*RC:}"
    out="${out%RC:*}"
    out="$(echo "$out" | sed '/^$/d' | head -1)"
    if [[ "$rc" -ne 0 ]]; then
        bad "$name" "${out:-(no output)}"
    elif [[ -z "$out" ]]; then
        # Silence is not success. A version probe that printed nothing did not
        # tell us the tool is fine, it told us nothing -- and that used to score
        # as a pass under "(empty output)".
        bad "$name" "(no output — probe told us nothing)"
    elif [[ "$out" =~ $_BROKEN_RE ]]; then
        bad "$name" "$out"
    else
        ok "$name" "$out"
    fi
}

# check_tool <label> <binary> [version args]
#
# The honest form of a tool probe: `command -v` is a HARD gate whose failure
# cannot be masked by a downstream pipe, and only then does the version command
# run. No `|| echo missing` fallback -- a fallback is how the probe learns to
# always pass.
check_tool() {
    # `${3-...}`, NOT `${3:-...}`: the colon form treats an EMPTY third argument
    # as unset, so `check_tool kdir kdir ""` -- meaning "this tool takes no flag"
    # -- silently became `kdir --version` and failed on a flag kdir does not
    # have. The distinction is the whole point of passing an empty string here.
    local name="$1" bin="$2" args="${3---version}"
    # Blank lines are dropped BEFORE head, on the remote. kst and kdf open their
    # output with an empty line for spacing, so a bare `head -1` returned that
    # blank and the tool scored as "(no output)" while working perfectly.
    check "$name" "command -v ${bin} >/dev/null && ${bin} ${args} 2>&1 | grep -v '^[[:space:]]*$' | head -1"
}

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  kldloadOS Full Audit — ${IP}"
echo "══════════════════════════════════════════════════════════════"
echo ""

echo "── OS ──────────────────────────────────────────────────────"
check "OS release" "sed -n '1p' /etc/os-release"
check "Kernel" "uname -r"
check "Hostname" "hostname 2>/dev/null || hostnamectl hostname 2>/dev/null || cat /etc/hostname"

echo ""
echo "── ZFS ─────────────────────────────────────────────────────"
check "ZFS module loaded" "lsmod | grep -q zfs && echo loaded"
check "ZFS version" "zfs version | head -1"
check "Pool health" "zpool status -x"
check "Pool list" "zpool list -H -o name,health | head -1"
check "Dataset hierarchy" "zfs list -H | wc -l | xargs printf '%s datasets'"
check "Compression" "zfs get -H -o value compression rpool | head -1"
check "Snapshots" "zfs list -t snapshot -H 2>/dev/null | wc -l | xargs printf '%s snapshots'"

echo ""
echo "── kldload Tools ───────────────────────────────────────────"
# kst, kdf, kdir and ksnap print their banner or usage on a BARE invocation and
# reject --help outright ("kdir: error: unknown option: --"). Probing them with
# --help measures the flag, not the tool. That the flag is missing at all is a
# real gap against the "--help is the contract" rule, tracked separately -- it
# is not something this probe should invent a failure for.
check_tool "kst" "kst" ""
check "kst-dashboard" "command -v kst-dashboard && echo found"
check_tool "ksnap" "ksnap" ""
check "kclone" "command -v kclone && echo found"
check_tool "kdf" "kdf" ""
check_tool "kdir" "kdir" ""
check_tool "kpkg" "kpkg" "help"
check_tool "kexport" "kexport" ""
check "kldload-help" "kldload-help 2>/dev/null | grep -c 'kldloadOS' | xargs printf '%s lines matched'"
check "kbe" "command -v kbe && echo found"
check "krecovery" "command -v krecovery && echo found"
check "kupgrade" "command -v kupgrade && echo found"

echo ""
echo "── Modern CLI ──────────────────────────────────────────────"
check_tool "fzf" "fzf"
# btop is NOT checked: it was deliberately removed from every install in build
# #51 (d769013), replaced by kst-dashboard's tmux panes, because leaving it in
# produced "I dropped btop but it is still on the install" reports (.135,
# 2026-06-05). This probe outlived that decision by three months and went on
# demanding a tool the project had chosen not to ship -- scoring it green the
# whole time, because `|| echo missing` made the check unfailable.
check_tool "eza" "eza"
check_tool "ripgrep (rg)" "rg"
# fd is `fdfind` on Debian/Ubuntu -- a real name difference, not a fallback
check "fd" "command -v fd >/dev/null && fd --version 2>&1 | head -1 || { command -v fdfind >/dev/null && fdfind --version 2>&1 | head -1; }"
check_tool "zoxide" "zoxide"
check_tool "fastfetch" "fastfetch"
# bat ships as `batcat` on Debian/Ubuntu; both names are checked, neither is
# allowed to fall through to a string that scores as a pass.
check "bat" "command -v bat >/dev/null && bat --version 2>&1 | head -1 || { command -v batcat >/dev/null && batcat --version 2>&1 | head -1; }"
check_tool "tmux" "tmux" "-V"

echo ""
echo "── Services ────────────────────────────────────────────────"
check "sshd" "systemctl is-active sshd"
check "zfs-zed" "systemctl is-active zfs-zed"
check "sanoid.timer" "systemctl is-active sanoid.timer"
check "NetworkManager" "systemctl is-active NetworkManager"

echo ""
echo "── Sanoid ──────────────────────────────────────────────────"
check_tool "sanoid binary" "sanoid"
check "syncoid binary" "command -v syncoid && echo found"
check "sanoid config" "test -f /etc/sanoid/sanoid.conf && echo exists"
check "sanoid timer unit" "test -f /lib/systemd/system/sanoid.timer && echo exists || test -f /usr/lib/systemd/system/sanoid.timer && echo exists"

echo ""
echo "── Networking ──────────────────────────────────────────────"
check "WireGuard" "wg --version 2>&1 | head -1 || echo missing"
check "nftables" "command -v nft && echo found"
check "IP address" "ip -4 addr show scope global | grep inet | head -1 | awk '{print \$2}'"

echo ""
echo "── eBPF ────────────────────────────────────────────────────"
check "bpftool" "command -v bpftool && echo found || echo 'not installed (optional)'"
check "bpftrace" "command -v bpftrace && echo found || echo 'not installed (optional)'"
check "execsnoop" "command -v execsnoop && echo found || command -v execsnoop-bpfcc && echo found || echo 'not installed (optional)'"

echo ""
echo "── Cloud / Export ──────────────────────────────────────────"
check "cloud-init" "cloud-init --version 2>&1 | head -1 || echo missing"
check "qemu-img" "qemu-img --version 2>&1 | head -1 || echo missing"

echo ""
echo "── Desktop ─────────────────────────────────────────────────"
check ".desktop files" "ls /usr/share/applications/k*.desktop 2>/dev/null | wc -l | xargs printf '%s entries'"
check "tmux config" "grep -c 'prefix' ~/.tmux.conf 2>/dev/null | xargs printf '%s prefix lines'"
check ".bashrc fzf" "grep -c fzf ~/.bashrc 2>/dev/null | xargs printf '%s fzf refs'"
check ".bashrc eza" "grep -c eza ~/.bashrc 2>/dev/null | xargs printf '%s eza refs'"
check ".bashrc fastfetch" "grep -c fastfetch ~/.bashrc 2>/dev/null | xargs printf '%s fastfetch refs'"
check "vim colorscheme" "test -f ~/.vim/colors/kldload.vim && echo exists || echo missing"

echo ""
echo "══════════════════════════════════════════════════════════════"
printf "  Results: \e[32m%d passed\e[0m  \e[31m%d failed\e[0m  \e[33m%d skipped\e[0m\n" "$pass" "$fail" "$skip"
echo "══════════════════════════════════════════════════════════════"
echo ""
