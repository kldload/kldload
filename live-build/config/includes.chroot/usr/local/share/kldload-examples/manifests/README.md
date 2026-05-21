# Raw kubectl-apply manifests

Self-contained `kubectl apply -f` targets. Copy-paste into the webui
**K8s → Apply YAML** drawer, or shell out:

```bash
kubectl apply -f /usr/local/share/kldload-examples/manifests/deployment-with-pvc.yaml
```

| File | What it deploys |
|---|---|
| `deployment-with-pvc.yaml` | 1-replica busybox + ZFS-backed PVC + log-tail to demonstrate persistence across restart |
| `statefulset-multi-pvc.yaml` | 3-replica StatefulSet, each pod gets its own PVC, headless Service |
| `cronjob-loadgen.yaml` | k6 every minute, no PVC (results to stdout — Loki picks them up) |
| `networkpolicy-allow-namespace.yaml` | Default-deny, then explicit allow from same namespace — Cilium pattern |
| `ingress-metallb-vip.yaml` | LoadBalancer Service requesting a specific VIP from the kldload-pool |

Every file uses the `examples` namespace by default. Edit the
`metadata.namespace:` line to retarget.
