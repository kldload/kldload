# HA Control-Plane Design — "3 control planes with my nose, 20 workers with a fart"

Status: **DESIGN** (2026-07-25). Brick 1 committed (`2db98a3`) but never boot-tested.
Target branch: `fix/sb-mok-tpm-defaults` (HA work rides here for now).

## 1. Goal

Every Kubernetes cluster kldload deploys comes up **HA-ready from the first
control plane** — a floating VIP, `--control-plane-endpoint`, and uploaded
certs — so it can grow to 3 or 5 control planes and N workers **on command,
with no reinstall**. HA-by-default means: click "Kubernetes," get a cluster
that is *already* expandable, even if it starts as a single CP on a tight host.

Non-goal: forcing 3 CPs on a laptop. Resource preflight decides the *starting*
CP count; HA-readiness is always on regardless.

## 2. Why you can't do it today (the seams, grounded)

| Piece | State | Gap |
|---|---|---|
| `kube-init` | Brick 1 VIP path exists (`KUBE_VIP_ADDRESS` → `--control-plane-endpoint` + kube-vip static pod + `--upload-certs` + VIP in cert SANs) | **Opt-in.** Default init is plain single-CP. |
| `kube-cluster` | Runs `kube-init` over SSH in the CP VM (`kube-cluster:1345`) | **Never passes a VIP** → clusters are born non-HA. `scale` adds workers only. |
| `kube-join` | Worker-only (`Joins this node as a worker`) | **No `--control-plane` path.** |
| Web UI | Add-nodes dropdown has a `<option value="cp" disabled>` (`index.html:1750`) | Disabled + mislabeled "1.2 feature" (we're on 1.3.1). |
| `.111` today | CP `192.168.122.192`, workers `.79/.104/.47`, **no `controlPlaneEndpoint`, no VIP** | kubeadm cannot add CPs to it — must reinit HA-ready. |

**The hard constraint:** kubeadm can only join additional control planes if the
cluster was `init`'d with a stable `--control-plane-endpoint`. This cannot be
retrofitted cleanly. Therefore HA-readiness **must be decided at init time** —
which is exactly what brick 4 fixes.

## 3. Architecture (what's actually there)

`kube-cluster` deploys onto KVM using **ZFS instant clones**: a golden zvol
(cloud image + k8s packages) is snapshotted once, then cloned per node in
~100 ms at near-zero disk cost. Each clone gets a per-node cloud-init ISO,
joins a **WireGuard mesh**, then `kubeadm init/join` → **Cilium** eBPF (kube-proxy
replacement) → **MetalLB** (pool `192.168.122.200-220`). CP and workers are all
VMs on the libvirt `default` network (`192.168.122.0/24`).

## 4. The VIP

- **kube-vip v0.8.9**, ARP/L2 mode, **leader-elected** — the VIP floats to
  whichever control plane holds the lease. Runs as a static pod on every CP.
- Baked into the API-server cert SANs at init, so it stays valid as CPs come
  and go.
- **Allocation rule** (brick 4, implemented): the libvirt `default` net's DHCP
  range is the *entire* subnet (`.2-.254`, confirmed on `.111`) and MetalLB's
  pool (`.200-.220`) already overlaps it — so there is no "free" slot; the VIP
  must be **reserved**. `_allocate_ha_vip()` defaults the VIP to
  `192.168.122.240` (above MetalLB), then adds a **static `ip-dhcp-host` entry**
  with a placeholder QEMU-OUI MAC (`52:54:00:00:00:fe`) so dnsmasq drops that
  address from the dynamic pool — cleaner and more idempotent than range
  surgery. An `arping -D` conflict check aborts if the VIP is already answering.
  TODO(prod): a dedicated k8s libvirt network with a carved DHCP range would be
  tidier than reserving out of the shared `default` net.

## 5. The bricks (build + live-test order)

Built and **live-tested on `.111`** one at a time — that's the point of the
test bed; each brick is proven before the next.

### Brick 4 — `kube-cluster` HA-ready by default *(do first: it also builds the test bed)*
- Allocate a VIP (§4), pass `KUBE_VIP_ADDRESS`/`KUBE_VIP_INTERFACE` into the
  over-SSH `kube-init` call. Result: even a **1-CP** cluster gets a
  control-plane-endpoint + kube-vip + uploaded certs → **expandable**.
- **Resource preflight**: size the box; default to **3 schedulable CPs** when it
  fits (per the settled decision — 3 CPs that also run workloads, *not* 3+3),
  fall back to **1 CP (still HA-ready)** on tight hosts, log which and why.
- Validates brick 1 for real (VIP comes up, `wait-control-plane` reaches the API
  through the VIP, `controlPlaneEndpoint` present).

### Brick 2 — `kube-join --control-plane`
- Fetch/refresh the certificate key (kubeadm `upload-certs` — **note the 2 h
  expiry**, so `scale` re-uploads just-in-time), `kubeadm join --control-plane
  --certificate-key … <VIP>:6443`.
- Remove the control-plane taint (schedulable CPs), join the WireGuard mesh
  first, point kube-vip/Cilium at the VIP.
- Guard the **k8s ≥1.29 `super-admin.conf` first-init trap** (only the bootstrap
  node has it; joiners use `admin.conf`).

### Brick 3 — `kube-cluster scale --control-planes N`
- Clone N CP VMs (ZFS), join each as a CP via brick 2, in **odd** target totals
  (1 → 3 → 5) for etcd quorum. Wait for `etcd` member health + `kubectl get
  nodes` Ready before declaring done.
- `scale --control-planes 3` on a 1-CP cluster performs the 1→3 stacked-etcd
  growth; refuse even totals with a clear message.

### Brick 5 — UI / installer
- Enable `index.html:1750` (`value="cp"`), drop the "1.2 feature" text, wire
  `k8sAddNodesFromOverview()` to send `kind=cp` → `kube-cluster scale
  --control-planes`. Add an installer "**N control planes × M workers**" selector.

## 6. etcd quorum & failure modes

- **Odd only** (1/3/5). 3 CPs tolerate 1 loss; 5 tolerate 2. Even counts buy
  nothing and split-brain risk — refused.
- **Quorum loss → API read-only.** Surface loudly in the Nodes/HA panel; never
  silently proceed.
- **VIP conflict**: preflight ARPs the candidate VIP before use; abort on reply.
- **cert-key expiry (2 h)**: `scale` always re-runs `upload-certs` immediately
  before a CP join; never relies on the init-time key.
- **Partial CP join**: on failure, `kubeadm reset` the half-joined node + remove
  its etcd member before retry (no orphan etcd members — they wedge quorum).
- **Reversibility**: ZFS snapshot the CP before a scale op; breadcrumbs in
  `/var/log/kldload/`; HA-ready stays a no-op cost when only 1 CP is wanted.

## 7. Test plan on `.111` (the live bed)

1. Brick 4 → **rebuild `.111`'s cluster HA-ready** via `kube-cluster` (wipes the
   current single-CP cluster — expected). Verify: `controlPlaneEndpoint` set,
   kube-vip pod Running, VIP answers `:6443`, cert SANs include the VIP.
2. Brick 2 → join a 2nd CP by hand; verify etcd 2-member (transient) → then 3rd
   for quorum. Verify VIP failover (kill the leader CP, VIP moves, API stays up).
3. Brick 3 → `scale --control-planes 3` from scratch; time it; verify quorum.
4. Brick 5 → dropdown drives the same path from the web UI.

Each step's kubectl/etcd output is the gate — no brick advances on an unverified
prior.
