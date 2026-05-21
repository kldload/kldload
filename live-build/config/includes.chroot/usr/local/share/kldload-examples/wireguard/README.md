# WireGuard examples

kldload ships WireGuard as part of the base image — kernel module +
`wg` CLI + `wg-quick` systemd integration. These examples cover the
three patterns kldload operators reach for:

| File | Topology | Use case |
|---|---|---|
| `01-host-to-host-mesh.sh` | Mesh between N kldload boxes | Cluster federation, syncoid backup-pair pipeline, multi-host webui reachability |
| `02-mobile-peer-config.sh` | Phone/laptop ↔ kldload box | Road-warrior remote access to the cluster + webui without exposing :8443 publicly |
| `03-site-to-site.sh` | LAN-to-LAN bridging | Office ↔ home, kldload at each end, bridges both /24s as one |
| `04-killswitch-allowedips.md` | Notes | How to use AllowedIPs as a kill-switch — clients lose internet if WG drops |

All four use `wg-quick` for activation + systemd persistence. Keys are
generated with `wg genkey | tee priv | wg pubkey > pub` — no external
key management needed.
