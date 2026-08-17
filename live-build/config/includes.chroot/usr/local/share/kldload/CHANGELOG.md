# Changelog

## 1.4.0 — 17 August 2026

369 commits since 1.3.1: 106 features, 179 fixes, 389 files changed.

---

### An update you can undo

`apt` and `dnf` take a ZFS snapshot before every transaction that changes the
system, and any of them can be reversed.

```console
$ sudo apt upgrade
kldload: snapshot rpool/ROOT/kldload@apt-pre-20260817-023105
Upgrading 8 packages: chromium, libwebkitgtk-6.0-4, dkms ...

$ sudo apt rollback            # undo it
Rollback staged.
  from snapshot   : apt-pre-20260817-023105
  new environment : rpool/ROOT/rollback-20260817-023340
  boot path       : direct kernel (Secure Boot compatible)

$ systemctl reboot
```

These are the normal commands, not a wrapper you have to remember. A script,
`unattended-upgrades`, or the GUI updater all get the same snapshot — the
`apt.conf.d` hooks fire from inside apt regardless of how it was called.

Rollback **clones** the snapshot into a new boot environment rather than
running `zfs rollback`, which cannot touch a mounted root and destroys every
newer snapshot. Nothing is overwritten, and `apt rollback cancel` reverses the
whole thing until you reboot.

It handles both boot paths. With Secure Boot off, ZFSBootMenu follows the
pool's `bootfs`. With Secure Boot on, shim 15.8 will not chainload ZBM's
unsigned bundle, so the install boots a signed kernel from the ESP with
`root=ZFS=` hardcoded in `grub.cfg` and `bootfs` is never read — so the ESP
kernel, initrd and `grub.cfg` are rewritten to match, backed up first.
Restoring the dataset without its matching kernel would boot a newer `vmlinuz`
against older `/lib/modules`: no ZFS, no network, no disks.

See `kldload-rollback(8)` and `kldload-apply-platform-holds(8)`.

### The kernel is pinned as a matched set

ZFS and NVIDIA are out-of-tree DKMS modules built against one specific kernel.
56 packages are held on a running desktop install — the kernel metapackages,
the ZFS set, the whole NVIDIA driver set, and the boot chain.

```console
$ apt-mark showhold | wc -l
56
$ dkms status
nvidia/610.57.04, 7.1.3+deb13-amd64, x86_64: installed
zfs/2.4.3, 7.1.3+deb13-amd64, x86_64: installed
```

NVIDIA is matched by pattern rather than by name, because the package set
differs per driver branch. `nvidia-container-toolkit` is deliberately excluded:
separate upstream, own version line, not coupled to the kernel module, so
holding it would block its security updates for no safety gain.

`apt upgrade` prints "The following packages have been kept back" and explains
nothing, and every search result for that phrase advises `apt-mark unhold`.
The holds now explain themselves before apt gets a chance to look broken.

### A console per subsystem

Each ships a GUI and a TUI, so a headless hypervisor gets the same tool over
SSH.

| console | subsystem |
|---|---|
| `zxplore` / `z9fs` | pools, datasets, snapshots, replication, both permission layers |
| `wgxplore` | every WireGuard interface and peer, declared against actual |
| `vmxplore` | the VM estate, serial and screen consoles, every verb |
| `ztxplore` | the OpenZFS test lab |
| `buildmon` | what the build is doing, and whether the install worked |

`vmxplore(1)` and `ztxplore(1)` carry full man pages, embedded in the binary
and rendered in a Manual pane, so a static build copied onto another machine is
never undocumented.

### Kubernetes is HA by default

Three control planes via kube-vip, with VIP float across them proven by
failover. Control planes can be added after install from the web console, and
adding or removing a node reconciles the WireGuard mesh, etcd membership and
firewall rules on every other node.

```console
$ kube-cluster mesh-repair
Reconciling 6 node(s) against 6 peer(s) + hypervisor
  kldload-cp-2: added hypervisor peer
  hypervisor: added missing peer kldload-cp-2 (5)
Mesh reconciled: 4 peer(s) added, 0 stale peer(s) removed
```

Day-2 operations that did not exist in 1.3.1: port-forward, editing existing
resources as YAML, Events, StatefulSets and DaemonSets, ConfigMaps, and
cluster start/stop.

### The AI stack runs offline

