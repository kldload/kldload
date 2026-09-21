# Frequently asked questions

The source of truth for the FAQ. `tools/gen-faq-html.py` renders this file into
the website's `faq.html`, so the answers cannot drift apart from each other --
edit this file, regenerate, and both are current.

**Every answer here is checked against this tree, not against memory.** The
previous FAQ shipped for months describing a seven-distribution menu that no
longer existed, and `docs/demo/pitch.md` is right that one catchable claim is
enough to lose a technical reader. Where something is only partly true it says
so. Where a number is measured, it says where it was measured.

**Last checked against the tree:** 2026-09-20, at release 1.4.2.

---

## What it is

### What is kldload?

A build tool that assembles a Linux distribution onto a ZFS root from the
vendor's own package repositories -- and the operating system that falls out of
that build.

There is no fork, no patch set and no kldload package repository. The build runs
`dnf --installroot` or `debootstrap` against Fedora's or Debian's own CDN, then
compiles ZFS and, optionally, NVIDIA against the kernel that install just laid
down. What you end up running is the vendor's distribution, on ZFS, with boot
environments and a set of tools wired together so they work on first boot.

### So is it a distribution or a tool?

Both, and you can use either half.

- **As a build tool**, it replaces "download the .iso". You point it at a distro
  and a profile and it produces a bootable image, or an installed machine, or a
  qcow2/VMDK/VHD/OVA/raw export.
- **As the finished article**, the ISO is what that build leaves behind: ZFS on
  root with boot environments, WireGuard, KVM, Kubernetes, an eBPF
  observability plane and a local AI stack, with the kernel and its out-of-tree
  modules pinned as one matched set.

### What does it add that the vendor's own image does not have?

One thing above all others: **`apt`, `dnf` and `pacman` snapshot the root before
every transaction.** They are symlinked to `kldload-pkg-wrapper` at install, so
this is not a separate command you have to remember -- a script, an unattended
upgrade or the GUI updater all get the same protection. Reversing a failed
upgrade becomes one command and a reboot instead of a rescue USB and an evening.

After that: ZFS on root with real boot environments, complete offline package
mirrors on the image, netboot provisioning for a whole rack, and the four
consoles (ZFS, VMs, WireGuard, the OpenZFS test lab).

### What is "BYOL0"?

Bring your own layer zero. The layer underneath the distribution -- the pool,
the boot chain, the module signing, the snapshot policy -- is the part nobody
hands you and everybody rebuilds by hand. kldload is that layer, and it is
yours: BSD-3, no licence server, no account, no vendor to stay solvent.

### Who is it for?

People who run machines: homelabs, small racks, test benches, lab fleets, and
anyone who has to rebuild the same box more than once. It is aimed at someone
comfortable with Linux who is tired of doing ZFS-on-root by hand.

It is not aimed at someone who wants an appliance. The installed system is a
full, ordinary, mutable Linux and it does not want the whole machine to itself.

### Is it opinionated?

Yes, and the opinions are stated rather than hidden: ZFS on root, UEFI only,
boot environments, snapshot before every package transaction, Cilium instead of
kube-proxy, everything offline by default. What it is not opinionated about is
the distribution -- that is your choice, and it stays the vendor's software
afterwards.

---

## Distributions

### Which distributions can I install?

Two are on the installer menu, and those two are the tested ones:

| Distribution | Bootstrap method | Offline |
|---|---|---|
| Fedora 44 | `dnf --installroot` | Yes, from the RPM darksite on the image |
| Debian 13 (Trixie) | `debootstrap` | Yes, from the APT darksite on the image |

### What happened to CentOS, Rocky, RHEL, Ubuntu and Arch?

They still work, and they are not on the menu.

The bootstrap method is not distro-specific, so the reachable set is wider than
the tested set: RHEL, CentOS Stream, Rocky, Ubuntu and Arch all install with
`KLDLOAD_DISTRO=<name>`, and those code paths are maintained. But they are not
mirrored offline, not in the test matrix, and not on the menu -- and the menu is
the honest statement of what is actually proven.

Two specific cautions, both learned the hard way: an encrypted Arch install
panics at boot, and a rolling release cannot be version-locked the way the rest
of the substrate is.

