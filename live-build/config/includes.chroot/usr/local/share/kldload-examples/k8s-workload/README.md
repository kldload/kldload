# k8s-workload — bring your own workload, end to end

A workload you can SEE working, wired to every layer kldload ships, with each
layer behind its own switch so you can turn them on one at a time.

`../helm/hello-world` is the bare scaffold to copy into a chart of your own.
This one is deliberately fuller: it is the example a class works through.

## What it is

`pod-inspector` — three nginx replicas, each serving a page naming the pod and
the node it landed on. Refresh the browser and the pod name changes, which is
the Service load balancing in front of you. Drain a node and watch it move.

Nothing is baked into an image: the page is a ConfigMap, so the entire
workload is text you can read in a review.

## The layers, and what each one demonstrates

| values.yaml | Turns on | Worth showing because |
|---|---|---|
| (default) | Deployment + Service + ConfigMap | installs on any cluster, no config |
| `service.type=LoadBalancer` | MetalLB | a real LAN address — then find it in Cilium's eBPF LB map |
| `persistence.enabled=true` | ZFS CSI | the PVC becomes a ZFS dataset: `zfs list`, `zfs snapshot`, roll back |
| `networkPolicy.enabled=true` | Cilium L7 | `GET /` allowed, `POST /` dropped in eBPF before nginx sees it |
| `tracing.enabled=true` | Tetragon | exec inside the pod raises an event; switch `action` to Sigkill and it blocks |

## Deploy it

Three ways, and the first is the one that makes kldload different.

**1. At install time — the machine deploys it on first boot**

```sh
sudo scripts/package-and-stage.sh --values
# -> /root/darksite/helm-charts/workloads/pod-inspector.tgz
```
Anything in that directory is installed when the machine finishes its first
boot. No registry, no pipeline, no cluster needed when you run it. Plain YAML
works the same way from `/root/darksite/manifests/`.

**2. Now, on a running cluster**

```sh
helm upgrade --install pod-inspector chart/ --create-namespace -n demo
kubectl -n demo port-forward svc/pod-inspector 8080:80
```

**3. From git, reconciled forever** — see `../argo/application-from-git.yaml`.
Point it at your fork and Argo keeps the cluster matching the repo.

## Make it yours

Everything a class changes lives in `values.yaml`, and every value maps to one
readable template in `chart/templates/`. Change the message and
`helm upgrade` — the pods roll, because the Deployment carries a checksum of
the ConfigMap. Add a container, a probe, a second Service: it is an ordinary
Helm chart, and none of the above is kldload-specific except which layers are
already running on the cluster underneath it.

## Air-gapped?

`nginx:1.27-alpine` is not one of the images baked into the darksite. Add that
exact line to `build/darksite/k8s-images.txt` and rebuild the ISO — that is
the whole air-gap workflow, and it is the same mechanism kldload uses for
Cilium, MetalLB, Argo, Tetragon and the ZFS CSI driver.
