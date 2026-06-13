# kldload `master` Profile — Architecture Draft

> **Status:** DRAFT / RFC — for discussion, not yet implemented.
> **Date:** 2026-06-13
> **Scope:** The third profile tier — a "Central Command" cluster master that
> provisions, configures, observes, and self-heals an entire fleet across
> bare-metal KVM and the three public clouds, driven from a point-and-shoot GUI.

---

## 1. Why this exists (context)

kldload today has two profile families:

- **Endpoint / OS install:** `workstation` (desktop), `server`, `core`.
- **Node / substrate roles:** `kvm`, `kubernetes`, `klab`, `zfslab`.

What's missing is a **control plane**: a box (or HA set) whose job is to *run
the rest*. The operator's vision, stated plainly:

> "Anyone should be able to build out their entire infrastructure, press a
> button, and have it magically appear wherever they like — KVM, AWS, Azure,
> GCP — self-healing, centrally reported, centrally secured."

That is the `master` profile. A partial scaffold already exists
(`kldload-install-target:1477`, `setup_master()` in `kldload-firstboot:159`):
the 4-plane WireGuard mesh, Salt-master enrollment, the webui, and image
tooling (`kimage`, `klab`, `kldload-aws-publish`). This draft proposes the
target architecture and the path from scaffold to product.

### Design goals
1. **Point-and-shoot.** The end user composes intent in a GUI and clicks
   deploy. They never touch the underlying engines.
2. **Universal target.** One golden image per substrate, deployed unchanged to
   KVM / AWS / Azure / GCP. The *only* thing that varies per deployment is the
   data handed to the machine at first boot.
3. **Self-healing.** Desired state lives on the master; a control loop
   continuously converges actual → desired and rebuilds what dies.
4. **Central focal point.** Metrics, logs, and secrets are aggregated to the
   master, not islanded per node.
5. **Enterprise-grade.** Federated identity (AD), RBAC, PKI, audit — the
   "normal cluster stuff" a real org requires.
6. **Cross-platform.** Linux *and* Windows Server / Windows 11 as managed,
   reporting members.

### Non-goals (for v1)
- True W11 endpoint **MDM** (device compliance / conditional access) — that is
  Entra/Intune territory; we manage Windows as config-managed members, not as
  MDM-enrolled endpoints. (Phase 2 / integration.)
- Replacing the existing endpoint/node profiles — `master` sits *above* them.

---

## 2. The core principle: separate the *what* from the *how*

The single most important architectural decision. There are three layers, and
**only the top one is ever user-facing:**

| | Layer | Who touches it |
|---|---|---|
| 1 | **Declarative infra spec** (the *what*) — composed in the GUI | the end user |
| 2 | **Orchestrator / reconcile brain** — compiles spec → actions | the platform |
| 3 | **Execution engines** (the *how*) — OpenTofu, Ansible, cloud-init | nobody, by hand |

This is why "Salt is hard to configure" stops being a problem: **no operator
ever writes engine config.** The platform generates it from the high-level
spec. The engine is an implementation detail behind the button.

---

## 3. The stack (proven tech, assembled opinionatedly)

A cluster control plane is **layers, each with a best-in-class pick** — not one
tool. `etcd`, `OpenTofu`, `Prometheus`, `Vault` answer *different* questions.