### Why Fedora and Debian specifically?

Because they are the widest useful *pair*, not the narrowest safe one: two
package managers, two firmware-splitting conventions, two initramfs generators,
and one leading-edge substrate against one stable one. Most bugs worth finding
show up as a difference between them.

### How much work is adding another distribution?

Its repositories and keys have to be declared, and its kernel has to be paired
with an OpenZFS version that builds against it. That is a morning's work, not a
port. What it is **not** is free: an untested distribution on the menu is a
promise nobody has checked.

---

## Installing

### What do I need?

| | |
|---|---|
| A 64-bit x86 machine | **UEFI required. Legacy BIOS is not supported.** |
| A USB stick, 32 GB or larger | The full image is about 15 GB. The 2.2 GB net installer fits a 4 GB stick. |
| A target disk | **It will be erased.** |
| RAM | 8 GB is comfortable; 4 GB works but is tight on the desktop profile. |
| Network | Optional. Both menu substrates install fully offline. |

### Why is legacy BIOS not supported?

It is absent by design rather than untested. There is no BIOS boot partition and
no `grub-install --target=i386-pc` anywhere in the tree.

The reason is a failure class, not laziness: GRUB on legacy BIOS with a ZFS root
embeds stage 1.5 in the post-MBR gap, and that code has to understand your
pool's feature flags -- so a routine `zpool upgrade` can make the machine
unbootable. Requiring UEFI removes that entirely. Practically this excludes
pre-2012 hardware, OEM desktops left in CSM-only mode, and VMs configured for
SeaBIOS instead of OVMF.

### How do I install it?

Burn the ISO, boot it, and the installer opens by itself -- no terminal, no
wiki. It is a web UI, so it is also reachable at `https://<host>:8443` from
another machine, which is how you install a box with no screen.

```
sudo wipefs -af /dev/sdX
sudo dd if=kldload.iso of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress && sync
```

Then: pick the distribution, pick the profile, pick the disk, start it.

### Can I install without answering questions?

Yes. An answers file carries the hostname, disk, profile and cluster shape, and
can be supplied over netboot or on the kernel command line. Secrets are the
deliberate exception: a login password or encryption passphrase the answers file
lacks is asked for on the machine's own screen, before anything is erased.

### How long does an install take?

The install itself is minutes; the interesting number is the end-to-end one.
Measured on one target, power-on to a six-node HA Kubernetes cluster with every
node `Ready` and a usable desktop: **fifteen minutes**.

### Can I build the ISO myself?

That is the normal way to use it.

```
git clone https://github.com/kldload/kldload.git && cd kldload
PROFILE=desktop ./deploy.sh build
sudo ./deploy.sh burn /dev/sdX
```

`PAYLOAD`, `DARKSITES`, `K8S_IMAGES` and `OLLAMA` decide what goes in;
`./deploy.sh help` lists them with sizes, and `./deploy.sh menu` is a checklist
that writes `kldload.env` and shows the resulting size.

### Can I customise the image for my organisation?

Yes, and this is a supported path rather than a hack. Drop a Helm chart in
`/root/darksite/helm-charts/workloads/` or plain YAML in
`/root/darksite/manifests/`, and first boot installs them once the cluster is up
and before it reports ready. Manifests apply in sorted order, so `10-namespace`
lands before `20-deploy`. Add your container images to
`build/darksite/k8s-images.txt` and they are baked into the image too.

---

## ZFS, snapshots and rollback

### Why ZFS rather than ext4, btrfs or LVM?

Because the properties that matter here are the ones ZFS has together:
end-to-end checksums, cheap snapshots and clones, `send`/`recv` replication,
native encryption, compression, and self-healing on a mirror. Boot environments
need snapshots and clones of the root filesystem to be free and instant; that is
what makes "reverse the upgrade" a one-liner rather than a restore.

### Does ZFS need a lot of RAM?

Less than folklore says, and the honest answer has two halves. The ARC will use
memory that is otherwise idle, and gives it back under pressure -- that is not a
leak. 8 GB is comfortable for a desktop or server profile. The case where RAM
genuinely matters is deduplication, which is off by default and should stay off
unless you have measured that your data dedupes.

### Do I need ECC memory?

