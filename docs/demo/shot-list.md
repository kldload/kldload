# Shot list — "rack to a six-node HA cluster, in one automation"

Everything below is grounded in the 6-full run on fiend, 2026-09-16, captured
read-only to `cluster-capture-fiend-20260916T143158.txt`. Nothing here is a
guess at what the machine will print. The demo edition builds only the cluster,
so it is faster than that run, but the cluster it ends with is the same one.

**Start it with:** `sudo ~/kldload-wip/record-demo.sh`
It prints a 10-second countdown so you can start the screen capture, then
reboots fiend into netboot. Pass `--now` to skip the countdown.

Edition `8-k8s-demo`: profile kvm, template k8s, **3 control planes + 3
workers**, image building off, AI off, ztest off.

---

## Beat 0: the trailer

Sixty seconds of rendered title sequence before any of this, making the claim
the run then checks. It is not footage and it is built elsewhere:
[trailer.md](trailer.md). Cut straight from its last frame to the bare machine
on the bench.

## The five beats

**1. Nothing, then a menu.** Fiend reboots with no disk worth keeping and finds
the netboot menu. One selection. From here nobody touches the keyboard again,
and that is the whole claim of the video.
*3-10 min depending on the link. Say the number out loud; it is the least
interesting part and the audience needs to know it is bounded.*

**2. The installer runs itself, and part 1 of the show explains what it is
doing.** Not a progress bar. The deck is the manual: it teaches ZFS boot
environments, datasets and the install decisions while those decisions are
being made.
*~12 min.*

**3. One reboot.** Worth showing in full rather than cutting. It is the only
reboot in the entire run.

**4. Part 2, while the cluster builds itself.** The show holds the screen and
the real build log runs in a window on it. This is the part that reads as
magic, because nothing is being typed.
*On the full edition, boot at 13:35 and all six nodes Ready by 13:49, so about
14 minutes. The demo edition has no goldens or images to build, so expect the
same or better.*

**5. The show hands the machine over by itself** and you land at a desktop.
That hand-over is the moment to stop narrating and start proving.

---

## The ending: prove it, do not narrate it

Run these in order. The output below is what the machine actually printed
today, so you know what you are looking at before you point a camera at it.

### The cluster is real

```
sudo kubectl get nodes -o wide
```

Six nodes, three of them `control-plane`, all `Ready`, v1.32.13 on Fedora 44
cloud images, kernel 6.19.10.

```
sudo kubectl get pods -A
```

56 pods: 40 in kube-system, 7 metallb-system, 7 argocd, 1 local-path-storage,
1 default. All Running.

### The claims, demonstrated

This is the part worth rehearsing. Saying "we use eBPF" is narration. Printing
the map is evidence.

```
sudo cilium status
```

Cilium OK, Operator OK, Envoy DaemonSet OK, Hubble Relay OK. `cilium 6/6`,
`cilium-envoy 6/6`, **Cluster Pods: 16/16 managed by Cilium**, chart 1.16.5.

```
sudo kubectl get ds -n kube-system | grep -iE 'NAME|proxy|cilium'
```

Only `cilium` and `cilium-envoy` come back. **There is no kube-proxy
DaemonSet** — kubeadm ran with `--skip-phases=addon/kube-proxy` and Cilium
replaced it. The absence IS the point; say so, because it otherwise reads as
something missing.

```
sudo kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf endpoint list
```

One entry per pod with its id, security identity and MACs. This is the kernel
doing the routing.

### The number that lands

```
sudo zfs list -o name,used,refer -r rpool/vms -t all | grep -E 'NAME|k8s'
```

`rpool/vms/k8s-golden` refers 2.32G. Every one of the six node clones shows
**0B USED**. Six machines off one image, paying for one image. Let that sit on
screen.

### Finish in k9s

```
k9s
```

v0.51.0, already installed. Nodes view, then pods. It is also served in the
web console on 7681 via ttyd if you would rather show it in a browser.

---

## Notes to self while filming

- Log in with the username and password set in the answers file.
- `record-demo.sh` refuses to start while any build or matrix unit is active.
  If it exits 1 naming a unit, that is the guard working, not a failure.
- F12 hands the machine over without stopping the build, if you need the
  desktop early.
- Do not run `kldload-loadtest` for b-roll unless you mean it: it fires HTTP
  load, block I/O and a fork storm, and it ignores SIGTERM.
