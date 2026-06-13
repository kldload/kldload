# kldload Roadmap — Master Profile, HA Cluster & Point-and-Shoot Infra

> **Status:** DRAFT / planning. Consolidates the 2026-06-13 security audit, the
> deployment code review (k8s + image/clone + dashboard), and the master
> architecture (`master-profile-architecture.md`). Line citations are from those
> reviews — verify at implementation time.
> **Goal:** "Anyone composes infra in the dashboard, picks N control planes + M
> workers + storage, presses deploy, and it self-wires anywhere (KVM/AWS/Azure/
> GCP) — HA, segmented networking, central reporting, self-healing."

Legend: **[B]** blocker · **[H]** high · **[M]** medium · **[1-line]** tiny
high-impact fix · **⚠matrix** = cluster/installer change → branch + `smoke-test`.

---

## Phase 0 — Security gate (MUST land before the `master` profile ships)
A box that controls the whole fleet amplifies every one of these to fleet-wide
root. Non-negotiable precondition for `master`.

- **[B]** webui WebSocket has **no auth** — add OIDC bearer-token validated
  before dispatch. `kldload-webui:1305-1316`. (Keystone — shrinks everything
  below to "authenticated operator.")
- **[B]** Bob runs shell **autonomously by default** — default autonomy OFF;
  never auto-run `shell_run`/`bob_exec`; delete the ```` ```exec ```` text-fence
  auto-exec; allowlist not deny-regex. `kldload-webui:8217,9490-9519,9550`;
  `index.html:9627-9652`.
- **[B]** Live ISO ships fixed `root:kldload`/`live:live` + root SSH — random/
  locked password, `PermitRootLogin prohibit-password`. `build-iso.sh:681-696`.
- **[B]** CA **private key** baked into the ISO + trust stores — generate the CA
  per-host at firstboot, key `0600`, never in the artifact. `5065-kldload-tls.hook.chroot`.
- **[B]** `gpgcheck=0` / `--nogpgcheck` / `--insecure` against live mirrors —
  re-enable signing. `kldload-install-target:368-415`, `bootstrap.sh:677-945`.
- **[B]** Kickstart unit binds webui `0.0.0.0:8080` no-TLS — match the hardened
  live-build args (`127.0.0.1`). `builder/kldload-live.ks:207`.
- **[H]** Shared fleet `admin@kldload` SSH key in ISO; Ollama `0.0.0.0:11434`
  (`firstboot:1478`); unpinned `ollama.com/install.sh | sh` (`firstboot:1463`);
  Ubuntu apt `[trusted=yes]` (`bootstrap.sh:29`); over-broad `efibootmgr`
  deletion regex (`bootloader.sh:1012` ⚠matrix); `esc()` not escaping `'` →
  stored XSS (`index.html:10417`); `kldload-poof` checks wrong CA path so the
  real key survives the live scrub (`kldload-poof:80`).
- **[1-line × 3]** `shellcheck -S error` failures that fail the smoke gate
  *today*: `tests/smoke-kvm.sh:39,50,69`, `tests/lifecycle.sh:263`,
  `tests/smoke-all.sh:157` (drop `local` outside functions).

**Exit:** webui OIDC+RBAC, Bob gated, no secrets in artifacts, signed installs,
smoke gate green.

---

## Phase 1 — Golden image + role-on-the-fly (deployment foundation) ⚠matrix
The whole point-and-shoot model rests here. Today a clone's role is frozen at
install time and the seal/identity path makes clones collide.

- **[B][1-line]** `kldload-seal` does **not** clear
  `/var/lib/kldload/firstboot-done` → a once-booted golden's clones **skip
  firstboot entirely**. Add `rm -f` for the marker. *Highest value, one line.*
- **[B]** Role cannot be injected — `firstboot` reads role only from the baked
  manifest (`kldload-firstboot:27-30`). Add `_resolve_role()` precedence:
  `/proc/cmdline kldload.role=` → cloud-init drop-in `/etc/kldload/role.d/*.env`
  → metadata → manifest fallback.
- **[B]** `KLDLOAD_NODE_INDEX` is never assigned → every clone claims
  `10.78.0.1` etc. → WG IP collision (`firstboot:48,129,749`). Master hands out
  the next free index at enrollment, or the seed writer injects it.