| Layer | Job | Pick | Notes |
|---|---|---|---|
| **Provisioning** | make machines *appear* anywhere | **OpenTofu** | declarative; libvirt/AWS/Azure/GCP providers; one spec, any target |
| **Image build** | produce the golden image | **`kimage` / `klab` / `kldload-*-publish`** | existing kldload tooling = our "Packer" layer |
| **First-boot bind** | machine learns its role | **cloud-init** | universal datasource: NoCloud (KVM) + native cloud metadata |
| **Configuration** | turn a node into its role | **Ansible** | easiest to author; agentless; run by the brain, not by hand |
| **Coordination/state** | HA truth + leader election | **etcd** | the DB the brain reads; *not* config-mgmt |
| **Event / C2 fabric** | health, commands, telemetry | **NATS JetStream** | leaf nodes for edge/cloud; request-reply for C2; durable streams for reporting/audit |
| **Metrics** | central TSDB + alerting | **Prometheus (+Thanos/Mimir) + Grafana + Alertmanager** | thin exporters on nodes; heavy collectors on master |
| **Logs** | central log store | **Loki** + **Vector** agents | Vector ships journald *and* Windows Event Log |
| **Secrets** | central issuance | **OpenBao/Vault** | short-lived creds; nothing long-lived on nodes |
| **PKI / certs** | identity material | **step-ca** | short-lived certs via ACME; mTLS everywhere |
| **Identity / SSO** | federated AD + RBAC | **Keycloak** + `realmd`/SSSD | OIDC to webui/k8s/Grafana/Bob; one role model projected everywhere |
| **The brain** | desired vs actual → converge/heal | **`kldload-reconcile`** (new) | the one piece worth building |

**Salt verdict:** dropped as the primary engine. OpenTofu (provision) + Ansible
(configure) + NATS (events/C2) cover Salt's ground far more accessibly. If
instant fleet-wide exec is ever needed, NATS request-reply to the node agent
provides it without Salt's operational burden. (The existing Salt enrollment
code is superseded; see §11 migration.)

---

## 4. Provisioning the clean modern way — OpenTofu

OpenTofu is the keystone for "appear wherever they like." A single declarative
description, `tofu apply`, and the machines materialize on the chosen target.

### 4.1 Provider-per-target
The same logical node maps to a provider resource per target:

| Target | OpenTofu provider | Resource |
|---|---|---|
| KVM / on-prem | `dmacvicar/libvirt` | `libvirt_domain` + `libvirt_volume` (from golden qcow2) |
| AWS | `hashicorp/aws` | `aws_instance` (from the AMI `kldload-aws-publish` registers) |
| Azure | `hashicorp/azurerm` | `azurerm_linux_virtual_machine` (from a Managed Image) |
| GCP | `hashicorp/google` | `google_compute_instance` (from a GCE image) |

The golden image is built **once per substrate** by the existing `kimage` /
`klab` pipeline and published into each cloud's image format
(`kldload-aws-publish` exists; Azure + GCP publishers are a build item).

### 4.2 Modules, not hand-written HCL
The GUI never emits raw HCL for the user. We ship a small set of **OpenTofu
modules** the orchestrator parameterizes:

```
tofu/
  modules/
    node/            # one machine on any target (var.target selects provider)
    cluster/         # N nodes + network + roles, composed from node/
  targets/
    kvm/  aws/  azure/  gcp/      # provider + backend config per target
```

Example (illustrative) — a node module call the orchestrator generates:

```hcl
module "web_lb" {
  source       = "../modules/node"
  target       = "aws"            # kvm | aws | azure | gcp
  region       = "us-east-1"
  golden_image = "kldload-server-1.4.0"
  count        = 1
  role         = "nginx"          # → cloud-init role contract (§5)
  env          = "prod"
  master       = "10.77.0.1"
}
```

### 4.3 State
OpenTofu state lives on the master, backed by the **etcd/HTTP backend** (or an
S3-compatible local store), so the reconcile brain and the GUI share one view
of "what we've provisioned." State is the boundary between OpenTofu (machine
existence) and the brain (machine health/role convergence).

---

## 5. The golden image + role contract (late binding)

**One sealed, identity-less golden image per substrate.** It carries the
minimal kldload agent and cloud-init; it carries *no role*. The role is bound
at first boot from cloud-init user-data — identical contract on KVM and every
cloud:

```yaml
#cloud-config
kldload:
  role:   k8s-worker          # nginx | k8s-control | k8s-worker | kvm-host | zfs | ...
  master: 10.77.0.1           # enrollment endpoint over wg0
  token:  <one-time enrollment token>
  env:    prod                # selects Ansible vars / pillar
```

