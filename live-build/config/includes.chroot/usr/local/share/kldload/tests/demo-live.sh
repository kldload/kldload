#!/usr/bin/env bash
# demo-live.sh — live demo driver for FOSS talk
# Run this from the build machine. The audience watches VNC.
# Usage: demo-live.sh <ip> [password]
set -euo pipefail

IP="${1:?Usage: demo-live.sh <ip> [password]}"
PW="${2:-Passw0rd}"
SSH="sshpass -p ${PW} ssh -o StrictHostKeyChecking=no admin@${IP}"
TMUX_SEND="$SSH tmux send-keys -t kldload"

pause() { echo ""; echo "  [Press Enter to continue]"; read -r; }
narrate() { printf '\n\e[1;36m  ▸ %s\e[0m\n' "$*"; }
type_cmd() {
  # Type command character by character into tmux for dramatic effect
  local cmd="$1"
  $SSH "tmux send-keys -t kldload -l ''" 2>/dev/null || true
  for (( i=0; i<${#cmd}; i++ )); do
    local char="${cmd:$i:1}"
    $SSH "tmux send-keys -t kldload -l '$char'" 2>/dev/null
    sleep 0.04
  done
  sleep 0.3
  $TMUX_SEND Enter
}

clear
echo ""
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║  kldloadOS Live Demo — FOSS Conference                   ║"
echo "  ║  Driving: admin@${IP} via SSH                     ║"
echo "  ║  Audience sees: VNC desktop with tmux                    ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "  Make sure the VM is showing tmux on VNC before starting."
echo ""
pause

# ── Act 1: System Health ──
narrate "Act 1: System health at a glance"
pause
type_cmd "kst"
sleep 3
pause

# ── Act 2: ZFS ──
narrate "Act 2: ZFS — the filesystem that doesn't lose data"
pause
type_cmd "zpool status"
sleep 2
type_cmd "zfs list"
sleep 2
type_cmd "kdf"
sleep 2
pause

# ── Act 3: Snapshots ──
narrate "Act 3: Snapshots — undo anything"
pause
type_cmd "ksnap"
sleep 2
type_cmd "echo 'important data' > /tmp/testfile && cat /tmp/testfile"
sleep 1
type_cmd "ksnap list"
sleep 2
pause

# ── Act 4: Clone ──
narrate "Act 4: Clone 500GB in 0.1 seconds"
pause
type_cmd "kclone /home/admin /home/admin-clone"
sleep 1
type_cmd "zfs list | grep clone"
sleep 2
pause

# ── Act 5: Modern Tools ──
narrate "Act 5: Modern CLI — not your grandfather's terminal"
pause
type_cmd "fastfetch"
sleep 3
type_cmd "ll"
sleep 2
type_cmd "btop"
sleep 4
$TMUX_SEND q
sleep 1
pause

# ── Act 6: WireGuard ──
narrate "Act 6: WireGuard — encrypted mesh in 20 lines"
pause
type_cmd "wg --version"
sleep 1
type_cmd "cat /etc/wireguard/wg0.conf 2>/dev/null || echo 'WireGuard ready — configure with wg-quick'"
sleep 2
pause

# ── Act 7: Help ──
narrate "Act 7: Built-in command reference"
pause
type_cmd "kldload-help"
sleep 5
pause

# ── Act 8: AI Assistant ──
narrate "Act 8: The AI that knows your infrastructure"
narrate "Watch — the AI reads the system state and responds."
pause
type_cmd "kai 'what is the health of my ZFS pool and what should I check?'"
sleep 15
pause

narrate "Ask it anything..."
pause
type_cmd "kai 'how do I replicate this system to a backup server over WireGuard?'"
sleep 15
pause

narrate "It can diagnose problems..."
pause
type_cmd "kai 'my ARC hit rate seems low, what should I tune?'"
sleep 15
pause

# ── Act 9: Image Export ──
narrate "Act 9: One install, every platform"
pause
type_cmd "kexport --help"
sleep 3
pause

# ── Finale ──
narrate "That was kldloadOS."
narrate "10 operating systems. One USB. Offline. AI-powered."
narrate "Download it. See for yourself. kldload.com"
echo ""
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║                    Du-Nn!                                ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo ""
