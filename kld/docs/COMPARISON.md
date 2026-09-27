# kld against the other terminal consoles

A survey of the KVM/libvirt and OpenZFS terminal tools, taken 2026-09-26
from each project's repository and README (stars and dates from the GitHub
API that day; nothing but the stock OpenZFS binaries was run). What each
does that kld does not, and what kld takes from it. The full survey notes
are in the session that wrote this; this file keeps the conclusions.

## ZFS

### What is out there
| tool | shape | alive | the one thing it does well |
|---|---|---|---|
| zfleet (Go, Aug 2026) | fleet tree over ssh, read-mostly | yes, one week old | per-vdev verdicts and a health roll-up; `zfs destroy` only after a priced `destroy -n` |
| zfs-file-history (Go) | file browser across snapshots | yes | diff against the previous snapshot or the live copy, then restore |
| httm (Rust, 1.6k stars) | fzf-style picker | yes, mature | find deleted files behind deleted directories; roll forward, not back |
| ztop (Rust) | top for datasets | yes | per-dataset I/O that `zpool iostat` cannot show |
| zrepl status | the daemon's own TUI | slow, fork active | replication progress bars per filesystem |
| ZFSBootMenu | boot-time fzf | yes | the only real boot-environment TUI, before the OS |
| zfs-allow, zfs-set (Go, FreeBSD) | one verb each | yes | the exact `zfs allow`/`zfs set` shown before it runs |
| zfsdu, zfstop, zfsguard, retrograde, ZC, zfstui | snapshot cleaners and dashboards | dormant or dead | ZC (2020) was the only attempt at the whole verb set in a terminal |

Web and GUI, for contrast: TrueNAS covers the whole list; WebZFS (a Klara
engineer's) covers pools, datasets, snapshots, replication, SMART and a
fleet but refuses to destroy anything from the UI; ZfDash and ZFSMgr
cover most verbs; 45Drives' cockpit-zfs replaced the dead cockpit-zfs-
manager.

### Where kld already stands
No terminal tool combines a dataset tree, property editing, the snapshot
verbs, send/receive with progress, pool topology and file-level restore.
kld has the tree, the property card, snapshot/rollback/clone/bookmark/
hold/diff, the explorer with restore, pools, topology, ARC, boot
environments and shares. Hold and bookmark exist in no other TUI.

### What to take
1. **Verdicts, not counters.** zfleet's per-vdev verdicts are what its
   reviewers praised. zxplore's Observe already judges (throttle, txg,
   ARC, SLOG, capacity, fragmentation): port it as Storage/Observe and put
   a one-line verdict in the pool row.
2. **A priced destroy.** zfleet runs `zfs destroy -n` first and shows the
   space and the snapshot count the destroy would take. kld's typed
   consent should show that line before asking for the name.
3. **The command, shown.** zfs-allow and WebZFS print the exact argv before
   running it. kld echoes the argv after; show it in the prompt too.
4. **Diff from the explorer.** zfs-file-history diffs a version against
   the previous snapshot and the live copy in place; kld has D and f on
   the Snapshots tab but not from the Versions row. Add d there.
5. **Roll forward.** httm restores a newer snapshot's file over an older
   live copy without a rollback; kld's restore-over-live is the same act,
   name it that way in the manual.
6. **Fleet tree.** zfleet shows every host's pools in one tree over ssh.
   kld's Network/Fleet lists hosts; a Storage view of a remote host is the
   port (the ssh path exists in kld already).
7. **Per-dataset I/O.** ztop's view is the one column kld's Observe lacks:
   objset kstats give it, no extra tool.
8. **Renamed binaries.** OpenZFS 2.4 renamed arcstat and arc_summary to
   zarcstat and zarcsummary; kld reads kstats directly and is unaffected,
   any script that shells out to the old names is not.

## KVM