Ollama and Open WebUI install by default. With
`KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1` the ISO carries 5.4 GB: the model
(`llama3.2:3b`), the embedding model (`nomic-embed-text`), the Open WebUI
container image and the Ollama runtime — so first boot has a working assistant
with the network unplugged.

The OpenAI-compatible API is published, the UI is behind TLS, and models can be
loaded and unloaded from VRAM over the websocket.

### The OpenZFS test lab

Six distributions — CentOS Stream, Rocky, RHEL, Fedora, Debian, Ubuntu — in
VMs on zvols. One golden per distribution, cloned per run.

```console
$ kzfs-test golden all
$ kzfs-test run --full --distro centos,debian
$ kzfs-test results
```

Two rules exist because their absence produced answers that looked correct and
were not: a golden that comes up without a working ZFS is **refused**, not
sealed, and a run that executes zero tests is scored **error**, never pass.

Guest kernels are pinned for the life of the build (`dnf exclude`, `apt-mark
hold`, `pacman IgnorePkg`) — installing the build dependencies used to pull a
newer kernel on Fedora, leaving the DKMS module built for a kernel the clone no
longer booted.

Live pass/fail/skip counts per distribution are on port 9101 while a run is in
progress. See `ztxplore(1)`.

### An estate Ansible can target

VMs land on a network that says what they are, and a dynamic inventory turns
that into groups.

```console
$ kldload-networks apply     # kld-klab, kld-zfslab, kld-vms
$ kldload-networks sync      # DHCP leases → the state DB
$ ansible -i /usr/local/bin/kldload-inventory role_klab_golden -m ping
```

`kldload-estate` reconciles what libvirt, the state database, DHCP, WireGuard
and Kubernetes each believe, and reports where they disagree:

```console
$ kldload-estate --table
[mesh-missing] kldload-cp-2
  Kubernetes reports Ready on 10.251.0.5, but no WireGuard peer covers it
  fix: kube-cluster mesh-repair
```

That class of drift is why it exists: `kubectl get nodes` reported six nodes
Ready while `wg show` had four peers. Both were correct about their own layer.

### Offline install

243 packages in the Debian darksite set, 23 container images, Helm charts for
Cilium, Tetragon, MetalLB and ArgoCD pinned to the versions whose images are
cached, and the AI stack when built with the flag. Your own charts dropped into
`/root/darksite/helm-charts/workloads` install at first boot.

Debian, Fedora and RHEL install green with no network at all. Arch is a rolling
release and needs one; Ubuntu's mirror was retired.

### Also

- Docker on the apt distributions, with its layers on ZFS
- 29 Grafana dashboards, with ZFS split between the pool and the test lab
- A five-second boot menu, because a hidden one cannot be used
- `kexport` writes qcow2, raw, VMDK or OVA, sealed by default, so the image you
  hand someone else is a golden rather than a clone of your laptop

---

### Fixed

179 fixes. The ones that changed behaviour you would notice:

- **Nine of eleven systemd units never reached the ISO.** Only two had a
  hand-written copy line, so the package-holds unit, the ZFS dbgmsg collector,
  the apt snapshot hook and the snapshot timers shipped and did nothing. The
  builder now copies the directory.
- **`kldload-examples`, `klab-bob` and the libvirt network definitions** were in
  the installer's copy list but never on the ISO, so that copy read an empty
  source on every install to date.
- **Darksite AI weights were ignored unless a checkbox was ticked**, even on an
  ISO carrying them, so first boot pulled a model that was already on disk.
- **NVIDIA was unheld**, so its userspace libraries could advance past the
  kernel module and X would fail with an API mismatch.
- **`grep -q installed` matched `unknown ok not-installed`**, so Ubuntu kernel
  names were treated as present on Debian.
- **The GPU advisory sized for a 9 GB model that no longer ships**, disabling
  the AI stack by default on machines with under 16 GB of RAM.
- **bcc tools were installed but never found** — they ship as
  `<name>-bpfcc` on Debian and under `/usr/share/bcc/tools` on RHEL, never the
  bare name, and on Debian in a directory absent from the GUI user's `PATH`.
- **NetworkManager managed WireGuard, libvirt and Cilium interfaces**, raising
  an activation-failure notification for each one during first boot.

---

## Documentation

- `ztxplore(1)` — the test lab: model, commands, ZFS sources, metrics, environment
- `vmxplore(1)` — the KVM console
- `kldload-rollback(8)` — boot environments and both boot paths
- `README.md`, `ci/README.md` — build, deploy, and the nightly matrix