First boot: the agent reads this, enrolls to the master (gets a step-ca cert +
NATS leaf creds), and the master applies the matching **Ansible role** (§6).
Updates have two clean lanes (matches the install-once + rebuild model):
- **Image change** → rebuild golden, redeploy (immutable).
- **Role-config change** → converges from the master, no rebuild.

The on-node agent is deliberately tiny and **self-updating** (signed binary
pulled from the master), so tooling updates rarely force an image rebuild.

---

## 6. The role catalog (the operator's "environments")

A **git-backed catalog on the master** — the operator authors this once; the
GUI exposes it as pickable roles:

```
roles/
  nginx/        playbook.yml   vars/{prod,staging,lab}.yml
  k8s-control/  playbook.yml   vars/...
  k8s-worker/   playbook.yml   vars/...
  kvm-host/     playbook.yml   vars/...
  zfs/          playbook.yml   vars/...
```

A role = an Ansible playbook + per-`env` variables. Adding a role = adding a
directory. The reconcile brain runs `ansible-playbook -l <node> roles/<role>/
playbook.yml -e @vars/<env>.yml` against a freshly-enrolled node. Git gives
auditability + rollback (the "reversible" ethos).

---

## 7. The declarative infra spec (the *what* the user composes)

The GUI produces this; it's the single artifact that describes a whole estate.
Think "docker-compose for infrastructure":

```yaml
# estate.yaml — composed in the GUI, compiled to OpenTofu + role assignments
apiVersion: kldload/v1
kind: Estate
metadata: { name: acme-prod, env: prod }
spec:
  targets:
    onprem:  { type: kvm,   host: kvm-host-a }
    cloud:   { type: aws,   region: us-east-1 }
  nodes:
    - name: lb        role: nginx        count: 2  target: cloud
    - name: k8s-cp    role: k8s-control  count: 3  target: onprem
    - name: k8s-wrk   role: k8s-worker   count: 6  target: onprem
  workloads:                       # second-tier: VMs/containers on the nodes
    - name: app       on: k8s-wrk  kind: helm   chart: acme/app
```

Compilation:
- `spec.nodes` → OpenTofu module calls (provider chosen by `target`).
- `node.role` → cloud-init role contract + Ansible role.
- `spec.workloads` → the second reconciliation tier (§8).

---

## 8. Two-tier reconciliation (nodes *and* what runs on them)

The same pattern, applied twice:

1. **Node tier** — does the machine exist and is it the right role?
   Reconciled via OpenTofu (existence) + Ansible (role) + NATS health.
2. **Workload tier** — do the right VMs/containers run on the right nodes?
   A `kvm-host` node gets VMs stamped onto it (`kimage deploy` + the same
   cloud-init role contract — a VM is just another clone that gets a role);
   a `kubernetes` node gets workloads via Argo CD/Flux from the same git spec.

So `master` reconciles both layers against `estate.yaml`. Turtles all the way
down, one mechanism.

---

## 9. The reconcile brain (`kldload-reconcile`)

The one piece worth building. A daemon on the master that:

1. Reads desired state (`estate.yaml` + role catalog, from git) and stores
   working state in **etcd** (HA, leader-elected across master replicas).
2. Observes actual state via **NATS** health events + Prometheus + OpenTofu
   state + Ansible facts.
3. Converges: provision missing nodes (OpenTofu), (re)apply roles (Ansible),
   stamp/relocate workloads, **rebuild a dead node** from the golden image.
4. Emits every action to the NATS `audit.>` stream (tamper-evident) and the
   reporting plane.

It does **not** reimplement provisioning, config-mgmt, or a TSDB — it
*orchestrates* them. Custom code lives only where the glue is.

---

## 10. The "press the button" flow (end-to-end)

1. User composes the estate in the GUI → kldload generates `estate.yaml` (+ the
   OpenTofu plan + role assignments behind the scenes).
