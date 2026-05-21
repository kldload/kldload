# Argo CD examples

CRDs you `kubectl apply -n argocd -f` to register workloads with the
continuous-reconcile controller installed by kldload-autodeploy at
`https://10.100.10.31`.

| File | Pattern |
|---|---|
| `application-from-git.yaml` | Application sourcing manifests from a Git repo + path |
| `application-from-helm.yaml` | Application sourcing a Helm chart by repo + chart name + values inline |
| `applicationset-multi-cluster.yaml` | ApplicationSet — template one Application per matching cluster |

## After apply

Watch in the Argo UI:
```
https://10.100.10.31/applications
```

Initial admin password:
```
cat /var/lib/kldload/argocd-admin-password
```

Or from the CLI:
```
argocd app get <name>
argocd app sync <name>
argocd app wait <name> --health --sync
```
