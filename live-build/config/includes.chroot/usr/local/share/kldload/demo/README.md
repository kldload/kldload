# kldload demo workload — the 1.0 release "Christmas tree"

Full-stack Java API + PostgreSQL + nginx (powered by Spring PetClinic
Microservices upstream) + k6 loadgen, deployed via Argo CD. Designed
to light up every Grafana dashboard on a kldload install and to
demonstrate sub-60-second ZFS-rollback recovery.

## CLI — kube-demo subcommands

This demo is wired into the existing `kube-demo` tool (no new CLI).

| Subcommand | What it does |
|---|---|
| `kube-demo javaapi` | Apply the Argo Application — Argo syncs the helm chart, ~5 min to fully Ready |
| `kube-demo javaapi_status` | Argo sync state + pod readiness + snapshot inventory + replication lag |
| `kube-demo javaapi_disaster [app\|fs\|operator]` | Break the workload: drop tables / corrupt fs / delete PVC |
| `kube-demo javaapi_recover` | ZFS rollback to the latest autosnap + restart Postgres + Argo re-sync. Measured TTR. |
| `kube-demo javaapi_verify` | Sanity SQL queries to confirm data is intact after a recover |
| `kube-demo javaapi_destroy` | Delete the Argo Application (cascade-deletes the demo namespace) |

Interactive menu: run `kube-demo` and pick **25-29** under the
"Full-stack demo (1.0 headline)" section.

## Architecture

| Component | Where | Image |
|---|---|---|
| Postgres 16 | StatefulSet, ZFS-tuned PVC `pvc-postgres-data` | `bitnami/postgresql:16.4.0-debian-12-r0` |
| Spring Cloud Config | `config-server` deployment | `springcommunity/spring-petclinic-config-server:3.1.0` |
| Eureka | `discovery-server` deployment | `springcommunity/spring-petclinic-discovery-server:3.1.0` |
| customers/vets/visits domain services | 3 deployments, each → Postgres | `springcommunity/spring-petclinic-*-service:3.1.0` |
| Spring Cloud Gateway | `api-gateway` (2 replicas) | `springcommunity/spring-petclinic-api-gateway:3.1.0` |
| Spring Boot Admin | `admin-server` | `springcommunity/spring-petclinic-admin-server:3.1.0` |
| nginx front | 2 replicas, MetalLB VIP `10.100.10.30` | `nginx:1.27-alpine` |
| k6 loadgen | CronJob, every minute, 50 RPS for 30s | `grafana/k6:0.52.0` |

8 deployments + 1 StatefulSet + 1 CronJob — 11 resources total. Argo
manages them all via one Application CRD.

## Files in this directory

```
argo/javaapi-fullstack-app.yaml          ← Argo Application CRD (the "deploy" trigger)
charts/javaapi-fullstack/Chart.yaml      ← Helm chart metadata
charts/javaapi-fullstack/values.yaml     ← every tunable, every image tag pinned
charts/javaapi-fullstack/templates/      ← _helpers.tpl + postgres / spring-services / ingress / loadgen
```

Host-side:
```
/etc/sanoid/sanoid.d/javaapi.conf        ← snapshot policy (every 5 min)
/usr/local/share/kldload/argocd-values.yaml ← Argo CD helm values for the autodeploy install
/usr/local/bin/kube-demo                   ← extended with 6 javaapi_* functions
```

## ZFS dataset — the rollback story

Postgres PVC `pvc-postgres-data` maps to ZFS dataset
`rpool/k8s/pvc-postgres-data` via the kldload default storage class.

Sanoid policy keeps **90+ snapshots online per dataset**:
- 12 × 5-min frequent (1 hour of fine-grained rollback)
- 48 × hourly (last 2 days)
- 30 × daily (last month)

Each snapshot costs only the ZFS-COW delta — typically ~50 MB/hr on
the steady-state load, ~1.5 GB total for the 48-hour rolling window.

When `kube-demo javaapi_recover` runs:
1. Find newest `autosnap_*` on `rpool/k8s/pvc-postgres-data`
2. If PVC was deleted (operator disaster), pause Argo auto-sync first
3. `zfs rollback -r <snap>` — sub-second on a quiet pool
4. Force-restart `postgres-0` to re-mount the rolled-back dataset
5. Re-enable Argo auto-sync — Argo confirms everything matches truth
6. Print TTR

End-to-end TTR target: **<60 seconds** (the 1.0 acceptance gate).
Most of the time is dominated by Postgres restart, NOT the rollback
itself.

## Webui

K8s tab → Overview sub-view → "+ Deploy & lifecycle" panel:

- **🎄 Full-stack demo** (primary button) — fires `kube-demo javaapi`
- **Demo mode** row (always visible):
  - 💥 Disaster — fires `kube-demo javaapi_disaster` (sub-prompts in CLI)
  - ↻ Recover — fires `kube-demo javaapi_recover`
  - 📊 Status, ✓ Verify data, ✕ Destroy demo

Every button has a `title` mouseover with the underlying CLI command
so the operator can run the same thing from a shell.

## Argo CD

Argo CD itself is installed by `kldload-autodeploy` after Cilium /
Tetragon (helm chart from `/root/darksite/helm-charts/argo-cd.tgz` if
vendored, online fallback otherwise). Server runs at
`https://10.100.10.31` (MetalLB VIP), admin password at
`/var/lib/kldload/argocd-admin-password`.

The Argo Application CRD points at the GitHub repo for the chart
path. For offline air-gap installs, repoint via:

```bash
kubectl -n argocd edit application javaapi-fullstack
# change spec.source.repoURL to a local git/OCI source
```

## Acceptance gate

`tests/smoke-javaapi-rollback.sh` is the 1.0 release gate:

1. Deploy via `kube-demo javaapi`
2. Verify 8 pods Ready + ingress VIP serves /api/customer
3. Capture baseline `owners.count()`
4. Trigger disaster (default: `app` — drop tables)
5. Confirm /api/customer now errors
6. Run `kube-demo javaapi_recover` — measure TTR
7. Assert TTR < 60 seconds
8. Verify owners table back + counts match baseline
9. Cleanup (unless `KEEP_DEMO=1`)

Pass on at least 3 distros (kvm + server + desktop profiles) → 1.0
ships.