2. **`tofu apply`** → machines materialize on each target from the golden image.
3. Each machine **cloud-init → enrolls** to the master (cert + NATS creds).
4. Master runs the **Ansible role** per node → it becomes nginx/k8s/etc.
5. **Workload tier** reconciles (VMs/Helm).
6. **`kldload-reconcile` + NATS** keep it true; the GUI shows it live.

Identical whether it's one VM or a 40-node estate.

---

## 11. Identity, RBAC, secrets, PKI (enterprise)

- **Host identity / AD:** `realmd` + **SSSD** join (or **FreeIPA** with an AD
  cross-forest trust). AD users get SSH/login + sudo/HBAC by AD group.
- **App SSO:** **Keycloak**, federating AD/Entra/LDAP. OIDC to webui, k8s API,
  Grafana, Headlamp, Bob. **One role model** in Keycloak projected onto webui
  actions, k8s RBAC, NATS account permissions, sudo.
- **Secrets:** **OpenBao/Vault** central; nodes fetch short-lived creds at
  enrollment. Replaces the plaintext `/run/...credentials.json`.
- **PKI:** **step-ca** issues short-lived node/service certs at enrollment;
  mTLS for NATS/webui/k8s. **Replaces the shipped-CA-key model entirely.**

> These directly close the CRITICAL findings from the 2026-06-13 audit (unauth
> webui, autonomous Bob shell, shipped CA private key, plaintext creds). A box
> that controls the whole fleet **must** land OIDC auth + RBAC + step-ca PKI +
> Bob gating **before** the `master` profile ships. This is a release gate, not
> a nice-to-have.

---

## 12. Central observability (the "focal point")

Today each node is an island (its own exporters/Prometheus). Target pattern —
**thin agents on nodes, heavy collectors on the master:**

- **Metrics:** keep lightweight exporters on nodes; central Prometheus scrapes
  over the mesh or nodes `remote_write` to it; **Thanos/Mimir** for
  long-term/HA at fleet scale. Nodes stop running Grafana.
- **Logs:** **Vector** (or Grafana Alloy) on every node → **Loki** on master.
- **Alerting:** **Alertmanager** on master; alerts also flow onto NATS for the
  reconcile brain to act on.

Consider a dedicated **observability WG plane** alongside the existing four.

---

## 13. Windows Server + Windows 11

Windows folds into the *same* plane — no separate stack:

- **Config/exec:** Ansible manages Windows over **WinRM/SSH**
  (`ansible.windows` collection) — software, registry, services, DSC.
- **Metrics:** `windows_exporter` → central Prometheus.
- **Logs:** **Vector** ships Windows Event Logs → central Loki.

So a Windows box enrolls and reports through the identical pipeline. **Caveat:**
this is full coverage for Windows *Server* and agent-managed W11; true W11 *MDM*
(compliance, conditional access, BitLocker escrow) stays a Phase-2 / Entra
integration. The existing "intune-for-linux" repo becomes the **enrollment +
policy portal** fronting Ansible for both Linux and Windows.

---

## 14. Networking — planes + per-role microsegmentation

Two axes: WG **planes** carry traffic *types* (encrypted transport); **per-role
subnets** segment *who* may talk, so policy is enforceable (zero-trust, not a
flat network). CPs, workers, VMs, and storage each live on their own subnet.

**Transport planes — a data-driven list, NOT hardcoded to 4 (add at will):**

| Plane | CIDR | Carries |
|---|---|---|
| wg0 | 10.77/16 | enrollment |
| wg1 | 10.78/16 | management (SSH, API VIP, NATS, identity) |
| wg2 | 10.79/16 | Kubernetes pod / Cilium data |
| wg3 | 10.80/16 | storage (NFS / iSCSI / CSI) |
| wg4+ | 10.81/16… | observability / per-tenant / per-cluster — appended on demand |

**Per-role subnets — deterministic IPAM, one /24 per role:**

