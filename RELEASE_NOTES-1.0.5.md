# kldload 1.0.5 — Proving Ground

**Shipped 2026-04-22.** Download the ISO at [dl.kldload.com](https://dl.kldload.com).

## The 30-second pitch

> "Let's test this on CentOS" used to mean 25 minutes of ISO + packages +
> deploy. With kldload it's **2 seconds** — a ZFS-cloned VM appears with your
> product pre-installed, you test, destroy, clone another. Do it 50 times in
> a row without flinching.
>
> Then you watch what's happening at the kernel level — not what the app
> thinks is happening, what the kernel is actually doing — and bugs that
> used to take an hour become plainly visible the second they happen.

## Why this release matters

1.0.5 is where kldload stops being "a nice multi-distro demo" and becomes
"the lab you build everything on." Four cross-cutting themes:

1. **The lab has a console.** A web UI with sub-tabbed workspaces for every
   resource type, plus a 24-key tmux drawer where every watchable pane is
   one keystroke away.
2. **Full OpenZFS observability end-to-end.** zfs_exporter + smartctl +
   ebpf biolatency + arcstats + scrub tracking + Loki log aggregation +
   zed→Loki + 8 Grafana dashboards, all baked in. Plus `klab-vm-debug-bundle`
   that auto-fires on any test failure with a paste-ready ISSUE.md for
   upstream.
3. **Install reliability is no longer "mostly works."** ZFS hostid propagates
   live→target→initramfs so rpools always import at boot. Dracut is
   `--no-hostonly` everywhere. Fedora 43's firmware split is handled. WiFi
   credentials in the installer land as an NM profile on the target. All
   the little install-day paper cuts got fixed.
4. **The ZFS test suite is first-class.** Separate goldens pre-loaded with
   every `zfs-tests.sh` prerequisite, parallel runs capped at 80% of host
   cores, per-test streaming output, auto-bundled audits on failure for
   attachment to upstream PRs.

## Top use cases

| Role | What kldload gives you |
|---|---|
| **OpenZFS maintainer** | `klab test --full` across 5 distros, one auto-generated audit bundle per failure, paste-ready ISSUE.md. |
| **Developer** | "Does my chart/playbook still work on every distro?" — one command, parallel test. No cloud bill. |
| **SRE / platform engineer** | Practice rig for eBPF, bpftrace, Cilium, Hubble, Tetragon. Break things safely, see the kernel-level cause, build the reflex. |
| **Security researcher** | Isolated bare-metal sandbox for kernel/BPF/CNI experiments. Detonate samples, destroy the VM, clone a fresh one. |
| **Trainer / consultant** | Reproducible demo rig. Carry a USB to the customer, lab is running in 30 min. |
| **CI operator** | Plug USB into an office NUC → persistent 5-distro test runner, no cloud bill, faster than hosted CI. |
| **Kernel/distro packager** | "Does this kernel/package still work with these workloads?" — one `klab test --full` away from the answer. |
| **Compliance / audit** | Run hardening scripts, capture `full.log` + Tetragon events + doctor output, zip as audit bundle. |

## What's new

### OpenZFS observability stack (this is the big one)

This is the demo you'd bring to OpenZFS maintainers. Click a test failure →
see kernel stack, last zio, D-state blocked task, SMART status, ARC state —
all correlated on one timeline. Bundle is paste-ready for `github.com/openzfs/zfs/issues/new`.

**Exporters, all enabled by default:**

- `zfs_exporter` (`:9134`) — per-pool/dataset metrics (fragmentation, dedup,
  compression, free/alloc)
- `smartctl_exporter` (`:9633`) — SMART attributes per disk
- `ebpf_exporter` (`:9435`) — biolatency histograms per block device
- `loki` (`:3100`) — single-node log aggregator, 7-day retention, TSDB fs
- `promtail` (`:9080`) — ships journald + kernel ring + zfs-dbgmsg + klab
  test logs to Loki
- `arcstats-exporter` — parses `/proc/spl/kstat/zfs/arcstats` via textfile
  collector (replaces the broken node_exporter zfs collector on newer
  kernels)
- `zpool-scrub-exporter` — parses `zpool status` → scrub age/duration/errors
  + per-vdev error counts

**zed → Loki.** `/etc/zfs/zed.d/all-loki.sh` pushes every zpool event
(checksum error, resilver, scrub, trim, vdev state change) into Loki with
`{class, pool}` labels — so the kernel-messages dashboard and ZFS health
board light up the instant anything happens.

**Tetragon.** `zfs-execs` TracingPolicy audits `zfs/zpool/zdb/ztest/zfs-tests.sh`
execve events inside test pods.

**Grafana dashboards (8):**

1. `zfs-pool-health` — capacity, fragmentation, ARC hit rate, top-10
   datasets, zed event feed
2. `scrub-history` — days-since, duration, errors, per-vdev counts, zed
   timeline
3. `compression-trend` — pool-wide ratio, per-dataset over time
4. `disk-health-smart` — NVMe spare/used/temp, iops, throughput, queue
5. `block-io-latency` — p50/p99/p99.9 histograms per device (ebpf)
6. `kernel-messages` — log volume, kernel ring, ZFS-related messages,
   systemd errors
7. `klab-test-matrix` — pass/fail/skip, per-distro status, test
   progression, goldens
8. `klab-test-debug` — per-VM: hung_task, kernel ring, dbgmsg, FAIL
   markers, debug bundles

**Helper tools:**

- `klab-vm-debug-bundle <distro> <run_id> [ip] [--deep]` — generates
  `.tar.gz` + OpenZFS-ready `ISSUE.md` containing `zdb`, tunables, kstat,
  D-state stacks, all-task stacks, SMART, packages. **Auto-invoked** by
  klab on watchdog timeout OR any `FAIL > 0`.
- `kldload-obs-check [--fix] [--vm X]` — 11-step end-to-end validation of
  the stack. Each failure points at the exact reproduction command.

### One-pane ops console (web UI)

Sub-tabbed workspaces for every resource, sticky headers with global search,
per-table filters, live tab badges, last-subtab persistence across reloads.

- **Kubernetes**: clickable nodes/pods expand to show events/containers/logs,
  multi-select bulk actions (drain / cordon / delete pod), Deployments panel
  with scale / rollout-restart / rollout-undo / delete, Services panel, live
  Events feed, Apply-YAML paste box, one-click demo deploy.
- **KVM**: Overview / VMs / Networks / Storage / Snapshots / Log. Bulk VM
  operations, Create menu with golden-clone shortcuts for every distro.
- **klab**: the 5 separate sidebar entries from 1.0.4 consolidated into one
  workspace (Status / Goldens / Operations / eBPF).
- **Tests → ZFS Suite**: dedicated workspace for the OpenZFS functional
  suite — Run controls, Results matrix, History, Audit (per-distro
  checklist parser), Live log stream, `.tar.gz` + plain `full.log`
  download endpoints.
- **Ansible** / **Helm** / **ZFS**: all sub-tabbed with the same pattern.
- Grafana iframe in the Observability tab renders with `kiosk=1` so the
  sidebar is fully hidden.

### Operator console (tmux drawer)

The terminal drawer reshapes the main content area via a CSS variable so
panels, VMs, logs never hide behind it. Every key is a toggle — press to
open, same key to close.

**Primary panes (F2-F12):**
- F2 k9s · F3 kldload-dash · F4 logs · F5 live firehose
- F6 htop · F7 k8s events · F8 hubble observe · F9 zpool iostat
- F10 scratch · F11 tcplife · F12 tcptop

**Deep-dive complements (Shift+F\<N\>):**
- Warnings-only events · dmesg --follow · doctor loop · iotop · kubectl top
- cilium drops · zfs iostat -l · kinspect picker · tcpretrans · tcpconnect

**Trace group (Alt+letter):**
- execsnoop · opensnoop · biosnoop · killsnoop
- iftop (Linux equivalent of OpenBSD pftop) · nethogs

**HUD popups (Alt+letter, auto-dismiss):**
- VMs & DHCP · cluster state · ZFS pools + ARC · WireGuard + routes ·
  disk+mem+cpu · uptime+who+last-logins

**Pane/window ops:**
- Alt+Enter new · Alt+\ vsplit · Alt+- hsplit · Alt+↔↕ walk panes
- Alt+x close pane · Alt+q / Ctrl+q close window
- Shift+↔ next/prev window · Shift+↕ newest/oldest

Home tab renders a 2-column ASCII-art cheatsheet (`_kconsole-home`) with a
`menu` shell alias to redraw anywhere.

### Install reliability drop

Every one of these was a concrete way 1.0.4 could leave you with an
unbootable system. All fixed:

- **ZFS hostid propagation** — live ISO's hostid is now copied into the
  target root and baked into the initramfs, so the pool imports the same
  way at every boot. (Old path: `chroot zgenhostid -f` → random hostid →
  rpool can't import → emergency shell.)
- **`dracut --no-hostonly` everywhere** — installer-generated initramfs
  ships drivers for every kernel module, not just what happened to be
  loaded on the live ISO when you ran the installer. No more "wrong NIC
  driver on first boot."
- **Fedora 43 firmware split** — bare `linux-firmware` is licenses-only
  on F43; installer now explicitly pulls `iwlwifi-{dvm,mvm,mld}-firmware`.
  WiFi actually works after Fedora installs.
- **NetworkManager-wifi + wpa_supplicant in RPM base** — previously
  present only on the Debian path. Fresh CentOS/Rocky/Fedora/RHEL
  installs can now join WiFi without post-install package-adding.
- **Hostname RFC 1123 validate + force-export** — fixes the "hostname
  drifts between `kldload` and `kldload-node` depending on which shell you
  look at" bug.
- **Timezone validate + force-export** — same pattern.
- **Fedora `zfs-release` retry loop** — tries `3-0 → 2-10 → 2-9 → 2-8 → 2-7`
  until one resolves. zfsonlinux sometimes lags a Fedora bump by a revision.
- **`systemd-run` transient units** — `_run_install` and `_klab_test` now
  run in their own cgroups, isolated from the webui. Crashing an install
  no longer blows up the web UI you're watching it from.
- **TLS services skip bounce during installs** — a flag at
  `/var/run/kldload/installer-busy` or `/var/run/klab/current-run.env`
  keeps the TLS-cert refresh timer from restarting the webui mid-install.
- **WiFi SSID + PSK in installer form** → writes an NM profile on the
  target so the machine reconnects to the same network on first boot.
- **Hostname normalization** (RFC 1123, lowercase, dashes-only, ≤63 chars)
  with a clear error in the UI if invalid.

### Laptop-ready desktop profile

The desktop edition grew ~350 MB of hardware enablement + codecs + fonts,
because the 1.0.4 desktop booted clean but then you had a laptop with no
WiFi, no webcam, no printer, and Liberation Sans.

**Hardware + codecs:**
- `microcode_ctl`, `alsa-sof-firmware`, `xorg-x11-drv-libinput`, `bluez`
- `mesa-vulkan-drivers`, `mesa-va-drivers`, `intel-media-driver`, `libva`
- `xdg-desktop-portal{,-gnome,-gtk}` + `pipewire-gstreamer` (Wayland
  screen share)
- `pipewire-libcamera` + `libcamera` + `v4l-utils` (webcams)
- `cups-filters`, `hplip`, `sane-backends`, `simple-scan`
- `ModemManager`, `NetworkManager-{wwan,openvpn,openconnect}(+gnome)`
- `pcsc-lite`, `opensc`, `libfido2`, `tpm2-tools`, `fwupd`
- `thermald`, `tlp`, `tlp-rdw`, `powertop`, `brightnessctl`, `ddcutil`
- `exfatprogs`, `ntfs-3g`, `cifs-utils`, `fuse3`
- gstreamer1 good/bad-free/base/libav + openh264 + pipewire-codec-aptx

**Fonts (all profiles)** — 180 families vs ~10 stock:
Liberation + DejaVu + Noto (sans/serif/mono/CJK/emoji) + Cascadia +
JetBrains Mono + Fira Code + Adobe Source + rsms-inter + Roboto + Open
Sans + STIX.

### Secure Boot — SBAT CSV for ZFSBootMenu

`bootloader.sh` now injects an SBAT CSV (`zfsbootmenu,1,...`) into the
ZBM EFI with `objcopy --update-section .sbat=` before MOK-signing. Shim
v15.8 policy 2021030218 now accepts it — no more
`mokutil --set-sbat-policy delete` workaround. MOK subject is now unique
per install (prevents key conflicts) and `--ignore-keyring` skips a stale
kernel keyring.

### New operator tools

- **kldload-dash** — single-pane "is everything OK?" overview (host +
  Kubernetes + ZFS + running VMs + recent warnings), auto-refreshing.
- **kinspect** — pick two endpoints (VMs or pods); get a 3-pane tmux layout:
  each one under SSH + live `watch`, with a Hubble/tcpdump flow stream of
  every packet between them.
- **kztest-tail** — follow the current ZFS test run's consolidated log
  from any shell pane.
- **kldload-obs-check** — 11-step observability validator, `--fix` mode
  repairs common drift.

### Bob (local LLM) — eyes, ears, and a voice

Bob can actually answer "why is hubble-relay not ready?" by calling
k8s_events → k8s_describe → k8s_logs → kernel_dmesg in sequence.

**18 observability tools** (all read-only by default):
- k8s: `get_pods`, `get_nodes`, `describe`, `logs`, `events`
- Prometheus: `prom_query` for arbitrary PromQL
- ZFS: `zfs_status`, `zfs_arc_stats`
- Host: `host_vitals`, `top_procs`, `ss_sockets`
- CNI / eBPF: `hubble_observe`, `cilium_monitor`, `cilium_status`,
  `cilium_endpoint_list`, `tetragon_watch`, `kernel_dmesg`,
  `bpftrace_oneliner` (human-approved)
- Self: `doctor_check`

**Voice input** — click the mic once, talk forever. Open-mic mode with
TTS self-talk ignored (Bob doesn't hear itself). Explicit
mic-permission button in the webui because Chrome revokes mic access on
self-signed TLS by default.

**Approve & Run actually dispatches** every execute tool (previous build
showed the button but some tools were silently ignored).

Strengthened system prompt with a diagnosis recipe so Bob reaches for
these tools by reflex. Silent disconnect handling — no tracebacks when
the browser tab closes mid-request.

Enabled by default on the k8s / kvm / zfslab tiles (DevOps had it already).

### ZFS test suite — first-class

- **Separate golden lineage**: `klab-ztest-<distro>` images carry every
  `zfs-tests.sh` prerequisite (`ksh`, `fio`, `net-tools`, `pamtester`,
  `pax`, `cryptsetup`, `xxhash`, `nfs-utils`, `bzip2`, `perf`,
  pre-created loopback vdevs) — kept separate from the lean blue-green
  `klab-golden-<distro>` images.
- **One-command builds** — "Build all ZFS test goldens" button in the UI,
  or `klab golden-ztest all` from the CLI.
- **Multi-distro CLI** — `klab golden centos debian ubuntu` now iterates
  across all args (was silently dropping extras in 1.0.4).
- **Streaming output** — every `[PASS]` / `[FAIL]` / `[SKIP]` line
  visible in real time, prefixed with `[distro]`, interleaved readably
  across parallel runs.
- **Audit bundles** — every run writes `/root/klab/<run-id>/full.log` +
  `manifest.txt` + per-distro logs. Download as `.tar.gz` from the UI to
  attach to an OpenZFS bug report.
- **Auto debug bundle** — `klab-vm-debug-bundle` fires automatically on
  any `FAIL > 0` OR watchdog timeout. The `ISSUE.md` is paste-ready.
- **Per-distro watchdog** — `KLAB_IDLE_MAX` default 14400s (4h) kills
  stuck subprocess, marks `timeout`, captures the bundle before kill.
- **Per-distro 20-min ztest golden build timeout** so one wedged distro
  doesn't stall the whole batch.
- **Parallel with a cap** — 80% of host cores by default
  (`KLAB_MAX_CONCURRENT` overrides) so the host isn't starved.
- **Per-test checklist parser** — audit panel parses every
  `Test: ... [PASS|FAIL|SKIP]` line into a sortable table.
- **Test-suite deps installed per-package** — one missing package no
  longer kills the whole dep install.
- **`pax` via CRB repo on EL** — eliminates ~15 SKIPs per distro.
- **`.packages` capture fixed on Debian/Ubuntu** — old `rpm||dpkg`
  fallthrough produced empty files on apt distros.
- **Promtail auto-installs per test VM** at test start (labels: `vm`,
  `test_run`, `host`, `case`).

### ZFS Lab profile (new install tile)

Fifth install profile: test-suite-first. Builds the `klab-ztest-*`
goldens on firstboot, adds a lean 1-CP / 0-worker K8s cluster alongside
(so Grafana still renders), skips the full 4-node cluster that k8s/kvm
profiles get. Ollama/Bob enabled by default.

### Observability chain finally renders

- Cilium / Hubble / Tetragon dashboards light up with real data.
- Fixed: `${DS_PROMETHEUS}` placeholder stripping at firstboot,
  synthesized `k8s_app` / `pod` / `io_cilium_app` labels on Prometheus
  scrapes, bundled Tetragon Grafana dashboard (9 panels) since no
  upstream Grafana.com ID exists.
- `metrics-server` installs automatically, powers `kubectl top` and the
  K8s tab's live CPU/Mem overlays on every row.
- `kube-network` firewall trusts node subnet + pod CIDR so hubble-peer,
  kubelet metrics, and cilium/tetragon metrics traffic traverse nodes.
- Cilium-operator scrape now only fires on the node it's actually
  running on (hostPort only binds where the pod is — 3 nodes out of 4
  would always show "down").
- Tetragon is actually shipped + installed (was missing from the
  install path, dashboards rendered empty).

### Doctor v2

- Grew from 22 checks to **33 checks across 10 subsystems**.
- New checks: metrics-server, prometheus targets, cilium scrape labels,
  tetragon scrape, hubble scrape, grafana dashboards, cluster firewall,
  Ollama, Bob tools, install artifacts.
- Writes `/root/kldload-doctor.log` on every run — grep-able history.

### Firstboot ordering

`kldload-firstboot` now defers **all** klab golden builds to
`kldload-autodeploy` so nothing races libvirtd startup. Autodeploy builds
both blue-green and ztest goldens on hardware profiles, with the
ZFS-Lab-tile gate controlling whether ztest specifically builds. libvirt
`isos` pool is defined explicitly (golden builds need it); no more ad-hoc
`zfs-vms` pool definition that fought the ZFS-native path.

### Installer fixes

- `profiles.sh` no longer silently skips copying `kldload-autodeploy`,
  `ttyd-k9s.service`, or the Ansible playbook library on install. Silent
  `cp` failures were the 1.0.4 root cause for autodeploy never running.
- libvirtd race fixed (wait for virsh socket, verify pool + default
  network actually got defined).
- Ansible playbook library always-copies with a loud WARNING if somehow
  missing on the live root.
- Install integrity checks run at end of install — validates the big
  four tool binaries, systemd units, and darksite presence.

### Distro updates

- **Fedora 41 → 43** — kernel 6.19+, current stable.
- CentOS stays 9 Stream (the bulletproof baseline).
- Debian 13 + Ubuntu 24.04 + Rocky 9 unchanged.
- Package additions to the darksite: `iftop`, `nethogs`, `bcc-tools`,
  `pax` — required by the operator console's trace/bandwidth keys to
  work fully offline.
- **Alpine removed** from klab. Alpine's apk + busybox stack doesn't
  share enough with the other distros to make uniform testing
  worthwhile; it was always the odd one out. Arch stays (bootstrap
  install path only, no golden — rolling release makes immutable
  goldens pointless).

### Fedora 43 darksite + DKMS build chain

Fedora was previously online-only for installs — **now has a full
offline darksite**. `build/darksite-fedora/` runs in a `fedora:43`
container, downloads ~1,356 RPMs (~1.8 GB), and creates a valid
`file://` repo baked into the ISO at `/root/darksite/fedora/`
(served on port 3145 for completeness). Pre-filters the package list
against actual repo contents (dnf5 dropped `--skip-broken` from
`download`, so we detect missing packages up-front rather than letting
dnf bail mid-transaction).

Because zfsonlinux.org hasn't always published a current fc43
`zfs-release` RPM, the fedora darksite ships the **full DKMS build chain**
(`dkms`, `autoconf`, `automake`, `kernel-devel`, `libblkid-devel`,
`libuuid-devel`, `python3-devel`, `rpm-build`, `gcc`, ...). ZFS compiles
from source during install — same userspace, same pool format, just
built at install-time.

### os-variant runtime resolver (klab)

`klab` now probes the host's `osinfo-db` and silently falls back when
the packaged db lags the distro (e.g. targets `fedora43` → host only
knows `fedora42` → use that). Fixes the "Failed to boot fedora" error
that appeared right after the F41→F43 bump on CentOS 9 hosts with
older `osinfo-db` packages.

### kspawn — ZFS-native multi-runtime cluster spawner (new)

New top-level CLI: `kspawn spawn --name web --distro debian --count 5`
clones 5 VMs from the klab debian golden **in parallel**, injects
cloud-init (hostname + SSH key per node), boots them, and writes a
JSON manifest at `/var/lib/kspawn/clusters/<name>/manifest.json`.
Subcommands: `spawn` / `list` / `status` / `ssh` / `destroy`.

v1 is KVM-only + local host. Firecracker microVMs + remote hosts (and
the `role=k8s-master|worker|etcd` provisioning) are v1.1. Because all
state is derivable from the manifest + ZFS clones, there is nothing to
"upgrade" — you destroy and re-spawn.

## Tested on

- **fiend (ASUS TUF X570)** — ZFSLAB profile running the 5-distro long
  OpenZFS test suite. centos / rocky / fedora / debian ≈98% pass.
  Ubuntu 58% — Canonical's vendored zfs-2.2.2 is the cause, not
  kldload. Full run is ~8.5h.
- **Dell XPS 13** — Debian 13 boots clean. Fedora 43 boots + WiFi
  works (post firmware-split fix). CentOS / Rocky still hit a kernel
  hang because Dell's BIOS defaults NVMe to RAID mode; switching to
  AHCI in BIOS resolves it. Not code-fixable.

## Upgrade

Fresh install recommended. 1.0.4 → 1.0.5 changes enough that an in-place
package-manager upgrade won't deliver the new UI / console / tool set.
Burn the new ISO, install, restore state from ZFS snapshots if you had
them.

## Known issues (punted to 1.0.6)

- **Profile gate `!= "core"` is too wide** — desktop/server profiles get
  bob+ansible+klab bleed-through. Needs per-tile gating.
- **RHEL credentials don't persist** past install to
  `/var/lib/kldload/secrets/`. Re-register is a manual step.
- **Fedora installer still uses metalink** instead of the bundled
  Fedora darksite on fresh networks. Works, but not offline-pure.
- **Ubuntu golden uses Canonical's vendored zfs-2.2.2** — switching to
  the zfsonlinux PPA is expected to push the pass rate from 58% → ~98%.
- **XPS 13 CentOS / Rocky** kernel hang on NVMe-RAID BIOS mode — user
  must switch to AHCI in BIOS. Dell default, not fixable in software.
- **Chrome captures F11/F12** (fullscreen/devtools); use Shift+F11/F12
  as the reliable bcc-tools keys on Chromium-based browsers. Firefox
  passes F11/F12 through to the tmux drawer.

## The point

Install kldload on real hardware. Deploy your charts, your Ansible, your
workloads. Watch what the kernel is actually doing while your product
runs. Break things safely. Rebuild in seconds. Test every distro before
you ship. See every zpool event, every slow IO, every ZFS kernel panic
with the full stack trace already attached to a bug-report-ready ISSUE.md.

The production-grade lab you always wanted and never had time to build.
