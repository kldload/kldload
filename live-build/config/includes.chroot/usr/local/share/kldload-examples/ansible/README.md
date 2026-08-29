# Ansible playbook examples

Eight paste-and-deploy playbooks demonstrating the canonical patterns
operators reach for on a kldload cluster. Every one is a single file —
no roles, no inventories, no vault — so `ansible-playbook example.yml`
or the **Ansible → Run** tab in the webui works without setup.

| File | What it does | What lights up |
|---|---|---|
| `01-nginx-app.yml` | 3-replica nginx + ZFS-backed PVC + MetalLB-advertised LoadBalancer | Cilium service map, Hubble L4 flows, ZFS dataset auto-creation |
| `02-postgres-with-pvc.yml` | Postgres 16 StatefulSet on ZFS-tuned PVC + headless Service + Secret | ebpf_exporter bio_latency, ZFS txg + ARC, Tetragon EXEC at startup |
| `03-helm-from-ansible.yml` | `kubernetes.core.helm` installs `bitnami/redis` with custom values | Helm Releases tab populates; pod metrics scraped by Prometheus |
| `04-argo-application.yml` | Registers a Git-sourced workload with Argo CD continuous-reconcile | Argo UI shows new Application card; sync state visible |
| `05-zfs-snapshot-flow.yml` | Host-side: snapshot a dataset, simulate corruption, rollback, verify | zfs list -t snapshot, sanoid log; demonstrates the rollback story |
| `06-multi-service-mesh.yml` | 3 microservices (api / worker / cache) + internal-only Services + a public Ingress | Hubble L7 (Cilium decodes HTTP), service-to-service flow visibility |
| `07-secret-from-tpm.yml` | Pulls a TPM-sealed secret from the host, projects as a K8s Secret | TPM unseal event in audit log; secret available to pods without plaintext on disk |
| `08-cronjob-with-pvc.yml` | k6 loadgen CronJob pattern — reusable for any HTTP target | Tetragon EXEC every minute (pod fires + exits), Prometheus job appears |

## Module deps (all available on kldload)

```yaml
collections:
  - kubernetes.core      # k8s, helm, k8s_info modules — installed by autodeploy
  - community.general    # zfs, zfs_facts — built into ansible-core
```

## Running

**Via webui**:
1. K8s tab → Ansible → Playbooks → pick the example from the dropdown
2. Click **Run** (target defaults to `localhost`, user defaults to `root`)
3. Output streams to the Output sub-tab in real-time

**Via shell**:
```bash
ansible-playbook /usr/local/share/kldload-examples/ansible/01-nginx-app.yml
```

**Override the defaults**:
```bash
ansible-playbook 01-nginx-app.yml \
  -e app_name=my-nginx -e namespace=my-apps -e replicas=5
```

## Self-cleanup

Every playbook has commented-out `state: absent` tasks at the bottom.
Uncomment them, re-run, and the playbook deletes what it created.

## Guest operations (`guest-*`)

The eight above target the **cluster**. These three target a **single guest**,
which is the other thing operators reach for — and they exist because a VM that
is not built from a kldload golden behaves differently from one that is.

| File | What it does |
|---|---|
| `guest-01-prove-alive.yml` | Reach a host and report enough for "alive" to mean something: uptime, load, memory, gateway reachability |
| `guest-02-install-package.yml` | Install a package **and verify the binary exists and runs** |
| `guest-03-enrol-a-clone.yml` | Give a hand-made VM the host ops key so `kldload-enroll` can finish |

Always pass `-l <host>`; without it these run against the whole estate.

`kldload-inventory` hands every VM `ansible_user=root` plus a key, because that
is how a guest cloned from a kldload golden is reachable. A VM built from any
other image has an empty `/root/.ssh/authorized_keys`, so it reports
`unreachable` while being perfectly healthy on `admin`:

```bash
ansible-playbook guest-01-prove-alive.yml -l <vm-name> \
  -e ansible_user=admin -e ansible_password="$ADMIN_PASSWORD" \
  -e ansible_become=true -e ansible_become_password="$ADMIN_PASSWORD"
```

Run `guest-03-enrol-a-clone.yml` once and that override stops being needed.
