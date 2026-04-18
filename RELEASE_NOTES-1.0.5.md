# kldload 1.0.5 — Proving Ground

**DRAFT** — not yet released. Tracking changes here.

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
"the lab you build everything on." Three cross-cutting themes:

1. **The lab has a console.** A web UI with sub-tabbed workspaces for every
   resource type, plus a 24-key tmux drawer where every watchable pane is
   one keystroke away.
2. **The observability chain works end-to-end.** Cilium + Hubble + Tetragon
   + Prometheus + Grafana + metrics-server all connected and rendering real
   data, not the placeholder-filled dashboards 1.0.4 shipped with.
3. **The ZFS test suite is first-class.** Separate goldens pre-loaded with
   every `zfs-tests.sh` prerequisite, parallel runs capped at 80% of host
   cores, per-test streaming output, consolidated audit bundles for
   attachment to upstream PRs.

## Top use cases

| Role | What kldload gives you |
|---|---|
| **OpenZFS maintainer** | `klab test --full` across 5 distros, one downloadable audit bundle per PR. |
| **Developer** | "Does my chart/playbook still work on every distro?" — one command, parallel test. No cloud bill. |
| **SRE / platform engineer** | Practice rig for eBPF, bpftrace, Cilium, Hubble, Tetragon. Break things safely, see the kernel-level cause, build the reflex. |
| **Security researcher** | Isolated bare-metal sandbox for kernel/BPF/CNI experiments. Detonate samples, destroy the VM, clone a fresh one. |
| **Trainer / consultant** | Reproducible demo rig. Carry a USB to the customer, lab is running in 30 min. |
| **CI operator** | Plug USB into an office NUC → persistent 5-distro test runner, no cloud bill, faster than hosted CI. |
| **Kernel/distro packager** | "Does this kernel/package still work with these workloads?" — one `klab test --full` away from the answer. |
| **Compliance / audit** | Run hardening scripts, capture `full.log` + Tetragon events + doctor output, zip as audit bundle. |

## What's new

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

### New operator tools

- **kldload-dash** — single-pane "is everything OK?" overview (host +
  Kubernetes + ZFS + running VMs + recent warnings), auto-refreshing.
- **kinspect** — pick two endpoints (VMs or pods); get a 3-pane tmux layout:
  each one under SSH + live `watch`, with a Hubble/tcpdump flow stream of
  every packet between them.
- **kztest-tail** — follow the current ZFS test run's consolidated log
  from any shell pane.

### Bob (local LLM) gained eyes

Bob can actually answer "why is hubble-relay not ready?" by calling
k8s_events → k8s_describe → k8s_logs → kernel_dmesg in sequence.

**18 new observability tools:**
- k8s: `get_pods`, `get_nodes`, `describe`, `logs`, `events`
- Prometheus: `prom_query` for arbitrary PromQL
- ZFS: `zfs_status`, `zfs_arc_stats`
- Host: `host_vitals`, `top_procs`, `ss_sockets`
- CNI / eBPF: `hubble_observe`, `cilium_monitor`, `cilium_status`,
  `cilium_endpoint_list`, `tetragon_watch`, `kernel_dmesg`,
  `bpftrace_oneliner` (human-approved)
- Self: `doctor_check`

Strengthened system prompt with a diagnosis recipe so Bob reaches for these
tools by reflex. Silent disconnect handling — no tracebacks when the
browser tab closes mid-request.

### ZFS test suite — first-class

- **Separate golden lineage**: `klab-ztest-<distro>` images carry every
  `zfs-tests.sh` prerequisite (`ksh`, `fio`, `net-tools`, `pamtester`,
  `pax`, `cryptsetup`, `xxhash`, `nfs-utils`, `bzip2`, `perf`,
  pre-created loopback vdevs) — kept separate from the lean blue-green
  `klab-golden-<distro>` images.
- **One-command builds** — "Build all ZFS test goldens" button in the UI,
  or `klab golden-ztest all` from the CLI.
- **Streaming output** — every `[PASS]` / `[FAIL]` / `[SKIP]` line
  visible in real time, prefixed with `[distro]`, interleaved readably
  across parallel runs.
- **Audit bundles** — every run writes `/root/klab/<run-id>/full.log` +
  `manifest.txt` + per-distro logs. Download as `.tar.gz` from the UI to
  attach to an OpenZFS bug report.
- **Real results in the UI** — per-distro matrix and history panel now
  show actual PASS/FAIL counts (fixed lowercase/uppercase key bug that
  rendered zeros for every historical run).
- **Parallel with a cap** — 80% of host cores by default
  (`KLAB_MAX_CONCURRENT` overrides) so the host isn't starved.
- **Per-test checklist parser** — audit panel parses every
  `Test: ... [PASS|FAIL|SKIP]` line into a sortable table.

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

### Doctor v2

- Grew from 22 checks to **33 checks across 10 subsystems**.
- New checks: metrics-server, prometheus targets, cilium scrape labels,
  tetragon scrape, hubble scrape, grafana dashboards, cluster firewall,
  Ollama, Bob tools, install artifacts.
- Writes `/root/kldload-doctor.log` on every run — grep-able history.

### Installer fixes

- `profiles.sh` no longer silently skips copying `kldload-autodeploy`,
  `ttyd-k9s.service`, or the Ansible playbook library on install. Silent
  `cp` failures were the 1.0.4 root cause for autodeploy never running.
- libvirtd race fixed (wait for virsh socket, verify pool + default
  network actually got defined).
- Ansible playbook library always-copies with a loud WARNING if somehow
  missing on the live root.

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

Because zfsonlinux.org hasn't published a prebuilt `zfs-release` RPM
for fc43 yet, the fedora darksite ships the **full DKMS build chain**
(`dkms`, `autoconf`, `automake`, `kernel-devel`, `libblkid-devel`,
`libuuid-devel`, `python3-devel`, `rpm-build`, `gcc`, ...). ZFS
compiles from source during install — same userspace, same pool
format, just built at install-time. When zfsonlinux.org publishes an
fc43 release RPM the darksite will pick it up automatically on the
next rebuild.

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

## Upgrade

Fresh install recommended. 1.0.4 → 1.0.5 changes enough that an in-place
package-manager upgrade won't deliver the new UI / console / tool set.
Burn the new ISO, install, restore state from ZFS snapshots if you had
them.

## Known issues

- Chrome captures F11/F12 (fullscreen/devtools); use Shift+F11/F12 as the
  reliable bcc-tools keys on Chromium-based browsers. Firefox passes
  F11/F12 through to the tmux drawer.
- `cilium_operator` scrape target is "down" on 3 of 4 nodes — expected,
  the operator runs on one node (hostPort only binds where the pod is).
- Tetragon dashboards require the cluster to be running — they show
  "No data" on a freshly-installed host until K8s is bootstrapped.

## The point

Install kldload on real hardware. Deploy your charts, your Ansible, your
workloads. Watch what the kernel is actually doing while your product
runs. Break things safely. Rebuild in seconds. Test every distro before
you ship. The production-grade lab you always wanted and never had time
to build.
