# Changelog

## 1.4.2 — 28 August 2026

195 commits since 1.4.1: 30 features, 127 fixes, 120 files changed.

---

This release is about hardware. Almost every fix below was found the same way —
installing on a real machine and measuring what actually landed, rather than
reading a package list and assuming. The dev box has an NVIDIA GPU and an Intel
CPU, which turns out to be the single configuration where all of these defects
are invisible.

### The desktop installer asks three questions

It used to ask nine. Eight of them were things you would answer the same way
every time to get a working desktop, so they are now silent defaults: the
virtualisation stack, the Kubernetes lab, the AI assistant, the monitoring
stack, the ZFS lab and the mesh all install because a desktop without them is
not the product.

What is left is what genuinely varies by machine:

```
  [x] NVIDIA proprietary driver     (shown only when an NVIDIA GPU is present)
  [ ] Secure Boot
  [x] Build VM golden images
```

The web console also no longer starts on every boot. It was useful exactly
once, during install.

### Firmware that was never actually installed

Both distributions shipped installs with large parts of the firmware tree
empty, and nothing reported it. On Fedora, because 43+ split `linux-firmware`
into per-vendor packages and this tree named a handful of wifi packages and
nothing else. On Debian, because `firmware-linux-nonfree` depends on exactly
two packages and lists every per-vendor set as a `Recommends`, while the
install runs `--no-install-recommends`.

Measured on real installs before and after, not inferred:

```
                        Fedora            Debian
  firmware files     2874 -> 4139      1361 -> 3093
  amd-ucode             0 -> 7            0 -> 5
  intel-ucode         152 (ok)            0 -> 126
  i915                  0 -> 57           0 -> 57
  brcm                  0 -> 54           1 -> 54
  mediatek              0 -> 99           0 -> 99
  cirrus                0 -> 433          0 -> 433
  qcom                  0 -> 129          0 -> 129
```

The first row of that table is CPU microcode, and it is the one that matters
most. An AMD machine booted with none at all, so Zenbleed- and Inception-class
fixes never loaded. An Intel machine picked its files up through a different
package and looked perfectly healthy, which is why this went unnoticed.

The rest decides whether a laptop has working wifi, sound and a graphical
console on first boot — `brcmfmac` is Broadcom, `mt7xxx` is most WiFi 6/6E
parts since 2023, `cirrus` is the audio codec in recent XPS and ThinkPad
hardware, `i915` is Intel graphics. A desktop with no GPU firmware is a black
screen, not a slow one.

### Codecs and video acceleration

Debian installed with no VA-API drivers and no `libav`, so hardware video
decode was unavailable and a browser fell back to software for everything.

```console
$ gst-inspect-1.0 | grep -c avdec_
211
$ ls /usr/lib/x86_64-linux-gnu/dri/*_drv_video.so | wc -l
7
```

Both numbers were zero on Debian before this release.

### The boot chain

**Secure Boot is off by default.** It is still a checkbox, and it still works,
but an install no longer walks the operator through a MOK enrolment ceremony
they did not ask for.

**The encrypted-pool passphrase prompt is visible.** It was being buried under
kernel output on a quiet boot — the pool was waiting for a passphrase on a
screen that showed no reason to type one.

**`spl_hostid` is set on every boot path.** GRUB was passing an empty value on
the one entry a Secure Boot install uses, which made pool import a coin flip.

**A failed kernel re-sign no longer destroys the signature.** The Secure Boot
path strips and re-applies the kernel signature; if that failed, the ESP was
left with an unsigned kernel and the machine would not boot. It now backs up
first, verifies the result, and restores on failure.

**The fallback boot entry is registered and stays in `BootOrder`.** The
recovery path also no longer registers an entry pointing at a file that was
never written.

ZFSBootMenu's countdown is 2 seconds instead of 10.

### The kernel pin is derived, not written down

ZFS and NVIDIA are out-of-tree DKMS modules built against one specific kernel,
so the kernel is held. That pin is now resolved at build time from what OpenZFS
actually declares it supports, rather than a literal someone updated by hand.
A literal goes stale silently and lies about having been tested.

```console
$ apt-mark showhold | wc -l
57
$ kldload-rollback status
Boot path        : ZFSBootMenu (follows bootfs)
Pinned platform packages           : 57
```

The pins were also being written under a mountpoint that had not been mounted
yet, so the tool that set them could not see them afterwards. Ordering a unit
`After=zfs-mount.service` orders it on the *service*, not on the *mount* —
`RequiresMountsFor=` is the one that works.

The system journal had the same defect, and the symptom was worse: it reported
that it was recording while every boot was being erased.

### Ansible proves itself on first boot

