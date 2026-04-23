# kldload 1.0.5 — Proving Ground

**Shipped 2026-04-22** · download at [dl.kldload.com](https://dl.kldload.com) · WIP candidate updates re-publish to the same URL · [`main`](https://github.com/kldload/kldload) is always current

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
"the lab you build everything on." Five cross-cutting themes:

1. **The lab has a console.** A web UI with sub-tabbed workspaces for every
   resource type, HTTPS out of the box, plus a 24-key tmux drawer where
   every watchable pane is one keystroke away.
2. **Full OpenZFS observability end-to-end.** zfs_exporter + smartctl +
   ebpf biolatency + arcstats + scrub tracking + Loki log aggregation +
   zed→Loki + 8 Grafana dashboards, all baked in. `klab-vm-debug-bundle`
   auto-fires on any test failure with a paste-ready ISSUE.md for upstream.
3. **Install reliability is no longer "mostly works."** ZFS hostid propagates
   live→target→initramfs. Dracut is `--no-hostonly` everywhere. Fedora 43's
   firmware split is handled. Install-time paper cuts got fixed, measured,
   and covered by the doctor.
4. **Real laptop hardware enablement.** Microcode, thermal, power, WiFi,
   Bluetooth, cameras (IPU6 via libcamera), printers/scanners, smartcards,
   FIDO2, TPM, modems, VPN plugins, fwupd LVFS, screen-share via Wayland
   portal. 1.0.4 booted clean on a laptop then left you with no WiFi and
   no webcam. Not any more.
5. **The ZFS test suite is first-class.** Separate goldens pre-loaded with
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

---

## What's new

### Web UI — HTTPS out of the box, standard port 8443

- Self-signed TLS cert generated on first start by `kldload-tls-cert`,
  regenerated on DHCP IP change, rotated weekly via timer. Cert is
  valid for the hostname + every live IP (LAN, WireGuard, loopback).
- Explicit 🔓 "Grant microphone access" button next to the 🎤 mic —
  Chromium revokes `getUserMedia()` on self-signed certs by default, so
  we can't just rely on the browser prompt.
- Previous HTTP `:8080` retired from the installer role (that port is now
  Bob's chat UI). Installer URL is `https://<host>:8443`.
- Non-root invocations of `kldload-webui` now refuse cleanly with a clear
  message pointing at `systemctl status kldload-webui` or
  `sudo kldload-webui` — previously silently EPERM-cascaded into a
  SQLite readonly-DB traceback.
- Install/klab subprocesses run under `systemd-run` transient units —
  cgroup-isolated from the webui, so a crashing install can't blow up
  the UI tracking it.

### One-pane ops console (web UI workspaces)

Sub-tabbed workspaces for every resource, sticky headers with global
search, per-table filters, live tab badges, last-subtab persistence
across reloads.

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

### Encrypted credentials store (webui)

The webui now has an encrypted at-rest credentials store, gated to
installed systems only (live ISO stays plain-mode).

- ZFS namespace created on first start of an installed system:
  `rpool/kldload/state` (SQLite DB, `com.sun:auto-snapshot=true`),
  `rpool/kldload/playbooks` (user Ansible uploads, 1G quota,
  no-setuid/exec/devices), `rpool/kldload/secrets`
  (**AES-256-GCM encryption**, 100 MB quota, per-install raw key file,
  no-setuid/exec/devices).
- `state.db` holds only names + timestamps; secret values live as 0600
  files inside the encrypted dataset and are never logged.
- Current producer (user-visible): Secrets panel in the webui.
- Current consumers: `klab` reads `rhel-username`/`rhel-password`/
  `rhel-activation-key` when building the RHEL golden. Other use cases
  follow as features land.
- Live ISO explicitly refuses to adopt a target-disk rpool: if a stale
  pool is present (from a prior install attempt), the webui logs a
  WARNING and runs plain-mode on tmpfs overlay.

### Operator console (tmux drawer)

The terminal drawer reshapes the main content area via a CSS variable
so panels, VMs, logs never hide behind it. Every key is a toggle —
press to open, same key to close.

**Primary panes (F2-F12):**
- F2 k9s · F3 kldload-dash · F4 logs · F5 live firehose (loghog / `lh`)
- F6 htop · F7 k8s events · F8 hubble observe · F9 zpool iostat
- F10 scratch · F11 tcplife · F12 tcptop

**Deep-dive complements (Shift+F\<N\>):**
- Warnings-only events · dmesg --follow · doctor loop · iotop · kubectl top
- cilium drops · zfs iostat -l · kinspect picker · tcpretrans · tcpconnect

**Trace group (Alt+letter):**
- execsnoop · opensnoop · biosnoop · killsnoop · iftop · nethogs

**HUD popups (Alt+letter, auto-dismiss):**
- VMs & DHCP · cluster state · ZFS pools + ARC · WireGuard + routes ·
  disk+mem+cpu · uptime+who+last-logins

**Pane/window ops:**
- Alt+Enter new · Alt+\ vsplit · Alt+- hsplit · Alt+↔↕ walk panes
- Alt+x close pane · Alt+q / Ctrl+q close window
- Shift+↔ next/prev window · Shift+↕ newest/oldest

Home tab renders a 2-column ASCII-art cheatsheet (`_kconsole-home`)
with a `menu` shell alias to redraw anywhere.

New companion: a **ttyd-k9s** systemd unit serves `k9s` directly over
HTTP so the web UI K8s tab can embed a live terminal without an SSH
bounce.

### OpenZFS observability stack

This is the demo you'd bring to OpenZFS maintainers. Click a test
failure → see kernel stack, last zio, D-state blocked task, SMART
status, ARC state — all correlated on one timeline. Bundle is
paste-ready for `github.com/openzfs/zfs/issues/new`.

**Exporters, all enabled by default:**

- `zfs_exporter` (`:9134`) — per-pool/dataset metrics (fragmentation,
  dedup, compression, free/alloc)
- `smartctl_exporter` (`:9633`) — SMART attributes per disk
- `ebpf_exporter` (`:9435`) — biolatency histograms per block device
- `loki` (`:3100`) — single-node log aggregator, 7-day retention,
  TSDB filesystem backend
- `promtail` (`:9080`) — ships journald + kernel ring + zfs-dbgmsg +
  klab test logs to Loki
- `arcstats-exporter` — parses `/proc/spl/kstat/zfs/arcstats` via
  textfile collector (replaces the broken node_exporter zfs collector
  on newer kernels where `memory_available_bytes` format drifted)
- `zpool-scrub-exporter` — parses `zpool status` → scrub
  age/duration/errors + per-vdev error counts

**zed → Loki.** `/etc/zfs/zed.d/all-loki.sh` pushes every zpool event
(checksum error, resilver, scrub, trim, vdev state change) into Loki
with `{class, pool}` labels — so the kernel-messages dashboard and
ZFS health board light up the instant anything happens.

**Tetragon.** `zfs-execs` TracingPolicy audits
`zfs/zpool/zdb/ztest/zfs-tests.sh` execve events inside test pods.

**Grafana dashboards (8 bundled):**

1. `zfs-pool-health` — capacity, fragmentation, ARC hit rate, top-10
   datasets, zed event feed
2. `scrub-history` — days-since, duration, errors, per-vdev counts,
   zed timeline
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
  `.tar.gz` + OpenZFS-ready `ISSUE.md` containing `zdb`, tunables,
  kstat, D-state stacks, all-task stacks, SMART, packages.
  **Auto-invoked** by klab on watchdog timeout OR any `FAIL > 0`.
- `kldload-obs-check [--fix] [--vm X]` — 11-step end-to-end validation
  of the stack. Each failure points at the exact reproduction command.

### Install reliability drop

Every one of these was a concrete way 1.0.4 could leave you with an
unbootable system. All fixed:

- **ZFS hostid propagation** — live ISO's hostid is now copied into
  the target root and baked into the initramfs, so the pool imports
  the same way at every boot. (Old path: `chroot zgenhostid -f` →
  random hostid → rpool can't import → emergency shell.)
- **`dracut --no-hostonly` everywhere** — installer-generated initramfs
  ships drivers for every kernel module, not just what happened to be
  loaded on the live ISO when you ran the installer. No more "wrong
  NIC driver on first boot."
- **Hostname RFC 1123 validate + force-export** — fixes the "hostname
  drifts between `kldload` and `kldload-node` depending on which shell
  you look at" bug.
- **Timezone validate + force-export** — same pattern.
- **Fedora `zfs-release` retry loop** — tries `3-0 → 2-10 → 2-9 → 2-8 → 2-7`
  until one resolves. zfsonlinux sometimes lags a Fedora bump by a
  revision.
- **Atomic download of cloud qcow2 images** in kube-cluster — eliminates
  a race where two concurrent bootstrap attempts truncated each other's
  download.
- **MOK key**: unique Subject per install + `--ignore-keyring` — fixes
  Secure Boot signing when a stale keyring was lying around.
- **Ansible playbook library always-copies** on install with a loud
  WARNING if the library is missing on the live root — previously
  silent failure.
- **Install integrity check** — post-install validation of required
  tool binaries, systemd units, and darksite presence.

### Hardware enablement — laptop-ready desktop profile

The desktop profile grew by ~350 MB of hardware enablement, codecs,
and fonts. The 1.0.4 desktop booted clean but then you had a laptop
with no WiFi, no webcam, no printer, and Liberation Sans.

All hardware packages are pulled from the distro darksites at
install time (not baked into the live squashfs) — applies to the
RPM path on CentOS / Rocky / RHEL / Fedora, with Debian/Ubuntu
equivalents added to their respective target package sets.

**Firmware:**

- `linux-firmware` + `linux-firmware-whence` (all distros)
- **Fedora 43 firmware-split workaround** — bare `linux-firmware` on
  F43 carries only licenses. Explicit `iwlwifi-dvm-firmware`,
  `iwlwifi-mvm-firmware`, and `iwlwifi-mld-firmware` are added so
  recent Intel WiFi cards (AX201/210/211, BE200) actually come up at
  boot.
- `fwupd` — firmware updates via LVFS. Dell, Lenovo, System76 all
  publish BIOS/EC updates here.

**CPU / Platform:**

- `microcode_ctl` (Intel + AMD microcode) — without this, modern
  CPUs run at stale microcode revision and can miss silicon errata
  workarounds.
- `thermald`, `tlp`, `tlp-rdw`, `powertop`, `brightnessctl`, `ddcutil`
- `tpm2-tools`, `libfido2`, `libfido2-devel`, `pcsc-lite`, `opensc`
  (smartcards, YubiKey, FIDO2)

**GPU + Hardware video decode:**

- `mesa-dri-drivers`, `mesa-vulkan-drivers`, `mesa-va-drivers`
- `vulkan-loader`, `vulkan-tools`
- `intel-media-driver` + `libva` + `libva-utils` — hardware H.264/H.265
  decode path; without this, modern Firefox/Chrome/Teams/Zoom pin the
  CPU on any video stream and 4K YouTube chugs.

**Audio + codecs (PipeWire stack, free/open):**

- `alsa-sof-firmware`, `alsa-ucm` — Intel SOF DSP firmware. Modern
  ThinkPads/XPSes have dead audio without this.
- `pipewire`, `pipewire-pulseaudio`, `pipewire-alsa`,
  `pipewire-gstreamer`, `pipewire-libcamera`, `pipewire-codec-aptx`
- `wireplumber`
- `gstreamer1-plugins-{good,bad-free,base}`, `gstreamer1-libav`,
  `gstreamer1-plugin-openh264`, `mozilla-openh264`

**Desktop portal (Wayland screen-sharing):**

- `xdg-desktop-portal`, `xdg-desktop-portal-gnome`,
  `xdg-desktop-portal-gtk` — Zoom, Teams, Discord, Firefox
  getDisplayMedia, OBS all need this. Without it, "Share Screen"
  produces a black rectangle.

**Input:**

- `xorg-x11-drv-libinput` — laptop touchpad tap-to-click, scroll,
  gestures
- `libwacom`, `xorg-x11-drv-wacom` — Wacom tablets and pen displays
- `bluez`, `bluez-tools` — Bluetooth

**Cameras:**

- `libcamera`, `libcamera-tools` — Intel IPU6 webcams (recent ThinkPads,
  XPS, Framework) require libcamera; legacy UVC webcams still work via
  v4l2
- `v4l-utils`

**Print + scan:**

- `cups`, `cups-filters`, `cups-pk-helper`, `system-config-printer`
- `hplip` — HP-specific proprietary protocols
- `sane-backends`, `simple-scan` — scanners + AIO scanner heads

**Network: cellular, VPN, WWAN:**

- `ModemManager`, `NetworkManager-wwan`, `NetworkManager-ppp`
- `NetworkManager-openvpn` + `NetworkManager-openvpn-gnome`
- `NetworkManager-openconnect` + `NetworkManager-openconnect-gnome`
- `NetworkManager-wifi` + `wpa_supplicant` in the RPM base (were only
  on the Debian path in 1.0.4 — fresh CentOS/Rocky/Fedora/RHEL installs
  can now join WiFi without post-install package fetching)

**Storage:**

- `exfatprogs`, `ntfs-3g`, `cifs-utils`, `fuse3`, `fuse-common` — read
  most external USB sticks and network mounts out of the box.

**Installer form carries to the target:**

- WiFi SSID + PSK entered during install → written as an NM profile on
  the target so the machine reconnects to the same network on first
  boot.
- Hostname entered is normalized (RFC 1123, lowercase, dashes-only,
  ≤ 63 chars) with a clear error in the UI if invalid.

### Fonts — 180 families bundled (all profiles)

Up from ~10 stock. Installed on every profile, not just desktop, so
SSH + terminal apps in the console get the full set:

- **Latin / CJK / emoji**: Liberation, DejaVu, Noto (sans/serif/mono/
  CJK/emoji) — Noto covers every script Unicode defines
- **Programming**: Cascadia Code, JetBrains Mono, Fira Code,
  Adobe Source Code Pro
- **Document / UI**: Adobe Source (Sans/Serif), rsms Inter, Roboto,
  Open Sans
- **Math/scientific**: STIX

### SSH post-quantum KEX

EL9's crypto-policy DEFAULT excludes `mlkem768x25519-sha256` and
`sntrup761x25519-sha512@openssh.com` from the advertised KEX list
even though the shipped OpenSSH supports them (CentOS Stream 9 now
ships 9.9p1; Fedora 43 + Debian 13 ship 10.0p1). Ships an
additive drop-in at
`/etc/ssh/sshd_config.d/90-kldload-pq.conf` that appends both
PQ hybrids on top of the classical set. Modern SSH clients
(OpenSSH 9.9+, Ghostty's embedded client) no longer print the
"store now, decrypt later" advisory on connect. Nothing classical
is removed — it's purely additive.

### Ghostty terminfo

`xterm-ghostty` + `ghostty` terminfo entries bundled at
`/usr/share/terminfo/x/xterm-ghostty` and `/g/ghostty` on the live
ISO and every installed target (including the `core` profile).
Upstream ncurses hasn't picked up the entry yet and no target distro's
stock `ncurses-term` ships it, so SSH-in from Ghostty (Hashimoto's
terminal) used to land on a broken TERM — now it just works. Purely
additive for non-Ghostty users; ~4 KB on disk.

### Secure Boot — SBAT CSV for ZFSBootMenu

`bootloader.sh` now injects an SBAT CSV (`zfsbootmenu,1,...`) into the
ZBM EFI with `objcopy --update-section .sbat=` before MOK-signing.
Shim v15.8 policy 2021030218 now accepts it — no more
`mokutil --set-sbat-policy delete` workaround. MOK subject is unique
per install (prevents key conflicts) and `--ignore-keyring` skips a
stale kernel keyring.

### New operator tools

Full inventory of tools added since 1.0.4:

- `kldload-dash` — single-pane "is everything OK?" overview (host +
  Kubernetes + ZFS + running VMs + recent warnings), auto-refreshing.
- `kldload-doctor` — 33 checks across 10 subsystems (up from 22).
  Writes `/root/kldload-doctor.log` on every run.
- `kldload-obs-check` — 11-step observability validator, `--fix` mode
  repairs common drift.
- `kldload-console` (+ `_kconsole-home`, `_ktoggle-win`) — the 24-key
  tmux drawer.
- `kinspect` — pick two endpoints (VMs or pods); get a 3-pane tmux
  layout: each one under SSH + live `watch`, with a Hubble/tcpdump
  flow stream of every packet between them.
- `kldload-db` — CLI for the webui SQLite state DB.
- `kldload-inventory` — dynamic Ansible inventory over the WireGuard
  mesh.
- `kldload-lh` — cluster-wide log stitcher (C binary at `/opt/lh/src`,
  built during ISO assembly; wraps `fuse-sshfs` and tails across
  nodes).
- `kzfs-test`, `kztest-tail` — ZFS test runner + live log tail.
- `klab`, `klab-exporter`, `klab-prom-targets`, `klab-vm-debug-bundle`
  — the klab test platform CLIs.
- `arcstats-exporter`, `zpool-scrub-exporter` — textfile-collector
  bash exporters.
- `kldload-tls-cert`, `kldload-bounce-tls-services`,
  `kldload-wait-for-ip` — TLS cert lifecycle.
- `kspawn` — ZFS-native multi-runtime cluster spawner (see below).
- `bob`, `bob-agent`, `bob-bash`, `bob-desktop`, `bob-do`, `bob-home`,
  `bob-model`, `bob-remote`, `bob-sys`, `bob-voice`, `bob-splash`,
  `bob-ui` — Bob LLM CLI family.

### Bob — eyes, ears, and a voice

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
mic-permission button in the webui because Chrome revokes mic access
on self-signed TLS by default.

**Approve & Run actually dispatches** every execute tool (previous
build showed the button but some tools were silently ignored).

Strengthened system prompt with a diagnosis recipe so Bob reaches for
these tools by reflex. Silent disconnect handling — no tracebacks
when the browser tab closes mid-request. Bob chat is routed through
a WebSocket proxy so the browser never talks directly to Ollama (CORS
and auth stay on the server side).

**Tesseract OCR** bundled for Bob's screenshot path — paste a
screenshot of log output or an error message and Bob reads the text
without needing the 6 GB vision model.

Enabled by default on the k8s / kvm / zfslab tiles (DevOps had it
already).

### ZFS test suite — first-class

- **Separate golden lineage**: `klab-ztest-<distro>` images carry every
  `zfs-tests.sh` prerequisite (`ksh`, `fio`, `net-tools`, `pamtester`,
  `pax`, `cryptsetup`, `xxhash`, `nfs-utils`, `bzip2`, `perf`,
  pre-created loopback vdevs) — kept separate from the lean blue-green
  `klab-golden-<distro>` images.
- **One-command builds** — "Build all ZFS test goldens" button in the
  UI, or `klab golden-ztest all` from the CLI.
- **Multi-distro CLI** — `klab golden centos debian ubuntu` now
  iterates across all args (was silently dropping extras in 1.0.4).
- **Streaming output** — every `[PASS]` / `[FAIL]` / `[SKIP]` line
  visible in real time, prefixed with `[distro]`, interleaved readably
  across parallel runs.
- **Audit bundles** — every run writes
  `/root/klab/<run-id>/full.log` + `manifest.txt` + per-distro logs.
  Download as `.tar.gz` from the UI to attach to an OpenZFS bug
  report.
- **Auto debug bundle** — `klab-vm-debug-bundle` fires automatically on
  any `FAIL > 0` OR watchdog timeout. The `ISSUE.md` is paste-ready.
- **Per-distro watchdog** — `KLAB_IDLE_MAX` default 14400s (4h) kills
  stuck subprocess, marks `timeout`, captures the bundle before kill.
- **Per-distro 20-min ztest golden build timeout** so one wedged
  distro doesn't stall the whole batch.
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
goldens on firstboot, adds a lean 1-CP / 0-worker K8s cluster
alongside (so Grafana still renders), skips the full 4-node cluster
that k8s/kvm profiles get. Ollama/Bob enabled by default.

### Observability chain finally renders

- Cilium / Hubble / Tetragon dashboards light up with real data.
- Fixed: `${DS_PROMETHEUS}` placeholder stripping at firstboot,
  synthesized `k8s_app` / `pod` / `io_cilium_app` labels on Prometheus
  scrapes, bundled Tetragon Grafana dashboard (9 panels) since no
  upstream Grafana.com ID exists.
- `metrics-server` installs automatically, powers `kubectl top` and
  the K8s tab's live CPU/Mem overlays on every row.
- `kube-network` firewall trusts node subnet + pod CIDR so
  hubble-peer, kubelet metrics, and cilium/tetragon metrics traffic
  traverse nodes.
- Cilium-operator scrape now only fires on the node it's actually
  running on (hostPort only binds where the pod is — 3 nodes out of
  4 would always show "down").
- Tetragon is actually shipped + installed (was missing from the
  install path, dashboards rendered empty).
- `kube-cluster` does atomic qcow2 downloads so two concurrent
  bootstraps don't race.

### Firstboot ordering

`kldload-firstboot` now defers **all** klab golden builds to
`kldload-autodeploy` so nothing races libvirtd startup. Autodeploy
builds both blue-green and ztest goldens on hardware profiles, with
the ZFS-Lab-tile gate controlling whether ztest specifically builds.
libvirt `isos` pool is defined explicitly (golden builds need it);
no more ad-hoc `zfs-vms` pool definition that fought the ZFS-native
path. Obs stack installs on kvm/k8s/zfslab profiles too (was
DevOps-only in earlier 1.0.5 candidates).

### Distro updates

- **Fedora 41 → 43** — kernel 6.19+, current stable.
- CentOS stays 9 Stream (the bulletproof baseline).
- Debian 13 + Ubuntu 24.04 + Rocky 9 unchanged.
- Package additions to the darksite (RPM base): `iftop`, `nethogs`,
  `bcc-tools`, `pax`, `ansible-core`, `fuse-sshfs`, `tesseract` +
  `tesseract-langpack-eng`, `zfs-dracut`, `nss-tools`, `json-c` +
  `readline` + `ncurses-libs` (for LogHog).
- Server profile: added `swtpm`, `swtpm-tools` (software TPM for VM
  flows), plus `golang-github-prometheus` + `prometheus-node-exporter`
  + `grafana` for the observability stack.
- Debian/Ubuntu target-base now carries `ansible-core`, `iftop`,
  `libjson-c5`, `libnss3-tools`, `libreadline8`, `libtinfo6`,
  `nethogs`, `sshfs`, `tesseract-ocr`, `tesseract-ocr-eng`.
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
`download`, so we detect missing packages up-front rather than
letting dnf bail mid-transaction).

Because zfsonlinux.org doesn't always publish a current fc43
`zfs-release` RPM, the fedora darksite ships the **full DKMS build
chain** (`dkms`, `autoconf`, `automake`, `kernel-devel`,
`libblkid-devel`, `libuuid-devel`, `python3-devel`, `rpm-build`,
`gcc`, ...). ZFS compiles from source during install — same
userspace, same pool format, just built at install-time.

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

v1 is KVM-only + local host. Firecracker microVMs + remote hosts
(and the `role=k8s-master|worker|etcd` provisioning) are v1.1.
Because all state is derivable from the manifest + ZFS clones, there
is nothing to "upgrade" — you destroy and re-spawn.

---

## New systemd units (19)

Every new unit shipped in 1.0.5:

| Unit | Purpose |
|---|---|
| `kldload-tls-cert.service`+`.timer` | Self-signed TLS cert gen + weekly rotation + DHCP SAN refresh |
| `kldload-webui.service` | Installer / ops web UI (HTTPS :8443, Python + websockets) |
| `kldload-autodeploy.service` | Post-install golden builds + cluster bootstrap |
| `kldload-journal-flush.service` | Forces journald to disk on boot so dmesg history survives reboots |
| `loki.service` | Single-node Loki log aggregator (:3100) |
| `promtail.service` | Ships journald + kernel + zfs-dbgmsg + klab logs to Loki |
| `zfs_exporter.service` | Per-pool/dataset Prometheus metrics (:9134) |
| `smartctl_exporter.service` | SMART attributes per disk (:9633) |
| `ebpf_exporter.service` | Biolatency + bio-trace histograms (:9435) |
| `arcstats-exporter.service`+`.timer` | ARC stats via textfile collector |
| `zpool-scrub-exporter.service`+`.timer` | Scrub age/duration/errors via textfile collector |
| `klab-exporter.service` | klab test matrix metrics |
| `klab-hubble-relay.service` | Hubble relay for K8s observability |
| `klab-prom-targets.service`+`.timer` | Prometheus file_sd target refresh from libvirt state |
| `ttyd-k9s.service` | `k9s` over HTTP for the web UI's embedded terminal |

Plus `node_exporter.service.d/textfile.conf` wiring the textfile
collector directory for ARC + scrub exporters.

---

## Tested on

- **fiend (ASUS TUF X570)** — ZFSLAB profile running the 5-distro
  long OpenZFS test suite. centos / rocky / fedora / debian ≈98%
  pass. Ubuntu 58% — Canonical's vendored zfs-2.2.2 is the cause,
  not kldload. Full run is ~8.5h.
- **Dell XPS 13** — Debian 13 boots clean. Fedora 43 boots + WiFi
  works (post firmware-split fix). CentOS / Rocky still hit a kernel
  hang because Dell's BIOS defaults NVMe to RAID mode; switching to
  AHCI in BIOS resolves it. Not code-fixable.
- **Old UEFI laptop** — Debian 13 install works; webui-on-live-ISO
  regression found + fixed (live ISO no longer adopts a target-disk
  rpool; `kldload-webui` refuses to run as non-root). Field report,
  thanks @markmcl.

## Upgrade

Fresh install recommended. 1.0.4 → 1.0.5 changes enough that an
in-place package-manager upgrade won't deliver the new UI / console
/ tool set. Burn the new ISO, install, restore state from ZFS
snapshots if you had them.

## Known issues (punted to 1.0.6)

- **Profile gate `!= "core"` is too wide** — desktop/server profiles
  get bob+ansible+klab bleed-through. Needs per-tile gating.
- **RHEL credentials don't persist** past install to
  `/var/lib/kldload/secrets/`. Re-register is a manual step for now.
- **Fedora installer still uses metalink** instead of the bundled
  Fedora darksite on fresh networks. Works, but not offline-pure.
- **Ubuntu golden uses Canonical's vendored zfs-2.2.2** — switching
  to the zfsonlinux PPA is expected to push the pass rate from 58% →
  ~98%.
- **XPS 13 CentOS / Rocky** kernel hang on NVMe-RAID BIOS mode — user
  must switch to AHCI in BIOS. Dell default, not fixable in
  software.
- **Chrome captures F11/F12** (fullscreen/devtools); use Shift+F11/F12
  as the reliable bcc-tools keys on Chromium-based browsers. Firefox
  passes F11/F12 through to the tmux drawer.
- **Kernel↔ZFS pinning** not enforced — a distro kernel update on
  Fedora (fast-moving) or Debian/Ubuntu (DKMS path) can leave ZFS
  unbuildable until the next zfs-release. Tracking for 1.0.6: pin
  kernels at install on DKMS distros, add boot-time ZFS self-heal.
- **Ubuntu 24.04 target** still ships OpenSSH 9.6p1 (pre-ML-KEM);
  our PQ drop-in advertises `sntrup761x25519-sha512@openssh.com` there
  but not `mlkem768x25519-sha256`. Ubuntu moves when Canonical ships
  10.0+.

## The point

Install kldload on real hardware. Deploy your charts, your Ansible,
your workloads. Watch what the kernel is actually doing while your
product runs. Break things safely. Rebuild in seconds. Test every
distro before you ship. See every zpool event, every slow IO, every
ZFS kernel panic with the full stack trace already attached to a
bug-report-ready ISSUE.md.

The production-grade lab you always wanted and never had time to
build.
