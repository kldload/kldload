# WG Networks — the WireGuard primitives console (design)

Captured 2026-08-02 from operator design sessions. Name: **wgxplore**
(confirmed 2026-08-02 — domains verified available; binary short-name `wgx`). Sister project to
zxplore: own repo, BSD-3, runs on any Linux with kernel WireGuard; kldload
is its first-party distribution.

## One sentence

Declare networks; attach anything to them; the kernel does the rest —
Tailscale/NetBird ergonomics with **zero coordination plane** and a
**pure-kernel datapath**.

## The model

Two nouns, one verb:

- **Network** — a first-class declared object: name, subnet, topology,
  members. Topologies:
  - `ptp` — two peers.
  - `hub-spoke` — one reachable hub (the kldload answer to NAT: you own a
    port; no relay fleet, no STUN service).
  - `mesh` — full peer-to-peer.
  - `joined` — two networks federated via designated **gateway peers**:
    each gateway carries the far network's subnet in allowed-ips; other
    members route through their local gateway. Mesh-of-meshes with no
    controller — just route aggregation rendered into configs.
- **Member** — host, container, VM, (k8s: see non-goals).
- **attach** — the universal verb:
  - `attach host <net>` — render peer config + systemd unit.
  - `attach container <net>` — **the kernel trick**: create the wg
    interface in the host namespace, then move it into the container's
    netns (`ip link set ... netns`). The UDP socket stays anchored in the
    birth namespace, so the tunnel keeps working — and a container whose
    ONLY interface is the mesh is unescapably on-fabric with no sidecar,
    no userspace proxy. This is the demo that sells the tool.
  - `attach vm <net>` — generated peer config injected via
    cloud-init/klab goldens (guest kernel runs its own wg; still
    all-kernel, still daemonless). Host-bridge fallback for dumb guests.
  - `detach`, `rotate` (keys — headline maintenance flow), `show`.