No, and anyone who tells you ZFS specifically requires it is repeating a myth.
ECC is good for any filesystem on any machine. ZFS without ECC is still
checksummed and still safer than the alternatives without ECC.

### What does the snapshot-before-every-transaction actually do?

`apt`, `dnf` and `pacman` are symlinked to `kldload-pkg-wrapper`. Before the
real transaction runs, the root is snapshotted. If the upgrade breaks something:

| Command | What it does |
|---|---|
| `apt rollback` | Stages a return to the pre-transaction snapshot; reboot to apply |
| `apt rollback list` | Shows which transactions you could go back to |
| `apt rollback cancel` | Un-stages it -- nothing has changed until you reboot |
| `kldload-rollback` | The same machinery directly, with boot-environment control |

### Is the rollback instant?

No, and it is worth being precise about it: `apt rollback` **stages** the
return, and **the reboot applies it**. Nothing on disk is destroyed in the
meantime, and `apt rollback cancel` undoes the decision.

### Does rolling back destroy my newer snapshots?

No. Rollback **clones** the snapshot into a new boot environment rather than
running `zfs rollback`. That is deliberate: `zfs rollback` cannot touch a
mounted root, and it would destroy every snapshot newer than its target. The
broken boot environment is still there afterwards, which is also how you get to
look at what went wrong.

### What is a boot environment, in practice?

A bootable clone of the root filesystem. You upgrade, and the version you were
running is still on the disk as a thing you can boot. ZFSBootMenu -- a UEFI
bootloader that understands ZFS -- lists them at boot time, so a machine that
will not come up can be returned to the version that worked from the boot screen
itself, without a rescue USB. `kbe` manages them from the running system.

### Why is there no GRUB?

Because ZFSBootMenu reads the pool directly and can therefore offer boot
environments and rollback from the boot screen. GRUB with a ZFS root has to
understand the pool's feature flags to find the kernel at all, which is the
failure class described under legacy BIOS. With Secure Boot turned on the chain
is firmware -> shim -> GRUB -> kernel; with it off (the default) the firmware
boots ZFSBootMenu directly.

### Are Docker and podman really on ZFS?

Yes, with the `zfs` storage driver rather than overlay: every image layer is a
real dataset. A `pull` is a clone, layers inherit the pool's compression, and
the whole container estate -- layers, the engine's database and the volumes --
snapshots and replicates as one recursive `zfs send`. Measured: a running
container cloned and started in **328 ms** with its state intact, and 24.7 GB of
estate moved in a single stream. Docker on the apt distributions, podman on the
RPM ones.

---

## Encryption and Secure Boot

### Is the disk encrypted?

Full-disk ZFS native encryption (AES-256-GCM) is **pre-selected in the
installer**, and the passphrase is always required -- there is no configuration
in which encryption is silently skipped, and turning Secure Boot on or off does
not change that.

You are asked for the passphrase once per boot. First boot asks a second time
while the system installs the key that makes later boots single-prompt. TPM2
auto-unlock is on the roadmap, not shipped.

### Is Secure Boot on?

**Off by default**, on purpose. With it off, the firmware boots ZFSBootMenu
directly: no shim, no GRUB stage, no MOK enrollment, and nothing to miss at a
ten-second prompt. That is the right default for a lab machine.

Turn it on with `KLDLOAD_ENABLE_SECURE_BOOT=1` at install time when the
machine's threat model wants a verified boot chain. The install then generates a
per-install MOK, signs ZFSBootMenu and the out-of-tree modules with it, and
powers the machine **off** at the end rather than rebooting -- so you control
the enrollment boot instead of racing an auto-reboot.

### I turned Secure Boot on and the machine will not boot.

Almost always the MOK is not enrolled. `sudo kldload-mok-repair` reports the
enrollment and signing state; `kldload-mok-repair repair` queues the fix. Then
reboot and **press a key immediately at the blue MokManager screen -- it waits
about ten seconds** -- and choose Enroll MOK, Continue, Yes, password
`kldload`, Reboot.

The tool is on the installed system *and* on the live USB, so a machine that
will not boot at all is still repairable. If the machine boots to emergency
mode, confirm the cause with `modprobe zfs`: **`Key was rejected by service`**
is conclusive. This failure can appear weeks after the missed prompt, at the
first kernel update.

