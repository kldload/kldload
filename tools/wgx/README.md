# wgx — the wgxplore prototype (WireGuard networks console)

Design: ../../docs/WG-NETWORKS-DESIGN.md. Declared networks (ptp /
hub-spoke / mesh / joined) rendered to plain wg configs; `attach` moves
kernel WireGuard interfaces — including into container network namespaces
(the tunnel keeps working; the socket stays anchored in the birth
namespace). Proven end-to-end on hardware 2026-08-02: a `--network none`
container pinged its hub at 0.2ms through the mesh.

Static pure-Go build (CGO off), shells out to `wg`/`ip`/`nsenter`, echoes
every privileged command before running it. Built into the ISO by
builder/build-iso.sh for every profile.

STATUS: prototype living in-tree until the wgxplore repo exists; it then
moves upstream (zxplore-style: shared chassis, GUI/TUI, full release
pipeline) and build-iso switches to tracking it like zxplore. Name
confirmed 2026-08-02: wgxplore, binary `wgx`.
