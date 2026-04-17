# kldload Ansible library

Replaces cloud-init runcmd for golden VM provisioning. Cloud-init stays
minimal (hostname, root password, SSH key, sshd on). Everything that was
previously jammed into `runcmd:` lives here as idempotent Ansible plays.

## Layout

- `playbooks/provision-golden.yml` — first-boot configuration of a golden VM
  (firewalls off, sshd hardened, swap off, kube-* tools copied, kube-setup
  runs inside the VM).
- `playbooks/seal-golden.yml` — clears machine-id, SSH host keys, hostname,
  cloud-init state. Runs right before `zfs snapshot @golden`.
- `playbooks/node-prep.yml` — runs on every ZFS clone (CP + workers) on
  first boot to regenerate identity and apply Kubernetes kernel tunings.
- `playbooks/kube-join.yml` — joins workers to an existing CP using a
  join command passed via `--extra-vars`.
- `playbooks/smoke-test.yml` — quick health-check, useful as a default
  target from the web UI.
- `inventory/hosts` — static inventory. kube-cluster writes dynamic node
  lists to `/etc/ansible/hosts.d/kube` (separate group_vars, not this file).
- `ansible.cfg` — project-level config; `ANSIBLE_CONFIG` points here.

## Invocation

From kube-cluster (host → golden VM):

```bash
ANSIBLE_CONFIG=/usr/local/share/kldload-ansible/ansible.cfg \
  ansible-playbook /usr/local/share/kldload-ansible/playbooks/provision-golden.yml \
    -i "${golden_ip}," \
    -u root --private-key "$SSH_KEY"
```

From the web UI's Ansible tab — playbooks in `playbooks/` auto-populate the
dropdown. Targets default to `localhost` but accept any SSH-reachable host
or inventory group.
