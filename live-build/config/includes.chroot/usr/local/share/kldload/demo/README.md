# kldload full-stack demo

A storefront application with a real schema, real seeded data, a real write
path, and blue/green deployment built in. It exists to show a complete
Kubernetes workload standing up from nothing in seconds, and to make a
blue/green cutover something you watch happen rather than something you read
about.

## What it deploys

| Tier | What | Why it is here |
|---|---|---|
| `postgres` | StatefulSet on a PVC, schema seeded at initdb | The data the cutover has to preserve |
| `app-blue` / `app-green` | Two independently versioned copies of the app | Both stay warm, so promotion and rollback are instant |
| `shop` | ClusterIP whose selector names the live track | **This selector is the cutover switch** |
| `shop-blue` / `shop-green` | Per-track private addresses | Lets the idle track be tested with real traffic before promotion |
| `web` | nginx reverse proxy, holds the public VIP | Security headers, rate limiting, and an address that never moves |
| `loadgen` | k6, continuous traffic | Measures the "no dropped requests" claim instead of asserting it |

The application image is **built by this project** (`kube-demo-image`) and
imported straight into containerd on every node. Nothing pulls a third-party
application image, so the demo works with the network unplugged.

> **HISTORY.** This chart used to deploy seven Spring PetClinic services. Those
> image tags were removed from Docker Hub, so every fresh install hit
> ImagePullBackOff, and build #46 cut the chart back to Postgres plus a
> contentless nginx that returned 404 on every path. Depending on someone
> else's tag for the centrepiece of an offline-first product was the real
> defect; owning the image is the fix.

## Getting to it from a browser

MetalLB assigns the VIP from the cluster's own pool, which on a single-node box
is reachable **on the host and nowhere else**. Worse, the default libvirt subnet
(`192.168.122.0/24`) is usually identical on a workstation, so a laptop trying
that address quietly reaches its own `virbr0`.

```sh
kube-demo-publish              # publish on the host's LAN address, default :8088
kube-demo-publish --status
kube-demo-publish --off
```

It prints the URL, and verifies it by fetching the page over that address
before claiming success.

## Blue/green

```sh
kube-bluegreen status          # which track is live, and both tracks' health
kube-bluegreen preview green   # real traffic to green, privately; production untouched
kube-bluegreen cutover green   # health-gated, smoke-tested, then flips the selector
kube-bluegreen rollback        # straight back
```

A cutover is **refused** unless every replica of the target is Ready and its
`/readyz` answers over the real network path. After the flip it verifies the
*endpoints*, not just the manifest: the spec says what was asked for, endpoints
say what traffic actually reaches.

Measured on a 6-node cluster: **~520ms**, zero failed requests at 10 req/s.

## CLI — kube-demo subcommands

| Subcommand | What it does |
|---|---|
| `kube-demo javaapi` | helm install the local chart (no Argo round-trip, no clone) |
| `kube-demo javaapi_status` | Pod readiness + snapshot inventory + replication lag |
| `kube-demo javaapi_disaster [app\|fs\|operator]` | Break it: drop tables / corrupt fs / delete PVC |
| `kube-demo javaapi_recover` | ZFS rollback + restart. Measured TTR. |
| `kube-demo javaapi_verify` | Sanity SQL confirming data is intact |
| `kube-demo javaapi_destroy` | Delete the release and namespace |

## Endpoints

| Path | Returns |
|---|---|
| `/` | The storefront page; theme and version come from the serving track |
| `/api/products` | Catalogue rows, with live stock |
| `/api/orders` | Recent orders via the `order_totals` view |
| `/api/customers` | Customer list |
| `/api/stats` | Totals, plus the pod and node that answered |
| `/api/version` | Track, version, and the schema version from the database |
| `POST /api/orders` | Places an order; decrements stock in the same transaction |
| `/healthz` `/readyz` | Liveness (no DB) and readiness (a real query) |
| `/metrics` | Prometheus counters, labelled by track |

Every response carries `X-Kldload-Track` and `X-Kldload-Pod`, which is what
makes a cutover observable from the client side.

## A caveat worth knowing

`javaapi_disaster` / `javaapi_recover` roll back a ZFS dataset **on the host**.
If the cluster's nodes are VMs, the Postgres PV lives inside a guest where the
host cannot snapshot it, and the recovery path does not apply. The acceptance
test checks for the dataset and **skips the destructive phase** rather than
breaking a demo it cannot restore.
