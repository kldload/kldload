# z9fs — the ZFS console + the ZFS-transaction API

Status: **layers 1–5 SHIPPED** (2026-07-25). Console `8caf461`, web-console
backend `994fa23`, web-console SPA `a4a0d81`, VM-explore + transaction API
`b9ff58e`, commander `6c70c49`. All proven on .111. Only layer 6 (tmux hub)
remains. This doc captures the full vision so the marathon stays coherent.

## Thesis

Everything in kldload is ZFS — datasets, boot environments, VM zvols. So **one
console manages it all**, and ZFS's cheap snapshots + send/recv become a
developer-grade primitive. z9fs is "k9s for ZFS": the human + programmatic layer
on top of sanoid (which keeps taking/pruning snapshots underneath — z9fs never
prunes sanoid's; it flags `autosnap_*` so ad-hoc vs automatic is obvious).

Mental model: **Midnight Commander × WinSCP × ssh**, ZFS-native.

## Layers (build order)

### 1. Console CLI — ✅ v1 SHIPPED (`/usr/local/bin/z9fs`)
fzf-driven browser: datasets/snapshots (used/refer/#snaps/sanoid), snapshot on
tap, **point-and-shoot replicate** (incremental when a common snap exists, else
full; mbuffer/pv; readonly+noauto target so replicas never drift; local pool OR
`host:pool` over ssh). Subcommands double as fzf key-binds + are CI-usable.
Proven on .111 scratch pools (incremental snap1→snap2 onto a readonly target).

### 2. Dual-pane commander — ✅ SHIPPED (`z9fs mc`, 6c70c49)
Left pane / right pane, each a *location* (local, or a remote host over ssh),
browsing pools→datasets→snapshots→BEs→**VM zvols**. F5 = replicate selection to
the other pane. F8 = destroy. Enter = drill. MC muscle memory. tmux-hosted (fits
the k9s/z9fs/VM-console tmux hub).

### 3. VM-zvol explore — ✅ SHIPPED (`z9fs browse <zvol>`, b9ff58e)
Point z9fs at `rpool/vms`: browse a VM's filesystem by cloning/mounting its zvol
read-only, snapshot/restore a VM "on tap." Wired into the VM tool too.

### 4. z9fs API + guest agent — ✅ SHIPPED (b9ff58e; design below)
Guest VMs / apps perform **their own** snapshots + rollbacks via a scoped,
authenticated host API. "Instant rollback as a function."

### 5. ZFS web console — ✅ SHIPPED (a4a0d81; Pools/Datasets/Snapshots)
Pools (topology/errors/scan/disk-replace — backend built), Datasets, Snapshots,
Replication, Performance (ARC/iostat), merge the tests-zfs Lab view.

### 6. z9fs in the tmux hub
Alongside k9s + VM consoles, sysdiag-style navigation.

## Layer 4 in detail — ZFS transactions as a developer primitive

**Why it's novel:** nobody exposes host ZFS snapshot/rollback to guests as a
transaction. It gives developers *instant, cheap, atomic rollback* of real state
(a DB, a deployed app) — snapshot → do risky thing → rollback-or-commit, as a
function call, in ~milliseconds (CoW), not a restore-from-backup.

**Mechanism:** the host owns `rpool/vms/<name>` (+ any data zvols). A guest can't
snapshot itself, so it *requests* the op from a host-side API, authenticated and
**scoped to its own zvols only** (a per-VM token injected at deploy via cloud-
init; the API refuses any dataset outside the caller's VM subtree).

**Transport (pick one; vsock preferred):**
- **vsock / virtio-serial** — private host↔guest channel, no network exposure;
  auth by the VM's vsock CID. Most secure.
- **network** — reuse the host webui API (already on :8443); per-VM bearer token.

**Guest CLI (`z9fs-txn`), the app-facing primitive:**
```
z9fs-txn begin [--zvol data]   # host snapshots the VM's (data) zvol → txn id
z9fs-txn rollback <txn>        # host rolls back to the snapshot (mode below)
z9fs-txn commit <txn>          # keep the change, drop the snapshot
z9fs-txn list                  # open transactions
```
Composable: `z9fs-txn begin && migrate.sh && test.sh || z9fs-txn rollback`.

**The hard constraint — you cannot roll back a zvol the guest is writing live.**
Two modes:
1. **Data-zvol (app-scoped, no reboot):** app data lives on a SEPARATE zvol.
   rollback = app quiesce (or fsfreeze) → guest unmounts data disk → host
   `zfs rollback` → guest remounts → app restart. Clean for "snapshot → DB
   migration → rollback."
2. **Boot-environment / reboot-onto-snapshot (whole-VM):** snapshot the OS zvol;
   rollback = reboot the VM into the snapshot (guest resets to pre-op state).
   The BE concept applied to VMs.

**Safety:** per-VM scoping (no cross-VM access), rate/quantity limits, an audit
log of every txn, and rollback always confirms unless `--force` (a CI flag).
sanoid stays the scheduled layer; txns are ad-hoc + short-lived.

**Killer demos:** DB migration with guaranteed rollback; ephemeral CI that
snapshots→tests→rolls-back in seconds; "golden dev state" you reset to on demand.

See [[k8s-cockpit-day2-roadmap]] (the parallel k8s work), [[reproducible-not-immutable]].
