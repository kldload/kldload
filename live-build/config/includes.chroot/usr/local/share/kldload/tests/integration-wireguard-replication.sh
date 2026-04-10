#!/bin/bash
# integration-wireguard-replication.sh
# End-to-end test: set up WireGuard between two kldloadOS nodes,
# create data, replicate over the tunnel, verify on the other side.
#
# Usage: ./integration-wireguard-replication.sh user password nodeA_ip nodeB_ip
set -euo pipefail

USER="${1:?Usage: $0 user password nodeA_ip nodeB_ip}"
PASS="${2:?}"
NODE_A="${3:?}"
NODE_B="${4:?}"

WG_A="10.99.0.1"
WG_B="10.99.0.2"
WG_PORT="51820"

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no"
SCP="sshpass -p $PASS scp -o StrictHostKeyChecking=no -q"

run_a() { $SSH ${USER}@${NODE_A} "echo '$PASS' | sudo -S bash -c '$1'" 2>/dev/null; }
run_b() { $SSH ${USER}@${NODE_B} "echo '$PASS' | sudo -S bash -c '$1'" 2>/dev/null; }

PASS_COUNT=0
FAIL_COUNT=0
_pass() { PASS_COUNT=$((PASS_COUNT+1)); printf "\e[1;32m  ✓ PASS\e[0m  %s\n" "$1"; }
_fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf "\e[1;31m  ✗ FAIL\e[0m  %s — %s\n" "$1" "$2"; }

clear
printf "\e[1;36m╔══════════════════════════════════════════════════════════╗\e[0m\n"
printf "\e[1;36m║  Integration Test: WireGuard + ZFS Replication           ║\e[0m\n"
printf "\e[1;36m╚══════════════════════════════════════════════════════════╝\e[0m\n"
echo ""
printf "  Node A: %s → wg0: %s\n" "$NODE_A" "$WG_A"
printf "  Node B: %s → wg0: %s\n" "$NODE_B" "$WG_B"
echo ""

# ── Step 1: Generate WireGuard keys ──────────────────────────────────────────
printf "\e[1;36m  ── Step 1: Generate WireGuard keys ──────────────────────\e[0m\n"

KEY_A_PRIV=$(run_a "wg genkey")
KEY_A_PUB=$(echo "$KEY_A_PRIV" | $SSH ${USER}@${NODE_A} "echo '$PASS' | sudo -S wg pubkey" 2>/dev/null)
KEY_B_PRIV=$(run_b "wg genkey")
KEY_B_PUB=$(echo "$KEY_B_PRIV" | $SSH ${USER}@${NODE_B} "echo '$PASS' | sudo -S wg pubkey" 2>/dev/null)

if [[ -n "$KEY_A_PUB" && -n "$KEY_B_PUB" ]]; then
  _pass "Keys generated (A: ${KEY_A_PUB:0:8}... B: ${KEY_B_PUB:0:8}...)"
else
  _fail "Key generation" "failed to generate WireGuard keys"
  exit 1
fi

# ── Step 2: Configure WireGuard on both nodes ────────────────────────────────
printf "\n\e[1;36m  ── Step 2: Configure WireGuard tunnels ──────────────────\e[0m\n"

run_a "cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = ${WG_A}/24
ListenPort = ${WG_PORT}
PrivateKey = ${KEY_A_PRIV}

[Peer]
PublicKey = ${KEY_B_PUB}
AllowedIPs = ${WG_B}/32
Endpoint = ${NODE_B}:${WG_PORT}
PersistentKeepalive = 25
WGEOF
chmod 600 /etc/wireguard/wg0.conf"

run_b "cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = ${WG_B}/24
ListenPort = ${WG_PORT}
PrivateKey = ${KEY_B_PRIV}

[Peer]
PublicKey = ${KEY_A_PUB}
AllowedIPs = ${WG_A}/32
Endpoint = ${NODE_A}:${WG_PORT}
PersistentKeepalive = 25
WGEOF
chmod 600 /etc/wireguard/wg0.conf"