- **[B]** `kldload-seal` leaves Salt `minion_id`/`pki` + manifest role → fleet
  identity bleed (one flapping minion). Wipe salt id/keys; blank/override role.
- **[B]** Define the role set as first-class incl. `nginx`/`storage`; each gets a
  `setup_*` (firstboot `case` at `:2643`) and/or an Ansible/Salt state.
- **[H]** Seed-ISO writers (`kimage:174-199`, `kube-cluster` ~827-881) must
  accept `--role`/`--master` and emit the role drop-in. `kimage build` should
  call `kldload-seal` rather than its own partial sysprep (`kimage:72-83`).
- Build the **role catalog** (git: `roles/<name>/playbook.yml + vars/<env>.yml`)
  and the **cloud-init role contract** (see ADR §5/§6).

**Exit:** "clone the golden → it boots with `role=X` → enrolls → self-builds"
works on KVM with unique identity.

---

## Phase 2 — Networking: proper 4-plane split ⚠matrix
*(Operator requirement: every build/run/communicate rule split across the 4
planes — never one UDP port doing everything. See ADR §14.)*

- **[B]** Subnet numbering contradiction: `kube-cluster` header says
  10.251/10.252, `kube-network` implements 10.250/10.251 (and `10.252` is never
  configured; the host kubeconfig rewrite at `kube-cluster:1662` points at a
  data-plane IP). Pick one source of truth, fix all refs.
- **[B]** `kube-network` copies **one keypair to both planes** (`:71-78`) — no
  real isolation, no independent rotation. Per-plane keypairs.
- **[H]** Implement the per-plane nftables rule split + per-role subnets (ADR
  §14 table); deploy **fails closed** if a required port isn't opened on its
  plane. Make the plane/subnet set a **data-driven table**, extensible past 4.
- **[H]** Reconcile the standalone `kube-cluster` 2-plane mesh with the master's
  4-plane model; add the **API VIP plane** (needed by Phase 3).

**Exit:** 4 distinct WG devices, per-plane keys, per-role subnets, rules split
per plane, one numbering scheme.

---

## Phase 3 — HA Kubernetes (5 CP + 12 workers + storage) ⚠matrix
The "add CPs" ask. Depends on Phase 2's VIP plane.

- **[B]** `kube-init`: add **kube-vip** + `--control-plane-endpoint <vip>:6443`
  (`--upload-certs` already set ✓). Without the endpoint, kubeadm refuses extra
  CPs. `kube-init:84`.
- **[B]** `kube-join --control-plane` mode (fetch cert key via `kubeadm init
  phase upload-certs`, join with `--control-plane --certificate-key`).
