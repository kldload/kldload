#!/usr/bin/env bash
# lifecycle-matrix.sh — run tests/lifecycle.sh across the (distro, profile)
# matrix that 1.1.0-dev needs to claim "consistent install across distros."
#
# Each cell spins a throwaway KVM, drives the install headlessly, reboots,
# runs smoke-auto.sh on the booted target. Collects results into a single
# pass/fail table at the end.
#
# Usage:
#   sudo tests/lifecycle-matrix.sh                    # full default matrix
#   sudo tests/lifecycle-matrix.sh centos rocky       # subset of distros
#   sudo PROFILES="core server" tests/lifecycle-matrix.sh
#   sudo PARALLEL=1 tests/lifecycle-matrix.sh         # serialize (debug)
#
# Env knobs:
#   DISTROS    default: centos rocky fedora debian ubuntu
#              (RHEL skipped — needs subscription cert)
#              (Arch/Alpine skipped — separate failure modes, not in default)
#   PROFILES   default: core server kvm desktop
#   PARALLEL   default: 2 (each VM = 8GB RAM + 4 cores; 2 fits 21GB host)
#   RESULTS_DIR default: /tmp/lifecycle-matrix-<UTC>
#
# Output:
#   $RESULTS_DIR/<distro>-<profile>.log   per-cell full lifecycle log
#   $RESULTS_DIR/<distro>-<profile>.bundle.tar.gz  on-failure debug bundle
#   $RESULTS_DIR/RESULTS.md               final markdown table
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 0 ]]; then
  DISTROS=("$@")
else
  read -ra DISTROS <<<"${DISTROS:-centos rocky fedora debian ubuntu}"
fi
read -ra PROFILES <<<"${PROFILES:-core server kvm desktop}"
PARALLEL="${PARALLEL:-2}"
TS="$(date -u +%Y%m%d-%H%M%SZ)"
RESULTS_DIR="${RESULTS_DIR:-/tmp/lifecycle-matrix-${TS}}"
mkdir -p "$RESULTS_DIR"

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
C_CYN=$'\033[1;36m'; C_RST=$'\033[0m'
say() { printf '%s[%s]%s %s\n' "$C_CYN" "$(date +%H:%M:%S)" "$C_RST" "$*"; }

# Build the cell list — every (distro, profile) pair
CELLS=()
for d in "${DISTROS[@]}"; do
  for p in "${PROFILES[@]}"; do
    CELLS+=("${d}/${p}")
  done
done
say "matrix: ${#CELLS[@]} cells (${#DISTROS[@]} distros × ${#PROFILES[@]} profiles), parallel=${PARALLEL}"
say "results → $RESULTS_DIR"

# ── Per-cell driver — runs lifecycle.sh, captures result + bundle on fail ────
run_cell() {
  local cell="$1"
  local distro="${cell%/*}"
  local profile="${cell#*/}"
  local cell_log="$RESULTS_DIR/${distro}-${profile}.log"
  local cell_status_file="$RESULTS_DIR/${distro}-${profile}.status"

  say "  start: $cell"
  local t0=$(date +%s)
  local rc=0
  # KEEP_VM=1 only if the cell fails — lifecycle.sh handles this internally
  # (always leaves VM on failure). We pass VM_NAME so multiple cells in
  # parallel don't collide.
  VM_NAME="kldload-mtx-${distro}-${profile}" \
    bash "$ROOT/tests/lifecycle.sh" "$distro" "$profile" \
    >"$cell_log" 2>&1 || rc=$?

  local elapsed=$(( $(date +%s) - t0 ))
  if [[ $rc -eq 0 ]]; then
    echo "PASS $elapsed" > "$cell_status_file"
    say "  ${C_GRN}PASS${C_RST} $cell  (${elapsed}s)"
  else
    echo "FAIL $elapsed rc=$rc" > "$cell_status_file"
    # On failure, lifecycle.sh leaves the VM running — pull a debug bundle
    # for offline analysis without re-ssh'ing.
    local vm="kldload-mtx-${distro}-${profile}"
    local vm_ip
    vm_ip="$(virsh domifaddr "$vm" 2>/dev/null \
              | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)"
    if [[ -n "$vm_ip" ]]; then
      sshpass -p admin scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "admin@${vm_ip}:/root/kldload-debug-*.tar.gz" \
        "$RESULTS_DIR/${distro}-${profile}.bundle.tar.gz" 2>/dev/null || true
    fi
    say "  ${C_RED}FAIL${C_RST} $cell  (${elapsed}s, rc=$rc) — log: $cell_log"
  fi
}

# ── Run cells in batches of $PARALLEL ────────────────────────────────────────
i=0
while [[ $i -lt ${#CELLS[@]} ]]; do
  batch=()
  for ((j=0; j<PARALLEL && i+j<${#CELLS[@]}; j++)); do
    batch+=("${CELLS[$((i+j))]}")
  done
  say "batch: ${batch[*]}"
  pids=()
  for cell in "${batch[@]}"; do
    run_cell "$cell" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  i=$((i + ${#batch[@]}))
done

# ── Final results table ──────────────────────────────────────────────────────
{
  echo "# Lifecycle matrix results — ${TS}"
  echo
  echo "Run from: $(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo unknown)"
  echo "Parallel: $PARALLEL"
  echo
  echo "| Distro | Profile | Status | Elapsed | Log |"
  echo "|---|---|---|---|---|"
  for cell in "${CELLS[@]}"; do
    distro="${cell%/*}"; profile="${cell#*/}"
    status_file="$RESULTS_DIR/${distro}-${profile}.status"
    if [[ -f "$status_file" ]]; then
      read -r status elapsed _ <"$status_file"
      bundle=""
      [[ -f "$RESULTS_DIR/${distro}-${profile}.bundle.tar.gz" ]] \
        && bundle=" [bundle](${distro}-${profile}.bundle.tar.gz)"
      echo "| $distro | $profile | **$status** | ${elapsed}s | [log](${distro}-${profile}.log)$bundle |"
    else
      echo "| $distro | $profile | SKIP | - | - |"
    fi
  done
  echo
  pass=$(grep -l '^PASS' "$RESULTS_DIR"/*.status 2>/dev/null | wc -l)
  fail=$(grep -l '^FAIL' "$RESULTS_DIR"/*.status 2>/dev/null | wc -l)
  total=${#CELLS[@]}
  echo "**Summary**: ${pass}/${total} pass, ${fail}/${total} fail"
} > "$RESULTS_DIR/RESULTS.md"

cat "$RESULTS_DIR/RESULTS.md"
echo
say "results: $RESULTS_DIR/RESULTS.md"
