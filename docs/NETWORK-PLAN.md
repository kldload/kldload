# Network plan — every kldload-internal network in one block (design)

Asked for by the operator on 2026-09-29, after Kubernetes was found giving
Services 10.96.0.0/12, a range that holds the bench LAN (10.100.10.0/24):
"the 10.100.10.0 network is basically the internet in terms of the VMs ... we
could redefine the network ranges for all of the networking", then "do the one
block". Status: **design, phase 1 in progress** (branch `fix/k8s-svc-range`).

## One sentence

Everything kldload creates -- VM networks, Kubernetes pods and Services,
WireGuard planes, lab meshes -- lives inside **10.240.0.0/12** (10.240.0.0 to
10.255.255.255), is defined in **one plan file** every tool reads, and is
**checked against the host's own routes** before anything is created, so no
kldload network can ever sit on the operator's LAN.

## Why one block

- The ranges grew one tool at a time: 10.77-10.80, 10.96/12, 10.244/16,
  10.250-10.254, 192.168.122/150/151/152. Nobody could say which ranges to
  keep off a LAN, and the /12 Services range was on one for months.
- Each default is re-typed in several scripts (the pod range in kube-init,
  kube-network and kube-setup; the planes in infra.sh and again, literally,
  in kldload-firstboot). `KLDLOAD_WG0_NET`..`WG3_NET` are exported by the
  installer and read by nothing.
- One /12 is one line of documentation, one firewall rule, one thing an
  operator avoids on their LAN.

## The allocation

| Range | What | Was |
|---|---|---|
| 10.240.1.0/24 | `kld-k8s`: the Kubernetes VMs; VIP `.240`, MetalLB `.200-.220` | 192.168.122.0/24 (libvirt `default`) |
| 10.240.2.0/24 | `kld-vms`: ordinary VMs | 192.168.152.0/24 |
| 10.240.3.0/24 | `kld-klab`: klab goldens and sites | 192.168.150.0/24 (klab actually used virbr0) |
| 10.240.4.0/24 | `kld-zfslab`: the ZFS lab | 192.168.151.0/24 |
| 10.240.5.0/24 | `kld-fire`: Firecracker microVMs | virbr0 |
| 10.241.0.0/16 | Kubernetes Services (API `.0.1`, DNS `.0.10`) | 10.96.0.0/12 |
| 10.244.0.0/16 | Kubernetes pods | unchanged |
| 10.246.0.0/18, .64/18, .128/18, .192/18 | installer planes wg0-wg3 | 10.77-10.80.0.0/16 |
| 10.247.0.0/20 | the master profile's cluster CIDR | 10.78.0.0/20 (overlapped wg1) |
| 10.250.0.0/24 | wg-mgmt, the estate mesh | unchanged |
| 10.251.0.0/24 | wg-k8s | unchanged |
| 10.252.0.0/24, 10.253.0.0/24 | klab blue/green meshes | unchanged |
| 10.254.0.0/16 | kvm-mesh / appliance meshes (/24 each) | unchanged |
| 10.240.0.0/24, 10.242-10.243, 10.245, 10.248-10.249, 10.255 | reserved | |

libvirt's own `default` network (192.168.122.0/24) is left alone for anything
that is not kldload's; kldload stops putting its VMs on it.

## The plan file

`/etc/kldload/network-plan.env`, KEY=VALUE, parsed (never sourced), written at
install from the shipped defaults (`/usr/lib/kldload/network-plan.defaults`)
and the answers file (`KLDLOAD_NET_*`). Every tool reads it through one small
library (`/usr/lib/kldload/netplan.sh`: `netplan_get K8S_SVC_CIDR`), and one
command answers for it:

    kldload-netplan show          the plan, one line per network
    kldload-netplan check         every range against this host's routes and
                                  each other; exit 1 on any overlap
    kldload-netplan get KEY       one value, for scripts

`check` runs at install (before a network is created), at first boot, and in
`kldload-doctor`; an overlap is fatal at install, not a warning.

## Existing installs

Ranges are **not** migrated in place. A running cluster's Service and pod
ranges cannot change (kubeadm and Cilium fix them at init); goldens bake
routes and addresses; API certificates name the mesh addresses. So:

- An install made before the plan file gets one generated from what it
  actually uses (`kldload-netplan adopt`), and keeps using it.
- New installs get the new block.
- A cluster moves by being rebuilt (`kube-cluster destroy --all` and
  bootstrap), which the offline rebuild test already does.

## Phases

1. **The plan file, the library, `kldload-netplan`, with defaults equal to
   today's values.** Every tool that hard-codes a range reads the plan
   instead. Nothing moves; a sweep must come out identical. This is what makes
   every later move a one-line change.
2. **Services and planes:** `K8S_SVC_CIDR` to 10.241.0.0/16 (supersedes the
   interim 10.96.0.0/16), installer planes to 10.246, cluster CIDR to 10.247.
3. **VM networks:** `kld-k8s`, `kld-vms`, `kld-klab`, `kld-zfslab`,
   `kld-fire` into 10.240.x; klab static addresses, MetalLB, the VIP and
   kfire's bridge follow.
4. **Matchers:** kldload-doctor, kube-smoke-test, kldload-obs-check,
   kube-cluster's address regex, the web UI's prefix strip -- all derive from
   the plan, because a check that greps for an old prefix silently passes or
   fails the wrong thing.

Each phase is its own build and a sweep of the editions it touches.

## Decisions (operator, 2026-09-29)

1. The cluster moves off libvirt's `default` network to `kld-k8s`; VMs an
   operator placed on `default` by hand stay where they are. **Yes.**
2. The block is **a setting**: `KLDLOAD_NET_BLOCK` in the answers file
   (default 10.240.0.0/12), and every range above is derived from it at a
   fixed offset (the table's third and fourth octets become offsets into the
   block). `kldload-netplan check` refuses a block that overlaps the host's
   LAN before anything is created. **The ZFS test lab (ztxplore, kzfs-lab)
   follows the same block**: its networks are cut from the plan like every
   other, not from libvirt's `default`.
