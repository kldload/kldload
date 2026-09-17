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
No package mirrors, no registries, no vendor endpoints during a build. A rack can
be provisioned in a room with no uplink at all. This is not a degraded mode; it
is the normal mode.

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
- Eight targets: Alpine, Arch, CentOS Stream, Debian, Fedora, RHEL, Rocky,
  Ubuntu
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

What "any landscape" honestly means: eight distributions, bare metal or virtual,
with or without Secure Boot, connected or completely air-gapped. Not every
combination is equally exercised, and the offline payloads are strongest on
Fedora and Debian; EL substrates fall back to the network for some content. That
is a real limitation and it is better said out loud than discovered.

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
