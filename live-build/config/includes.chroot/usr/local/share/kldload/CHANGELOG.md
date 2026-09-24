# Changelog

## 1.5.0 — 21 September 2026

449 commits since 1.4.2: 86 features, 298 fixes, 349 files changed,
40,227 lines added.

1. [One key provisions the rack](#one-key-provisions-the-rack)
2. [The netboot menu](#the-netboot-menu)
3. [Rebuild a node from its replica](#rebuild-a-node-from-its-replica)
4. [The first boot explains itself](#the-first-boot-explains-itself)
5. [Firecracker microVMs on the same substrate](#firecracker-microvms-on-the-same-substrate)
6. [Blue/green, one layer down](#bluegreen-one-layer-down)
7. [Failures that reported success](#failures-that-reported-success)
8. [Why the shape is what it is](#why-the-shape-is-what-it-is)
9. [Two defaults changed](#two-defaults-changed)
10. [Also](#also)
11. [The release review](#the-release-review)
12. [Known issues](#known-issues)

---

This release is about provisioning and recovery — getting a rack built without a
person at each keyboard, and getting a machine back when one dies. The ratio
tells the rest of the story: 298 fixes against 86 features. Nearly every fix
below was found the same way 1.4.2's were, by installing on real hardware and
measuring what actually landed.

This cycle that meant eleven editions installed end to end on the same machine,
repeatedly, across both Debian and Fedora: core, server, net, desktop, kvm, k8s,
storage and full. Every install succeeded. Everything that failed, failed
*after* the install — a cluster that came up without its mesh, a golden that
sealed empty, two fixes from different weeks quietly cancelling each other out
1,270 lines apart. That is the class of defect this release is mostly made of,
and it is only findable by standing the whole estate up and using it.

### One key provisions the rack

The live USB used to install one machine. It now serves the next one.

An installed machine can retain the netboot payload it was built from, so
machine one provisions machines two through N with no other infrastructure — no
separate PXE server, no DHCP surgery, nothing to stand up first. The payload is
the full darksite, deliberately: 15 GB over PXE so a rack can be built with no
internet at all.

Install the first machine with `KLDLOAD_KEEP_NETBOOT=1` in its answers file and
it keeps the kernel, initrd and squashfs it was installed *from*. That is the
whole server. `kldload-netboot.service` then lays out an HTTP tree, writes an
nginx config and a dnsmasq proxyDHCP+TFTP config bound to the LAN interface, and
brings both up:

```
$ kldload-netboot-server status
payload : /var/lib/kldload-netboot (kldload_version = 1.5.0-rc
iso_name        = kldload-1.5.0-rc-x86_64.iso
built_at        = 2026-09-22T01:39:40Z
edition         = free
profile         = desktop
arch            = x86_64
commit          = c4d55933c4cd
k8s_stack_lock  = 5c62d78a3495139d)
service : active
goldens : 0
armed   : 0 machine(s)
```

**proxyDHCP**, which is the part that makes this usable on a network you do not
own: it answers PXE *beside* the existing DHCP server and never hands out
addresses. There is nothing to reconfigure on the network, and nothing to undo
afterwards.

**A rack is a directory, and a machine is one file in it named after its MAC.**
That is the entire management model. There is no inventory database, no state
file, no controller to stand up and keep alive. The list of machines is `ls`.
Editing the fleet is `sed`.

The file is flat `KEY=value` — everything the installer would otherwise ask:

```
KLDLOAD_DISTRO=fedora
KLDLOAD_PROFILE=server
KLDLOAD_DISK=/dev/disk/by-id/nvme-SAMSUNG_MZQL2...
KLDLOAD_HOSTNAME=kldload-node
KLDLOAD_ZFS_ENCRYPT=0
KLDLOAD_ENABLE_SECURE_BOOT=0
KLDLOAD_K8S_BOOTSTRAP=0
KLDLOAD_KEEP_NETBOOT=0        # 1 makes this machine a server too
```

So a twelve-node rack is one template, a list of MACs, and a loop:

```
# one file per machine, named for the MAC that will boot it
i=1
while read -r mac; do
    sed -e "s/^KLDLOAD_HOSTNAME=.*/KLDLOAD_HOSTNAME=node-$(printf %02d "$i")/" \
        TEMPLATE.env > "rack/${mac}.env"
    i=$((i + 1))
done < macs.txt

# arm the lot: every .env in the directory, refusing duplicate MACs or
# duplicate hostnames, non-zero unless every machine armed
kldload-netboot-server arm-all ./rack/
```

Changing the fleet afterwards is the same shape. Turn Kubernetes on across the
rack, or move everyone to Debian, and re-arm:

```
sed -i 's/^KLDLOAD_K8S_BOOTSTRAP=0/KLDLOAD_K8S_BOOTSTRAP=1/' rack/*.env
kldload-netboot-server arm-all ./rack/
```

Single machines work the same way, with two variants:

```
# a box whose management NIC boots but whose 10G NIC should carry the
# 15 GB payload -- boot on one, pull the root image over the other
kldload-netboot-server arm-install f0:2f:74:cd:27:50 ./rack/node-07.env \
    --netdev a0:36:9f:9f:10:1c

# clone rather than install -- receive a golden as a zfs send stream over
# the same HTTP, no ssh identity needed on either end
kldload-netboot-server arm-deploy f0:2f:74:cd:27:50 \
    --golden k8s-worker --disk /dev/nvme0n1
```

Arming writes `armed/<mac>.ipxe` — one snippet per MAC, and that snippet *is*
the consent token. `boot.ipxe` probes net0 through net3 and chains the first
armed snippet it finds; an unarmed NIC gets a 404 and the chain falls through to
the next, and then to the local boot order. No token, no touch. `disarm <mac>`
and `disarm-all` take it back.

Around it: a boot menu so the distribution is chosen at the console, answers
taken from the kernel command line, and golden streams so a built machine can be
cloned over HTTP rather than reinstalled.

Four ways a netboot used to end quietly are now loud.

### The netboot menu

A netbooted machine used to do exactly what its answers file said, silently. It
now shows a menu before it fetches anything large. An armed target gets a summary
card of what it is about to do and a ten-second countdown; if nobody touches it,
the armed answers file runs exactly as before and the rack builds itself. Press
any key and the countdown stops and hands over the whole configuration:

- **Profile** — core, server, desktop, kvm, k8s, storage or ai, each with the
  one-line description of what it turns on.
- **Distribution** — whichever of the verified set the server was told to offer.
- **Security** — ZFS encryption and Secure Boot, as ticks.
- **Components** — KVM, golden images, Kubernetes, the ZFS lab, AI. Ticks again,
  so the machine you are standing in front of gets what you want rather than
  what the template assumed.
- **Identity** — hostname, user, time zone, keyboard.
- **Credentials** — login password and ZFS passphrase, entered on the machine's
  own screen with a show/hide toggle, confirmed twice.

Every choice rides out on the kernel command line as `kldload.<key>=`. Secrets
never do — a password or passphrase is asked for on the console, never written
into an answers file served to the LAN, and never visible in a process list.

Under it: iPXE is compiled as part of the build and gated on, so a broken menu
fails the build rather than the rack. `snponly` rather than the full image,
because the full one kills the USB keyboard on real hardware. The menu can also
boot a live desktop, the local disk, or drop to an iPXE shell.

A machine can now **boot on one NIC and pull the root image over another**, which is what a
box with a management port and a 10G data port actually needs. And RHEL and Arch
netboot the 2 GB net image rather than the 15 GB full one, because they were
never darksite-complete and pretending otherwise just made the download longer.

The consent model is unchanged and is the important part: an unarmed MAC 404s
and falls through to the local boot order. No token, no touch.

### Rebuild a node from its replica

Snapshots were already replicating. What was missing was the other half: taking a
replica and making it boot somewhere else.

A replicated boot environment can now be restamped for the machine it landed on,
and a node can be rebuilt from its replica and then *proved* — a canary boot that
checks the thing actually came up, rather than reporting that the receive
finished. A restore that is not verified is a backup you have not tested.

### The first boot explains itself

A kldload install reaches a desktop long before it is finished, and the machine
then spends up to an hour building golden images and a cluster behind a screen
that looks idle. That gap is now the manual.

The reasoning was not complicated: if I am going to make you sit through two
hours of building images, I may as well make it entertaining — and if something
has your attention for two hours anyway, it should teach you the machine you are
waiting for.

The install show holds the screen through the reboot and into first boot: 352
slides in two halves, with the real build log in a window beside them.

Part one is 202 slides in a remembered shuffle, played while the installer
works. Part two is 150 more for first boot — 28 ordered lessons, 62 tips, and
the rest grouped by subject — over 25 animated scenes, with a 41-entry command
manual underneath. The examples are real commands with the output the machine
actually printed, so the thing you watch while waiting is the thing you will
type afterwards.

**It tells you its own keys.** The legend shows for the first thirty seconds,
for twenty more after `K` or `?`, and briefly after any keypress, because keys
nobody is told about are keys nobody uses:

```
N NEXT SLIDE   B BACK   S SCENE   + - SPEED   F12 HAND OVER   CTRL+ALT+F2 TERMINAL
```

| Key | What it does |
|---|---|
| `N`, `→` | Next slide |
| `B`, `←` | Back a slide |
| `S` | Skip to the next scene |
| `+` / `-` | Slower or faster, two seconds a press |
| `K`, `?` | Show the legend again |
| `F12` | Hand the machine over |
| `Ctrl+Alt+F2` | A terminal, if you would rather not wait at all |

`F12` is a function key deliberately: `N`, `B`, `S`, `+` and `-` are all letters
a viewer can hit by accident, and this one ends the presentation. It stops the
*show*, not the build — `kldload-autodeploy` is its own unit and carries on
building images and the cluster behind the desktop, with `kldload-build-monitor`
on screen saying so.

The same thing runs on the console for machines with no graphics, and it is a
plain command you can drive yourself:

```
kldload-firstboot-show status        # building | ok | problem, exit 0
kldload-firstboot-show frame         # draw one frame and exit
kldload-firstboot-show logtail 40    # the source, then the last 40 cleaned lines
```

`logtail` is what the graphical show fetches, so the console screen and the
slides display the same text, redacted the same way. During a live install it
reads the newest `/var/log/installer/*.log`; afterwards it reads the journals of
`kldload-firstboot`, `kldload-autodeploy` and `klab-firstboot`.

An install kiosk runs the graphical half, so the show needs no desktop
underneath it: `cage` with a browser on `127.0.0.1:8099`, on tty1, with the
console screen still drawing on VT8 underneath and coming back into view if the
kiosk fails for good.

Which machines get it is a rule rather than a setting (fiend, 2026-09-14): core,
server and a plain desktop come straight up because they are ready; anything
building golden images, Kubernetes or KVM keeps the show on screen all the way
through.

**How it is built, because the constraints picked the technology.** Each half of
the show is a single self-contained HTML file — `index.html` for the install,
`firstboot.html` for first boot — served by the web UI off the machine itself.
No framework, no bundler, no CDN, no fonts fetched, no `<script src>` pointing
anywhere. That is not minimalism for its own sake: the machine playing the show
is mid-install with no internet, so anything it cannot draw from its own disk is
not available to it.

Everything moving is drawn on a **2D canvas at 30 fps, and there is no WebGL
anywhere in it on purpose** — the comment in the source puts it better than a
changelog can: *"no WebGL to fall back from."* The show runs during a first boot
where the NVIDIA driver may still be compiling, under `cage` on a software
renderer, on a server with no GPU at all. A 2D context is the one thing that
works in all three cases, so the effects were written to that budget rather than
the budget being raised to fit the effects. Copper bars, a starfield and
scrollers — demoscene technique, chosen because it was invented for exactly this
constraint.

The slides are text in an array in one file. Editing what the machine teaches you is editing `free/index.html` and
rebuilding — there is no content pipeline, no database and no separate asset
store to keep in sync.

The debt is acknowledged inside the show rather than in a footer, because that
is where anyone will actually read it. Four slides credit the Amiga for the
grammar every effect here is borrowed from — *"copper bars, sine scrollers,
starfields, greets: every visual idea in this show was invented on that machine
by people giving it away for the credit"* — and tie it to the argument rather
than just tipping a hat: three coprocessors doing work the CPU should not have
to is the same trade as eBPF and the GPU in this box, and a demo that arrived as
one file and ran on any Amiga every time is a machine you can reproduce exactly,
which is not a new idea but a very old one that got lost. The effects are
original drawings; where one is a nod to something specific the source says
`Homage only, drawn from nothing`.

### Firecracker microVMs on the same substrate

Appliances can now be stamped as Firecracker microVMs from the ZFS zvols they
already live on, run under the jailer as an unprivileged user, and be enrolled,
metered, meshed and torn down exactly like the full VMs beside them. Clone and
teardown run in parallel, with a TCP readiness probe for the clones that do not
speak HTTP.

Arbitrary VMs can also be put on a private WireGuard mesh.

### Blue/green, one layer down

`kube-bluegreen` could already preview a workload, cut over to it and roll back.
It now does the same thing to an entire cluster: deploy a second one beside the
first, promote it, destroy the loser. Three tiers of the same idea — workload,
cluster, and the klab golden VMs underneath both.

Two defects in it were found by running the cycle rather than reading it, and
both had the same shape: deploying green quietly took over the default
kubeconfig, so `kubectl` pointed at the new cluster while you still believed you
were talking to the old one, and destroying a track left the mesh unpeered. The
first fix corrected the address and missed that deploy rewrites the file
wholesale, which only showed up on the second run of the fixed build.

### Failures that reported success

The largest single class of fix this cycle.

A clone made with `kvm-clone` could not be enrolled, because sshd refused root.
The tool went to some trouble over root's `authorized_keys` — including
installing it last to beat cloud-init's forced-command banner — and never
permitted the login that key was for. Four tools that clone had each grown their
own sshd drop-in for this, and all four call `kvm-clone` to do the cloning; the
shipped verb they all go through was the only one without it. The estate sweep
logged "no SSH as root while reading its node id", wrote the database row, and
left the guest off the mesh.

It stayed hidden because the check that would have caught it could not pass
either: the lifecycle's mesh probe called `kldload-estate --json`, and there is
no `--json` flag, so it read an empty stdout and returned "not on the mesh" every
time — including for the machines that were. Two broken things agreeing is not
evidence, and it cost days.

Fixing both still left every clone off the mesh, and this time the message was
the lie. With root SSH working, `kldload-enroll` read the guest's mesh id with a
`cat` that exits 1 when the file is absent — which it is on every fresh clone,
because goldens are sealed without one and the id is allocated a few lines
later. That 1 came back through ssh and was reported as "no SSH as root". It was
not a Debian problem, and it was not cloud-init timing: the enrol sweep retried
thirteen minutes after the clone booted and got the same answer. Under that sat
a third layer: the klab goldens carry WireGuard but not `kube-network`, the
guest half of the mesh, so every clone of them was refused as "not a kldload
image". The enroller now carries the host's own copy across.

Fixing that uncovered a race that had been hidden behind it. The enrol sweep
runs on a timer, and if it fired while a golden was still being built, it
enrolled the golden: a WireGuard key and a mesh id, which the seal then kept and
every clone inherited. A Kubernetes cluster cloned from such a golden came up
with six nodes sharing one key and one id, overwriting each other on the host,
and its API unreachable. Goldens are now never enrolled, and every seal forgets
the mesh identity the way it already forgot SSH host keys. The same timer also
raced the cluster build itself: it could reach a node before the cluster had
meshed it and give it an ordinary VM's id, renumbering the control plane off the
API address. A cluster node is now left to the cluster until it is meshed. And
on a hypervisor with no cluster, nothing had ever put the host itself on the
mesh, so no VM could join it; the host now joins with its first VM when
WireGuard was chosen at install.

The other half had never worked either. Deleting a VM left it a peer on both
mesh planes, because nothing on the delete path removed peers — and the check
meant to catch it asked the estate for the machine by name, which a deleted
machine no longer has, so it reported "released" every time. Enrolment now
records each VM's mesh id and key; `kvm-delete` removes the peer while the key
still matches and exits non-zero if it is still on the interface afterwards.

Goldens ran two DHCP clients. `kube-setup` enabled systemd-networkd beside
NetworkManager on the Kubernetes golden, and a klab desktop golden runs GNOME's
NetworkManager beside the networkd that klab chose; the seals also kept
NetworkManager's lease files, so a clone asked for the golden's last address
with one client and took a fresh one with the other. Two addresses on one
interface, WireGuard following whichever the guest sent from, and an estate
that could not match the peer to the machine. Each golden now has exactly one
client on its NIC, and every seal forgets its leases.

A clone of any golden was invisible to monitoring: the target generator knew
three klab name patterns and nothing else, and the Kubernetes golden did not
ship node_exporter at all. Every enrolled VM is now a Prometheus target, and the
Kubernetes golden installs the exporter.

The estate test now runs on every golden rather than the first one it found, and
for each clone proves the shipped playbooks run, that it has exactly one
address, that Prometheus scrapes it, and that deleting it takes it off the mesh
and out of monitoring. The lesson is the same one three times: a defect that two
broken instruments agreed about needs each instrument fixed separately before
anything is concluded.

The installer stamped every install as version 1.1.0, and the Secure Boot
re-signer that runs after a kernel update signed nothing. Both came from this
cycle's own silent-failure cleanup: a comment explaining an error swallow was
placed inside a multi-line command, which ends the command there, and every
linter accepted it. A gate now fails the build on a comment inside a command.

MetalLB's doctor check failed on Kubernetes installs with every node Ready. The
chart deploys FRR, a BGP routing daemon, beside every speaker by default, and on
one node FRR's zebra never started, so that speaker sat at three of four
containers ready. kldload announces its address pool in L2 mode and never speaks
BGP, so FRR is now turned off: each speaker is one container.

**Security:** installed Fedora and EL systems updated without checking package
signatures. Every upstream repository the installer wrote had signature checking
off, and it stayed off on the installed machine — including the EL ZFS repository,
which its host serves only over plain HTTP. Every repository now checks
signatures with its vendor's key; on EL the EPEL and OpenZFS keys are installed
for the first time. A repository whose key is missing refuses updates instead of
installing them unverified. On a Fedora machine installed with an earlier
release, this switches checking on (it adds Fedora's key, which the machine
already has):

    sed -i -e 's/^gpgcheck=0/gpgcheck=1/' \
        -e '/^\[fedora/a gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch' \
        /etc/yum.repos.d/fedora.repo

Building the core or single-mirror edition beside the full one renamed the full
ISO to `.prev`, because the keep-the-previous-image step knew only the `-net`
suffix. It now derives the name exactly as the builder does.

`klab` announced fifteen golden images ready and exited 0 after every one of
them had failed to build. The exit status is what the orchestrator reads, so it
wrote a ready marker over an empty pool. A golden is now "ready" when ZFS has the
snapshot, not when the log says so.

A systemd unit set `StandardOutput` twice — a file, and thirty lines below it a
leftover `journal` from April. systemd silently takes the last one, and
`systemd-analyze verify` is happy with both, so the first-boot smoke suite ran
and its report went nowhere. There is now a gate that fails the build on any
directive set twice in one section.

The installer enabled the monolithic `libvirtd` on distributions that ship
modular libvirt. The two conflict, so `virtqemud.socket` stayed inactive and
every `virsh` call failed — which took out a Kubernetes bootstrap and fifteen
golden images in one go, on the one profile combination nobody had tested.

A first-boot script called a logging helper that only exists inside the
installer: exit 127, command not found, on the benign path where the network was
already up.

Silent failures were cleared out of the whole install path — `kldload-firstboot`,
`bootstrap.sh`, `profiles.sh`, `kldload-install-target`, and the storage and
bootloader paths — and both ratchets that police them now hold at their
baselines.

### Why the shape is what it is

Most of what is above only makes sense with what was deliberately left out.

**ZFS is the substrate, not a storage plugin.** Proxmox supports ZFS well, among
LVM-thin, directory storage, Ceph and the rest — which means nothing in it can
*assume* ZFS. kldload assumes it, and that assumption is what the whole product
is made of. A VM disk is a zvol. A new node is a clone of a golden zvol. A
backup is a snapshot. Disaster recovery is send, receive, restamp, boot. None of
those are features that were added; they are the filesystem behaving normally,
and the tooling is thin because it has to be.

**No qcow2, no image files, no format layer.** A qcow2 file is a
copy-on-write filesystem implemented inside a file that is itself sitting on a
copy-on-write filesystem. That is the same work done twice, with a backing-file
chain that lengthens as you clone and eventually wants consolidating. A zvol is
a block device on the pool: one copy-on-write layer, no chain, no consolidation,
no format to convert when you move it. `kube-demo` measures the clone on the
machine in front of you and prints the milliseconds it took — a 40 GB disk,
created by writing metadata. It is not a benchmark we are asking you to believe;
it is a command you run.

Every node in a six-node cluster
stores only the blocks that diverged from the one golden image, so cluster size
stops being a disk-capacity question. Compression and the ARC operate on real
blocks rather than through a format layer. A snapshot of a running VM is
instant, and so is the rollback.

**Immutable where it helps, ordinary Linux where it does not.** Talos is
genuinely excellent at what it does, and what it does is remove the shell. That
is the right trade for a fleet that never needs debugging by hand and the wrong
one the first time it does. kldload is immutable at *deployment* — the install
is reproducible, air-gappable and rebuilt from a manifest rather than patched
into shape — and a full mutable Linux once it is running. You can `ssh` in and
read the logs, because eventually you will have to.

**Provisioning tools assume a substrate exists.** MAAS and Foreman are
provisioning layers, and good ones, but both start from the premise that
something already stands up the machine underneath. This release closes that
gap from the other direction: the live key *is* the infrastructure. One machine
is installed by hand, retains its netboot payload, and provisions the rest of
the rack over PXE with the full offline mirror — no DHCP surgery, no separate
server, no internet.

And the same path raises a node *back*. A destroyed machine does not have to be
reinstalled and reconfigured into something resembling what it was: arm its MAC
for deploy instead of install, and it netboots, receives its own replicated
snapshot as a `zfs send` stream over HTTP, and comes back as the machine it was
— operating system, VMs, state and identity, from the pool that already held
them. No USB, nobody in the room, and no ssh identity on either end, which is
the reason that transport is HTTP.

Two things a receive alone cannot fix are fixed with it, both measured by
restoring a real machine and booting it (onyx, 2026-09-09). The initramfs
imports by cache file, and a cache records the vdev paths of the machine that
wrote it, so recovered hardware lands in emergency with "no such pool
available"; restores switch to scan-based import and rebuild the initramfs. And
the ESP is not in ZFS, so the restored `/etc/fstab` names an ESP UUID that no
longer exists and `local-fs.target` fails with a perfectly good pool underneath.

The drill that proves it round-trips a canary token rather than checking that
the machine booted, because a restore can succeed, boot, and still be a week
old. That distinction is the whole difference between a backup and a backup you
have tested.

**The class of work that disappears.**

When a node is a clone of a golden image, and the install that produced the
golden is reproducible from a manifest rather than patched into shape by hand,
the response to a broken machine changes category. It stops being *diagnose,
form a theory, apply a change, hope* and becomes *destroy, replace, carry on*.
The replacement is not "a machine like the old one"; it is the same blocks from
the same snapshot, which is why you can trust it without re-testing it.

That removes work rather than automating it. Configuration drift stops being a
thing you detect and reconcile, because nothing drifts — the node is replaced,
not repaired. The long tail of "this one box is weird" evaporates, because there
is no mechanism by which a box becomes weird and survives. Most of a
troubleshooting session is establishing what state a machine is actually in, and
that question stops being interesting when the answer is always "identical to
the golden, plus whatever diverged since Tuesday, and here is the snapshot."

It works because the two halves meet. Layer zero — before the OS, the firmware
and boot path and pool layout — is provisioned by the same artefact that
installs layer one, from one key, over PXE, offline. Neither half assumes the
other was done by somebody else, which is exactly the seam that normally leaks:
a provisioning tool that hands off to a configuration tool that inherits a
machine neither of them fully built.

The honest limit: the *machine* is disposable, the *pool* is not. Data, state
and the goldens themselves still need the care they always did — which is what
the replication and the restamped-and-canaried restore in this release are for.
Destroy-and-replace is a claim about compute, not about storage, and a product
that blurs that line is lying to you.

**And the automation is the boring kind.** Answers come from a file or the
kernel command line, per-MAC snippets give each machine its own, and the whole
thing is verifiable afterwards: this cycle every edition was installed end to
end on real hardware and checked against what the answers asked for, which is
how the four worst defects in this release were found.

None of this is invention. It is an opinionated assembly of proven parts, and
the opinions are the product.

### Two defaults changed

Neither breaks an existing answers file, but both change what a machine does:

- **ZFS encryption defaults to off.** State it explicitly if you want it.
- **Shipped answer templates no longer carry a real default password.** The old
  templates did, which is exactly the kind of thing that gets copied once and
  lives forever.

### Also

- The desktop keymap rotates workspaces, and `Super+G` tiles every ordinary
  window on the workspace into an even grid — four windows become four
  quarters, where stock mutter only tiles one window to a half. It does not
  un-tile: the previous geometry is not recorded, so the way back is by hand
- A metrics explorer that walks the machine as a tree, BPF run-time statistics,
  and dashboards that read zero rather than blank when there is nothing to show
- Storage controller, firmware and drive health reported without a vendor tool
- Guests get a sound card and something to drive it
- The ISO build chooses what it carries: payload, darksites, Kubernetes images,
  Ollama
- The installer refuses to create `rpool` while another importable pool already
  has that name — three importable pools called `rpool` is how a machine boots
  into the wrong one
- A storage profile that actually serves something: NFS, SMB and iSCSI, verified
  against real clients rather than against a running daemon
- The encrypted root can be unlocked by the TPM, bound to Secure Boot through
  PCR 7. Inert until you seal it, and not yet tested on real hardware
- Every ISO records the commit it was built from and a digest of the resolved
  Kubernetes stack, so an image can be traced to a tree rather than a date
- The darksite resolves the Kubernetes stack fresh on every build and then locks
  it, instead of carrying a pinned literal that goes stale without saying so
- KVM is on by default on every profile but core
- Xfce and KDE golden lineages beside GNOME

Two things were taken back out before release. The vdi/rdp desktop profiles and
the proxmox profile were reverted — they were half-built and shipping them would
have meant four more editions to verify for no one who had asked. The arcade
session was reverted because it segfaulted on the first keypress.

### The release review

Before tagging, the whole tree was read against the question "would I put this
in front of an enterprise security team". Six passes — security, silent failure
on the install path, things written but never wired, operator interface against
its own documentation, the Go and Python, and what the tests actually prove —
each with file and line for every claim, and each claim re-read before it was
acted on. Build 66 is the first build with the results in it. What was found,
in the order it would have hurt:

- **The live image accepted root over SSH with a published password.** Every
  USB or PXE boot — a whole rack mid-provisioning — ran sshd with
  `PermitRootLogin yes` and `root:kldload`, while the disks and the install
  secrets were present. root is locked on the live image now and sshd allows
  it by key only. A script that hard-coded the build host's root key into
  live's and root's `authorized_keys` — under a comment saying the release
  process stripped it — is deleted; it had never run, because the unit that
  called it was enabled by a live-build hook the lorax build never executes.
- **Every install trusted one shared key.** The image carried a single
  `admin@kldload` public key that the installer appended to every install's
  `~admin/.ssh/authorized_keys`, next to NOPASSWD sudo. Whoever held that
  private key was root on every kldload box. The file is gone, the build
  refuses to ship it, and keys reach a target only from `KLDLOAD_ADMIN_SSH_KEYS`.
- **The netboot menu put passwords on the kernel command line.** The
  credentials form added on 18 September carried the login password, the ZFS
  passphrase and the Red Hat login on the live cmdline, URI-encoded.
  `/proc/cmdline`, dmesg and the journal are readable by every live user. The
  form is gone; the machine's own screen asks for what the answers file does
  not carry, and `kldload-autoinstall` refuses any secret it finds there.
- **The support bundle carried the keys.** `kldload-debug-bundle` copied all of
  `/etc/kldload`: the root SSH private key, the WireGuard keys, the web UI root
  token, the CA private key and, until first boot finished, the ZFS passphrase.
  It now copies an allowlist and redacts by name pattern.
- **A failed Red Hat registration was retried with `--insecure`.** One verified
  attempt now; the password no longer sits on the process list.
- **`hub.env` was fetched over HTTP and sourced as root** at first boot. It is
  parsed as `KEY=VALUE` and nothing else.
- **Arch and Alpine reported success on a machine that could not boot.** The
  bootstrap logged "system WILL NOT boot with ZFS" and returned 0. Both paths
  now end in one outcome check — kernel, initramfs, `zfs.ko` — and fail
  without them. The GRUB `direct` default, which Secure Boot intent selects,
  is refused when nothing was staged behind it; the admin account is checked
  after it is created, on the dnf path where a failure was previously invisible.
- **Two MOK passwords.** The installer hard-coded `kldload` for the enrolment
  while every screen said `KLDLOAD_MOK_PASSWORD`; and its `chroot target
  command -v mokutil` exits 127 on Debian, Ubuntu and Arch (`command` is a
  builtin, only Fedora ships the wrapper), so the enrolment in `security.sh`
  never ran there. One variable, a file test.
- **The web UI trusted an IP address as identity.** Loopback auto-auth is
  now bound to the proxy-only unix socket; in any TCP run mode nothing is
  trusted. Bob's autonomy defaults to off, and to off again when its settings
  file cannot be read — it used to default to running root commands unasked.
  `wipe_disk` matched pools by substring (`sda` matched `sdaa`) and destroyed a
  pool when it could not export it; it matches real paths and stops instead.
  The install answers were quoted in a form the loader does not un-escape (a
  password with a quote landed altered) and written to a predictable name in
  `/tmp`; the New VM button called a tool that was never shipped.
- **`apt rollback` rebooted in two seconds.** The README, and the wrapper's own
  comment, said it only staged. It stages. `deploy.sh burn` defaulted to
  `/dev/sda` so its documented auto-detect could never run; `kupgrade --help`
  ran the upgrade.
- **The CI smoke gate never looked inside the ISO.** `smoke-build` mounts the
  image with `mount -o loop`, which fails for the unprivileged user CI runs it
  as; the failure was a warning, and every ISO-content check has been skipped on
  every CI run since the gate was written. The mount is now `sudo -n` and a
  mount failure is a failed gate. The estate sweep judged the bench by profile
  and uptime alone — a failed install that fell back to the previous local
  boot would have passed as the requested edition; it now reads the distro and
  the build commit off the machine.
- **46 live-build hooks that nothing ran.** The `live-build/config/hooks` tree
  predates the lorax build and was never executed; the units and files it
  would have wired (`zexplore-api` on installed targets, `klab-hubble-relay`,
  the qemu guest agent on the live image) are wired explicitly now, and the
  dead tree, three dead units, two dead tools and a JavaScript file no page
  loaded are gone. `kube-setup` pinned Cilium CLI and Helm versions under a
  comment saying versions are never pinned; they come from the stack lock.

What the review did not change, and why, is under Known issues.

### Known issues

- `builder/build-iso.sh` is the last script not running under strict mode, held
  back deliberately because the only honest test of it is a full build.
- Arch is demoted, not deleted. An encrypted Arch install panics at boot because
  the initcpio ZFS hook exits; the code is still there and the distribution is
  off the netboot list until that is fixed.
- MetalLB installs chart 0.14.9 from its upstream repository at first boot,
  while the build resolves and mirrors 0.16.1. The installed version is not the
  one the build locked, and a Kubernetes bootstrap needs the network for it.
- The `|| true` baseline is still large even though the ratchet holds, and 45 of
  those swallows are continuation-blind — they cannot distinguish a harmless case
  from a real failure. Only the install path has been cleaned.

Two things that were on this list in the 1.5.0 pre-releases are now closed:
the module-signing **private** key no longer ships in the installation media
(the build fails on any private key found in the rootfs, and installs use BYOK
or a per-install key), and every shipped tool now answers `-h`/`--help` without
root and without side effects — that baseline is empty and gated.

Left for 1.5.1, found by the release review and not changed here: the web UI
treats a loopback client behind nginx as the operator (any local process is
root through it — a design decision that predates the review, now bounded to
the unix-socket mode); `kldload-webui` and `kldload-doctor` are far from
`mypy --strict`; 23 of the 25 main tools have no man page and none reach an
installed system; the `--help` contract still drifts on a handful of tools;
no automated install covers Ubuntu, CentOS, Rocky or Arch, or Secure Boot
with encryption; the `|| true` ratchet stands at 432 uncommented swallows in
the install and cluster scope.

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