### Does a kernel update break module signing?

No -- DKMS auto-signs on kernel upgrade, and on the installed system the kernel
set plus NVIDIA are versionlocked at first boot, so a routine `dnf update`
cannot pull a kernel that OpenZFS has no build for.

---

## Offline and air-gapped

### What is the "darksite"?

The complete package mirrors, baked into the image. The Fedora (RPM) and Debian
(APT) trees, the Kubernetes container images and the Helm charts are all inside
it already, so the installer never needs a package mirror, a registry or a
vendor endpoint.

### Does it really install with no internet?

Yes, for both menu substrates, and it is the normal mode rather than a degraded
one. Measured on the shipped image: **zero public network traffic during a
build**, with the Fedora (3.4 GB) and Debian (2.7 GB) package trees, 23
container images (1.5 GB) and the charts already present.

The caveat worth saying out loud: the offline payloads are strongest on Fedora
and Debian. Other substrates reach the network for part of their content, so
air-gapped is fully proven on the two on the menu and "it depends what you are
pulling" everywhere else.

### Can I use it in a secured facility with no uplink at all?

That is what it was built for. One image is staged on a server on your LAN and
every machine pulls from it. Nothing leaves the network -- no mirrors, no
registries, no git servers, no vendor endpoints.

### What about bandwidth?

The image is uploaded once, no matter how many machines boot from it. Fifty
machines fetching their own packages from vendor mirrors is roughly 700 GB over
your internet connection, and 250 machines about 3.4 TB. Here it is one image,
once, and everything after that is LAN traffic you already own.

---

## Fleets, netboot and clusters

### How do I install more than one machine?

The same image, served over the network. The per-machine work is inventorying a
MAC address.

```
kldload-netboot-server arm-install <mac> <answers>.env   # one machine
kldload-netboot-server arm-all     ./rack/               # every .env in a directory
kldload-netboot-server status                            # what is armed right now
```

A target needs nothing but a network port, and the fiftieth machine costs the
same to prepare as the second because nothing is fetched per machine.

### Can a network boot wipe a machine by accident?

No. Installing requires a per-MAC consent token. A machine that network-boots
without one prints that it is continuing the boot order and boots from its own
disk. `arm-all` refuses duplicate MACs or hostnames outright and exits non-zero
unless every machine armed, so a half-armed rack is an error you hear about
rather than discover.

An armed machine shows what it was armed with and counts down before fetching
anything large; any key opens a manual override, and Esc boots the local disk.

### Do I need a PXE server, DHCP surgery or an Ansible control node?

None of the three. An installed machine can retain the netboot payload it was
built from, so machine one provisions machines two through N with nothing else
to stand up. Ansible runs inverted: `ansible-playbook` executes locally on each
machine at first boot rather than being pushed from a control node, so there is
no inventory to keep current, no SSH fan-out and no credentials held centrally.
A hundred machines build themselves at once without coordinating.

### What does the Kubernetes profile actually give me?

A cluster that is HA by default: three control planes behind a kube-vip VIP,
with Cilium as the CNI and **kube-proxy deliberately absent** (kubeadm runs with
`--skip-phases=addon/kube-proxy`), plus Hubble, Tetragon, MetalLB, Argo CD,
metrics-server and ZFS-backed storage. Adding a node reconciles the mesh, etcd
and the firewall everywhere else.

### Is "six nodes off one image" really free?

Measured on the demo cluster: the golden image refers **2.32 GB**, and each of
the six node clones reports **0 B used**. Six machines, one image's worth of
disk, because a clone only starts costing space when it is written to.

### Do VM clones actually take 100 ms?

VMs live on ZFS zvols, so a clone is copy-on-write: about 100 ms to create, and
near-zero to store. Snapshots are atomic, `fs-freeze` gives application
consistency, and replication is incremental `zfs send`.

---

## Hardware, GPUs and the AI stack

### What architectures are supported?

x86_64, UEFI. That is the whole list. There is no ARM build.

### Do I need an NVIDIA card?

No. NVIDIA drivers and CUDA are opt-in at install. If you do have one, the GPU
is time-sliced across the local model and guest VMs, so PCIe passthrough is not
required to share it.

