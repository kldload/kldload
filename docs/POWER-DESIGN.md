# Power — out-of-band control of the rack (design)

Captured 2026-09-28. Asked for by the operator after a day in which the
estate test could only reboot fiend because fiend happened to be running an
OS with ssh: "kldload [is] missing the ability to do remote power cycling
and such for a data center". Scheduled after the estate runs green
(operator: "for now lets get everything working first"); this document is
what gets built then. Status: **design, nothing implemented**.

## One sentence

`kldload-power <machine> on|off|cycle|status|pxe-once`, keyed by MAC like
the netboot server, driving whatever the machine has — a BMC over Redfish or
IPMI, Intel AMT, or Wake-on-LAN plus a switched outlet — so that provisioning,
recovery and the test harness never need a hand on the button or a working
OS on the target.

## Why this is the missing piece

kldload already provisions a rack from one USB or one netboot server: arm a
MAC, the machine PXE-boots, installs, comes up enrolled. Every step assumes
something outside kldload has already made the machine *boot*:

| Where | How it reboots a machine today | What that cannot do |
|---|---|---|
| `ci/kldload-netboot-run`, phase `boot` (~l. 480-505) | ssh in, `efibootmgr -v` to find the PXE entry for the MAC, `efibootmgr -n`, `systemctl reboot` | a machine that is off, hung, at a ZFSBootMenu passphrase, or never installed |
| `tests/estate-sweep.sh`, `kick_pxe` (~l. 185) | the same trick, over ssh | same; the sweep waits `BENCH_WAIT` and then fails the edition |
| the operator | walks to the rack | nothing, but it is 2026-09-28 06:19 and fiend is sitting in an iPXE retry loop |

A machine that is bricked by a bad install — exactly the machine that most
needs reprovisioning — is the one kldload cannot touch. Out-of-band power
closes that gap, and one-time network boot through the BMC (`pxe-once`)
replaces the ssh/efibootmgr trick with something that works on a dead box.

## The model

Three nouns:

- **Machine** — identified by its boot MAC, the same key `kldload-netboot-server
  arm-install <mac>` and the answers files (`live-build/pxe/matrix/*/<mac>.env`)
  already use. A machine may also have a hostname and a DB node row; the MAC
  is what survives a reinstall.
- **Controller** — how the machine is reached out of band: `redfish`, `ipmi`,
  `amt`, `wol`, or `outlet` (a switched PDU port or smart plug). A machine has
  at most one power controller and, optionally, a separate `wol` for on.
- **Verb** — `status`, `on`, `off` (graceful, then forced after a timeout),
  `force-off`, `cycle`, `pxe-once` (next boot from the network, once, then
  back to disk), and `console` where the controller has one (Redfish/IPMI
  SOL, AMT SOL).

### What each controller can do

| Verb | redfish | ipmi | amt | wol | outlet |
|---|---|---|---|---|---|
| status | yes | yes | yes | no (ping/arp only) | outlet state only |
| on | yes | yes | yes | yes | yes |
| off (graceful) | yes | yes (soft) | yes | no | no |
| force-off / cycle | yes | yes | yes | no | yes (hard) |
| pxe-once | yes (`BootSourceOverrideTarget=Pxe`, `Enabled=Once`, `Mode=UEFI`) | yes (`chassis bootdev pxe options=efiboot`) | yes (boot options; to confirm) | no | no |
| console | Redfish SOL / vendor | `sol activate` | AMT SOL | no | no |

A verb a controller cannot do is **exit 3, "not supported by <controller>"**,
never a silent no-op. `pxe-once` on a `wol`/`outlet` machine falls back to the
existing ssh/efibootmgr path only when the operator passes `--via-ssh`, and
says so.

The Redfish verbs map onto DMTF `ComputerSystem.Reset` ResetType values (`On`,
`GracefulShutdown`, `ForceOff`, `PowerCycle`/`ForceRestart`) and the
`Boot` object on the ComputerSystem resource; the IPMI verbs onto `ipmitool
-I lanplus chassis power ...` and `chassis bootdev`. AMT and outlet drivers
are phase 3 and their exact calls are to be looked up, not assumed (see Open
decisions).