| Role | Subnet | Policy |
|---|---|---|
| control-plane | 10.78.1.0/24 | API **VIP 10.78.1.254** (kube-vip); etcd peering CP↔CP only |
| worker | 10.78.2.0/24 | reaches CP only via the VIP:6443 |
| vm (app) | 10.78.3.0/24 | isolated by default; opt-in egress |
| storage | 10.80.1.0/24 | reachable only from k8s + vm subnets, storage ports only |

Policy is enforced twice: **nftables on the WG mesh** (host firewall, already in
`setup_master()`) for L3/L4 between subnets, and **Cilium NetworkPolicy** inside
k8s for pod-level. The IPAM scheme is a **table (role → plane → CIDR)** the
orchestrator owns — adding a role or plane is a new row, so "more subnets at
will" is data, not code. NATS leaf nodes ride the mesh (or dial home with mTLS
for cloud nodes — no inbound ports).

**Rule-splitting invariant (build / run / communicate — non-negotiable):**
Every traffic class a node needs to be *built*, *run*, and *talk to its peers*
is carried on its **designated plane with its own nftables rule** — never
funnelled through one UDP port or one flat plane. Canonical split:

| Plane | Opens (and nothing else) |
|---|---|
| wg0 (51820) | enrollment only — hub.env/PXE on :80 from 10.77/16 |
| wg1 (51821) | Salt 4505/4506, SSH 22, NATS 4222, **API VIP** 6443, identity — from 10.78/16 |
| wg2 (51822) | k8s data: etcd 2379-2380, kubelet 10250, CNI/VXLAN/Geneve — from 10.79/16 |
| wg3 (51823) | storage: NFS 2049, iSCSI 3260, CSI — from 10.80/16 |

Hard requirements this implies (all currently violated — see roadmap):
1. **Each plane is a distinct WG device with its OWN keypair.** `kube-network`
   today copies one key to both planes — a compromise of one plane is a
   compromise of all; planes can't rotate independently. Fix to per-plane keys.
2. **One source of truth for subnet numbering.** `kube-cluster` comments claim
   10.251/10.252 while `kube-network` implements 10.250/10.251 — they must agree.
3. **The nftables ruleset is the contract.** Any new service maps to exactly one
   plane + one rule; the deploy **fails closed** if a required port isn't opened
   on its plane (no "open everything on wg1 and hope").

---

## 15. Profile separation (taxonomy)

Orthogonal axes — **substrate (distro) × role** — with roles in three tiers:

- **Control tier — `master`** (this doc): Keycloak, NATS, step-ca, etcd,
  OpenTofu, the role catalog, `kldload-reconcile`, webui+reporting, central
  obs/secrets, image-build + cloud-publish. **Design for HA (3+ masters,
  raft/etcd quorum)** even if v1 ships a single node.
- **Node tier — `kvm` / `kubernetes` / `klab` / `zfslab` / `storage`** (+ generic
  `node`): golden image + agent; enroll to master; get a role. (`storage` is new
  — see §20.)
- **Endpoint tier — `workstation` / `core`**: human-facing or minimal.

Offer a single-node **`master-lite`** (systemd-native) entry tier and a
**k8s-native HA master** for enterprise — the same lean→enterprise gradient as
the other profiles. (Open decision, §17.)

---

## 16. Reuse vs build

| Already have | Build |
|---|---|
| `kimage` / `klab` (golden build/export/deploy) | OpenTofu modules (`node`, `cluster`) + target configs |
| `kldload-aws-publish` (AMI pipeline) | Azure + GCP image publishers |
| 4-plane WG mesh, enrollment endpoint | cloud-init **role contract** reader in the agent |
| webui (fleet/inventory/reconcile hooks) | the **GUI compose → estate.yaml** surface |
| Prometheus/Grafana/Loki/Tetragon/Hubble | central collectors + Vector agents + remote-write |
| ZFS-encrypted secret store | OpenBao/Vault + step-ca integration |
| (none) | **`kldload-reconcile`** brain (etcd + OpenTofu + Ansible + NATS) |
| (none) | Keycloak/OIDC auth + RBAC across webui/k8s/NATS |

