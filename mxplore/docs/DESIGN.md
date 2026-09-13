# mxplore — why a tree

kldload ships 28 Grafana dashboards and a Prometheus that scrapes 33 targets.
None of that answers the question an operator actually asks, which is almost
never "show me a time series" and almost always "which one".

Which disk, in which vdev, in which pool. Which guest, on which host, holding
which virtual disk. Which cgroup, running which process, eating the CPU. Every
one of those is a walk down a hierarchy, and a dashboard answers it by making
you already know the answer so you can pick the right value from a dropdown.

So: a tree you walk into. Grafana stays, because it is genuinely good at the
thing it is good at — history, correlation, a wall display. mxplore is the
front door; Grafana is what you open when the tree has told you where to look.

## Shape

One model, two front ends, the same arrangement zxplore and ztxplore use.

    tree.go     the model: nodes, and a Build that walks a spec
    specs.go    the opinion: which four views, and what hangs under each
    prom.go     the only thing that touches the network
    render.go   the terminal
    gui.go      the window (-tags gui)

`Build` takes a `Querier`, which is one method. prom.go satisfies it over HTTP
and the tests satisfy it with a map. That split is the only reason the model is
testable at all, and it is worth defending: the moment Build reaches for a URL
directly, every test needs a Prometheus.

## Four views, in compass order

The desktop has four static workspaces in a + layout and the command center
puts view N on workspace N. So the order in `Views()` is load-bearing, and
there is a test that says so.

| # | View | Sources |
|---|---|---|
| 1 north | Network | node_exporter, Hubble, Tetragon |
| 2 west | Storage | zfs_exporter, smartctl_exporter, ebpf_exporter |
| 3 east | Compute | libvirt-exporter, kubelet |
| 4 south | Host | node_exporter, process-exporter |

## A branch that fails says so

A branch whose exporter is down renders as a row reading "unavailable", not as
a branch that is absent. This is the whole reason the tool exists: kldload
shipped six exporters in every ISO for months and delivered them to no
installed machine, and nothing anywhere said a word. A view that hides what is
missing is worse than no view.

## Not yet

The interactive paned interface. The model and the data path had to settle
first — building a layout around a shape that is still moving is how the layout
ends up owning the shape. `--watch` is the placeholder and it is honest about
being one.