_pass "WireGuard configs written"

# ── Step 3: Bring up tunnels ─────────────────────────────────────────────────
printf "\n\e[1;36m  ── Step 3: Bring up WireGuard tunnels ───────────────────\e[0m\n"

run_a "wg-quick up wg0 2>&1 || true"
run_b "wg-quick up wg0 2>&1 || true"
sleep 3

# Test connectivity
if run_a "ping -c 2 -W 3 ${WG_B}" | grep -q "2 received"; then
  _pass "Node A can ping Node B over WireGuard (${WG_A} → ${WG_B})"
else
  _fail "WireGuard connectivity" "ping from A to B failed"
fi

if run_b "ping -c 2 -W 3 ${WG_A}" | grep -q "2 received"; then
  _pass "Node B can ping Node A over WireGuard (${WG_B} → ${WG_A})"
else
  _fail "WireGuard connectivity" "ping from B to A failed"
fi

# Check handshakes
HANDSHAKE_A=$(run_a "wg show wg0 latest-handshakes | awk '{print \$2}'")
if [[ -n "$HANDSHAKE_A" && "$HANDSHAKE_A" != "0" ]]; then
  _pass "WireGuard handshake established"
else
  _fail "WireGuard handshake" "no handshake detected"
fi

# ── Step 4: Set up SSH keys for replication ──────────────────────────────────
printf "\n\e[1;36m  ── Step 4: Set up SSH keys for replication ──────────────\e[0m\n"

run_a "ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -q 2>/dev/null || true"
PUBKEY_A=$(run_a "cat /root/.ssh/id_ed25519.pub")
run_b "mkdir -p /root/.ssh && echo '${PUBKEY_A}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
_pass "SSH key distributed (A → B)"

# Test SSH over WireGuard
if run_a "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${WG_B} echo ok 2>/dev/null" | grep -q "ok"; then
  _pass "SSH over WireGuard works (A → B via ${WG_B})"
else
  _fail "SSH over WireGuard" "cannot SSH from A to B over tunnel"
fi

# ── Step 5: Create test data on Node A ───────────────────────────────────────
printf "\n\e[1;36m  ── Step 5: Create test data on Node A ───────────────────\e[0m\n"

run_a "zfs create -o mountpoint=/srv/repltest rpool/srv/repltest 2>/dev/null || true"
run_a "echo 'kldloadOS replication test - $(date)' > /srv/repltest/testfile.txt"
run_a "dd if=/dev/urandom of=/srv/repltest/random.bin bs=1M count=5 2>/dev/null"
run_a "zfs snapshot rpool/srv/repltest@test1"

SIZE_A=$(run_a "du -sh /srv/repltest/ | cut -f1")
_pass "Test data created on Node A ($SIZE_A)"
_pass "Snapshot rpool/srv/repltest@test1 created"

# ── Step 6: Replicate over WireGuard ────────────────────────────────────────
printf "\n\e[1;36m  ── Step 6: Replicate over WireGuard tunnel ──────────────\e[0m\n"

REPL_START=$(date +%s)
if run_a "zfs send rpool/srv/repltest@test1 | ssh -o StrictHostKeyChecking=no root@${WG_B} zfs receive -F rpool/srv/repltest-replica 2>&1"; then
  REPL_END=$(date +%s)
  REPL_TIME=$((REPL_END - REPL_START))
  _pass "ZFS replication completed in ${REPL_TIME}s over WireGuard"
else
  _fail "ZFS replication" "zfs send | ssh zfs receive failed"
fi

# ── Step 7: Verify replicated data ──────────────────────────────────────────
printf "\n\e[1;36m  ── Step 7: Verify replicated data on Node B ─────────────\e[0m\n"

if run_b "zfs list rpool/srv/repltest-replica" >/dev/null 2>&1; then
  _pass "Replica dataset exists on Node B"
else
  _fail "Replica dataset" "rpool/srv/repltest-replica not found on Node B"
