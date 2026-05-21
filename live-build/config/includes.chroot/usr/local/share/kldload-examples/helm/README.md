# Helm examples

## hello-world/

The smallest possible kldload-style Helm chart — `Chart.yaml` + one
template + one values file. Copy this directory as a starting point
when scaffolding your own chart:

```bash
cp -r /usr/local/share/kldload-examples/helm/hello-world /root/my-chart
cd /root/my-chart
# Edit Chart.yaml, templates/, values.yaml
helm install my-app . -n my-ns --create-namespace
```

## Reusable values overlays

Drop-in `values.yaml` snippets to apply to ANY chart via
`helm install ... -f <overlay>.yaml`:

| File | What it sets |
|---|---|
| `values-zfs-tuned.yaml` | PVC annotations + storageClass for ZFS-CSI; `kldload.io/dataset-class` and snapshot-policy labels |
| `values-monitored.yaml` | Prometheus scrape annotations + Loki labels + ServiceMonitor (if chart supports) |

Use one or both as overlays:

```bash
helm install my-db bitnami/postgresql -n my-ns \
  -f /usr/local/share/kldload-examples/helm/values-zfs-tuned.yaml \
  -f /usr/local/share/kldload-examples/helm/values-monitored.yaml
```

The webui Helm tab's "📚 Browse examples" button surfaces these and
click-loads them into the Install form.
