# Deploy — N of anything, onto any backend (design)

Captured 2026-09-28 from the operator, while planning a video shoot: "a tool
we're missing is the ability to quickly deploy not only VM/Firecracker and
containers" and "take the test demo and make it into a more point and shoot
tool ... deploy say 50 VDIs or 50 RDP with Firecracker". Status: **design,
nothing implemented** (operator: "just make designs, don't try and
implement"). A prototype of the install knobs in section 5 was written and
exercised, then set aside; what it showed is recorded there.

## One sentence

`kdeploy <what>=<count>[,<what>=<count>...] [--on kvm|firecracker|podman|k8s]`
turns a golden, an appliance or a container image into N running, enrolled,
reachable instances, prints how long each took to answer, and remembers the
batch so `kdeploy destroy <batch>` removes exactly what it made.

## What exists today, and the gap

| Exists | Covers | Missing |
|---|---|---|
| `kvm-clone <src> <name>` | one full VM from a golden, ZFS clone + domain + seed | a count, parallel lanes, batch timing, batch teardown |
| `kfire clone <golden> -n N --wait` | N Firecracker microVMs, timed to first answer, enrolled (mesh, CA, inventory) | only Firecracker; only from a shell |
| vmxplore `fcdemo` (the 45-machine demo) | three lanes at once, wall/RDP/browser opened | hard-wired to vdi/rdp/lamp and `/etc/vmxplore/demo-count` |
| `klab deploy blue\|green` | one test VM per distro | a lab shape, not "give me N" |
| vmxplore TUI/GUI and kld | clone WITH A QUANTITY (vmx `C` "name and qty", kld `c <name> <count>`), the Factory (build goldens), the VDI wall (`vmx --vdi-wall`, kld `W`), microVM clone (`kfire clone -n`) | one batch record and one "destroy this batch"; containers; a report checked against what was asked |
| Image Factory (design, memory) | BUILDING goldens and image sets | the deploy side |
| containers | `podman run` / `kubectl` / helm by hand | anything point-and-shoot |
| `kldload-db deployments` | Ansible playbook runs (target, playbook, rc) | not a record of machines made |

Correction (operator, 2026-09-28: "it's already all built in vmxplore"): most
of point-and-shoot exists in vmxplore and kld already -- quantity clones, the
Factory, the wall. The genuine gaps are containers, a batch record with one
teardown, and one report across backends. Phase 1 below shrinks to those.

The Image Factory builds images; this deploys them. Together they are the
"provision like a cloud, on your own iron" argument the demo makes by hand.

## The model

- **Source** — what an instance is made from:
  - a klab golden (`klab-golden-<distro>`, `klab-desktop-<distro>`),
  - an appliance golden (the VM tile `app-*`, and its Firecracker golden),
  - a container image (from the darksite registry mirror when offline),
  - a Helm chart or manifest (the Kubernetes backend).
  Friendly names resolve against the owning catalog (vmx's appliances, klab's
  goldens, the image list), never a copy of it in this tool.
- **Backend** — where it runs: `kvm` (full VM), `firecracker` (microVM),
  `podman` (container on this host), `k8s` (the cluster). Default per source:
  appliances with a Firecracker golden -> firecracker; klab goldens -> kvm;
  images -> podman; charts -> k8s.
- **Batch** — one invocation: a name (default `<what>-<yyyymmdd-hhmm>`), the
  lanes, the counts, the sizes, the network. Recorded in a new `batches`
  table: batch id, lanes, backend, count asked, instance names made, per
  instance time-to-answer, state. The instance names are what `destroy`
  removes, by exact name (never a glob: a test's `destroy --all` once took six
  of the operator's clones).
- **Report** — per lane: asked, up, failed (named, with why), p50/max
  time-to-answer; one line total. Exit 0 only when every instance asked for
  answers; the count is checked against what was asked (core §2).

## Backends

| | kvm | firecracker | podman | k8s |
|---|---|---|---|---|
| make | ZFS clone of the golden's `@golden`, domain, cloud-init seed (what `kvm-clone` does) | `kfire clone <golden> -n N` | `podman run` / a Quadlet unit per instance, storage on the ZFS driver | a Deployment with `replicas: N`, or a chart from the darksite |
| answers when | ssh / the tile's port | the golden's port (kfire already measures) | the container's port or healthcheck | Ready replicas + the Service answering |
| enrolled into | mesh + CA + inventory (vmx enroll) | same (kfire --wait -> vmx) | inventory with `ansible_connection=podman`; not the mesh | the cluster is already enrolled |
| destroy | `kvm-delete <name>` (leaves every registry; estate-lifecycle proves it) | `kfire destroy <name>` | `podman rm` + the unit | `kubectl delete` / `helm uninstall` |
| parallel | lanes in parallel, clones in a lane serial (fcdemo's measured shape) | same | same | one apply |

Everything under "make" and "destroy" is a shipped verb today except the
podman lane and the batch record. The tool is a conductor, not a second
implementation (core §1.2: never re-implement logic that already exists; the
project memory "harnesses drive shipped verbs").

## Point and shoot

```
kdeploy vdi=50                              # 50 VDI desktops, Firecracker, enrolled
kdeploy rdp=12 --open                       # twelve seats, each opened logged in (see --open)
kdeploy vdi=15,rdp=15,lamp=15               # the 45-machine demo, as one command
kdeploy fedora-desktop=10 --on kvm          # ten full GNOME VMs from the desktop golden
kdeploy nginx=20 --on podman                # twenty containers on this host
kdeploy list                                # batches and their state
kdeploy destroy vdi-20260929-0712           # exactly what that batch made
```

- `--open`: what fcdemo does now — the VDI wall for desktops, RDP windows for
  seats (capped: opening 50 windows is a denial of service on the operator's
  own screen; the wall is the view for large counts), browser tabs for web
  tiles.
- `--dry-run`: the plan, the RAM it needs, and whether it fits.
- The same thing is a **Deploy** pane in the TUI/GUI (pick sources, counts,
  backend; a live table of instances coming up) and a verb in `kld`.
- fcdemo becomes `kdeploy vdi=N,rdp=N,lamp=N --open` with the demo count; the
  demo keeps its button, the implementation stops being special.

## The terminal wall

Operator, 2026-09-28: "a literal VDI wall in terminal" -- the browser wall
(`vmx --vdi-wall`, kld `W`) drawn inside kld instead. kld already draws one
VM's screen in the terminal (its VNC framebuffer as sixel, `w`), so the
drawing half exists. What differs:

- VDI desktops have no VNC: Firecracker has no display device, and the VDI
  tile streams its session through mediamtx (what the browser wall plays).
  The terminal wall decodes those streams: one `ffmpeg` per stream at ~1 fps,
  scaled to a tile, composed into one grid image, drawn as sixel. KVM VMs in
  the grid can use their VNC display, as `w` does.
- Throughput: 50 tiles at 1 fps is 50 small decodes and one composite per
  second; the limit is the terminal's sixel speed (foot is fast; a terminal
  with no image support falls back to a text grid of names and states).
- Pages when the grid would make tiles smaller than readable; enter on a
  tile opens that desktop's screen (`w`).
- To measure before promising a frame rate: decode cost per stream on fiend,
  composite + sixel time for 50 tiles in foot.

## Safety and admission

- **RAM admission before anything starts.** count x instance size against
  MemAvailable, minus a host reserve; refuse with the arithmetic, or
  `--squeeze` to shrink per-instance RAM to a stated floor. History: ten 4 GB
  klab clones OOM-killed a GNOME session on .121; 384 MiB is too little for
  EL10 (3-kvm, 2026-09-28); five parallel tiles thrashed a 32 GB desktop.
- **Addresses:** a batch larger than the free DHCP range is refused up front
  (the libvirt default net's range, kube-cluster's reservations, MetalLB's
  pool), not discovered at instance 180.
- **Teardown by record only**, never by pattern; a batch whose record is
  missing is listed as unowned and left alone.
- **Enrollment is bounded and reported:** the enrol sweep is a 10-minute
  timer; the tool runs it directly (as estate-lifecycle does) and reports who
  is not on the mesh yet rather than waiting for ever.

## 5. Install-time selection knobs (for the shoot, and generally)

"Build all images" builds 5 lean klab goldens, 5 desktop goldens and 13
appliance tiles — over two hours on fiend (6-full, build 153: 2 h 12 min to
ready). The shoot wants k8s 3+3, one desktop golden, and VDI/RDP/LAMP. Three
knobs narrow it, only meaningful with `KLDLOAD_BUILD_IMAGES=1`:

| Knob | Values | Drives |
|---|---|---|
| `KLDLOAD_LEAN_GOLDENS` | unset = all · `none` · list of klab distros | the `klab golden <distro>` lines the installer writes into klab-firstboot.service; `none` also drops the blue/green `klab deploy` lines (they clone the lean goldens) |
| `KLDLOAD_DESKTOP_GOLDENS` | unset = all · `none` · list | `klab golden-desktop <distros>` in autodeploy (it builds from the cloud image; it does not need the lean golden — checked in klab `cmd_golden_desktop`) |
| `KLDLOAD_APPLIANCES` | unset = all · `none` · list | `vmx --build-all --only <catalog names>` |

Rules, from the prototype run against onyx's real catalog:

- Written by BOTH writers of install state: the installer's
  install-manifest.env (bootstrap.sh) and kldload-install-target's effective
  config; autodeploy sources both.
- A name that matches nothing is an **error at install time and at first
  boot**, never "built nothing". `vmx --build-all --only nope` today builds
  nothing and exits 0 — fixed separately in vmxplore (simple fix).
- Appliance names resolve against `vmx --appliances` (full name, tile VM name
  such as `app-vdi-deskto`, or a word that picks exactly one tile: `vdi`,
  `rdp`, `lamp`). The prototype resolved `vdi,rdp,lamp` correctly, rejected
  `desktop` as ambiguous (VDI and RDP) and `nope` as unknown — **and split
  `"VDI Desktop"` on its space**, so the list separator must be the comma
  alone once full names are allowed.
- Everything that COUNTS goldens must read the same selection, or a narrowed
  install fails its own checks: netboot-run's verify ("requested goldens
  sealed" multiplies phases by klab's DISTROS), profile-report's asked-vs-on-
  disk, autodeploy's plan (a phase that never runs leaves the progress bar
  short), and the Firecracker golden count autodeploy now reports.
- A new matrix edition, `17-shoot`: desktop profile, KVM, k8s 3+3,
  `KLDLOAD_LEAN_GOLDENS=none`, `KLDLOAD_DESKTOP_GOLDENS=fedora`,
  `KLDLOAD_APPLIANCES=vdi,rdp,lamp`. It is the video's install and a sweep
  edition, so filming it also tests it.

## 6. The TUI replicate verb (for the video's third promise)

The video title is "snapshot, clone and replicate a VM in seconds". The
vmxplore TUI has snapshot (`s` pane, rollback `R`, typed snapshot) and clone
(`C`, prefilled name); **replicate is absent** (only `kvm-replicate` on the
command line, whose `--help` was broken — fixed separately).

- Key: a free verb key in the table (to be checked against tui.go's set;
  `r`/`R` are taken by the snapshot pane's rollback context).
- Input overlay: destination — another local pool (`tank/replicas/<vm>`) or
  `host:pool/dataset` over ssh; the first run is a full send, later runs are
  incremental from the last common snapshot (what `kvm-replicate` and
  syncoid already do; drive syncoid, which ships, rather than a new sender).
- Progress in the job pane (bytes sent, rate), then a read-back: the
  destination's newest snapshot equals the source's, or it failed.
- Marked rows replicate in sequence (one ZFS send per pool at a time).
- Shown on camera from fiend: replicate a VM to the second pool, then to onyx.

## Testing

- Every lane both ways (core §5d.3): N asked -> N up passes; one instance
  sabotaged (bad port, starved RAM) fails the batch and names it.
- Count against what was asked; exit status reflects it.
- Destroy leaves every registry (the estate-lifecycle checks, per instance).
- A 50-instance Firecracker batch on fiend, timed, as the demo figure;
  numbers only from the machine, never invented (project rule 13).

## Phasing

| Phase | Scope |
|---|---|
| 0 | the install knobs + `17-shoot` edition (the video's install) |
| 1 | `kdeploy` with firecracker and kvm lanes, batch record, report, destroy, `--open` (fcdemo re-based on it) |
| 2 | TUI/GUI Deploy pane; `kld` verb; TUI replicate verb |
| 3 | podman lane (Quadlet, ZFS storage, inventory) |
| 4 | k8s lane (Deployment/chart, from the darksite) |

## Open decisions (operator)

1. Name: `kdeploy` (k* family) or a `kld deploy` verb only?
2. Default backend for appliances: Firecracker (fast, dense) or KVM (full
   feature set, e.g. USB passthrough tiles cannot be microVMs)?
3. Containers: podman on the host, the k8s cluster, or both as separate
   lanes (this design assumes both)?
4. The replicate verb's destination default: second local pool, or a named
   remote (fiend -> onyx)?