### What is the local AI stack, and does it phone home?

Ollama with Open WebUI, RAG over your own documents via ChromaDB, voice in and
out (whisper.cpp and Piper). The model is chosen automatically by detected VRAM.
No cloud, no telemetry, no API key -- the models and the index live on the
machine.

### Can I leave the AI stack out?

Yes: `OLLAMA=no` at build time, and the image gets smaller by the size of the
model bundle. The same is true of the offline mirrors (`DARKSITES=fedora` for a
single-mirror build) and of the Kubernetes images.

---

## Compared with other things

### How is this different from Proxmox VE?

Proxmox is a hypervisor appliance that wants the machine. kldload is a way to
build a machine: it installs the vendor's Linux, and virtualization is one
profile among several. If you want a web UI to run VMs on a dedicated box,
Proxmox is a fine answer. If you want ZFS on root with boot environments,
package rollback and an offline installer -- on a machine that is also a
workstation, or a Kubernetes node, or all three -- that is this.

### How is this different from NixOS?

NixOS gets reproducibility by making the system declarative and then keeping you
inside that model. kldload gets it by making the *deployment* reproducible and
then leaving you an ordinary mutable Linux: same package manager, same paths,
same `/etc`, and every skill you already have still works. The rollback story
is comparable in effect; the price is different. Nix asks you to learn a
language. This asks you to accept its opinions about layer zero.

### How is this different from just running Ubuntu Server?

Ubuntu Server ships ext4 by default, no boot environments, no snapshot policy
and no offline installer. You can assemble the same properties by hand -- people
do -- and that assembly is exactly what this automates and tests.

### Does it replace Packer?

No, it feeds it. `kexport` produces qcow2, VMDK, VHD, OVA and raw images,
auto-sealed with cloud-init multi-datasource config, ready for Packer or a
direct hypervisor import.

---

## The project

### Is it open source?

Yes, BSD 3-Clause. Not a trial, not a community edition, not open core with the
useful half withheld.

Two shipped components are not open source and it would be dishonest to bury
them: **Google Chrome** (the default browser on RPM desktops and the renderer
for the kldload GUI apps -- Debian targets get Chromium) and the **NVIDIA driver
and CUDA**, which are opt-in at install. Everything else arrives from its
upstream under its own licence.

### Is anything forked or patched?

No. The tree carries **zero `.patch` files and zero vendored third-party
source** -- every component arrives from its upstream package repo, its official
release artifact, or its own git remote. That is a checkable claim, and checking
it is one command:

```
git ls-files | grep -cE '\.patch$'    # 0
```

### What is it written in?

Bash, mostly and deliberately: the installer, the first-boot scripts, the
snapshot machinery, the boot-environment manager and the darksite builder are
all shell you can read on the machine at 2am. The web UI and a handful of
tools are Python with no dependencies beyond the standard library.

### What are zxplore, vmxplore, wgxplore and ztxplore?

The consoles. zxplore is the ZFS console (datasets, properties, the snapshot
list that makes rollback visible), vmxplore the VM estate with the guest's own
screen rendered in it, wgxplore the WireGuard estate across a fleet, and
ztxplore an OpenZFS test lab that runs six distributions on zvols against their
own kernels.

Three are separate BSD-3 projects by the same author with their own repos.
kldload builds each from its own upstream at ISO-build time and records the
exact commit it shipped in `/etc/kldload/`, so an installed system can say
precisely what it is running. They run on any Linux or BSD box -- kldload is
their first-party distribution, not their owner.

### Is there a kldload package repository I have to trust?

No. After install the system runs upstream packages from the vendor's public
repos, and `dnf update` / `apt upgrade` just work. There are no kldload-specific
runtime updates.

### How do I know what tree an ISO was built from?

Every release is tagged, so `git show v1.4.2` is the exact tree. The build also
records the stack lock's digest beside the commit, and the installed machine
carries its build provenance.

### Where do I get help?

The Discord is at [discord.gg/QX8wf38N3V](https://discord.gg/QX8wf38N3V), and
the issue tracker is on
[GitHub](https://github.com/kldload/kldload). For an install that went wrong,
`tests/collect-bundle.sh` gathers what anyone answering will ask for.