## Inventory and credentials

**Where the record lives.** One file per machine,
`/etc/kldload/power/<mac>.env`, mode `0600`, root-owned, created with
`install -m 0600` (never chmod after the fact):

```
POWER_CONTROLLER=redfish          # redfish | ipmi | amt | wol | outlet
POWER_ADDRESS=10.100.20.31        # BMC / AMT / PDU address
POWER_USER=kldload
POWER_PASSWORD=...                # never on a command line; see below
POWER_TLS_CA=/etc/kldload/power/ca/<mac>.pem   # optional pinned BMC cert
POWER_SYSTEM=/redfish/v1/Systems/1 # redfish: which system, when a BMC has several
POWER_OUTLET=3                    # outlet: port number
POWER_WOL_MAC=f0:2f:74:cd:27:50   # optional: WoL for "on"
```

Why files and not the state DB: `kldload-db` keeps `state.db` group-readable
(`_heal_perms`, 0664) so the web UI and tools can read the estate, and its
`secrets` table has no code behind it. BMC credentials are root-on-the-rack
credentials; they belong where only root reads them. The DB gets the
**non-secret** half — a `power` column set on the node row (controller type,
address, last known state, last verb and its result) — so the estate, the
inventory and the web UI can show and filter it without touching a password.

**Answers files carry it for new machines.** `KLDLOAD_POWER_*` in an answers
file are consumed by `arm-install`/`arm-all` on the netboot server (which is
where the rack's inventory already is) and written to
`/etc/kldload/power/<mac>.env` there. The installed machine never receives
another machine's BMC password: the answers file's effective copy on the
target is already redacted for secrets (project memory: answers-file audit);
`KLDLOAD_POWER_PASSWORD` joins that redaction list and a test asserts it.

**Secrets never reach a log, a process listing or a temp file:**

- IPMI: `ipmitool -E` (password from `IPMI_PASSWORD` in the environment of
  that one child) or `-f` on a 0600 file; never `-P`.
- Redfish/AMT/outlet over HTTP: `curl -K <0600 config>` with `user = "..."`,
  or `--netrc-file`; never `-u user:pass` on argv.
- The tool logs the verb, the machine, the controller and the outcome — never
  the address with credentials, never a response body that might echo them.

**TLS.** BMCs ship self-signed certificates. Default is verify-with-pinned-CA
when `POWER_TLS_CA` is set; without it, the first contact records the
certificate fingerprint (trust on first use) into the machine's file and every
later call pins it. `--insecure` exists for a BMC being set up and prints a
warning each time (core rule: do not weaken transport by default; the reason
belongs next to the flag).

## The tool

`/usr/local/sbin/kldload-power` — bash, one file, drivers as functions
(`_redfish_<verb>`, `_ipmi_<verb>`, ...), because every verb is a short
sequence of HTTP calls or one ipmitool call and the project language is bash.
If the Redfish JSON handling outgrows `jq`, the driver moves to Python behind
the same CLI.

```
kldload-power <mac|hostname> status|on|off|force-off|cycle|pxe-once|console
kldload-power <mac|hostname> set --controller redfish --address A --user U   (password on stdin)
kldload-power list [--json]          every machine with a power record, and its state
kldload-power probe <address>        what is this BMC: Redfish service root, IPMI, AMT
```

- `--help` answers first, needs no root, exits 0 (project rule 9).
- stdout is data (`status` prints one word; `list --json` is JSON), stderr is
  diagnostics.
- Exit: 0 done and verified, 1 failed, 2 usage, 3 not supported by this
  controller, 4 controller unreachable, 5 authentication refused.
- **Outcome, not exit code.** Every verb reads the state back: `on` polls
  `status` until On (bounded), `off` until Off, `pxe-once` reads the boot
  override back from the BMC before returning 0. A 204 from a BMC is not
  evidence the machine did anything.
- **Idempotent.** `on` on a machine that is on is 0 and says so; `pxe-once`
  twice sets it once.
- Man page (mdoc, OpenBSD order, a worked example per verb) ships with it; the
  interface is small enough to settle before release.

## Integration — where it plugs in

1. **netboot-run `boot` phase.** Try `kldload-power <mac> pxe-once &&
   kldload-power <mac> cycle` first; fall back to today's ssh/efibootmgr path
   only when the machine has no power record, and log which path was taken.
   A machine that is off or hung now reinstalls unattended.
2. **estate-sweep `kick_pxe` and bench discovery.** Same order. With a power
   record the sweep no longer needs the bench to be up at all, so
   `BENCH_WAIT` stops being a guess about when a human will press a button.
3. **Netboot server: a provision verb.** `kldload-netboot-server
   provision <mac> <answers>` = `arm-install` + `pxe-once` + `cycle`, and
   `provision-all <dir>` for the rack. This is the "rack from one USB" story
   finished: arm and power, not arm and walk.
4. **Recovery.** `krecovery`/`kldload-restore-machine` gain "reboot it into
   the restore image" via `pxe-once` — the bricked-install case.
5. **Estate and inventory.** `kldload-estate` shows a `power` column
   (controller, state) for physical machines; the Ansible inventory exposes
   `kldload_power_controller` as a host var and a `power_<controller>` group,
   so a play can target "every Redfish machine". No credentials in either.
6. **Console (kld) and web UI.** A Power pane on physical machines: status,
   on/off/cycle, "reinstall from network" (= provision). Destructive verbs
   need the typed machine name, the same pattern kld's VM delete uses — the
   VM table's blind `ctrl+] d` once pressed delete on the wrong row
   (2026-09-26); a power-off of the wrong host is worse.
7. **Doctor.** `kldload-doctor` reports machines whose controller does not
   answer or whose credentials are refused, before an unattended run needs
   them.

## Discovery — finding machines, and finding their controllers

Two different questions, answered by two different protocols (operator,
2026-09-28: "wouldn't a simple mdns request do it?").

**Where is a machine that is UP?** mDNS. Today netboot-run's `find_target`
and estate-sweep's `find_bench` ping every address from .100 to .200 and ssh
into each to read its install manifest -- seven minutes to find fiend for one
edition on 2026-09-28, and the reason "fiend's address moves" is a memory.
Nothing in kldload advertises or resolves mDNS today (checked: no avahi, and
systemd-resolved's MulticastDNS is off, on the installs and on onyx). Plan:

- every install answers `<hostname>.local`: systemd-resolved `MulticastDNS=yes`
  on the primary link where resolved runs, avahi-daemon where it does not;
  the firewall opens UDP 5353 on the LAN zone only;
- the harness resolves the name first and falls back to the subnet scan;
- identity is still confirmed from `/etc/kldload/install-manifest.env` over
  ssh. mDNS gives an address, not proof of which machine answered: two
  installs with one hostname become `fiend.local` and `fiend-2.local`, and
  multicast stays on the local segment (a rack, not a routed estate).

**Where is a machine's CONTROLLER?** Not mDNS -- a powered-off or hung machine
answers nothing, which is the whole reason for out-of-band power. Redfish
specifies SSDP for BMC discovery; `kldload-power probe` listens for it on the
BMC network and, given an address, identifies what answers (Redfish service
root, IPMI, AMT). Discovery proposes; the operator binds a controller to a
MAC with `kldload-power <mac> set`, because a wrong binding power-cycles the
wrong machine.

## Safety

- **Never power off the machine running the command, or the netboot server
  serving the rack,** without `--self`; the tool compares the target's MAC
  set against the local host's NICs.
- **A cluster node is not power-cycled while it is the last Ready control
  plane** unless forced: the tool asks kubectl (when the machine is a
  registered node) and refuses with the reason.
- **By exact target only.** No globs, no `--all` on destructive verbs; a
  rack-wide cycle is `provision-all <dir>`, which lists what it will do and
  requires the directory of answers files the operator wrote. (A test
  `destroy --all` once took six of the operator's clones.)
- **Every destructive verb is logged** to `/var/log/kldload/power.log` with
  who (the sudo user), what, and the read-back outcome.

## Testing — without buying a server

The whole driver layer can be exercised against VMs, before any real BMC:

- **Redfish:** OpenStack's `sushy-tools` provides a Redfish emulator whose
  ComputerSystems are libvirt domains — power, boot override and all. A
  throwaway VM named `power-probe-<pid>` on onyx or fiend becomes a "server
  with a BMC".
- **IPMI:** OpenStack's `virtualbmc` exposes a libvirt domain as an IPMI
  endpoint that `ipmitool -I lanplus` drives.
- Packaging for both is to be verified (Fedora/EPEL package vs a venv on the
  test host only); they are test dependencies, never shipped.
- **WoL:** a libvirt VM does not honour magic packets; WoL is tested on fiend
  itself (Realtek NIC, `ethtool` wol flags), which is also the first real
  machine the feature serves.
- **Gates, both directions** (core §5d.3): each verb against the emulator
  passes; the same verb with a wrong password exits 5, against a stopped
  emulator exits 4, `pxe-once` whose read-back does not match fails; a
  fixture asserts no password appears in `ps`, the journal or the log.
- **The test harness owns only what it names** (project rule 12): it creates
  `power-probe-*` domains and destroys them by exact name.
- **Real hardware** before release: fiend (WoL + a switched outlet), and one
  machine with a real Redfish BMC (iDRAC, iLO or a Supermicro board) —
  emulators agree with the spec; vendors agree with it less.

## Phasing

| Phase | Scope | Done when |
|---|---|---|
| 0 | mDNS: installs answer `<hostname>.local`; netboot-run and estate-sweep resolve names first, subnet scan as fallback | the sweep finds the bench in seconds; a test asserts `<hostname>.local` resolves on every profile |
| 1 | `kldload-power` with `redfish` + `ipmi`; status/on/off/cycle/pxe-once; per-MAC 0600 records; man page | emulator gates pass both ways; no secret in ps/journal/log |
| 2 | netboot-run `boot`, estate-sweep `kick_pxe`, `kldload-netboot-server provision` | an estate sweep runs start-to-finish against a machine that starts powered OFF |
| 3 | `wol` + `outlet` drivers; fiend on WoL + a switched outlet | the sweep recovers fiend from a hang with no human |
| 4 | estate column, inventory vars/groups, kld Power pane, web UI, doctor | shown for every physical machine; typed-name confirm on destructive verbs |
| 5 | `amt`; recovery via pxe-once | a desktop-class machine with AMT is reprovisioned remotely |

Phase 0 needs no hardware and is worth doing on its own; phase 1 and 2 are the value; 3 makes the test bench unattended; 4-5 are
reach.

## Non-goals

- A DCIM: no rack diagrams, no power budgeting, no PDU telemetry beyond
  on/off state.
- Firmware updates through the BMC.
- BMC provisioning (setting BMC IPs, users, VLANs) — that is the operator's
  network, done once; kldload consumes it.
- Anything that needs a cloud or vendor service to reach a machine.

## Open decisions (operator)

1. **Binary name:** `kldload-power` (matches `kldload-netboot-server`) or a
   short `kpower` beside the other `k*` tools?
2. **Where the rack's power records live when there are several netboot
   servers** (a live USB per rack vs one onyx): per server, or synced with the
   answers files?
3. **fiend's first controller:** WoL alone covers "on" only; a switched outlet
   (which one — a smart plug with a local HTTP API, or a PDU?) is needed for
   "off/cycle" on a board without a BMC.
4. **AMT tooling:** which client (WS-Management via `wsman`/`amtterm`, or
   something maintained) — to be looked up before phase 5, not assumed.
5. **Release placement:** 2.0 gate or a 2.x feature? This document assumes
   after the estate is green, on its own branch.
