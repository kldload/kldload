# eBPF examples

Five paste-and-apply examples covering the BPF surfaces kldload ships:

| File | Layer | What it does |
|---|---|---|
| `01-tetragon-tracingpolicy-exec.yaml` | Tetragon | KPROBE on `do_execve` — emit an event for every exec of a denylisted binary |
| `02-tetragon-tracingpolicy-write.yaml` | Tetragon | KPROBE on `sys_write` — emit an event when /etc/passwd is modified |
| `03-cilium-l7-http-policy.yaml` | Cilium | CiliumNetworkPolicy enforcing HTTP method + path at L7 |
| `04-ebpf-exporter-custom.yaml` | ebpf_exporter | Custom config exposing block I/O latency histograms as Prometheus metrics |
| `05-bpftrace-oneliners.md` | bpftrace | 12 ready-to-run bpftrace one-liners that work on the kldload kernel |

## Apply

Tetragon + Cilium policies:
```bash
kubectl apply -f 01-tetragon-tracingpolicy-exec.yaml
kubectl apply -f 03-cilium-l7-http-policy.yaml
```

ebpf_exporter custom metrics:
```bash
sudo cp 04-ebpf-exporter-custom.yaml /etc/ebpf_exporter/my-metric.yaml
sudo systemctl restart ebpf_exporter
curl -s localhost:9435/metrics | grep my_metric
```

bpftrace one-liners — copy any line from `05-bpftrace-oneliners.md`
and paste into a shell. Each runs until Ctrl-C.

## Watch policy events

```
hubble observe --follow --type policy-verdict        # cilium policy hits
kubectl logs -n kube-system ds/tetragon -c export-stdout -f | \
  jq -r -f /usr/local/share/kldload/tetragon-filter.jq   # tetragon events
journalctl -u ebpf_exporter -f                       # exporter
```
