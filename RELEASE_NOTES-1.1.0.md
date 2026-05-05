# kldload 1.1.0 — Hardware Reality

**Shipped 2026-05-04** · download at [dl.kldload.com](https://dl.kldload.com) · [`main`](https://github.com/kldload/kldload) is always current

> **212 commits since v1.0.4.** This release absorbs everything that
> would have been 1.0.5 (never tagged) plus the entire F44 cutover.
>
> **The platform has been re-architected.** The web UI is now a single
> sub-tabbed console behind a Go-native single-port TLS reverse proxy
> (`kldload-proxy`) that fronts every service — Grafana, Prometheus,
> Headlamp, Bob, ttyd-k9s, libvirt console — on **one URL with one
> certificate**. eBPF runtime security via **Tetragon** is wired all
> the way to Grafana panels. **klab** — the multi-distro test sandbox
> — graduated from "1.0.5 promise" to "the lab you build everything
> on": ZFS instant-clone goldens, OpenZFS test-suite runner across 7
> distros, WireGuard mesh, deterministic networking, eight Grafana
> dashboards.
>
> **The live environment cut over** from CentOS Stream 9 (kernel 5.14,
> OpenZFS 2.2) to **Fedora 44** (kernel 6.19, OpenZFS 2.4.1, shim 15.8,
> dnf5). The install path was rewritten end-to-end against real
> hardware until it stopped fighting the firmware and started routing
> through it.
>
> **Hardware enablement** got a 350 MB upgrade: microcode, thermal,
> PipeWire, Wayland portals, libcamera, 180 fonts, ModemManager + VPN
> plugins, fwupd LVFS, post-quantum SSH KEX. The 1.0.4 desktop booted
> clean and left you with no WiFi, no webcam, no printer. Not anymore.
>
> **Bob AI** is a real agentic assistant — voice → 18 read-only
> observability tools → multi-terminal → OCR vision → packet-flow
> attribution. Voice in, action out, kernel-level evidence on the
> way back.

---

## The 30-second pitch

> "Let's test this on CentOS" used to mean 25 minutes of ISO + packages
> + deploy. With kldload it's **2 seconds** — a ZFS-cloned VM appears
> with your product pre-installed, you test, destroy, clone another.
> Do it 50 times in a row without flinching.
>
> Then you watch what's happening at the kernel level — not what the
> app thinks is happening, what the kernel is actually doing — and
> bugs that used to take an hour become plainly visible the second
> they happen.

## Why this release matters

Two structural shifts happened together:

1. **Hardware truth.** The 1.0.x line shipped on CentOS Stream 9
   with kernel 5.14 and OpenZFS 2.2. Fine for VMs. On real hardware
   with newer NVMe controllers, recent NVIDIA cards, USB 3.2 sticks,
   and Secure Boot firmwares from 2024 onwards, the boot path was
   getting frayed at the edges: rootdelay races on slow USBs, NVIDIA
   DKMS conftest mismatches, shim-grub-kernel chain breakage on
   multi-kernel Rocky/RHEL installs, firmware-split brain damage on
   Fedora 43+, GDM crashing because `gnome-session-xsession` wasn't
   pulled in by default deps.

2. **One product, one proxy, one cert.** Pre-1.1.0 the platform was a
   constellation of services on different ports, each with its own
   self-signed cert. 1.1.0 introduces `kldload-proxy` — a Go-native
   single-port TLS reverse proxy that fronts the whole stack so you
   hit one URL, one cert, one UI, and SNI routes you to whatever you
   clicked on.

1.1.0 fixes both at once.

---

## Top use cases

| Role | What kldload gives you |
|---|---|
| **OpenZFS maintainer** | `klab test --full` across 5 distros, one auto-generated audit bundle per failure, paste-ready `ISSUE.md` for github.com/openzfs/zfs/issues. |
| **Developer** | "Does my chart/playbook still work on every distro?" — one command, parallel test. No cloud bill. |
| **SRE / platform engineer** | Practice rig for eBPF, bpftrace, Cilium, Hubble, Tetragon. Break things safely, see the kernel-level cause. |
| **Security researcher** | Isolated bare-metal sandbox for kernel/BPF/CNI experiments. Detonate samples, destroy the VM, clone a fresh one. |
| **Trainer / consultant** | Reproducible demo rig. Carry a USB to the customer, lab is running in 30 min. |
| **CI operator** | Plug USB into an office NUC → persistent 5-distro test runner, no cloud bill. |
| **Kernel/distro packager** | "Does this kernel/package still work with these workloads?" — one `klab test --full` away. |
| **Compliance / audit** | Run hardening, capture `full.log` + Tetragon events + doctor output, zip as audit bundle. |

---

## Headline themes

1. **Live environment: CentOS Stream 9 → Fedora 44** — kernel 6.19,
   OpenZFS 2.4.1, dnf5, shim 15.8, modern firmware coverage.
2. **Single-port TLS reverse proxy (`kldload-proxy`)** — one cert,
   one port, every service. Built in Go, ships as a unit, terminates
   TLS once.
3. **Unified web UI** — sub-tabbed workspaces for every resource
   (Kubernetes / KVM / klab / ZFS / Ansible / Helm / Bob / Tests),
   sticky headers, global search, per-table filters, live tab badges.
4. **klab — the multi-distro test sandbox** — first-class ZFS test
   suite runner across 7 distros, ZFS instant-clone goldens,
   blue-green deploys, deterministic networking via WireGuard mesh.
5. **24-key tmux operator console** — every watchable pane is one
   keystroke away, F2-F12 + Shift-F + Alt-letter HUDs.
6. **OpenZFS observability stack** — `zfs_exporter` + `smartctl` +
   eBPF biolatency + arcstats + scrub tracking + Loki + zed→Loki +
   8 Grafana dashboards, all baked in.
7. **Tetragon eBPF runtime security** — kernel-level process &
   syscall observability, plumbed into Grafana dashboards.
8. **Bob AI** — voice → 18 read-only diagnostic tools → multi-terminal
   → packet-flow vision → agentic execution.
9. **Hardware enablement** — laptop-ready desktop profile (microcode,
   thermal, PipeWire, libcamera IPU6, fwupd LVFS, ModemManager, VPN
   plugins, 180 fonts).
10. **Install reliability** — hostid propagation, `dracut --no-hostonly`
    everywhere, kernel-staging, NVIDIA DKMS race, MOK leaf cert,
    50+ targeted fixes for hardware that was actually failing.
11. **kldload-ca PKI** — per-install trust root, automatic cert
    issuance for every service, no separate cert-management UX.
12. **Real Secure Boot toolchain** — distro-signed boot chain,
    MOK-signed kernel modules, `kldload-sb` enable/disable/status CLI,
    `kldload-secure-boot` reenroll path.
13. **kspawn — ZFS-native multi-runtime cluster spawner** — clone N
    VMs from a golden in parallel, cloud-init-injected, manifest-tracked.
14. **Encrypted credentials store** — AES-256-GCM-encrypted ZFS
    dataset for secrets, plain-mode on live ISO, `rpool/kldload/secrets`
    on installed systems.
15. **Test harness** — `tests/lifecycle.sh` (KVM-driven full install
    smoke) + `tests/lifecycle-matrix.sh` (cross-distro × cross-profile
    matrix runner).

---

## 1. Live environment: CentOS Stream 9 → Fedora 44

| Component | 1.0.x | 1.1.0 |
|---|---|---|
| Kernel | 5.14.0-el9 | **6.19.14-fc44** |
| OpenZFS | 2.2.x | **2.4.1** |
| shim | 15.6 | **15.8** |
| dnf | dnf4 | **dnf5** |
| Builder image | `centos-stream:9` | **`fedora:44`** |
| Init / sessions | systemd 252 | **systemd 256 + dbus-broker** |
| Rescue toolset | basic | gparted, testdisk, ddrescue, fsarchiver |

What this unlocks:

- Modern NVMe / Wi-Fi 7 / Bluetooth 5.4 firmware fully supported in
  the live env.
- USB-C / Thunderbolt boot paths work without manual `rd.retry`
  tuning.
- NVIDIA driver chain matches what users run in 2026.
- Fedora 43+ `linux-firmware` split correctly handled —
  `iwlwifi-{dvm,mvm,mld}-firmware`, `realtek-firmware`,
  `atheros-firmware` explicitly installed.
- Bootstrap repos swapped in `bootstrap.sh`; Python `websockets`
  dependency now satisfied by the F44 RPM (no more pip-install
  workaround during build).

---

## 2. kldload-proxy — single-port TLS reverse proxy

**The biggest architectural change since 1.0.0.**

```
           https://<host>/             →  kldload-webui
           https://<host>/grafana/     →  Grafana (3000)
           https://<host>/prometheus/  →  Prometheus (9090)
           https://<host>/headlamp/    →  k8s Headlamp (4466)
           https://<host>/console/     →  libvirt VNC console
           https://<host>/k9s/         →  ttyd-k9s embedded terminal
           wss://<host>/               →  Bob chat over WebSocket
```

Properties:

- **One cert** issued by `kldload-ca` covers every backend.
- **TLS terminated once** at the proxy; backends run plain HTTP on
  the loopback.
- **WebSocket-aware** — preserves `Connection: Upgrade` headers,
  preserves `Transfer-Encoding: chunked` on response forwarding.
- **Body-buffer accounting** — handles "body bytes already drained
  from the headers read" edge cases.
- **Concurrent cert issuance is serialized** + atomic install so two
  services starting at the same boot can't race the cert lock.
- **`bounce-tls-services`** restarts kldload-proxy too on cert
  renewal.
- **Grafana CSRF policy** trusts all origins because the proxy
  terminates TLS separately.

### Stage-2 nginx + Headlamp scaffold

A second proxy layer for scenarios where users want Headlamp or
similar at a clean sub-path. Ships as `kldload-session`,
`kldload-headlamp-install`, `kldload-session-run`. Optional, off by
default.

---

## 3. Unified web UI — sub-tabbed workspaces

Pre-1.1.0 the web UI was a single-page installer that became a
dashboard after install. Now it's a **single-page application with
sub-tabbed workspaces for every resource type**, behind the proxy,
with Grafana / Headlamp / k9s embedded as iframes that share the
same TLS cert.

- **HTTPS out of the box on port 8443.** Self-signed TLS cert
  generated on first start by `kldload-tls-cert`, regenerated on DHCP
  IP change, rotated weekly via timer. Cert is valid for hostname +
  every live IP (LAN, WireGuard, loopback).
- **Explicit 🔓 "Grant microphone access" button** next to the 🎤 mic
  — Chromium revokes `getUserMedia()` on self-signed certs by
  default, so we can't just rely on the browser prompt.
- **HTTP `:8080` retired** from the installer role. Installer URL is
  `https://<host>:8443`.
- **Non-root invocations refuse cleanly** with a clear message —
  previously silent EPERM-cascaded into a SQLite readonly-DB
  traceback.
- **Install/klab subprocesses run under `systemd-run` transient units**
  — cgroup-isolated from the webui.

### Workspaces

| Workspace | Sub-tabs |
|---|---|
| **Kubernetes** | Nodes / Pods / Deployments / Services / Events / Apply YAML |
| **KVM** | Overview / VMs / Networks / Storage / Snapshots / Log |
| **klab** | Status / Goldens / Operations / eBPF |
| **Tests → ZFS Suite** | Run / Results / History / Audit / Live log |
| **Ansible** | Playbook upload / dynamic inventory / run |
| **Helm** | Chart upload / repo / one-click deploy |
| **ZFS** | Pools / Datasets / Snapshots / Health |
| **Bob AI** | Voice / chat / multi-terminal / agentic |
| **Observability** | Grafana iframe (kiosk=1) |

Plus: **clickable rows expand** to events/containers/logs, multi-select
bulk actions, live tab badges, last-subtab persistence across reloads.

### Encrypted credentials store

- ZFS namespace created on first start of an installed system:
  `rpool/kldload/state` (SQLite DB, `com.sun:auto-snapshot=true`),
  `rpool/kldload/playbooks` (Ansible uploads, 1 GB quota,
  no-setuid/exec/devices), `rpool/kldload/secrets` (**AES-256-GCM
  encryption**, 100 MB quota, per-install raw key, no-setuid/exec).
- `state.db` holds only names + timestamps; secret values live as
  0600 files inside the encrypted dataset and are never logged.
- Live ISO refuses to adopt a target-disk rpool; if a stale pool is
  present the webui logs a WARNING and runs plain-mode on tmpfs
  overlay.

---

## 4. Operator console — 24-key tmux drawer

Every watchable pane is one keystroke away. The drawer reshapes the
main content area via a CSS variable so panels, VMs, logs never hide
behind it. Every key is a toggle.

**Primary panes (F2-F12):**

- F2 k9s · F3 ZFS test tail (`kztest-tail`) · F4 logs · F5 live
  firehose (loghog / `lh`)
- F6 htop · F7 k8s events · F8 hubble observe · F9 zpool iostat
- F10 scratch · F11 tcplife · F12 tcptop

**Deep-dive complements (Shift+F\<N\>):**

- Warnings-only events · dmesg --follow · doctor loop · iotop ·
  kubectl top
- cilium drops · zfs iostat -l · kinspect picker · tcpretrans ·
  tcpconnect

**Trace group (Alt+letter):**

- execsnoop · opensnoop · biosnoop · killsnoop · iftop · nethogs

**HUD popups (Alt+letter, auto-dismiss):**

- VMs & DHCP · cluster state · ZFS pools + ARC · WireGuard + routes ·
  disk+mem+cpu · uptime+who+last-logins

Home tab renders a 2-column ASCII-art cheatsheet (`_kconsole-home`)
with a `menu` shell alias to redraw anywhere.

**ttyd-k9s** systemd unit serves `k9s` directly over HTTP so the web
UI K8s tab can embed a live terminal without an SSH bounce.

---

## 5. klab — the multi-distro test sandbox

Renamed from "OpenZFS Test Lab", and from "DevOps profile" before
that. By 1.1.0 klab is the **substrate** the rest of the platform
runs on: hypervisor + multi-distro test runner + WireGuard mesh +
observability stack + web UI in one.

### kzfs-test — OpenZFS test matrix runner

Run the real OpenZFS test suite across **7 distros** from one host:
CentOS Stream 9, Debian 13, Ubuntu 24.04, Fedora 44, Rocky 9, RHEL 9,
Arch. Each is a ZFS-cloned VM brought up from a golden image in
~100ms, runs the suite, reports back. Tear down. Spawn another.

- **Separate golden lineage** — `klab-ztest-<distro>` images carry
  every `zfs-tests.sh` prerequisite (`ksh`, `fio`, `net-tools`,
  `pamtester`, `pax`, `cryptsetup`, `xxhash`, `nfs-utils`, `bzip2`,
  `perf`, pre-created loopback vdevs) — kept separate from the lean
  blue-green `klab-golden-<distro>` images.
- **One-command builds** — "Build all ZFS test goldens" button in
  the UI, or `klab golden-ztest all` from the CLI.
- **Multi-distro CLI** — `klab golden centos debian ubuntu` iterates
  across all args (was silently dropping extras in 1.0.4).
- **Streaming output** — every `[PASS]`/`[FAIL]`/`[SKIP]` line visible
  in real time, prefixed with `[distro]`, interleaved readably across
  parallel runs.
- **Audit bundles** — every run writes `/root/klab/<run-id>/full.log`
  + `manifest.txt` + per-distro logs. Download as `.tar.gz` from the
  UI.
- **Auto debug bundle** — `klab-vm-debug-bundle` fires automatically
  on any `FAIL > 0` OR watchdog timeout. The `ISSUE.md` is paste-ready
  for `github.com/openzfs/zfs/issues/new`.
- **Per-distro watchdog** — `KLAB_IDLE_MAX` default 14400s (4h).
- **Per-distro 20-min ztest golden build timeout.**
- **Parallel cap** — 80% of host cores by default
  (`KLAB_MAX_CONCURRENT` overrides).
- **Per-test checklist parser** — audit panel parses every `Test: …
  [PASS|FAIL|SKIP]` line into a sortable table.
- **RHEL 9 support** with `subscription-manager` activation +
  credential redaction in logs.
- **DKMS autoinstall** if the cloned VM's ZFS module fails to load
  due to kernel mismatch.
- **Heredoc-stdin survival** — current version writes the test
  script to the remote first then executes (single-file, no stdin
  trick).
- **F3 = live ZFS test tail** (`kztest-tail`) console for watching
  test output in real time.

### klab observability stack (auto-installed)

Eight Grafana dashboards, plus exporters wired to Prometheus and Loki:

1. `zfs-pool-health` — capacity, fragmentation, ARC hit rate, top-10
   datasets, zed event feed
2. `scrub-history` — days-since, duration, errors, per-vdev counts,
   zed timeline
3. `compression-trend` — pool-wide ratio, per-dataset over time
4. `disk-health-smart` — NVMe spare/used/temp, iops, throughput
5. `block-io-latency` — p50/p99/p99.9 histograms per device (eBPF)
6. `kernel-messages` — log volume, kernel ring, ZFS-related messages
7. `klab-test-matrix` — pass/fail/skip, per-distro status,
   progression
8. `klab-test-debug` — per-VM hung_task, kernel ring, dbgmsg, FAIL
   markers, debug bundles

### Profiles

- **ZFS Lab** — test-suite-first install profile. Builds the
  `klab-ztest-*` goldens on firstboot, lean K8s (1 CP, 0 workers)
  alongside, skips the full 4-node cluster. Ollama/Bob enabled.
- All `kvm`/`k8s`/`zfslab` tiles install the obs stack (was
  DevOps-only in earlier candidates).

### Static IPs + WireGuard mesh

Every klab node auto-joins a `/24` WireGuard mesh on first boot.
Site VMs get deterministic static addresses. Mesh is the transport
for Prometheus federation + Tetragon event shipping.

---

## 6. OpenZFS observability stack

This is the demo you'd bring to OpenZFS maintainers. Click a test
failure → see kernel stack, last zio, D-state blocked task, SMART
status, ARC state — all correlated on one timeline. Bundle is
paste-ready for upstream.

**Exporters, all enabled by default:**

| Exporter | Port | What it provides |
|---|---|---|
| `zfs_exporter` | 9134 | per-pool/dataset metrics (fragmentation, dedup, compression, free/alloc) |
| `smartctl_exporter` | 9633 | SMART attributes per disk |
| `ebpf_exporter` | 9435 | biolatency histograms per block device |
| `loki` | 3100 | single-node log aggregator, 7-day retention, TSDB filesystem backend |
| `promtail` | 9080 | ships journald + kernel ring + zfs-dbgmsg + klab logs to Loki |
| `arcstats-exporter` | textfile | parses `/proc/spl/kstat/zfs/arcstats` |
| `zpool-scrub-exporter` | textfile | parses `zpool status` → scrub age/duration/errors |
| `klab-exporter` | textfile | live klab state (VM list, IPs, golden image age, generations) |
| `kvm-exporter` | textfile | per-VM disk/cpu/mem usage |
| `zfs-deep-exporter` | textfile | ARC internals, dataset properties, snapshot lag |
| `ebpf-events-exporter` | textfile | Tetragon event counts |

**zed → Loki.** `/etc/zfs/zed.d/all-loki.sh` pushes every zpool event
(checksum error, resilver, scrub, trim, vdev state change) into Loki
with `{class, pool}` labels.

**Helper tools:**

- `klab-vm-debug-bundle <distro> <run_id> [ip] [--deep]` — generates
  `.tar.gz` + OpenZFS-ready `ISSUE.md` containing `zdb`, tunables,
  kstat, D-state stacks, all-task stacks, SMART, packages.
  Auto-invoked by klab on watchdog timeout OR `FAIL > 0`.
- `kldload-obs-check [--fix] [--vm X]` — 11-step end-to-end validation
  of the observability stack.

---

## 7. Tetragon — eBPF runtime security

Tetragon now ships in 1.1.0 with full Grafana plumbing.

- **Process flow tracing** — every exec, fork, exit captured.
- **Syscall flow** — read/write/connect/socket events.
- **Packet flow attribution** — packets tagged with the originating
  process, visible in the Traffic Map.
- **kprobe-based observation** — kernel-level visibility, no
  application instrumentation required.
- **`zfs-execs` TracingPolicy** audits `zfs/zpool/zdb/ztest/zfs-tests.sh`
  execve events inside test pods.
- **Tetragon UI plumbing fix** — actually ship + install Tetragon so
  its dashboards populate (was loadable but not loaded in pre-1.1.0
  candidates).
- **eBPF deep-dive demos** added to `kube-demo` (demos 22-24).

This is the "advanced messaging" surface — kernel-to-application
event correlation, not just metric aggregation.

---

## 8. Bob AI — eyes, ears, and a voice

Bob graduated from "kldload-aware chat" to "agent that can actually
do things on the system." Bob can answer "why is hubble-relay not
ready?" by calling `k8s_events → k8s_describe → k8s_logs →
kernel_dmesg` in sequence.

**18 read-only observability tools (default):**

- **Kubernetes**: `get_pods`, `get_nodes`, `describe`, `logs`, `events`
- **Prometheus**: `prom_query` (arbitrary PromQL)
- **ZFS**: `zfs_status`, `zfs_arc_stats`
- **Host**: `host_vitals`, `top_procs`, `ss_sockets`
- **CNI / eBPF**: `hubble_observe`, `cilium_monitor`, `cilium_status`,
  `cilium_endpoint_list`, `tetragon_watch`, `kernel_dmesg`,
  `bpftrace_oneliner` (human-approved)
- **Self**: `doctor_check`

**Voice input** — click the mic once, talk forever (open-mic mode).
TTS self-talk ignored (Bob doesn't hear itself). Explicit
mic-permission button in the webui because Chrome revokes mic access
on self-signed TLS.

**Approve & Run** dispatches every execute tool. Strengthened system
prompt with a diagnosis recipe so Bob reaches for these tools by
reflex. Silent disconnect handling — no tracebacks when the browser
tab closes mid-request.

**Bob chat over WebSocket proxy** — proxied via kldload-proxy, not
direct browser → Ollama (CORS + auth stay on the server side).

**Tesseract OCR** bundled — paste a screenshot of log output or an
error message and Bob reads the text without needing a 6 GB vision
model.

**Tool-call rescue** — text-emitted tool calls (LLM forgets the JSON
envelope) are now caught and parsed instead of hallucinated as text.

**Loop-cap bumped + prompt tightened** for agentic execution that
needs ≥10 sequential tool calls.

**Post-quantum SSH KEX** advertised on every kldload sshd —
`sntrup761x25519-sha512` + `mlkem768x25519-sha256` (where the OpenSSH
version supports them).

**Bob CLI family**: `bob`, `bob-agent`, `bob-bash`, `bob-desktop`,
`bob-do`, `bob-home`, `bob-model`, `bob-remote`, `bob-sys`,
`bob-voice`, `bob-splash`, `bob-ui`.

---

## 9. Hardware enablement — laptop-ready desktop

The desktop profile grew by ~350 MB of hardware enablement, codecs,
fonts. The 1.0.4 desktop booted clean but then you had a laptop with
no WiFi, no webcam, no printer, and Liberation Sans.

**Firmware:**

- `linux-firmware` + `linux-firmware-whence` (all distros)
- **Fedora 43+ firmware-split workaround** — bare `linux-firmware`
  carries only licenses on F43+. Explicit `iwlwifi-dvm-firmware`,
  `iwlwifi-mvm-firmware`, `iwlwifi-mld-firmware`, `realtek-firmware`,
  `atheros-firmware`.
- `fwupd` — firmware updates via LVFS.

**CPU / Platform:**

- `microcode_ctl` (Intel + AMD microcode)
- `thermald`, `tlp`, `tlp-rdw`, `powertop`, `brightnessctl`, `ddcutil`
- `tpm2-tools`, `libfido2`, `libfido2-devel`, `pcsc-lite`, `opensc`
  (smartcards, YubiKey, FIDO2)

**GPU + hardware video decode:**

- `mesa-dri-drivers`, `mesa-vulkan-drivers`, `mesa-va-drivers`
- `vulkan-loader`, `vulkan-tools`
- `intel-media-driver` + `libva` + `libva-utils` — hardware H.264/H.265

**Audio (PipeWire stack, free/open):**

- `alsa-sof-firmware`, `alsa-ucm`
- `pipewire`, `pipewire-pulseaudio`, `pipewire-alsa`,
  `pipewire-gstreamer`, `pipewire-libcamera`, `pipewire-codec-aptx`
- `wireplumber`
- `gstreamer1-plugins-{good,bad-free,base}`, `gstreamer1-libav`,
  `gstreamer1-plugin-openh264`, `mozilla-openh264`

**Desktop portal (Wayland screen-sharing):**

- `xdg-desktop-portal`, `xdg-desktop-portal-gnome`,
  `xdg-desktop-portal-gtk` — Zoom, Teams, Discord, Firefox
  getDisplayMedia, OBS all need this.

**Input:**

- `xorg-x11-drv-libinput`, `libwacom`, `xorg-x11-drv-wacom`
- `bluez`, `bluez-tools`

**Cameras:**

- `libcamera`, `libcamera-tools` — Intel IPU6 (recent ThinkPads, XPS,
  Framework). Legacy UVC still via v4l2.
- `v4l-utils`

**Print + scan:**

- `cups`, `cups-filters`, `cups-pk-helper`, `system-config-printer`
- `hplip` — HP-specific protocols
- `sane-backends`, `simple-scan`

**Network: cellular, VPN, WWAN:**

- `ModemManager`, `NetworkManager-wwan`, `NetworkManager-ppp`
- `NetworkManager-openvpn` + `-openvpn-gnome`
- `NetworkManager-openconnect` + `-openconnect-gnome`
- `NetworkManager-wifi` + `wpa_supplicant` in RPM base (was Debian-only
  in 1.0.4)

**Storage:**

- `exfatprogs`, `ntfs-3g`, `cifs-utils`, `fuse3`, `fuse-common`

**Installer-form-carries-to-target:**

- WiFi SSID + PSK entered during install → NM profile written on the
  target so the machine reconnects on first boot.
- Hostname is normalized (RFC 1123, lowercase, dashes-only, ≤63 chars)
  with a clear error in the UI if invalid.

### Fonts — 180 families bundled (all profiles)

Up from ~10 stock. Installed on every profile, not just desktop, so
SSH + terminal apps in the console get the full set:

- **Latin / CJK / emoji**: Liberation, DejaVu, Noto (sans/serif/mono/
  CJK/emoji)
- **Programming**: Cascadia Code, JetBrains Mono, Fira Code, Adobe
  Source Code Pro
- **Document / UI**: Adobe Source (Sans/Serif), rsms Inter, Roboto,
  Open Sans
- **Math/scientific**: STIX

### SSH post-quantum KEX

Additive drop-in at `/etc/ssh/sshd_config.d/90-kldload-pq.conf` that
appends `mlkem768x25519-sha256` + `sntrup761x25519-sha512@openssh.com`
on top of the classical KEX list. Modern SSH clients (OpenSSH 9.9+,
Ghostty's embedded client) no longer print the "store now, decrypt
later" advisory on connect.

### Ghostty terminfo

`xterm-ghostty` + `ghostty` terminfo entries bundled at
`/usr/share/terminfo/x/xterm-ghostty` and `/g/ghostty` on the live
ISO and every installed target (including the `core` profile). SSH-in
from Ghostty no longer lands on a broken TERM.

---

## 10. Install reliability — the hardware-truth pass

Each item below was found by installing onto **real hardware** and
watching it fail. Each is a discrete commit with a comment in the
source explaining the failure mode.

### Boot path

- **Promoted compat cmdline to default**, added `rootdelay` +
  `rd.retry` for slow USBs, added a Compatibility entry for HP /
  2-second USB carriers.
- **Silent ZBM chainload** — clean direct boot under non-SB without
  flashing the ZBM splash.
- **Auto-refresh ESP grubx64.efi on distro update** —
  `kldload-grub-refresh.path` systemd path unit watches
  `/boot/efi/EFI/BOOT/grubx64.efi`, syncs from distro on upgrade.

### Kernel staging (the Rocky 9 fix)

Multi-kernel installs (e.g. dnf pulling in both `kernel-697.el9` and
`kernel-611.49.1.el9_7`) routinely leave one kernel without a usable
initramfs because DKMS only builds zfs.ko for the kernel matching
chroot's running headers. Old code blindly picked the highest version,
found vmlinuz, found NO initramfs, logged a warning, left
`/EFI/BOOT/` empty of kernel files. The result: GRUB option 1 silently
dropped to dracut emergency shell at boot.

1.1.0 picks the highest-versioned kernel that has BOTH a vmlinuz AND
a matching initramfs.

### Multi-signature kernel re-signing under SB

`sbsign` appends rather than replaces, so naively re-signing the
distro-supplied kernel produced a multi-signature PE. Some shim
versions iterate properly and accept; some only check the first
signature and reject. 1.1.0 strips the existing signature with
`sbattach --remove` first, then signs once with the kldload MOK leaf.

### NVIDIA DKMS race

Chroot-time DKMS fails on conftest macros.h corruption. Installer
parks `nouveau-blacklist` + `xorg.conf` aside, firstboot retries DKMS
on the running kernel, restores parked configs, regenerates the
initramfs so the next boot has nouveau properly blacklisted. Captures
DKMS build log on failure.

### MOK code-signing leaf cert

Real Secure Boot fix — the previous approach reused the kldload-ca
root as the MOK, which has `CA:TRUE` + multi-EKU + an
Authenticode-incompatible structure. shim accepted the enrollment but
rejected the actual signatures. 1.1.0 generates a dedicated leaf cert
(no `v3_ca` extensions, single `codeSigning` EKU) for PE signing.
`sbverify` goes from "Signature verification failed" to "OK".

### Hostid propagation (1.0.5 fix, validated in 1.1.0)

ZFS hostid must match: live env `/etc/hostid` → target `/etc/hostid` →
initramfs `/etc/hostid` → pool stamp. Fixed end-to-end. Final
`force-sync /target/etc/hostid right before dracut runs` ensures the
initramfs is built with the right value.

### `dracut --no-hostonly` everywhere

Installer-generated initramfs now ships drivers for every kernel
module, not just what happened to be loaded on the live ISO when you
ran the installer. No more "wrong NIC driver on first boot."

### Per-distro install fixes

| Distro | Fix |
|---|---|
| Debian Trixie | LightDM (GDM 48 systemd-integration bug); `libpam-gnome-keyring`, `libpam-systemd`, `dbus-x11`, `xdg-desktop-portal-{gnome,gtk}`; nginx user `www-data` (was `nginx`) |
| Ubuntu 24.04 | universe component for ZFS, retain `gdm3` (Ubuntu's GDM 46 unaffected) |
| Rocky / RHEL / CentOS desktop | `gnome-session-xsession` package added — without it `/usr/share/xsessions/` is empty and GDM 40 on NVIDIA hardware crashes "no session desktop files installed" |
| Fedora 43+ target | bootupd shim/grub paths (`/usr/lib/efi/...` not `/boot/efi/EFI/<distro>/`); zfs-dracut release pinning |
| Arch | online-only by design |
| Alpine | core profile only; mkinitfs path; **removed from klab** (apk + busybox stack not uniform with the others) |

### Other install fixes

- **Hostname RFC 1123 validate + force-export.**
- **Timezone validate + force-export.**
- **Fedora `zfs-release` retry loop** — `3-0 → 2-10 → 2-9 → 2-8 → 2-7`
  fallback.
- **Atomic download of cloud qcow2** in `kube-cluster`.
- **MOK key**: unique Subject per install + `--ignore-keyring`.
- **Ansible playbook library always-copies** with WARNING if missing.
- **Install integrity check** — post-install validation of required
  binaries, units, darksite presence.
- **darksite chroot file:// URLs** — bind-mount `/root/darksite` to
  `/run/kldload-darksite` (same path inside and outside chroot).
- **chroot `command -v`** — bash builtin, not on PATH inside chroot;
  fixed several call sites to direct-path tests.
- **dnf5 `--skip-broken` position** — now post-subcommand (works on
  both dnf4 and dnf5).
- **Per-(distro,release) ZFS feature compatibility table.**
- **Pool race surviving** — defensive re-import on import-cache
  conflict; stop `zfs-zed` before pool ops.
- **Re-mount BE if rpool imported but `/target` unmounted.**
- **F44 zfs udev rule masked** to prevent races + per-command remount.
- **Live ISO → target hostid** — always copy with no early-return.
- **kldload-debug-bundle ships to install target** — auto-bundles on
  install failure for paste-into-issue.

---

## 11. Secure Boot architecture

Honest history: an interim approach in 1.0.5 development tried to sign
ZFSBootMenu ourselves with the MOK key and drop it in as the primary
`grubx64.efi`. That surfaced two real, gnarly toolchain bugs:

1. **`objcopy --update-section .sbat=… ` before sbsign corrupts the
   PE.** GNU binutils' PE writer rearranges section layout in ways
   sbsign's precomputed Authenticode hash doesn't reflect. sbsign
   reports success; every verifier rejects; shim throws
   `0x1a EFI_SECURITY_VIOLATION`.
2. **sbsigntools 0.9.5 on EL9** has broken PE hash computation for
   binaries with COFF section gaps — i.e. every EFI binary that
   matters. Fixed upstream in 0.9.6+.

**The shipped chain** is the smallest possible Secure Boot trust
footprint for a ZFS-on-root distro:

```
firmware
  └─ shim.efi          (Microsoft-signed, distro-shipped)
       └─ grubx64.efi  (RH/CentOS/Rocky/Fedora distro-signed —
                        already trusted by shim's embedded vendor cert)
            └─ vmlinuz (distro-signed by the same vendor cert,
                        re-signed with kldload MOK leaf in 1.1.0)
                 └─ zfs.ko (MOK-signed via DKMS sign_tool)
```

The only thing **we** sign is `zfs.ko` and the staged `vmlinuz`, with
the kldload MOK key. Everything else is already signed by trusted
vendor certs.

### Components

- **Per-install MOK leaf cert** generated fresh per install, no CA
  reuse, single EKU.
- **`kldload-ca init`** creates the per-install CA (separate from the
  MOK). Stamped with hostname + timestamp + random suffix.
- **`kldload-grub-refresh.path`** systemd path unit watches
  `/boot/efi/EFI/BOOT/grubx64.efi`, auto-refreshes on upgrade.
- **`kldload-secure-boot`** (`enable | disable | status | reenroll`)
  — replaces the vaporware tool from earlier 1.0.5 candidates.
- **`kldload-sb`** — a thinner CLI wrapper for enable/disable/status.

### Unified trust root

The kldload CA at `/etc/kldload/ca/root/ca.{crt,key,der}` signs TLS
certs for webui/grafana/k9s AND is enrolled as the MOK signing key.
One cert, one fingerprint covers browser trust and kernel module
signing.

(One bug worth flagging: `/var/lib/kldload` was previously the CA
location, and it's the mount point of `rpool/kldload/state`. Install-
time writes landed on the parent dataset, then the child mounted on
top at first boot and hid the install-time CA. Fixed by moving the CA
to `/etc/kldload/ca/` — never shadowed by sub-dataset mounts.)

### Expected MOK enrollment flow

1. BIOS: Secure Boot OFF (live USB can't SB-boot yet — see Known Gaps).
2. Install via web UI, leave Secure Boot checkbox ON.
3. Install completes, auto-reboots (pull USB).
4. Optional: flip BIOS Secure Boot ON during reboot.
5. MokManager blue screen: `Enroll MOK → Continue → kldload → Yes →
   reboot`.
6. Boots clean under Secure Boot. Browser trusts TLS. ZFS loads.

Full chain-of-trust walkthrough at
[kldload.com/learn/secure-boot-chain](https://kldload.com/learn/secure-boot-chain).

### Known SB gaps

- Live ISO's own `\EFI\BOOT\BOOTX64.EFI` is raw GRUB, not shim. Users
  with SB ON in firmware must turn SB OFF to boot the installer USB.
- Rocky 9 still rejects the re-signed kernel under SB despite the
  MOK leaf being enrolled. Tracked.

---

## 12. K8s / kube-cluster

- **Pre-flight libvirt default network** before `virt-install` —
  fixes `kube-cluster bootstrap` on fresh hosts where `virbr0` has no
  carrier yet.
- **kubeconfig + kubectl published to host BEFORE step 7** — you can
  `kubectl` from the host immediately, not after the cluster fully
  initializes.
- **Atomic download of cloud qcow2** — fixes a race where parallel
  `kube-cluster` invocations corrupted the source image.
- **AI / Ollama enabled by default** for k8s/kvm/zfslab tiles.
- **`metrics-server`** auto-installs, powers `kubectl top` and the
  K8s tab's live CPU/Mem overlays on every row.
- **`kube-network` firewall** trusts node subnet + pod CIDR so
  hubble-peer, kubelet metrics, and cilium/tetragon traffic traverse
  nodes.
- **Cilium-operator scrape** only fires on the node it's actually
  running on (hostPort only binds where the pod is).
- **VM ops + ANSI stripping + K8s destroy-confirm** — UX hardening
  across the lifecycle.
- **kube-demo** — 21+ interactive options exercising every layer.
  eBPF deep-dives are demos 22-24.

---

## 13. kspawn — ZFS-native multi-runtime cluster spawner

New top-level CLI introduced in late 1.0.5 development, hardened in
1.1.0:

```
kspawn spawn --name web --distro debian --count 5
```

Clones 5 VMs from the klab debian golden **in parallel**, injects
cloud-init (hostname + SSH key per node), boots them, writes a JSON
manifest at `/var/lib/kspawn/clusters/<name>/manifest.json`.

Subcommands: `spawn` / `list` / `status` / `ssh` / `destroy`.

v1 is KVM-only + local host. Firecracker microVMs + remote hosts +
`role=k8s-master|worker|etcd` provisioning are v1.1. Because all state
is derivable from the manifest + ZFS clones, there is nothing to
"upgrade" — destroy and re-spawn.

---

## 14. Operator tools (full inventory since 1.0.4)

| Tool | What it does |
|---|---|
| `kldload-dash` | single-pane "is everything OK?" overview (host + k8s + ZFS + VMs + warnings) |
| `kldload-doctor` | 33 checks across 10 subsystems. Writes `/root/kldload-doctor.log` on every run |
| `kldload-obs-check` | 11-step observability validator. `--fix` repairs common drift |
| `kldload-debug-bundle` | one-command state collection on install failure |
| `kldload-console` (+ `_kconsole-home`, `_ktoggle-win`) | the 24-key tmux drawer |
| `kinspect` | pick two endpoints; get a 3-pane tmux layout: each one under SSH + live `watch`, with Hubble/tcpdump flow stream |
| `kldload-db` | CLI for the webui SQLite state DB |
| `kldload-inventory` | dynamic Ansible inventory over the WireGuard mesh |
| `kldload-lh` | cluster-wide log stitcher (C binary at `/opt/lh/src`) |
| `kzfs-test`, `kztest-tail` | ZFS test runner + live log tail |
| `klab`, `klab-exporter`, `klab-prom-targets`, `klab-vm-debug-bundle` | klab platform CLIs |
| `arcstats-exporter`, `zpool-scrub-exporter` | textfile-collector bash exporters |
| `kldload-tls-cert`, `kldload-bounce-tls-services`, `kldload-wait-for-ip` | TLS cert lifecycle |
| `kldload-proxy` | single-port TLS reverse proxy (Go) |
| `kldload-ca` | per-install PKI CLI |
| `kldload-secure-boot`, `kldload-sb` | SB enable/disable/status/reenroll |
| `kldload-grub-refresh` | ESP grubx64.efi auto-refresh on distro upgrade |
| `kspawn` | ZFS-native multi-runtime cluster spawner |
| `kbe` | boot-environment management |
| `kupgrade` | distro-aware upgrade |
| `krecovery` | recovery-shell helper |
| `kexport` | image export to qcow2/vmdk/vhd/ova/raw |
| `bob`, `bob-agent`, `bob-bash`, `bob-desktop`, `bob-do`, `bob-home`, `bob-model`, `bob-remote`, `bob-sys`, `bob-voice`, `bob-splash`, `bob-ui` | Bob LLM CLI family |

---

## 15. New systemd units (since 1.0.4)

| Unit | Purpose |
|---|---|
| `kldload-tls-cert.service` + `.timer` | Self-signed TLS gen + weekly rotation + DHCP SAN refresh |
| `kldload-webui.service` | Installer / ops web UI (HTTPS :8443) |
| `kldload-proxy.service` | Single-port TLS reverse proxy |
| `kldload-autodeploy.service` | Post-install golden builds + cluster bootstrap |
| `kldload-journal-flush.service` | Forces journald to disk on boot |
| `kldload-grub-refresh.path` | ESP grubx64.efi watch + sync |
| `loki.service` | Single-node log aggregator (:3100) |
| `promtail.service` | journald + kernel + zfs-dbgmsg + klab logs → Loki |
| `zfs_exporter.service` | per-pool/dataset metrics (:9134) |
| `smartctl_exporter.service` | SMART per disk (:9633) |
| `ebpf_exporter.service` | biolatency + bio-trace (:9435) |
| `arcstats-exporter.service` + `.timer` | ARC stats via textfile collector |
| `zpool-scrub-exporter.service` + `.timer` | scrub age/duration/errors via textfile collector |
| `klab-exporter.service` | klab test matrix metrics |
| `klab-hubble-relay.service` | Hubble relay |
| `klab-prom-targets.service` + `.timer` | Prometheus file_sd target refresh from libvirt state |
| `ttyd-k9s.service` | `k9s` over HTTP for embedded terminal |
| `kldload-firstboot.service` | First-boot init |
| `kldload-smoke-firstboot.service` | post-install smoke run |

Plus `node_exporter.service.d/textfile.conf` wiring the textfile
collector directory.

---

## 16. Distro updates

- **Fedora 41 → 43 → 44** — kernel 6.19+, current stable.
- **CentOS Stream 9** baseline (the bulletproof one).
- **Debian 13 + Ubuntu 24.04 + Rocky 9 + RHEL 9** unchanged at the
  top-level; many target-side fixes.
- **Alpine removed from klab** — apk + busybox doesn't share enough
  with the other distros for uniform testing. Arch stays (bootstrap
  install path only, no golden — rolling release makes immutable
  goldens pointless).

### New darksite content

**RPM base**: `iftop`, `nethogs`, `bcc-tools`, `pax`, `ansible-core`,
`fuse-sshfs`, `tesseract` + `tesseract-langpack-eng`, `zfs-dracut`,
`nss-tools`, `json-c`, `readline`, `ncurses-libs` (LogHog deps),
`gnome-session-xsession` (Rocky/RHEL/CentOS).

**Server profile**: `swtpm` + `swtpm-tools` (software TPM for VM
flows), `golang-github-prometheus`, `prometheus-node-exporter`,
`grafana`.

**Debian/Ubuntu target-base**: `ansible-core`, `iftop`, `libjson-c5`,
`libnss3-tools`, `libreadline8`, `libtinfo6`, `nethogs`, `sshfs`,
`tesseract-ocr`, `tesseract-ocr-eng`.

### Fedora 43+ darksite + DKMS build chain

Fedora was previously online-only — now has a **full offline
darksite**. `build/darksite-fedora/` runs in a `fedora:43` (now
`fedora:44`) container, downloads the package set + dependency
closure, creates a `file://` repo at `/root/darksite/fedora/`, served
on port 3145. Pre-filters the package list against actual repo
contents (dnf5 dropped `--skip-broken` from `download`).

Because `zfsonlinux.org` doesn't always publish a current Fedora
`zfs-release` RPM, the darksite ships the **full DKMS build chain**
(`dkms`, `autoconf`, `automake`, `kernel-devel`, `libblkid-devel`,
`libuuid-devel`, `python3-devel`, `rpm-build`, `gcc`, …). ZFS compiles
from source during install.

### os-variant runtime resolver (klab)

`klab` probes the host's `osinfo-db` and silently falls back when the
packaged db lags the distro (e.g. targets `fedora44` → host knows
`fedora42` → use that). Fixes "Failed to boot fedora" on hosts with
older `osinfo-db`.

---

## 17. Test harness

Two new test scripts:

- **`tests/lifecycle.sh`** — KVM-driven full-loop install smoke.
  Hooked into `deploy.sh smoke-test <distro> <profile>`. Boots a
  throwaway VM off the latest ISO, SCPs an answers env, runs
  `kldload-install-target` headlessly, reboots with disk-first boot
  order, runs `tests/smoke-auto.sh` on the installed target. Tears
  the VM down on success; leaves it on failure (`KEEP_VM=1` to keep
  on success too).
- **`tests/lifecycle-matrix.sh`** — cross-distro × cross-profile
  matrix runner. Parallelizable. Generates `RESULTS.md`.

Existing `smoke-*.sh` scripts in `tests/`:

- `smoke-build.sh` — validates the ISO file (no boot required)
- `smoke-auto.sh` — detects profile, dispatches
- `smoke-core.sh` / `smoke-server.sh` / `smoke-kvm.sh` /
  `smoke-desktop.sh`
- `audit-full.sh` — extended audit (security, drift)
- `lib-test.sh` — shared `_pass / _fail / _warn` helpers

---

## Known issues

- **Secure Boot direct-kernel boot fails on Rocky 9** with the current
  signing chain. The kernel is re-signed with the kldload MOK leaf
  during install (`sbverify` validates, MokListRT contains a matching
  CN) yet shim still rejects with `bad shim signature`. Tracked.
  Workaround: boot with SB off, or use ZBM (also non-SB).
- **GRUB menu under SB direct-kernel boot doesn't auto-rewrite on
  `kbe activate`** — manual `grub.cfg` edit required to switch active
  BE. Tracked for 1.2.
- **ZFSBootMenu under SB ON** — upstream-unsupported (no `shim,X`
  SBAT entry).
- **Rocky kernel-697 ships alongside kernel-611** during dnf install
  on some hardware — `kernel-611` has zfs.ko, `kernel-697` does not.
  Installer correctly stages the 611 one; 697 lives on disk unused.
- **Live ISO can't SB-boot** — its `\EFI\BOOT\BOOTX64.EFI` is raw
  GRUB, not shim. Users with SB ON in firmware must turn SB OFF to
  boot the installer USB. Installed system enables SB normally.
- **Profile gate `!= "core"` is too wide** — desktop/server profiles
  get bob+ansible+klab bleed-through. Per-tile gating tracked for 1.1.x.
- **RHEL credentials don't persist** past install to
  `/var/lib/kldload/secrets/`. Re-register is a manual step.
- **Fedora installer still uses metalink** instead of the bundled
  Fedora darksite on fresh networks. Works, but not offline-pure.
- **Ubuntu golden uses Canonical's vendored zfs-2.2.2** — switching
  to the zfsonlinux PPA expected to push pass rate from 58% → ~98%.
- **XPS 13 CentOS / Rocky** kernel hang on NVMe-RAID BIOS mode — user
  must switch to AHCI in BIOS. Dell default, not fixable in software.
- **Chrome captures F11/F12** (fullscreen/devtools); use Shift+F11/F12
  on Chromium-based browsers. Firefox passes them through.
- **Kernel↔ZFS pinning** not enforced — a distro kernel update on
  Fedora (fast) or Debian/Ubuntu (DKMS) can leave ZFS unbuildable
  until the next zfs-release. Tracking for 1.1.x.
- **Ubuntu 24.04 target** ships OpenSSH 9.6p1 (pre-ML-KEM); our PQ
  drop-in advertises `sntrup761x25519-sha512` there but not
  `mlkem768x25519-sha256`.
- **Smoke matrix not re-run for 1.1.0 final** — Rocky 9 desktop is
  validated end-to-end on real hardware; full matrix is the first
  item on the 1.1.x patch series. Run it yourself with
  `sudo ./tests/lifecycle-matrix.sh PARALLEL=2`.

---

## Tested on

- **fiend (ASUS TUF X570)** — ZFSLAB profile running the 5-distro
  long OpenZFS test suite. centos / rocky / fedora / debian ≈98%
  pass. Ubuntu 58% — Canonical's vendored zfs-2.2.2 is the cause,
  not kldload. Full run is ~8.5h.
- **XPS-class with NVIDIA RTX 3080** — Rocky 9 desktop install +
  boot non-SB, ZFS root, NVIDIA loaded, GDM, GNOME, network all up.
- **HP USB stick** — boots cleanly with the rootdelay/rd.retry compat
  cmdline (was failing 1.0.5 candidates).
- **Dell XPS 13** — Debian 13 boots clean. Fedora 44 boots + WiFi
  works (post firmware-split fix). CentOS / Rocky still hit a kernel
  hang because Dell's BIOS defaults NVMe to RAID mode; AHCI in BIOS
  resolves it.

---

## Upgrade

This is a **major version**. Live env, kernel, ZFS, shim, dnf are all
stepping forward. **No in-place upgrade from 1.0.x** — do a fresh
install onto a different ZFS pool, or wipe and reinstall on the same
disk. Restore state from ZFS snapshots if you had them.

```bash
# Get it
curl -L -o /tmp/kldload.iso https://dl.kldload.com/kldload-free-latest.iso

# Burn it (USB at /dev/sda — verify with lsblk first)
sudo bash -c 'wipefs -af /dev/sda && \
  dd if=/tmp/kldload.iso of=/dev/sda bs=4M oflag=direct \
     status=progress conv=fsync && sync && eject /dev/sda'
```

---

## The point

Install kldload on real hardware. Deploy your charts, your Ansible,
your workloads. Watch what the kernel is actually doing while your
product runs. Break things safely. Rebuild in seconds. Test every
distro before you ship. See every zpool event, every slow IO, every
ZFS kernel panic with the full stack trace already attached to a
bug-report-ready `ISSUE.md`.

The production-grade lab you always wanted and never had time to
build.

---

## Thanks

To everyone who reported install failures with hardware they actually
own. The "boots once, never again" footgun, the multi-kernel
zfs.ko-mismatch, the GDM-with-NVIDIA xsession bug, the MOK
CA-vs-leaf root cause, the heredoc-stdin-eaten-by-background-&,
the F44 udev rule racing the installer, the F43 firmware split
brain damage — all surfaced by people running it on real machines
and saying "this didn't work, here's exactly what happened." 1.1.0
is a hardware-reality release because hardware reality is what
tested it.

Full commit-by-commit changelog: `git log --oneline v1.0.4..v1.1.0`.