fi

# Verify file content matches
HASH_A=$(run_a "sha256sum /srv/repltest/testfile.txt | awk '{print \$1}'")
HASH_B=$(run_b "sha256sum /srv/repltest-replica/testfile.txt | awk '{print \$1}'")

if [[ "$HASH_A" == "$HASH_B" && -n "$HASH_A" ]]; then
  _pass "File checksum matches (${HASH_A:0:16}...)"
else
  _fail "File checksum" "A=${HASH_A:0:16} B=${HASH_B:0:16} — data mismatch"
fi

HASH_BIN_A=$(run_a "sha256sum /srv/repltest/random.bin | awk '{print \$1}'")
HASH_BIN_B=$(run_b "sha256sum /srv/repltest-replica/random.bin | awk '{print \$1}'")

if [[ "$HASH_BIN_A" == "$HASH_BIN_B" && -n "$HASH_BIN_A" ]]; then
  _pass "Binary file checksum matches (5MB random data)"
else
  _fail "Binary checksum" "data mismatch on random.bin"
fi

SIZE_B=$(run_b "du -sh /srv/repltest-replica/ | cut -f1")
_pass "Replica size on Node B: $SIZE_B"

# ── Step 8: Incremental replication ──────────────────────────────────────────
printf "\n\e[1;36m  ── Step 8: Incremental replication ──────────────────────\e[0m\n"

run_a "echo 'incremental update - $(date)' >> /srv/repltest/testfile.txt"
run_a "zfs snapshot rpool/srv/repltest@test2"

if run_a "zfs send -i rpool/srv/repltest@test1 rpool/srv/repltest@test2 | ssh -o StrictHostKeyChecking=no root@${WG_B} zfs receive -F rpool/srv/repltest-replica 2>&1"; then
  _pass "Incremental replication succeeded (@test1 → @test2)"
else
  _fail "Incremental replication" "failed"
fi

# Verify incremental data
HASH_A2=$(run_a "sha256sum /srv/repltest/testfile.txt | awk '{print \$1}'")
HASH_B2=$(run_b "sha256sum /srv/repltest-replica/testfile.txt | awk '{print \$1}'")

if [[ "$HASH_A2" == "$HASH_B2" && -n "$HASH_A2" ]]; then
  _pass "Incremental data verified"
else
  _fail "Incremental verification" "checksums don't match after incremental send"
fi

# ── Step 9: Cleanup ──────────────────────────────────────────────────────────
printf "\n\e[1;36m  ── Step 9: Cleanup ──────────────────────────────────────\e[0m\n"

run_a "zfs destroy -r rpool/srv/repltest 2>/dev/null || true"
run_b "zfs destroy -r rpool/srv/repltest-replica 2>/dev/null || true"
run_a "wg-quick down wg0 2>/dev/null || true"
run_b "wg-quick down wg0 2>/dev/null || true"
run_a "rm -f /etc/wireguard/wg0.conf"
run_b "rm -f /etc/wireguard/wg0.conf"
_pass "Test data and WireGuard configs cleaned up"

# ── Summary ──────────────────────────────────────────────────────────────────
TOTAL=$((PASS_COUNT + FAIL_COUNT))
printf "\n\e[1;36m  ══════════════════════════════════════════════════════════\e[0m\n"
printf "  \e[1mResults:\e[0m  %d passed  " "$PASS_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && printf "\e[1;31m%d failed\e[0m  " "$FAIL_COUNT"
printf "(%d total)\n" "$TOTAL"

if [[ $FAIL_COUNT -eq 0 ]]; then
  printf "\n  \e[1;32m✓ FULL STACK VERIFIED: WireGuard tunnel + ZFS replication\e[0m\n"
  printf "  \e[1;32m  Two kldloadOS nodes, encrypted backplane, data replicated.\e[0m\n"
fi
printf "\e[1;36m  ══════════════════════════════════════════════════════════\e[0m\n\n"

[[ $FAIL_COUNT -eq 0 ]]
