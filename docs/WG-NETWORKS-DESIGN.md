# WG Networks — the WireGuard primitives console (design)

Captured 2026-08-02 from operator design sessions. Working name: **wgxplore**
(final name TBD — sets the console-family convention). Sister project to
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

## Open decisions

- Name + org (family convention: zxplore sibling; operator to confirm).
- Config schema format (leaning: one YAML per network, rendered to
  per-member wg configs; the file IS the API).
- Where estate network declarations live on kldload (kldload-db vs
  /etc/kldload/networks/).