### What is out there
| tool | shape | alive | the one thing it does well |
|---|---|---|---|
| virtui-manager (Python/Textual, SUSE hackweek) | full libvirt manager, 37 stars, weekly releases | yes, the most complete | multi-server, bulk operations including configuration, live and offline migration, an auto-install wizard for seven distros, web VNC over an ssh tunnel |
| dirt (Go/Bubble Tea, one author) | "k9s for libvirt", 4 stars | yes | marks with numeric prefixes and a typed phrase above 20, `/` filter, a `:` command palette with tab completion, a fleet view across a hosts file, sparklines and braille perf graphs, hot-plug disk and NIC, DHCP-lease drill-down with static-lease promotion, XML edit with incremental search, CSV/JSON export |
| virt-top (OCaml, Red Hat) | top for domains | yes, slow | the packaged monitor; cannot act |
| nEMU (C/ncurses, 608 stars), vm-curator (Rust, 481), kudu (Rust, 187) | raw QEMU, no libvirt | yes | GPU passthrough with Looking Glass, 130 OS profiles, USB and disk passthrough; they cannot see libvirt domains |
| kvmtop, vmtui, virt-tui (nyanco01), virtop | monitors and managers | dead | — |
| virt-spinner, lazyvirtmanager, vmyard, virt-tui (fcoromo), virTUI | prototypes of one to thirty commits | stale | vmyard is the only other one that knows ZFS zvols (one commit) |

Web, for contrast: cockpit-machines is Red Hat's replacement for
virt-manager (create, consoles, disks, NICs, clone, snapshots, one host per
session, three CVE releases in September 2026); Proxmox is a different
stack with ZFS first-class but no libvirt.

### Where kld already stands
No other libvirt console reads the storage layer: the zvol under each
machine, its clone lineage, the snapshots, instant clones. kld also has
the consoles inside the TUI (screen, serial, ssh), jobs with panes, the
Build menu, marks and batches, the live CPU column and the filter.
vmxplore is the only one with a built-in VNC client; kld inherited it.

### What to take
1. **A `:` command palette** (dirt): every verb and tab reachable by name
   with tab completion, for the operator who does not remember the key.
   Cheap: the verb registry already has labels.
2. **A typed count above a threshold** (dirt: above 20 marks). kld's
   Machines verbs ask nothing now; a batch delete of twenty machines
   should still take the count typed. Threshold five.
3. **Hot-plug** (dirt): attach and detach a disk or a NIC on a running
   machine (`virsh attach-disk`, `attach-interface`, and the detach pair),
   plus the USB attach already on the parity list.
4. **XML view and edit** (dirt): `virsh dumpxml` in a pane with search;
   `virsh edit` as a job with the editor in the pane.
5. **Leases and static promotion** (dirt): the Networks tab shows the DHCP
   leases of a network; a lease becomes a static host entry on one key.
6. **Live migration** (dirt, virtui-manager): `virsh migrate --live` to a
   fleet host, with the zvol replicated first (the teleport design in
   VM-CONSOLE-DESIGN.md); until then, a pointer row saying so.
7. **Per-machine history** (dirt's perf graphs): the CPU column sampled
   every 3 s already; keep the last minute per machine and draw it in
   the detail pane as a sparkline.
8. **An audit log** (vmxplore): every verb's argv and exit status to
   /var/log/kldload/kld.log, which no-confirmation verbs make necessary.
9. **JSON output** (dirt): `--print --json` for every tab, so scripts and
   the web console read the same data.
10. **The auto-install wizard** (virtui-manager): kld's build-your-own VM
    covers it through the klab goldens for five distros; SUSE and Alpine
    are the gap, and only if anyone asks.

### The two things not to take
- Confirmation dialogs on every verb (virtui-manager, lazyvirtmanager):
  the operator's model is vmxplore's, no prompts, an audit log instead,
  with the typed count for batches and the double d for a running
  machine as the only gates.
- A raw-QEMU backend (nEMU, vm-curator, kudu): their stars come from
  desktop users; kld's estate is libvirt and ZFS, and the two camps
  cannot see each other's machines.