---

## 17. Open decisions
1. ~~`master-lite` (systemd-native) vs k8s-native HA master~~ — **DECIDED
   (2026-06-13): ship both.** `master-lite` (systemd-native) is the single-node
   entry tier; k8s-native HA master (3+ raft quorum) is the enterprise tier.
   Same lean→enterprise gradient as the other profiles.
2. **OpenTofu state backend** — etcd HTTP backend vs local S3-compatible (MinIO).
3. **Workload tier on k8s** — Argo CD vs Flux for GitOps.
4. **Identity** — Keycloak + SSSD/AD vs FreeIPA-with-AD-trust as the default.
5. Whether the on-node agent is Go (single static binary, self-update) — likely
   yes, given the self-update + NATS-leaf requirements.

## 18. Suggested phasing
1. **P0 (gate):** webui OIDC auth + RBAC + step-ca PKI + Bob gating (audit fix).
2. **P1:** OpenTofu modules + cloud-init role contract + role catalog + KVM
   target → "deploy a node, pick a role, it builds" on-prem.
3. **P2:** `kldload-reconcile` brain + NATS event fabric + central obs.
4. **P3:** AWS/Azure/GCP publishers + targets → multi-cloud point-and-shoot.
5. **P4:** workload tier (Argo/Flux + VM stamping), HA master, Windows members.

---

## 19. HA Kubernetes control planes (e.g. 5 CP + 12 workers)

Today `kube-cluster` hardcodes **1 CP** (only `--workers` scales) and the
dashboard CP `<option>` is **disabled** ("1.2 feature — requires etcd quorum").
To make N CPs deploy-and-self-wire:

- **Stable endpoint (the keystone):** `kube-init` sets `--control-plane-endpoint
  <vip>:6443` via **kube-vip** (static pod; VIP on the control-plane subnet,
  10.78.1.254). Without a stable endpoint kubeadm refuses additional CPs.
  `--upload-certs` is already set ✓ (half the prerequisite).
- **CP join:** `kube-init` emits a CP-join command (`kubeadm join <vip>
  --control-plane --certificate-key …`; mint a fresh key via `kubeadm init phase
  upload-certs` — it expires in 2h). `kube-join` gains a `--control-plane` mode.
- **Orchestration:** `kube-cluster --control-planes N --workers M` stamps N CP +
  M worker ZFS instant-clones, inits CP#1, joins CP#2..N as control planes,
  joins workers, installs Cilium. **Odd CP counts (1/3/5) for etcd quorum —
  warn/round on even.**
- **Dashboard:** un-disable the CP option; CP-count + worker-count inputs; webui
  `kube_bootstrap`/`kube_scale` accept `control_planes` alongside `workers`.

Matrix-affecting cluster change → branch + `smoke-test`.

## 20. Storage profile (new node-tier role)

kldload's ZFS identity applied to shared cluster storage. A `storage` node
provides:

- **NFS** exports (shared filesystems) and **iSCSI** targets (block) on the
  storage plane (wg3 / 10.80.1.0/24).
- **democratic-csi (ZFS-CSI)** so k8s PVCs provision real ZFS datasets/zvols on
  the storage node — replacing the local-path-on-worker-zvol fallback `kube-init`
  notes today.
- Snapshots / replication via `zfs send` (ties into the existing DR + backup
  model).

Scale-out is ZFS-first (multiple storage nodes + replication). It enrolls like
any other node (golden image + cloud-init `role=storage` + Ansible role).

**Open:** ZFS + NFS/iSCSI + democratic-csi (recommended, on-identity) vs Ceph
for large scale-out.

---

*This is a draft for discussion. Nothing here is implemented yet; engine and
phasing choices in §17/§19/§20 are open. No code has been written against it.*
