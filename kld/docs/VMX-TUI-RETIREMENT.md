# Retiring `vmx --tui`: what kld must carry first

Decided 2026-09-29 (operator): kld is the only terminal UI; vmxplore stays the GUI;
the `vmx`/`vmxplore` binaries keep their non-interactive flags (--build-all,
--vdi-wall, --appliances, --selftest, --console). Open: whether kld is renamed `vmx`
(costs: `vmx` is a live CLI name used by autodeploy; man page, launcher,
smoke-console, docs; keep `kld` as an alias for one release).

Source-only parity audit, 2026-09-29. File:line refs are to ~/vmxplore and kld/.

## Safety first (kld as it ships today)

- **VMs `b` rolls back a RUNNING VM on one key**: `kvm-snap rollback` force-destroys
  it, rolls back to the newest snapshot, restarts it (kld verbs.go:207). vmx refused
  a running VM and said how many newer snapshots the rollback destroys
  (vmx verbs.go:574-584, tui.go:885-898).
  **FIXED f9d17d8a**: VMs `b` refuses a running VM and wants the name typed;
  Snapshots `b` checks the domain state before rolling back.
- **Same keys, different meanings**: vmx `d` = graceful shutdown, kld `d` = delete
  (a stopped VM goes on one key); vmx `b` = reboot, kld `b` = rollback.

## Port before retiring `vmx --tui`

| # | Item | Size |
|---|---|---|
| 1 | ~~Rollback refuses a running VM (or confirms)~~ done f9d17d8a; still to do: show how many newer snapshots it destroys | S |
| 2 | ~~Delete also removes the VM's `-data` zvol and seed (in kvm-delete, so the CLI gets it)~~ done bdcd89be, tested on onyx probes | S |
| 3 | Rules file: honour `snap` class lines + `--rules`; classify/collapse noise in Snapshots | M |
| 4 | Snapshot with a typed suffix on VMs | S |
| 5 | Marks: space on a group header marks the group; plan all targets first; clear marks after a batch | M |
| 6 | Clone: prefilled `<name>-HHMMSS` example | S |
| 7 | Detail: persistent/transient, IPs, full lineage chain | S |
| 8 | ssh as a chosen user (`$VMX_SSH_USER`/admin), not only root | S |
| 9 | Build: add kzfs-test; `F` pre-checks (shut off, kfire present) + appliance port | S |
| 10 | Remote hypervisor (`--connect`) | L |
| 11 | Foldable groups, mouse, microVMs in the main estate view | M (optional) |
| 12 | Remove kld `V` (`vmxplore --tui`) and its man page line | S |

Already kld-only (vmx never had them): filter, sort, typed-name confirms, the 3 s
double-press delete on running VMs, prefilled prompts, the guided build and clone
wizard, job panes, in-TUI serial/screen/ssh consoles, the VDI wall verb.

vmx's own help is wrong twice (advertises `r` refresh, unbound; says it "asks
first", it does not): moot once retired.
