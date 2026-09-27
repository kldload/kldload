# kld parity with vmxplore and zxplore

The operator's rule (2026-09-26): "the Machines part should literally have
everything vmxplore can do, and the Storage tab should literally be all of
zxplore." This is the checklist, taken from a full read of both source trees
on that day. One line per capability, its state in kld, and the decision
where kld deliberately differs. Update it in the same commit as the port.

States: `done` · `partial` (what is missing) · `todo` · `skip (why)`.
Underlying commands are the canonical kldload verbs where one exists
(kvm-clone, kvm-delete, kvm-snap, kldload-seal, kfire, klab, kube-cluster),
never a second implementation of them.

## Machines (vmxplore)

### Estate table and detail
- done — grouped rows by rules (/etc/vmxplore/rules), state, boot, vcpus,
  memory, address, clone-of, snapshot count, mesh, role, notes; synthetic
  "unreconciled" rows for DB ghosts and orphan zvols.
- done — live CPU% column from consecutive domstats samples, 3 s refresh
  while the tab is on screen, cursor kept on the same VM.
- partial — detail pane: disks, NICs, verbs. Missing: origin lineage chain
  (up to 16 hops), snapshot counts per class (noise/human/golden/provenance/
  checkpoint/repl), agent up/down, uuid, persistent/transient.
- todo — fold/unfold groups (← → on a header), group header rows with
  "N running · N marked".
- done — text filter (/) which vmxplore's TUI lacks.
- done — marks (Space) and batch verbs; batch of job verbs runs in one pane.
- todo — Space on a group header marks the whole group.

### Lifecycle
- done — start S, shutdown T, reboot R, force off K, suspend z, resume Z,
  autostart A, delete d (kvm-delete --force: destroy, undefine --nvram,
  zvol and -data, DB row, mesh, seed ISO), reconcile X for synthetic rows.
