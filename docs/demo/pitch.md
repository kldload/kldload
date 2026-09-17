# What this actually buys you

Source material for the video description and for answering "so what does it
do". Every number here was measured on real hardware, not estimated. Where
something is only partly true, it says so, because the fastest way to lose a
technical audience is one claim they can catch.

---

## The one-sentence version

A bare machine becomes a working system — with its cluster, its tools and its
desktop — from one action, with no internet, and the fiftieth machine costs the
same to prepare as the second.

---

## The benefits, in the order people care about

**You stop building machines by hand.** Inventory the MAC, write the answers
once, arm it, power it on. Nobody stands at a keyboard. The difference between
one machine and a rack is the length of a directory listing.

**It works with no internet.** The whole operating system, every package and the
container images ship inside one image that is staged on a server on your LAN.
No package mirror, no container registry, no git server, no vendor endpoint.
**Zero public network traffic during a build.** Measured on the shipped image:
the Fedora (3.4 GB) and Debian (2.7 GB) package trees, 23 container images
(1.5 GB) and the Helm charts are all inside it already, so there is no
infrastructure to stand up before you can provision anything. A rack can be provisioned in a room with no uplink at
all. This is not a degraded mode; it is the normal mode.

**You do not pay for it in bandwidth, either.** The image is 13.91 GB and it is
uploaded once, regardless of how many machines boot from it. Fifty machines
fetching their own packages from vendor mirrors is roughly 700 GB pulled over
your internet connection; 250 machines is about 3.4 TB. Here it is 13.91 GB,
once, and everything after that is LAN traffic you already own. Deploying
hundreds of nodes costs the same external bandwidth as deploying one.

**The expensive part happens once.** One image is staged and served to every
machine that asks. Machine fifty does not cost more to prepare than machine two,
because nothing is downloaded per machine.

**Troubleshooting stops being the job.** Nodes are ZFS clones of a golden image.
A broken one is not diagnosed, it is destroyed and replaced in seconds, and the
replacement is byte-identical to the one that worked. Whole categories of work
disappear rather than getting faster.

**It costs almost nothing to run many.** Measured on the demo cluster: six
Kubernetes nodes cloned from one 2.32 GB golden, each reporting **0 bytes used**.
Six machines, one image's worth of disk.

**You get a workstation, not just a node.** The machine that runs the cluster is
one you can sit down at. Same hardware, same boot, ordinary GNOME desktop, with
the tools already installed and configured.

**It is free, and the licence is not a trap.** BSD 3-Clause. Not a trial, not a
community edition, not open-core with the useful half withheld.

---

## The features, concretely

**Provisioning**
- Netboot install from one staged image; targets need nothing but a network port
- Per-machine answers files: hostname, disk, profile, cluster shape
- `arm-all` over a directory; refuses duplicate MACs or hostnames, exits
  non-zero unless every machine armed
- A consent token per MAC, so an accidental network boot can never wipe a
  machine
- Offline payloads built at build time (Fedora via RPM, Debian via APT)

**Substrates**
- Works with any **apt**, **dnf** or **pacman** based distribution. The build
  runs the vendor's own package manager against the vendor's own repositories --
  `debootstrap`, `dnf --installroot`, `pacstrap` -- so there is no list of
  blessed distros to fall off the end of
- Nothing is forked and nothing is patched
- The component choices are independent of the distro, so the same opinions
  apply wherever you land

**Storage**
- ZFS on root, with boot environments — upgrade, and roll back a bad one from
  the boot menu
- Guests are zvol clones: near-instant to create, near-zero to store
- Snapshot and replication built in rather than bolted on

**Clusters**
- Kubernetes with control-plane HA; the demo builds three control planes and
  three workers
- Cilium as CNI with kube-proxy deliberately absent, plus Hubble and Tetragon
- kube-vip, MetalLB, ArgoCD, metrics-server, local-path storage
- Measured: fifteen minutes from power-on to all six nodes Ready

**Day two**
- Per-tool desktop launchers: Kubernetes, k9s, Helm, Ansible, Metrics, sysdiag,
  Secure Boot Repair, Build and Audit
- A web console on :8443 for the headless profiles
- Secure Boot supported, with a repair path when firmware loses the enrolment

---

## Legions of machines, across any landscape

The scaling claim is worth stating carefully, because "it scales" is what
everybody says.

What is true: the per-machine cost of provisioning is inventorying a MAC and
writing an answers file. The image is staged once. Every machine pulls the same
bytes from the same LAN server, and nothing else leaves the network. There is
no per-node licence, no control plane you have to buy, and no dependency on a
vendor being reachable — or solvent.

What "any landscape" means: any apt, dnf or pacman based distribution, bare
metal or virtual, with or without Secure Boot, connected or completely
air-gapped. It is the vendor's package manager doing the work against the
vendor's repositories, so support is a property of the mechanism rather than a
list somebody has to keep up to date.

The one caveat worth saying out loud: the *offline* payloads are strongest on
Fedora and Debian, and some substrates still reach the network for part of their
content. Air-gapped is fully proven on the two; elsewhere it depends what you
are pulling.

The constraint you will hit first is not software. It is how fast your switch
can push one image at however many machines you boot at once — and unlike most
constraints, that one you can see, measure and fix.

---

## What it is not

- Not an appliance. It does not want the whole machine to itself.
- Not immutable. The installed system is a full, ordinary, mutable Linux. The
  reproducibility is in how it is *deployed*, not in locking you out afterwards.
- Not a new thing to learn. It is an opinionated assembly of tools you already
  know, wired together so they work on first boot.
