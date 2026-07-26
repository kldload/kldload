# zexplore — the ZFS console + the ZFS-transaction API

Status: **layers 1–5 SHIPPED** (2026-07-25). Console `8caf461`, web-console
backend `994fa23`, web-console SPA `a4a0d81`, VM-explore + transaction API
`b9ff58e`, commander `6c70c49`. All proven on .111. Only layer 6 (tmux hub)
remains. This doc captures the full vision so the marathon stays coherent.

## Thesis

Everything in kldload is ZFS — datasets, boot environments, VM zvols. So **one
console manages it all**, and ZFS's cheap snapshots + send/recv become a
developer-grade primitive. zexplore is "k9s for ZFS": the human + programmatic layer
on top of sanoid (which keeps taking/pruning snapshots underneath — zexplore never
prunes sanoid's; it flags `autosnap_*` so ad-hoc vs automatic is obvious).

Mental model: **Midnight Commander × WinSCP × ssh**, ZFS-native.

## Layers (build order)

### 1. Console CLI — ✅ v1 SHIPPED (`/usr/local/bin/zexplore`)
fzf-driven browser: datasets/snapshots (used/refer/#snaps/sanoid), snapshot on
tap, **point-and-shoot replicate** (incremental when a common snap exists, else
full; mbuffer/pv; readonly+noauto target so replicas never drift; local pool OR
`host:pool` over ssh). Subcommands double as fzf key-binds + are CI-usable.
Proven on .111 scratch pools (incremental snap1→snap2 onto a readonly target).

### 2. Dual-pane commander — ✅ SHIPPED (`zexplore mc`, 6c70c49)
Left pane / right pane, each a *location* (local, or a remote host over ssh),
browsing pools→datasets→snapshots→BEs→**VM zvols**. F5 = replicate selection to
the other pane. F8 = destroy. Enter = drill. MC muscle memory. tmux-hosted (fits
the k9s/zexplore/VM-console tmux hub).

### 3. VM-zvol explore — ✅ SHIPPED (`zexplore browse <zvol>`, b9ff58e)
Point zexplore at `rpool/vms`: browse a VM's filesystem by cloning/mounting its zvol
read-only, snapshot/restore a VM "on tap." Wired into the VM tool too.

### 4. zexplore API + guest agent — ✅ SHIPPED (b9ff58e; design below)
Guest VMs / apps perform **their own** snapshots + rollbacks via a scoped,
authenticated host API. "Instant rollback as a function."

### 5. ZFS web console — ✅ SHIPPED (a4a0d81; Pools/Datasets/Snapshots)
Pools (topology/errors/scan/disk-replace — backend built), Datasets, Snapshots,
Replication, Performance (ARC/iostat), merge the tests-zfs Lab view.

### 6. zexplore in the tmux hub
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

**Guest CLI (`zexplore-txn`), the app-facing primitive:**
```
zexplore-txn begin [--zvol data]   # host snapshots the VM's (data) zvol → txn id
zexplore-txn rollback <txn>        # host rolls back to the snapshot (mode below)
zexplore-txn commit <txn>          # keep the change, drop the snapshot
zexplore-txn list                  # open transactions
```
Composable: `zexplore-txn begin && migrate.sh && test.sh || zexplore-txn rollback`.

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

---

## zexplore v2 — the UI design (locked 2026-07-26)

Renamed from z9fs (which aped k9s / implied a polished-TUI framework). **zexplore
advertises what it is: a direct interface to ZFS primitives, not a dashboard.**

### Three surfaces, one set of primitives
- **Terminal TUI** — the locked 3-pane below (build FIRST).
- **Clickable web GUI** — like the k8s cockpit; expand the ZFS web console SPA
  (Pools/Datasets/Snapshots already shipped) to the same 4 sections.
- **Programmatic API** — zexplore-api/-txn ("instant rollback as a function").

Different audiences, trivial marginal cost → ship all three.

### Portability (the pitch beyond kldload)
Core = plain `zfs`/`zpool` → runs on ANY ZFS box (Linux/BSD). kldload detected →
light up extras (zexplore-api txns, sanoid-awareness, the WireGuard mesh for
remotes, delegation presets, offline/darksite). Vanilla → plain `ssh`, plain
`zfs allow`. Nothing kldload-specific is required; all additive.

### The locked 3-pane layout (terminal) — kills the drill-down nav
```
┌ F1 Filesystems  F2 Transfer  F3 Restore  F4 Pools ─────────────┐
│ PANE 1 (left)        │ PANE 2 (right-top)                       │
│ source: zpool/zfs    │ Filesystems: the detail dossier          │
│ list, navigable      │ Transfer:    TARGET (ssh host / VM)      │
│                      ├──────────────────────────────────────────┤
│                      │ PANE 3 (right-bottom): pane-aware TERM    │
└──────────────────────┴──────────────────────────────────────────┘
```
Stable frame; F-keys switch the section, arrows/type-filter within a pane.
Filesystems mode: pane2 = the dossier (properties + both permission layers).
Transfer mode (FTP-analog): pane1 = LOCAL source, pane2 = REMOTE/VM target.

### The pane-aware terminal (the killer feature)
Pane 3 is a REAL shell — raw zfs/zpool/ssh all work — but it also knows the two
panes. Selections publish to shared state; the shell exposes `$SRC`/`$DST`
(+ `$SRC_HOST`/`$DST_HOST`) and helper verbs that auto-populate from them:
```
replicate      # zfs send $SRC | ssh $DST_HOST zfs recv $DST   (incremental)
copy / snap / rollback / clone / hold …
```
Navigate pane1→source, pane2→target, type `replicate` — done. Or type the full
command yourself. MC's "the command line knows the panels," for ZFS.
Ex: on fiend, pane1 = onyx (ssh) → onyx:rpool/opt/webserver; pane2 = local
fiend:zpool/webserver; `replicate` sends onyx→fiend with paths filled.

### The 4 sections + gaps folded in
- **F1 Filesystems** — datasets/zvols + dossier; + encryption&keys, delegation
  (`zfs allow` grant/revoke), sharing (NFS/SMB/iSCSI) as first-class actions.
- **F2 Transfer** — the 3-pane replicate/copy/manage (local↔remote↔VM).
- **F3 Restore points** — snapshots + boot environments; rollback/clone/hold/
  bookmark; + `zfs diff` (what changed).
- **F4 Pools** — status/iostat/scrub/trim/vdev+disk ops; + events/errors (ZED).

### zexplore-demo (like kube-demo)
Scripted walkthrough of every feature = **demo + functional test + video**. Uses
onyx (kldload) + a `zexp` user with seamless SSH keys to show remote replication.
Runs each primitive, asserts success. Build after the terminal 3-pane lands.