- done — no typed confirmation on Machines verbs; the argv is what the
  status line reports (vmxplore's model). Storage keeps typed consent
  (zxplore's model).
- done — `virsh destroy` "not running" (and start on a running machine)
  reported as a note, not an error. kvm-delete owns "domain not found" and
  the zfs destroy busy retry; checked 2026-09-26: two deletes of clones of
  one source at once both clean.

### Snapshot and rollback
- done — snapshot s (kvm-snap), rollback b to newest, Snapshots drill-in
  (Enter) with rollback b / delete d / snapshot s.
- todo — snapshot with a typed suffix (@manual-<suffix>); crash-consistent
  warning while running.
- todo — snapshot classes in the Snapshots drill-in (noise collapsed,
  classes grouped, newest 12 per class).

### Clone, golden, fleet
- done — clone c with name, count (name-1..N in one job), --snap @name
  (kvm-clone: snapshot+clone, seed ISO, DB register).
- todo — "power them on once cloned" option and enrol after start
  (vmxplore GUI does reseed → retarget logs → start → enrol). Decide: a
  `--start` flag on the clone prompt running `virsh start` per clone in the
  same job, then `kldload-enroll`.
- done — M make golden on a VM row: shut down, seal (kldload-seal,
  virt-sysprep fallback), @golden. Only the root zvol (kldload has no
  -data disks on goldens today).
- todo — clone from @golden when the source has one (planCloneFrom's rule).
  Check whether kvm-clone --snap @golden is the equivalent; document.
- done — build your own golden / VM: kvm-golden clones a klab golden (or
  any VM), boots, runs a post-install file or command as root, seals and
  takes @golden (or --keep leaves the VM). Then c clones N. Machines / Build
  rows "build your own golden|VM". Run on onyx 2026-09-26: fedora base,
  marker file written, sealed, @golden in 3m47.
- done — F seal as a Firecracker golden (kfire golden).

### Consoles
- done — screen w (VNC in cells; `kld screen` full-screen sixel), serial C,
  ssh H, all in the TUI body; ctrl+] menu; ctrl+t host terminal.
- todo — screen: guest clipboard → host (ServerCutText is read, not
  exposed); paste from host (ClientCutText + typed).
- skip — fullscreen chord alt+insert (foot/Sway own fullscreen).
- todo — ssh user from $VMX_SSH_USER / admin on kldload; kld uses root
  with the host's key. Decide per operator.

### Configuration
- done — v vcpus and memory for next boot; + grow root disk (kvm-grow, all
  three layers); A autostart.
- todo — resize reading the current size first and refusing shrink (kvm-grow
  does; surface its message).

### Appliances, factory, microVMs
- done — Appliances tab: catalog with fit, b build one (fields as KEY=VALUE),
  s show script, B build all; Factory tab: klab goldens per distro, k8s
  golden, appliance catalogue, tests.
- todo — appliance build form: per-field labels, defaults, secrets masked,
  generated values, validation (vmxplore's Field list via --appliances
  JSON if it exposes it; else a fixed table).
- todo — self-test (vmx --selftest) and destroy-all appliances as Factory
  rows with confirm.
- done — microVMs tab: kfire list, S start, T stop, d destroy, H ssh,
  C console, ! status, c clone (raw kfire args).
- todo — kfire clone form: golden, how many, vcpu, ram, follow-up (wall /
  rdp / browser); demo estate (`vmx --demo` or kvm-demo); destroy all
  microVMs (kfire destroy --all, goldens kept) with typed consent.
- todo — VDI wall verb (vmx --vdi-wall --open) on app-vdi rows.
- todo — USB attach/detach verb: lsusb list → virsh attach-device (hostdev
  XML) --live --persistent; detach-device.

### Hosts
- todo — connect to another hypervisor (virsh -c qemu+ssh://host/system;
  zfs over ssh; VNC through ssh -L). kld's Network/Fleet already lists
  hosts; a "Machines on <host>" context is the port.
- skip — migrate/teleport (vmxplore: designed, not built).

### Not ported on purpose
- skip — Fyne manual/sysdiag windows (kld has man kld; kldload-doctor is
  the health source), the kldload tool-launcher tree (kld IS the launcher),
  arcade palette, rules file editing.

## Storage (zxplore)

### Browser and dossier
- done — Datasets table (name, type, used, avail, refer, mountpoint,
  ratio), Pools, Pool drill-in (vitals, space, vdevs, I/O, events), ARC,
  Topology, Shares (NFS/SMB read-only), Boot envs (kldload-rollback).
- partial — detail pane shows a property card. Missing: HEALTH verdict
  (pool state, capacity ≥80%, errors, vdev counters), the seven grouped
  property cards with source tags, PERMISSIONS (ls -ld, getfacl, zfs
  allow), the type header.
- todo — tree badges (POOL, ZVOL, BE ●, container, NOT MOUNTED) and folding.

### Lifecycle
- done — create child n, zvol V, rename m, mount M, unmount N, load-key L
  (stdin, masked), unload U, encrypted child E, destroy -r d (typed),
  snapshot s, set property P, zxplore z.
- todo — change-key (passphrase twice on stdin), zfs inherit (reset to
  inherited), clone/duplicate a dataset (newest snapshot or zx-<ts>),
  roll back to latest snapshot from the dataset row.
- todo — Properties sub-tab: every settable property with value and
  source, Enter → picker for enums/bools, text prompt otherwise; the risky
  set (mountpoint, canmount, readonly, quota…) asks y/n.

### Snapshots, bookmarks, holds
- done — Snapshots: rollback b, destroy d (typed), clone c, diff D / f,
  bookmark K, hold H, release U, replicate T.
- todo — Bookmarks sub-tab (list -t bookmark, destroy with the "next send
  is FULL" warning); holds listing (zfs holds); zfs promote verb.
- done — unscoped listing kept with its cost stated (4,866 snapshots = 11 s
  of zfs stat; Enter on a dataset is instant).

### Pools
- done — scrub S, stop scrub P, clear errors E, offline F / online O
  (Topology).
- todo — trim (zpool trim) and stop, importable scan (`zpool import` with
  no name) + import <name>, export, `zpool history` pane, `zpool events`
  as a follow, upgrade, checkpoint, scrub pause. zxplore lacks the last
  three too; kld adds them since the verbs are one line each.
- todo — vdev replace/attach/detach/add/remove (zxplore lacks them; kld
  should have them with typed consent on the device).

### Replication
- partial — T replicate: zfs send | zfs recv -F to local or user@host.
  Missing zxplore's pipeline rules: resume token (-t), raw -w unless the
  source is unencrypted and the target inherits encryption, restore mode
  (-p / -x readonly), incremental base from the newest common snapshot or
  bookmark, progress from -vP with cancel of the process group, permission
  grant (zfs allow) on failure. Port the pipeline as one function with a
  table test on the rule matrix.
- todo — Sync jobs (syncoid timers): /etc/zxplore/syncjobs.json, install /
  remove / run now / show command, state records, boot manifest capture.
  Reuse `zxplore --sync …` verbs from a Sync sub-tab rather than
  re-implementing the job runner.

### Explorer
- done — files of a dataset, directories, versions across snapshots with
  differs flag, restore copy c, restore over live R (typed).
- todo — [ ] cycle the source snapshot while keeping the path; d diff the
  version against live; directory restore merges (cp -a src/. dst).

### Builder
- todo — pool create: shelf (lsblk -J, by-id, in-use reasons), candidates
  (mirror/raidz1-3/draid2/stripe, log/cache extras with badges), custom
  vdev, layout, warnings, validation, dry-run (zpool create -n), typed
  ERASE. `zxplore --builder disks|suggest|dry-run|create` exist as CLI:
  drive them from a Builder sub-tab instead of re-implementing.

### Observe
- todo — one-second samples (arcstats, zil, dmu_tx, zfetch, objsets,
  iostat -Hpvly), gauges, verdicts with fix lines, vdev table, busiest
  datasets, kstat groups. `zxplore --observe POOL json` exists: an
  Observe sub-tab that renders its JSON is the port.

### Containers on ZFS
- todo — engine detection (docker/podman, storage driver), containers and
  images lists, start/stop/restart/logs/rm, estate snapshot/rollback of the
  store dataset. `zxplore --containers …` exists for the estate half.

### Boot environments
- done — Boot envs tab with B boot into, X cancel; kldload-rollback owns
  the safe path (clone BE, never rollback -r on a live root).
- todo — create BE from the row (snapshot of bootfs), delete.

### Not ported on purpose
- skip — read-only lock (:rw/:ro): kld's stance is typed consent on the
  destructive verbs, no global lock.
- skip — Fyne servers manager and favourites (kld's Network/Fleet is the
  host list); polkit/pkexec (kld uses sudo -n).
- skip — zxplore-api / zxplore-txn daemons (separate binaries, no UI).

## Performance rules learned on 2026-09-26
- One host command for the whole table, never one per row (virsh domstats,
  virsh list --autostart; the dominfo fallback runs eight at a time).
- Anything slower than a second is cached with a TTL and refreshed in the
  background (doctor 120 s, snapshot counts 30 s).
- A verb reloads the table it acted on; the live view refreshes itself
  every 3 s without a spinner; the cursor follows the row name.

## Storage as a NAS console (operator, 2026-09-26: "a full zxplore console like the NAS guys")

What TrueNAS-class consoles have that the Storage section does not yet,
each mapped to the kldload verb or file that already owns it. Nothing here
is a new engine.
- todo — Shares: create/edit/remove NFS and SMB exports on a dataset
  (sharenfs/sharesmb properties, /etc/exports.d, smb.conf shares, samba
  users with smbpasswd), iSCSI targets (targetcli), with the daemon state
  and "SHARES NOT SERVED" verdict the read-only tab already shows.
- todo — Disks: the shelf (lsblk by-id, in-use reasons), SMART health and
  self-tests (smartctl -H/-a/-t), temperatures, wear; a failing disk's
  place in the pool topology; replace from the shelf.
- todo — Snapshot policy: sanoid.conf templates per dataset (hourly/daily/
  weekly/monthly counts, autosnap on/off) edited from the dataset row;
  what the policy will keep, shown against what exists.
- todo — Scrub and trim schedules: the timers, next run, last result.
- todo — Replication tasks: the Sync tab (syncoid timers) with source,
  target, schedule, last run and next; run now; the boot manifest capture.
- todo — Quotas and reservations per dataset and per user/group
  (userspace/groupspace), with usage against the limit.
- todo — Permissions: owner/mode, POSIX ACLs and ZFS delegation (zfs
  allow/unallow) from the dataset row; the dossier shows them first.
- todo — Encryption: per-dataset keys with load/unload/change-key (partly
  done) plus a key-status overview and unlock-at-boot state.
- todo — Alerts: a Storage/Alerts tab from kldload-doctor's storage checks
  and observe's verdicts, with the fix line; degraded pool, capacity,
  errors, failed scrub, SMART failure.
- todo — Users for shares: the local accounts a share is served to, with
  smbpasswd; never a second identity store.
- done — pools, datasets, snapshots, explorer with restore, ARC, topology,
  boot environments, the read-only shares view.