Ansible shipped configured and had never once run. The inventory listed the
estate, the dropdown listed playbooks, and "is Ansible working?" was answered
by reading configuration rather than by evidence.

`system-info.yml` now runs unattended on first boot and writes
`/root/kldload-ansible-report.txt` — per-host distro, kernel, uptime and
memory, then a summary that names the hosts it could not reach. A count on its
own would have read as success while half the estate was unreachable.

The same playbook is in the dropdown, so the proof is one click away later.

### Debian and Fedora

The installer menu offers Debian and Fedora. The other substrates still build
and the code is unchanged — they are no longer presented as choices a first-time
operator should be making, and the documentation describes what is supported
rather than what compiles.

### Every machine records what built it

```console
$ cat /etc/kldload-release
kldload_version=1.4.2
iso_name=kldload-1.4.2-x86_64.iso
iso_built_at=2026-08-28T...
installed_at=2026-08-29T04:01:22Z
requested_distro=debian
requested_profile=desktop
requested_secureboot=off
```

Asked "which ISO installed this machine?", the only previous way to answer was
to infer it from which packages happened to be present. The second half of that
file — what the installer was *told* to do — is the half that turns a support
report into a bug report.

### Diagnostics and IPMI

`smartmontools`, `nvme-cli`, `ipmitool`, `OpenIPMI`, `lm_sensors`, `sg3_utils`,
`lsscsi`, `usbutils`, `nethogs` and `iftop` ship on every profile, on both
package managers. A machine that cannot report its own disk health is not a
substrate you would trust with a pool, and without `ipmitool` a server's
sensors, event log and power state are unreachable from inside the OS even
though every driver is already in-tree.

They are inert on hardware with no BMC, so they ship everywhere rather than
only on the server profile — gating them means the operator who needs them is
the one who did not pick the profile that has them.

### Validation

Four installs on real hardware, both distributions, both boot paths:

```
                    Fedora           Fedora        Debian          Debian
                    SB + enc         no SB         SB + enc        no SB
  firmware          4139             4139          3093            3093
  codecs (avdec)    211              211           211             211
  VA-API            11               11            7               7
  kubernetes        6/6 Ready        6/6           6/6             6/6
  failed units      0                0             0               0
```

`apt rollback` and `dnf rollback` were exercised on both boot paths.

## 1.4.1 — 18 August 2026

A same-day follow-up to 1.4.0. Every fix here was found by installing 1.4.0 on
real hardware and using it, and each was verified on that machine before it was
written down.

---

### The installer's icons were blank on every installed system

The distribution and profile cards are drawn with emoji, and the ISO build
installs an emoji font for the **live** medium only — nothing ever installed one
on the target. So the installer looked right while you were installing and wrong
on the machine you had just installed. One glyph rendered (FreeBSD's, which
DejaVu happens to carry) and five did not.

Now installed on every target: `fonts-noto-color-emoji` (apt),
`google-noto-color-emoji-fonts` (dnf), `noto-fonts-emoji` (pacman).

### Clones shared the golden's identity

`virt-clone --preserve-data` remaps only the first disk, so the golden's
cloud-init seed cdrom was carried into every clone by reference. All of them
booted the golden's user-data and came up answering to its hostname, which is
why they never registered as separate peers on the mesh.

Each clone is now given its own seed — its own hostname and a fresh
instance-id — before it is started. Reusing the instance-id makes cloud-init
treat the run as already done and skip it, so both had to change.

### Clones also shared its console log

The same by-reference problem, one device along. libvirt holds that log open
for the life of the guest, so the first clone to start owned it and every other
one failed with `Device or resource busy` — reported to the operator as
"failed to start". Starting them one at a time does not help; the lock is held
for as long as the guest runs.

### The guest agent was never installed

Every domain has carried the virtio guest-agent channel since it was added, and
nothing ever installed the guest half — a channel with nothing on the other end.
On a host with eleven guests libvirtd logged "Guest agent is not responding"
1,863 times in ten minutes, and the estate fell back to DHCP leases for
addresses it should have been able to ask the guest for.

### Picking a desktop silently built a server

Selecting a row in the image list reset the desktop choice to "none" on every
selection. "none" is a valid answer, so the build went ahead and produced
headless machines with nothing anywhere saying why. Three "Fedora GNOME
desktops" came up as three Fedora servers.

### Also

- `kvm-delete` undefined the domain *before* attempting the zvol destroy, so a
  golden with clones left the VM deleted and its storage orphaned. It now
  refuses up front and names the clones.
- Dock pins are filtered to applications that exist on the target. The list
  pins four browsers deliberately; every target also kept the ones it does not
  have as dead entries.
- The squashfs step accepts `KLDLOAD_BUILD_PROCESSORS` so a build can leave the
  machine usable.

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
