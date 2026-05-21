# kldload examples — paste-and-deploy catalogue

Every file under this tree is a self-contained sample that an operator
can `apply`, `helm install`, `ansible-playbook`, or paste into the
kldload webui without editing anything but a few clearly-marked vars
at the top.

## Layout

```
/usr/local/share/kldload-examples/
├── ansible/      Ansible playbooks — paste into the webui Ansible tab, click Run
├── helm/         Helm charts + reusable values.yaml overlays
├── manifests/    Raw kubectl apply -f targets
└── argo/         Argo CD Application / ApplicationSet CRDs
```

## How the webui surfaces these

| Tab | What it scans |
|---|---|
| **Ansible → Playbooks** | `/usr/local/share/kldload-ansible/playbooks/` (system) + `playbooks/examples/` (symlink → `kldload-examples/ansible/`). Examples appear in the Run dropdown alongside system playbooks. |
| **Helm → Install** | "📚 Browse examples" button opens `kldload-examples/helm/` — click-to-load chart path + values into the install form. |
| **K8s → Apply YAML** | Operator opens a manifest file from `kldload-examples/manifests/`, copy-paste into the textarea. |
| **K8s → GitOps (Argo)** | Apply Argo Application CRDs from `kldload-examples/argo/` via `kubectl -n argocd apply -f`. |

## Convention every example follows

1. **First 10 lines = description block**: what the example deploys, what it demonstrates, what to watch on dashboards once it's running.
2. **Vars at the top, defaults provided**: edit-and-paste, no surprise prompts.
3. **Pinned image tags**: no `:latest`. Bumping a sample is a deliberate commit.
4. **kldload.io/app=true label** on Services exposed via MetalLB: surfaces them in the webui Cluster Apps panel automatically.
5. **Self-cleanup pattern**: every example has a paired `state: absent` / `kubectl delete` line at the bottom (commented out) so undeploy is one uncomment + re-run.

## What's here today

See each subdirectory's own `README.md` for the per-example catalog:
- [ansible/README.md](ansible/README.md)
- [helm/README.md](helm/README.md)
- [manifests/README.md](manifests/README.md)
- [argo/README.md](argo/README.md)

## Adding your own

Drop a file in the matching subdirectory. The webui Ansible scanner
re-reads on the **↻** button on the Playbooks sub-tab. For Helm /
manifests / Argo, the file is picked up by the next directory-listing
fetch in those tabs.
