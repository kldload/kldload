# vmxplore — the VM & cluster estate console (design)

Sister project to [zxplore](https://github.com/zxplore/zxplore) and
[wgxplore](https://github.com/wgxplore/wgxplore): own repo, BSD-3, runs on any
Linux with libvirt; kldload is its first-party distribution, not its owner.
Console #3 in the family — the one `WG-NETWORKS-DESIGN.md` already anticipated
when it said chassis extraction is what makes #3 cheap.

Status: **design, not started.** Nothing here is built.

---

## One sentence

**The ZFS-aware VM console**: one keyboard-driven view that joins every libvirt
domain to the zvol under it — its clone ancestry, its snapshot classes, its live
counters — because that join exists in no tool today, and without it a VM estate
on ZFS is two unrelated inventories you hold in your head.

Deliberately *not* pitched as "k9s for VMs." That niche is already occupied by
at least three TUIs (see Competitive honesty). The **ZFS join is the uncrowded
claim**, and it is the one worth building on.

---

## Universality — four tiers, and why it matters

The obvious objection to everything below: *if this is a superset of `klab`,
`kube-cluster`, `kldload-db` and the `k`-commands, isn't it just a kldload
tool wearing a sister-project badge?* Yes — if the kldload knowledge lives in
the core model. So it must not.

zxplore already solved this and the solution is about twenty-five lines. It
carries a `zfsKTools` list and an `IsKldload()` probe, does `exec.LookPath` per
tool, and lights up extras only for what it finds. The comment above it is the
whole design rule:

> `zfsKTools` are the kldload ZFS "k-commands" zxplore surfaces extra flair for
> when it detects them. **zxplore stays fully generic without them.**

`vmx` inherits exactly that, in four tiers that each degrade cleanly:

| Tier | Needs | What it gives | Audience |
|---|---|---|---|
| **1. libvirt** | any libvirt host | domains, state, stats, NICs, guest agent, serial console, start/stop/snapshot | anyone — a competent standalone KVM manager |
| **2. + local ZFS** | disks are zvols | **the join**: backing dataset, `origin` lineage, snapshot classification, instant clone-from-golden, orphan reconciliation | libvirt-on-ZFS |
| **3. + reachable peers** | ZFS on a second host + ssh (WireGuard if present) | **VM teleport** — point-and-shoot a running VM to another machine and boot it there | anyone with two ZFS hosts |
| **4. + kldload** | detected `k`-commands | estate grouping, `com.kldload:clone-origin`, `kldload-db`/kspawn reconciliation, delegation to `klab`/`kube-cluster` | kldload |

Tiers 2–3 are the identity. Tier 1 alone is a commodity (see Competitive
honesty); tier 4 alone is a subdirectory of this repo.

**Gate on capability, not identity.** Tier 3 must *not* be `if IsKldload()`.
kldload merely **guarantees** the substrate — ZFS everywhere, WireGuard mesh,
ssh — so on kldload it simply always lights up. Anyone else with two ZFS boxes
and an ssh key gets the same feature. This repo has already learned this lesson
once the hard way: `build-iso.sh` used to gate the GUI build on
`PROFILE == desktop` and so missed the `kvm` profile, and was fixed by detecting
`libGL.so.1` instead. Same rule here. `IsKldload()` earns its keep only for
cosmetic flair and the naming ruleset — never for whether a capability exists.

**The rule that keeps tier 3 out of the core:** estate grouping and snapshot
classification are **data, not Go**. Ship a rules file — prefix patterns →
group labels, snapshot prefix → class — with a kldload ruleset as one profile
among several. Nothing in the compiled core may know the string `klab-`.

This is not purity for its own sake. It produces a **better tool for kldload
too**: a naming convention that lives in an editable rules file survives the
next `kspawn`-shaped tool being added, whereas one hardcoded in Go needs a
release. And it is the only version of this project that can honestly ship in
its own repo at Phase C without dragging kldload's vocabulary in as its core
nouns.

---

## Naming — decided: `vmxplore`, binary `vmx`

**Confirmed by the operator, 2026-08-07.** Matches wgxplore exactly (project
`<domain>xplore`, binary `<domain>x`), so the family reads `zxplore` / `wgx` /
`vmx`.

Plain `vm` is **disqualified**, not merely inelegant: `/usr/bin/vm` is already
owned by `mgetty-voice` in the Fedora repos. The family ships rpm/deb via nfpm,
so that is a hard file conflict at install time, not a style opinion. `vmx` and
`vx` are both unclaimed in the Fedora repos.

`vmx` is also the Intel VT-x CPU flag, which reads as apposite. The one mark
against it is VMware's `.vmx` file extension; if distance from VMware matters
more than family symmetry, `vxplore`/`vx` is the fallback.

---

## The model

Four nouns, and the point is that they are shown **joined**:

| Noun | Lives in | Today's tool |
|---|---|---|
| **Domain** — VM state, vCPU/mem, NICs, guest agent | libvirt | `virsh` |
| **Volume** — the zvol behind it, used/refer | ZFS | `zfs list` |
| **Lineage** — golden → clone → clone-of-clone | ZFS `origin`, `com.kldload:clone-origin` | nothing |
| **Estate** — blue/green pairs, k8s CP+workers, goldens | naming convention | `klab`, `kube-cluster` |

The join is the product. A row reading *"running, cloned from
`klab-golden-fedora@golden`, 604 snapshots (1 operator-made), 1.7G referenced,
agent up"* exists in no tool today: `virt-manager` knows the domain and nothing
about ZFS; `zxplore` knows the dataset and nothing about the domain.

### The real problem: four sources of truth

The inventory turned up something more important than a missing view — the
estate's state is scattered across **four stores that already disagree**:

1. **libvirt** — domains. Authoritative for what is defined and running.
2. **ZFS** — zvols, origins, snapshots. Authoritative for storage and lineage.
3. **`kldload-db`** — a SQLite inventory at `/var/lib/kldload/state.db`
   (nodes/vms/clusters/deployments/events, soft-delete, WAL). Written by
   `kvm-create`, `kvm-clone`, `kvm-delete` and `kube-cluster` — and **not** by
   `klab`, `kvm-win`, `kimage`, `kspawn`, `kzfs-lab` or `kzfs-test`. It is a
   partial view by construction.
4. **`kspawn`'s JSON manifest** at `/var/lib/kspawn/clusters/<c>/manifest.json`
   — hand-rolled with `printf`, parsed back with `awk`/bash regex, and the sole
   source of truth for `kspawn list/status/ssh/destroy`.

Plus webui marker files (`/var/lib/kldload/vm-build-pending/<name>`,
`vm-export-pending/<name>`) carrying provisioning state.

**Design consequence, and the load-bearing decision in this document:** `vmx`
treats **live libvirt + live ZFS as the only truth**, and reads `kldload-db`
and the kspawn manifest as *annotations that may be stale*. It reconciles and
shows the disagreement rather than trusting any register. "This VM exists in
libvirt but not in state.db" is a row worth rendering, not an error to hide.

### Verified, not assumed

Before writing this I built a throwaway pure-Go binary against the real estate
on onyx. The following is measured:

- `github.com/digitalocean/go-libvirt` (pure Go, speaks the libvirt RPC wire
  protocol directly) builds with `CGO_ENABLED=0` into a **fully static** ELF —
  the family's 8-platform static-TUI release story survives.
- It connected to `qemu:///system` and enumerated all **25** domains on onyx.
- Parsing each domain's XML for `<source dev='/dev/zvol/…'>` and joining against
  `zfs list -H -r -t all -o name,used,origin rpool/vms` reproduced full lineage,
  e.g. `klab-green-fedora → rpool/vms/klab-golden-fedora@golden` and
  `kldload-w-2 → rpool/vms/k8s-golden@clone-20260705_143916906897718`.
- API surface for every headline feature exists: `ConnectGetAllDomainStats`
  (whole-estate counters in one round trip), `SubscribeEvents`/`LifecycleEvents`
  (push refresh, no polling), `DomainOpenConsoleBidirectional` (in-TUI serial
  console), `QEMUDomainAgentCommand` (guest agent), plus
  define/create/undefine/migrate/snapshot/storage.
- Privilege: `qemu:///system` returned "Timeout was reached" as an ordinary
  user and worked under `sudo`. Root or `libvirt` group is required.

**The finding that shapes the whole UI:** `rpool/vms` on onyx holds **16,351
snapshots** — ~604 per zvol, essentially all `@autosnap_*` from sanoid (every
15 min; hourly=48/daily=14/weekly=4/monthly=3, recursive). A naive snapshot
pane is unusable on day one. Snapshot **classification is a launch requirement**,
not polish. The classes in the wild:

| Prefix | Producer | Meaning to an operator |
|---|---|---|
| `@autosnap_*` | sanoid timer | noise — collapse to a count |
| `@auto-*` | `kvm-snapshot.timer` | noise (see note below) |
| `@manual-*` | `ksnap`, webui | **what a human made** — show these |
| `@golden` | klab, kvm-win, kimage | the lineage root — show always |
| `@clone-*`, `@create-*` | `kvm-clone`, webui | clone provenance |
| `@pre-kube-{init,join,reset}-*` | kube-* | safety checkpoints — show |
| `@repl-*` | `kvm-replicate` | replication bookmarks |

> Side observation worth its own look, unrelated to this tool: `kvm-snapshot.timer`
> **and** `sanoid.timer` are both active on `rpool/vms`, but zero `@auto-*`
> snapshots exist on the datasets I sampled — so the hourly timer appears to be
> firing and producing nothing. Not a blocker here; flagging it because I found it.

---

## Competitive honesty

**Correction to my first pass, which claimed this space was empty — it is not.**
A terminal libvirt manager is an occupied niche:

- **[virt-tui](https://github.com/fcoromo/virt-tui)** — Go + tview + the official
  libvirt bindings, `qemu:///system`, start/stop/suspend/resume/terminate.
  Closest in stack to what is proposed here.
- **[VirtUI Manager](https://github.com/aginies/virtui-manager)** — Python, the
  most featureful of the three: snapshots, disk overlays, fleet selection by
  regex and group filters.
- **[Virtual Man](https://lets-build-an-ocean.github.io/virtual-man/)** — a
  third, lighter TUI in the same space.

So "a libvirt TUI" is **not** a differentiator and must not be the pitch. What
none of them appears to do is know about ZFS: no domain↔zvol join, no `origin`
lineage, no snapshot classification. Supporting evidence that this is a genuine
gap rather than an oversight — libvirt's *own* ZFS storage-pool driver still
carries an open upstream issue for
[creating a volume from an existing volume](https://gitlab.com/libvirt/libvirt/-/issues/48),
i.e. libvirt cannot express a ZFS clone. Anything that wants lineage has to go
around libvirt to the `zfs` CLI, which is precisely tier 2's job.

- **virt-manager** — the incumbent GTK app. Better at device editing and SPICE
  consoles, forever. Knows nothing about ZFS, shows no lineage, and is a desktop
  app: not a thing you drive over SSH on a headless hypervisor.
- **kldload's own webui** — the real incumbent here, and a big one: ~11.5k lines
  of Python serving a WebSocket API with `list_vms`, `vm_op`, `vm_bulk`,
  `vm_clone`, `vm_create_cloud`, `vm_snaps`, `vm_rollback`, `vm_delete_full`,
  console/SSH/VNC panes, and the whole `klab_*` and `k8s_*` surface. `vmx` is
  the terminal-native counterpart, not a replacement — but it should reach
  feature parity on the *VM* verbs, and it inherits the webui's hard-won
  lessons (see below).
- **k9s** — the ergonomics we are stealing; not the domain we are entering.
- **cockpit-machines** — web, per-host, no ZFS awareness.
- **virsh** — complete and scriptable. `vmx` must never fight it: every mutation
  prints the exact `virsh`/`zfs` command it is about to run, zxplore-style, so
  the TUI teaches the CLI rather than hiding it.

Trade accepted: `vmx` will be worse than virt-manager at graphical console and
device-form editing. It wins on estate-scale reading, lineage, ZFS integration,
reconciliation, and working over SSH.

### How big is "universal", honestly

Smaller than it first looks, and worth saying plainly so the decision is made
with open eyes. The intersection is *libvirt* **and** *ZFS zvols*, and several
of the biggest ZFS-VM populations fall outside it:

- **Proxmox VE** — the largest ZFS-backed VM estate in the wild by some margin,
  and **not reachable**: it drives QEMU directly through its own stack rather
  than through libvirt.
- **FreeBSD/bhyve**, **SmartOS/illumos** — ZFS-native, not libvirt.
- **oVirt** — libvirt-based, but effectively dead upstream.

What remains is homelab, lab and SMB Linux hosts running plain libvirt with
zvol-backed disks. That is a real constituency and an underserved one, but it is
a niche, not a market.

**So the recommendation is: stay universal, but not because of audience size.**
Stay universal because (a) tier separation costs almost nothing here — it is a
rules file and a `LookPath` probe, not an architecture; (b) it is the only way
this is honestly a sister project rather than a kldload subdirectory; and
(c) it produces a better tool for kldload, since baking `klab-` into compiled Go
is a worse design even when kldload is the only consumer.

If the tiering ever starts costing real design effort, that is the signal the
answer was "kldload-specific after all" — and the fallback is legitimate: keep
`vmx` in this repo permanently as a first-party tool, skip Phase C, and lose
nothing except a badge.

### Lessons already paid for by the webui — do not re-learn

- Snapshots are **ZFS** snapshots (`zfs list -t snapshot -r rpool/vms`), not
  `virsh snapshot-list`. The webui shipped the wrong concept once.
- `virsh destroy` on a transient domain loses it — stash `dumpxml` before
  destroy and re-define after (the webui's rollback path does this).
- Deleting a VM must destroy the zvol too, or you orphan storage
  (`vm_delete_full` exists because `vm_op delete` only undefined the domain).
- Validate dataset names against a regex before any `zfs rollback`.

---

## Non-goals (the hypervisor test)

If a feature makes sense on a hypervisor with no ZFS underneath, it probably
belongs in virsh or virt-manager, not here.

- **Not a k9s replacement.** k9s exists, is excellent, and tracks upstream
  forever. `vmx` shows the *VMs that are k8s nodes* and the ZFS under them;
  cluster internals stay k9s's job. (This reverses my earlier instinct to build
  both — the VM console is the gap; the k9s clone is not.)
- No scheduler, placement engine, or HA orchestration.
- No management fabric (no oVirt/Proxmox ambitions, no daemon, no web UI).
- No image building — that is `klab`, `kvm-create`, `kimage`, `kvm-win`. `vmx`
  drives them.
- No SPICE/VNC graphical console. Serial only; hand graphical to virt-viewer.
- No migration orchestration in v1.
- **No new state store.** Adding a fifth register would be the single worst
  outcome of this project.

---

## Architecture

**Milestone 0 is chassis extraction, and it has not happened.** `WG-NETWORKS-DESIGN.md`
commits to pulling zxplore's shared parts into a module both consoles consume:
engine + mock-CLI test rig, read-only-default/explicit-unlock elevation, audit
log, ssh transport, dual GUI+TUI build, release pipeline. Today zxplore is still
a flat `package main` at its repo root, so **nothing in it is importable**.

That settles the sequencing, and it matches what you asked for — integrate
first, split later:

**Phase A — inside kldload.** `vmx` starts as a directory in this repo, built
from local source. It borrows zxplore's shape by copying, not importing. We
learn what the estate view needs by running it against klab and the k8s estate
daily.

**Phase B — extract the chassis.** Once `vmx` and `zxplore` have visibly
duplicated the same engine/elevation/audit/ssh code twice, the module's shape is
known from evidence rather than guessed. Extract from zxplore, port both.

**Phase C — split to its own repo**, identity `Anthony <admin@zxplore.dev>`
(the console-family identity, never kldload's), BSD-3, and flip kldload's build
to the clone-and-cache pattern.

Doing B before A means designing a shared abstraction against one real consumer
and one imagined one. That is how chassis extractions go wrong.

**Stack** (matching the family): Go 1.26.x, flat root package, `bubbletea` TUI,
Fyne GUI behind `-tags gui` + CGO with a `nogui.go` stub, `Makefile`,
`nfpm.yaml`, `packaging/{rpm,debian,arch,freebsd}`.

**Talking to the substrate:** libvirt via `go-libvirt` (pure Go, static, no
`virsh` fork per refresh — this matters at 25 domains on a 2s refresh). ZFS via
`exec.Command("zfs", …)`, exactly as zxplore does, because the ZFS CLI is the
stable interface and the mock-CLI test rig already exists for it.

---

## Tier 3 — VM teleport (the feature that justifies the family)

Select a VM, select another host, press one key: the VM appears there and boots.
Incremental after the first seed, resumable over a flaky link, encrypted end to
end. This is the capability that makes `vmx` more than "another libvirt TUI",
and it is the point where the three consoles compose into something none of them
is alone — ZFS moves the bytes, WireGuard carries them, `vmx` moves the machine.

### Most of this already exists — in zxplore

`zxplore`'s F2 dual-pane commander is *already* point-and-shoot replication:
active pane is source, other pane is destination, F5 replicates, either pane may
sit on a different host — so local→remote, remote→local and remote→remote are
one gesture. Its `ReplicatePipeline` is more mature than I assumed before
reading it, and it already handles the three things that are easy to get wrong:

- **Resumable** — probes the destination's `receive_resume_token` and switches to
  `zfs send -t <token>` to continue an interrupted transfer; receives with
  `zfs recv -s`.
- **Encrypted end to end** — if the source dataset has encryption on, it sends
  `-w` (raw), replicating *without ever loading the key* on either side.
- **Incremental** — finds a common snapshot and sends `-i <base>`.

So tier 3 is not a new engine. It is that engine, with the unit changed from
**dataset** to **virtual machine**.

### The delta `vmx` has to add

A VM is a zvol *plus* the machine that boots it. Honest list of what teleport
must handle beyond `zfs send | recv`:

1. **Domain XML portability.** Rewrite name, drop `<uuid>` and `<mac address>`
   so libvirt mints fresh ones (`kvm-clone` already does exactly this for local
   clones — copy its sed dance). Then *validate*, not assume: machine type
   (`q35` + version), CPU model (`host-model` vs `host-passthrough` — the latter
   will not boot on a different CPU), and firmware.
2. **UEFI/OVMF is the sharp edge.** Loader paths differ per distro
   (`/usr/share/OVMF/...` vs `/usr/share/edk2/...`), and the per-VM NVRAM
   `_VARS.fd` is a separate file that must travel too — it carries boot entries
   and any enrolled MOK. `kvm-clone` copies it locally; teleport must ship it.
3. **Network mapping.** A `bridge=br0` or libvirt network `default` on the
   source may not exist on the target. Resolve to a target-side selection and
   fail loudly before sending gigabytes, not after.
4. **zvol receive flags differ from filesystem ones.** zxplore receives with
   `-o readonly=on -o canmount=noauto`, which is right for datasets; `canmount`
   does not apply to volumes. Teleport needs a zvol variant of the recv
   properties, and `zfs send -p` to carry `volblocksize`/`compression`.
5. **Quiesce or accept crash-consistency.** For a running VM, freeze the guest
   filesystems via `guest-fsfreeze-freeze` before snapshotting, thaw after —
   the same trick the ransomware demo's `_snapshot_root` uses. Fall back to
   crash-consistent with a loud warning if the agent is absent.
6. **First seed is the honest cost.** Full send of a multi-GB zvol is minutes;
   every subsequent teleport of the same lineage is incremental and seconds.
   The UI must say which one it is about to do, and how big.

### Where WireGuard earns its place

Not encryption — `zfs send -w` and ssh already cover that. WireGuard gives
**stable addressing**: peers are `10.x` addresses that do not change with the
site's DHCP or NAT, so a saved replication target keeps working, and hosts need
no public exposure. `wgxplore` is the view of that backplane; `vmx` just
consumes reachable peers. On a non-kldload host, plain ssh reachability is a
perfectly good substitute — hence tier 3 gates on *a reachable ZFS peer*, not on
WireGuard being present.

---

## The headline view — estate, joined

The screen that justifies the project. One row per domain, grouped by estate,
live:

```
DOMAIN               STATE     CPU   MEM      BACKING ZVOL             CLONE OF                   SNAPS   AGENT
▸ k8s  (1 cp, 2 workers)
  kldload-cp         running   4.2%  2.1/4G   rpool/vms/kldload-cp     k8s-golden@clone-20260705  605✎3   up
  kldload-w-1        running   1.1%  1.4/4G   rpool/vms/kldload-w-1    k8s-golden@clone-20260705  605✎0   up
▸ klab  (blue/green × 5 distros)
  klab-blue-fedora   shut off    -      -     rpool/vms/klab-blue-fed  klab-golden-fedora@golden  604✎1   -
▸ goldens (sealed)
  klab-golden-fedora sealed      -   1.75G    rpool/vms/klab-golden-f  -                          606     -
▸ unreconciled
  demo-leftover      defined     -    412M    rpool/vms/demo-leftover  -                          88      -   ⚠ not in state.db
```

`605✎3` = 605 snapshots, 3 operator-made. That collapse is the answer to the
16k-snapshot problem: show the count, surface what a human created, let `s`
expand with class filters.

Estate grouping is **derived, never configured**, from conventions the shell
tools already enforce: `klab-{blue,green,golden,ztest,test}-<distro>`,
`<cluster>-cp[N]` / `<cluster>-w<N>`, `k8s-golden`, `kspawn-<cluster>-<NN>`,
`win-<os>-golden`, plus the `com.kldload:clone-origin` property.

---

## What it must be a superset of

`vmx` earns its place only if an operator stops reaching for these. Everything
below stays shipped and supported; `vmx` drives or reimplements, it deprecates
nothing on day one. Line counts are the porting cost, and they are the reason
Phase A is read-first.

**Single-VM lifecycle** (thin ZFS+virsh wrappers, all `rpool/vms/<name>` 1:1
with the domain name, all self-elevating):
`kvm-create` (173) · `kvm-clone` (134) · `kvm-delete` (81) · `kvm-list` (23) ·
`kvm-snap` (86) · `kvm-win` (427, Windows golden pipeline with TPM/SecureBoot) ·
`kimage` (285, sysprep→qcow2 fan-out) · `kexport` (359, whole-disk + OCI/LXC/
Firecracker export) · `kldload-seal` (sysprep primitive) · `kclone`/`ksnap`
(generic ZFS helpers) · `kinspect` (tmux traffic inspection).

**Estate tools** (large, orchestration-shaped — delegate, do not port):
`klab` (3866) · `kube-cluster` (2953) · `kube-demo` (3650) · `kvm-demo` (1085) ·
`kspawn` (554, `/usr/local/sbin`) · `kube-{init,join,network,reset,status,setup,
smoke-test,load-images}` · `klab-{exporter,prom-targets,vm-debug-bundle}`.

**Legacy duplicates — decide before porting:** `kzfs-lab` (2305) and `kzfs-test`
(2093) are near-identical predecessors of `klab` (klab's own header says it
unifies them), yet all three still ship and the `kvm` profile installs all
three. `vmx` should almost certainly model `klab` only and treat the other two
as deprecated — but that is a call for you, not an assumption for me.

**v1 scope:** read + the safe verbs (start, shutdown, destroy, snapshot,
rollback, clone-from-golden, console). Estate verbs (`klab deploy`,
`kube-cluster scale`) are v2 and are **invoked as the existing tools**, with the
command shown, never reimplemented in Go. Porting 25k lines of orchestration
shell into Go is not a project, it is a career.

### Consolidation this project should surface (not silently fix)

- **Three WireGuard subnet schemes** coexist: `kube-network` standalone
  (mgmt `10.250/24`, k8s `10.251/24`), `kube-cluster` inline (`10.251/24`,
  `10.252/24`), klab sites (blue `10.252/24`, green `10.253/24`). `vmx` should
  label which scheme a VM is on rather than pick a winner.
- **`kube-cluster` duplicates `kube-network`'s mesh logic inline** rather than
  calling it.
- **The webui's legacy `_vm_clone`/`_vm_replace` qcow2 path** depends on
  `/usr/local/sbin/kldload-stamp-identity`, which does not exist in the repo —
  a dead reference beside the current ZFS-golden `_vm_create_cloud` path.

---

## Privilege model & policy

Same discipline as wgxplore, adapted.

- **Read-only by default and prompt-free.** Either ship
  `usr/share/polkit-1/actions/org.kldload.vmxplore.policy` with
  `allow_active=yes` for the read-only verb — mirroring
  `org.kldload.wgxplore.policy`, whose rationale comment (a console that
  re-reads every N seconds cannot show an auth prompt per refresh) applies
  verbatim — or add the desktop user to the `libvirt` group and skip polkit for
  reads. **Decide before Phase A ships.**
- **Every mutation prints its exact command first** and elevates per-command.
- **Destructive verbs retype-to-confirm** (zxplore-style): `zfs rollback`,
  `zfs destroy`, `virsh undefine`. These are the verbs that have already cost
  real homelab hours.
- **Audit log** at `/var/log/kldload/vmx.log`: command, exit status, timestamp.

---

## kldload integration checklist

Derived from how zxplore and wgxplore actually hook in. Phase A uses local
source; Phase C flips 1–4 to clone-and-cache.

1. `builder/build-iso.sh` — build block modeled on the wgxplore one:
   `VMXPLORE_REF` env pin, `live-build/vmxplore-cache/`, depth-1
   fetch-or-clone, darksite behaviour (fatal only when there is neither network
   nor cache; otherwise warn and ship the cached commit),
   `/etc/kldload/vmxplore-commit` breadcrumb.
2. Follow **wgxplore's single-binary** shape (`vmx`, GUI or TUI chosen by GL
   capability detection), not zxplore's two-binary split. Capability detection
   is the pattern that already survived a real bug — profile-name gating missed
   the `kvm` profile.
3. Keep the `readelf -d … NEEDED.*(libGL|libX11|libwayland|libxkbcommon)`
   assertion after any `-tags gui` build. A tagless GUI build fails silently and
   has shipped before.
4. `.gitignore` — add `live-build/vmxplore-cache/`.
5. `.desktop` + icon: static file in `includes.chroot`, icon generated by
   `tools/icons/gen_icons.py` (new `ICONS`/`LABELS`/`COLORS` entry, unused
   colour). **`StartupWMClass` must equal the Fyne window title string exactly**
   — GLFW derives WM_CLASS from the title, not the app id.
6. `profiles.sh` — `vmx` does not start with `k`, so it must be added to the
   explicit binary glob, the launcher glob, the icon glob, **and** the
   commit-breadcrumb copy. All four, or it silently does not install.
7. `tests/smoke-{desktop,server,kvm}.sh` — binary + `--help` signature string +
   launcher + icon in **all three**. wgxplore's kvm-only coverage is a gap to
   avoid, not a precedent to copy.
8. `README.md` — family line plus a bullet section matching the two siblings.
9. Decide whether to add a `KLDLOAD_ENABLE_VMXPLORE` opt-out (zxplore has one,
   wgxplore does not).

---

## Appliances — the catalog

Nearly every "how to self-host X" writeup is the same four moves: fetch a
pinned artifact, write a config, initialise a database, drop a unit file.
The New VM pipeline already ends in a post-install hook that runs once as
root on first boot, so encoding those four moves per app costs one struct
literal and one bash string — and turns a weekend of following a blog post
into a button.

An `Appliance` (`appliances.go`) is **data, not code**: a cloud-image preset,
a sizing default, a list of operator-facing fields, an optional `Validate`,
and a fixed script. Adding an entry never touches the pipeline, the GUI or
the tests. `Build ▸ Appliance…` renders it and hands the result to
`BuildNewVM` unchanged, so an appliance is a New VM with the form pre-filled.

**The self-contained rule.** An appliance script assumes nothing but a stock
cloud image and a network: it fetches its own binaries, writes its own
config, and installs its own reverse proxy. It must not require vmxplore,
libvirt, or kldload to have touched the guest. That is deliberate — most
people running one of these will never install kldload, and the script has
to stand alone as something an upstream project can publish as their own
install path. `vmx --appliance-script NAME KEY=VALUE` prints exactly that
file. On a kldload host the *surroundings* get better (zvol-backed disks,
`Make Golden` → instant clones, the estate view), but the guest is identical.

**Injection is handled structurally, not by escaping rules.** Operator values
are never interpolated into the body of a script. The body is fixed bash that
reads named variables; rendering only prepends single-quoted assignments, and
values containing a newline are rejected because the scripts write them into
line-oriented config formats. The test suite round-trips shell metacharacter
payloads through a real bash and asserts both that the value survives byte-
identical and that the marker file a successful injection would create never
appears.

**Verification ladder.** `bash -n` and `shellcheck -S warning` run against
every rendered script in `go test`, so a broken heredoc in a catalog entry
fails at CI rather than in a guest where the only symptom is a VM that boots
without its service. Above that, an entry is proven by actually running it:
the WriteFreely script was verified end to end in a systemd container —
services active, site served through the proxy, admin login accepted, wrong
password rejected, and the app confirmed unreachable except through the edge.

**Pin and verify.** Every artifact an appliance downloads is version-pinned
with a checksum, using whatever algorithm upstream publishes (WriteFreely
ships no manifest, so those are ours; Caddy's is SHA-512). A tampered or
truncated download is a hard failure, not a mystery.

## Phasing

- **0.1 (Phase A, in-repo)** — read-only estate view: the joined table, live
  stats via `ConnectGetAllDomainStats`, event-driven refresh, snapshot
  classification, reconciliation against `kldload-db`/kspawn manifests, domain
  detail (XML, disks, NICs, guest-agent IPs), serial console. **No mutations.**
  This alone replaces `kvm-list`, `kldload-overview`, and most `virsh list`
  muscle memory.
- **0.2** — safe verbs: start / shutdown / destroy / snapshot / rollback /
  clone-from-golden, each printing its command, destructive ones retype-gated.
  Audit log.
- **0.2.3** — the appliance catalog: `Build ▸ Appliance…`, `--appliances`,
  `--appliance-script`. First entry WriteFreely (federated blogging, behind
  Caddy with automatic HTTPS). The catalog is the cheap, compounding surface —
  each new entry is a struct literal and a bash string.
- **0.3 — teleport.** ssh remote transport (the `~/.ssh/config`-as-inventory
  model inherited from zxplore) so one console sees several hypervisors, then
  the headline verb: send a VM to another host and boot it there. Reuses
  zxplore's `ReplicatePipeline` for the bytes; adds domain XML porting, NVRAM
  carriage, network mapping and guest quiesce. **This is the milestone that
  makes the project worth doing** — plan for it to take longer than 0.1 and 0.2
  combined.
- **0.4** — estate verbs by delegation (`klab deploy`, `kube-cluster scale`).
- **1.0 (Phase B+C)** — chassis extracted, repo split, release pipeline, man
  page, 8-platform static builds.

---

## Risks

- **Chassis extraction slips forever.** The honest failure mode: Phase A ships,
  works, and nobody does Phase B — leaving three consoles with three copies of
  the elevation code. Mitigation: keep copied code *obviously* copied (same file
  and function names as zxplore) so the diff stays cheap, and make B a release
  blocker for 1.0.
- **Scope gravity toward the 25k lines of shell.** The tool must stay a
  *console*. Every estate verb it reimplements instead of delegating is a
  second implementation to keep correct across nine distros.
- **`DomainOpenConsoleBidirectional` has no clean abort handle** — a blocking
  call taking an `io.Reader`/`io.Writer` pair with no stream object to close;
  cancelling means closing the reader underneath it. Prototype early. It is the
  one API whose signature I verified but whose ergonomics I did not.
- **go-libvirt is a `v0.0.0-<pseudo-version>` module** with no tagged releases.
  DigitalOcean-maintained and widely used, but pin it and treat bumps as real
  upgrades.
- **Reconciliation surfaces mess.** The first honest run will show drift between
  libvirt, ZFS and `state.db`. That is the feature working, but it will look
  like the tool is broken. Design the "unreconciled" group to explain itself.
- **Teleport's failure mode is a VM that arrives and will not boot.** The bytes
  are the easy part; `host-passthrough` CPU models, mismatched OVMF loader paths
  and a missing target bridge each produce a silent non-boot after a long
  transfer. Mitigation: a **preflight** that compares machine type, CPU mode,
  firmware paths and network availability on both ends and refuses *before*
  sending, plus a dry-run that prints the exact `zfs send | recv` pipeline and
  the target domain XML diff. Never send gigabytes to discover a mismatch.

---

## Decided

- **Name:** `vmxplore`, binary `vmx` (operator, 2026-08-07).
- **Universal, in tiers.** A standalone KVM manager for anyone; the ZFS and
  teleport superpowers light up wherever the substrate is present, which on
  kldload is always. Capability-detected, never identity-gated.

## Open decisions

1. polkit read policy vs `libvirt` group membership for the desktop user.
2. Are `kzfs-lab` and `kzfs-test` deprecated? If yes, the kldload ruleset models
   `klab` only.
3. Does `vmx` absorb the k8s *estate* view (nodes as VMs) at 0.1 or 0.3? That is
   where the ZFS lineage story is most striking.
4. Teleport UX: zxplore's two-pane commander gesture (familiar to anyone who
   uses zxplore) or a single-pane "send to…" picker (fewer keystrokes for the
   one-host-to-one-host case)?
5. GitHub org: a third `vmxplore` account, or consolidate the family under one?
   Three single-repo orgs is already awkward at two.