Everything renders to **plain wg/wg-quick configs + systemd units**:
auditable with cat, versioned in git, replicable over the mesh itself
(zrepl rides these networks; the BE-fetch primitive provisions over them;
klab's blue/green meshes become declared networks).

## Competitive honesty

- **Tailscale**: always userspace (wireguard-go/TUN) + coordination SaaS +
  DERP relays. We are in-kernel and phone-home-free.
- **NetBird**: uses kernel WG on Linux — the differentiator there is NOT
  the datapath; it is that they ship a coordination server and we ship
  **none**. Topology is a file.
- **The trade we accept**: no CGNAT hole-punching. Two laptops behind
  hostile NATs is not our problem; an estate with one reachable hub port
  is. Say this in the README.

## Non-goals (the fabric test)

A feature is in scope iff it manages THE FABRIC. Things running ON the
fabric get read-only panes at most:

- No coordination daemon, discovery service, relay fleet, or magic DNS.
- No CNI: k8s gets "enable your CNI's WG encryption" + read-only
  visibility of its interfaces beside the machine mesh.
- No infra deployment (that is OpenTofu/Ansible, layers above).
- If the protocol grows scheduling, negotiation, or its own crypto, we
  have rebuilt zrepl/Netmaker and lost.

## Architecture

- Console UX inherits zxplore wholesale: GUI (Fyne) + static TUI from one
  tree, dossier views (peer: pubkey, endpoint, allowed-ips,
  **last-handshake age**, rx/tx), read-only default with explicit unlock,
  every mutation shows its exact wg command, audit log, mock-CLI test rig
  (fake wg/ip/ssh serving fixtures), remote ops over plain ssh.
- **Chassis extraction is milestone 0**: engine/mock-CLI rig, elevation,
  audit, ssh transport, dual-build Makefile, and the release pipeline
  (version-guard, nfpm staging, makewhatis, 8-platform static builds)
  move from zxplore into a shared module; zxplore 1.2 rebases onto it.
  That extraction is what makes console #3 (eBPF) cheap.

## Phasing

- **0.1** — read-only: `wg show` as dossiers with handshake-freshness
  coloring, local + ssh. Already beats every WG tool for "is my tunnel
  actually alive?".
- **0.2** — networks + attach host/container; topology render; enrollment.
- **0.3** — attach vm (cloud-init/klab), joined networks, key rotation.
- **kldload integration** (parallel): profiles wire the daemonless units;
  installer/firstboot enroll boxes into a declared estate network;
  zrepl-over-wg0 config generation (see storage design discussions).

## Remote management — ssh-native, ~/.ssh/config as the inventory

Exactly zxplore's server model, inherited via the shared chassis: the far
side needs nothing but sshd and kernel WireGuard. Declarations are
rendered locally; applying to a remote member runs the same wg/ip
commands over ssh (BatchMode, accept-new pinning, delegation-aware). The
operator's existing ~/.ssh/config IS the global machine inventory — Host
aliases, jump hosts, per-host keys all just work, so one seat manages an
estate's networks the way one seat manages its pools. This is also the
universality claim: anyone with plain WireGuard on any distro can build
networks and imbue policy with this tool — kldload merely ships it wired
in by default.

## Privilege model & policy

Same discipline as zxplore, adapted to the domain:

- **Unprivileged-first.** Declarations are plain files a user can create,
  edit, diff, and version without root. Reading live state and every
  mutation elevate per-command (pkexec on desktops, sudo in the TUI),
  with the exact wg/ip command shown before it runs and appended to the
  audit log. Destructive ops (detach, network delete, key rotation)
  require target-name retyping, zxplore-style.
- **add / subtract are declaration edits**, not imperative daemon calls:
  adding a member appends to the network file; applying renders configs
  and elevates only for the interface operations. Removing a member is
  the reverse — and because the declaration is the source of truth, a
  subtracted peer disappears from every other member's allowed-ips on
  the next render.
- **Fabric plumbing is IN scope** (refined 2026-08-02): a declared network
  implies host facts that must be true or the network does not work — the
  hub's listen port open, ip_forward on hubs/gateways, the joined-gateway
  route. `net up` emits exactly these (additive firewalld/nftables rules,
  one per network, shown before applied, removed on `net down`).
  "Everything just works" means the network finishes its own promise —
  NOT that the tool becomes a general firewall/NetworkManager. Positioning:
  NetworkManager : interfaces :: this tool : networks.
- **Policy compiles to cryptokey routing.** WireGuard's allowed-ips is
  both routing AND ingress filter — a peer cannot address, and will not
  be heard from, outside its declared scope. So "imbue policy" means
  declaring reachability in the network file (member roles/tags:
  full-mesh, service-only, gateway; who-sees-what subsets), and the
  renderer emits per-member allowed-ips accordingly. Tailscale-style
  ACLs, except enforcement is the kernel's crypto — no policy daemon, no
  iptables management, nothing to bypass. (nftables beyond what wg-quick
  itself emits is OUT of scope: the moment we manage a firewall we have
  left the fabric.)

## Composition with the storage primitives (the point of it all)

With zxplore managing ZFS and this tool managing networks, fleets become
à-la-carte: **clone-time network membership**. kldload VMs are ZFS clones
of golden snapshots — near-free to stamp. Add one step to kvm-clone/klab:
generate a keypair, append the member to the network's declaration,
inject the peer config via cloud-init. Then:

- Build the 27 goldens once. Clone 50 more — **all 50 are on the estate
  mesh at first boot**, or on their own freshly declared hub-spoke,
  chosen per clone batch. No DHCP archaeology, no per-VM setup: storage
  primitive (instant clone) × network primitive (declared attach) =
  connected fleets materialize in one command.
- This also dissolves the nested-lab subnet problem at its root (see the
  subnet-aware-networking backlog item): lab VMs addressed on a declared
  WG network stop depending on which 192.168.122.0/24 their host's
  libvirt NAT could or could not claim. The NAT bridge becomes mere
  transport; identity and reachability live in the mesh.
- The IaC layers above compose unchanged: Terraform/OpenTofu creates
  machines; the substrate answers with machines that are already
  storage-managed and network-attached. Layer 0 keeps its promise.

## Open decisions

- Name + org (family convention: zxplore sibling; operator to confirm).
- Config schema format (leaning: one YAML per network, rendered to
  per-member wg configs; the file IS the API).
- Where estate network declarations live on kldload (kldload-db vs
  /etc/kldload/networks/).