- **[B]** `kube-cluster --control-planes N` (stamp N CP clones, init #1, join
  #2..N as CPs); CP count hardcoded to 1 today (`kube-cluster:152,978`).
  **Odd CP counts (1/3/5)** for etcd quorum — warn/round on even.
- **[H]** Lifecycle gaps: scale-**down**/node removal + `kubectl delete node` +
  `etcdctl member remove` + WG `remove-peer` (ghost NotReady nodes today);
  `kubeadm certs renew` + expiry in `kube-status` (**1-year cert cliff**, none
  today; `kube-setup:10`); Cilium operator `replicas=1` hardcoded
  (`kube-init:144`) → scale to 2 on multi-node; untaint CP **unconditionally**
  (`kube-init:395,437`) → only when `workers==0`.
- **[M]** webui bootstrap sends a positional scale arg `kube-cluster` rejects
  (`kldload-webui:6603`; the b113/b137 bug, fixed in the sibling path);
  `--skip-broken` on k8s pkgs (`kube-setup:178`); expose POD/SVC CIDR + MetalLB
  range (hardcoded `kube-init:9-10,216`).

**Exit:** `kube-cluster --control-planes 5 --workers 12` → HA cluster self-wires.

---

## Phase 4 — Storage profile ⚠matrix
- New `storage` node role: ZFS + **NFS/iSCSI** + **democratic-csi (ZFS-CSI)** so
  k8s PVCs provision real datasets/zvols — replaces the local-path fallback
  `kube-init` notes. On wg3 / `10.80.1.0/24`. Snapshots/replication via
  `zfs send`. (ADR §20.)

**Exit:** storage node enrolls; k8s PVCs land on real ZFS over the storage plane.

---

## Phase 5 — Dashboard parity (point-and-shoot GUI)
The backend already has more than the GUI exposes — wire it up.

- **[B]** Wire the **existing** `cluster_deploy` (per-role × per-target,
  `kldload-webui:4174`) to a deploy wizard — it's the closest thing to the goal
  and currently has **no UI**.
- **[B]** Bootstrap form has **no inputs** (always `workers:3`; `#k8s-workers`
  doesn't exist — `index.html:6226`). Add CP-count + worker-count + ram/cpu/disk
  + storage + target; un-disable the CP `<option>` (`index.html:1732`).
- **[M][1-line]** Dead command-palette/Events sends → "unknown action" toasts:
  `kube_bootstrap`→`k8s_bootstrap`, `kube_scale`→`k8s_cluster_scale`,
  `kube_destroy`→`k8s_destroy_cluster` (`index.html:3232-3240`); add `k8s_events`
  (`:7195`), `klab_golden_one` (`:3250`) handlers.
- **[M]** Surface orphaned backend control plane: `golden`/`stamp` (kimage),
  `node_list`/`db_nodes`/`node_accept_key` (**enrollment status**),
  `infra_status`. Add etcd health + CP/worker rollup to `_k8s_status`.
- **[M]** Credentials UI (CRUD+test) for aws/azure/gcp; `credentials_test` only
  implements proxmox today (`kldload-webui:1436`).

**Exit:** "5 CP + 12 workers + storage, pick target, press deploy" works from the
dashboard end to end.

---

## Phase 6 — Master profile (lite + k8s-native) — *ship both*
- **`master-lite`** (systemd-native, single node): NATS JetStream, etcd,
  step-ca, OpenBao, `kldload-reconcile`, webui+reporting, role catalog, central
  obs/secrets. Entry tier.
- **k8s-native HA master** (3+ raft quorum): the same services as workloads so
  k8s self-heals the brain. Enterprise tier.
- **`kldload-reconcile`** brain (the one service worth building): desired
  (`estate.yaml`+catalog) vs actual (NATS/Prometheus/OpenTofu state) → converge,
  rebuild dead nodes, emit `audit.>`.
- **Identity:** Keycloak (federates AD via SSSD/realmd) → OIDC for webui/k8s/
  Grafana/Bob; one RBAC model projected onto webui/k8s/NATS/sudo.
- **Central observability:** thin exporters + **Vector**→Loki; central
  Prometheus(+Thanos/Mimir)+Grafana+Alertmanager.

**Exit:** a master (lite or HA) runs the control plane and self-heals the fleet.

---

## Phase 7 — Multi-cloud (OpenTofu + publishers)
- **OpenTofu** modules (`node`, `cluster`) + per-target backends (libvirt/aws/
  azure/gcp); state on the master.
- `kldload-azure-publish` (consume `kexport vhd`) + `kldload-gcp-publish`
  (raw→tar.gz→GCS→image), mirroring `kldload-aws-publish`'s pipeline.
- **[1-line]** AMI version tag is the literal `"1.1.0"` (`kldload-aws-publish:298`)
  → read `/etc/kldload/version`.

**Exit:** same golden image deploys to KVM + all three clouds from one spec.

---

## Phase 8 — Windows members
- Ansible over WinRM/SSH (`ansible.windows`) for Server + W11 config; the
  "intune-for-linux" repo becomes the enrollment/policy portal for both OSes.
- `windows_exporter`→central Prometheus; **Vector** ships Windows Event Log→Loki.
- (W11 *MDM*-grade compliance = Entra/Intune integration, later.)

**Exit:** Windows hosts enroll, converge, and report through the same pipeline.

---

## Dependency order & quick wins
**Order:** Phase 0 (gate) → 1 (foundation) → 2 (network) → 3 (HA k8s) → 4
(storage) → 5 (GUI) → 6 (master) → 7 (cloud) → 8 (windows). Phases 2/3/4 are
⚠matrix — one branch (`feature/cluster-ha-net`), one `smoke-test` pass.

**Do-first quick wins (tiny, high impact):**
1. `kldload-seal` clear `firstboot-done` — without it clones never self-configure.
2. The 3 `shellcheck -S error` fixes — unblock the smoke gate.
3. Rename the dead palette actions — stops user-visible "unknown action" toasts.
4. `esc()` escape `'`; `kldload-poof` CA path — security one-liners.

---

*Planning artifact. Nothing here is implemented yet. Companion:
`master-profile-architecture.md`.*
