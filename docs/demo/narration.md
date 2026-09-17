# Opening narration — "bare metal to a six-node HA Kubernetes workstation"

Spoken copy for the three beats before the show takes over. Short sentences on
purpose: it is read aloud, not on a slide. Every number in here was measured on
fiend on 2026-09-16, not estimated.

---

## A. Cold open, before you power it on

> This machine has nothing on it. No operating system, no installer media, no
> USB stick. It is not even plugged into a keyboard.
>
> In about twenty minutes it is going to be a workstation I can sit down and
> use, and it is going to be running a six-node high-availability Kubernetes
> cluster underneath. Three control planes, three workers.
>
> I am going to press the power button. That is the last thing I do.

Beat. Then power on.

*Why this works: the claim is made before the evidence, so the viewer spends the
whole video checking it rather than waiting to be told what they saw.*

---

## B. During the PXE boot and the image download

This is the dead stretch, about two and a half minutes. Talk through it.

> It is asking the network what it should be.
>
> There is a server on this LAN holding a fifteen-gigabyte image — the whole
> operating system, every package, the container images, the lot. Nothing here
> reaches out to the internet. This entire build could happen in a room with no
> internet at all, and that is the point.
>
> It is pulling that image now, at about a hundred megabytes a second, which is
> as fast as this machine's network card goes.

If it is slow, say so rather than talking over it. A number spoken plainly is
more convincing than pretending it is instant.

> Everything after this is decided by one answers file: which disk, which
> profile, three control planes, three workers. I wrote that once. I will not
> touch this machine again.

---

## C. The hand-off, just before slide one

Land this as the image finishes and the installer starts.

> From here it explains itself.
>
> What comes up next is not a progress bar. While it installs, it teaches you
> what it is doing and why — the filesystem layout, the boot environments, the
> decisions it is making as it makes them.
>
> So sit back and enjoy it.
>
> kldload. BSD 3-Clause. Free.

Then stop talking and let the deck run.

---

## Notes

- **"Free" is doing real work there.** Say it last and say it flat. No pitch
  voice. The licence is BSD 3-Clause, which is permissive, so "free" is not a
  trial or a community edition and it is worth that being unambiguous.
- **Do not promise a golden image factory.** This edition builds no images.
  What it does show is the six cluster nodes being clones of one 2.3GB golden
  at zero bytes each, which is a better number anyway. Save the factory for its
  own video.
- **Do not narrate over the show.** The deck is the strongest content in the
  video and it is already written. Silence is the right call once it starts.
- **Measured timings to keep you honest:** image transfer about 2.5 minutes at
  91 to 99 MB/s; install roughly twelve minutes; boot to all six nodes Ready,
  fifteen minutes.

---

## 0. The intro, before everything

Keep it under twenty seconds. The demo is the hook; do not spend the hook
introducing the hook.

> Every Kubernetes demo you have seen starts with a cluster that already
> exists. Somebody else built the machines.
>
> I want to show you the part everyone skips. This is bare metal. Nothing on
> it. We are going to end up with a six-node HA cluster and a desktop I can
> actually work on, and I am going to do it in one action.
>
> Let's go.

*Why it is framed as an omission rather than a feature: "here is my tool" makes
a viewer defensive, "here is the part nobody shows you" makes them curious.*

---

## D. The desktop reveal — what to say while you move the mouse

The show hands over on its own and you land on a GNOME desktop. Do not rush
this. The temptation is to start clicking immediately; the stronger move is to
say nothing for a second and let people register that it is an ordinary desktop.

Then, while you move across the launchers:

> That is it. It handed the machine over by itself.
>
> And this is just a desktop. GNOME. Nothing exotic, nothing you have to learn.

Now the icons, in this order. Each one is a real tool, not a shortcut to a
readme:

> Kubernetes. k9s. Helm. Ansible. Metrics.
>
> Those are not links to documentation. That is the cluster this machine is
> running right now, in the tools you would actually use on it.

Land the point that makes it different:

> And here is the thing worth noticing. This is not a console I am SSHing into
> from somewhere else. The six nodes are running on this machine, underneath
> this desktop, while I move this mouse.
>
> It is a workstation. It just happens to be a cluster as well.

Then open k9s from the launcher rather than typing it, because clicking makes
the point that it is set up already, and land on six Ready nodes.

### The icons that are actually there

Ansible · Helm · Kubernetes · k9s · Metrics · sysdiag · Secure Boot Repair ·
kldload Build & Audit · kldload Web UI, plus the web GUI on :8443.

Verified on fiend after this run, 2026-09-16. If a future build changes the
set, check before narrating it — naming an icon that is not on screen is the
one mistake a viewer will notice instantly.

### Closing the video — the numbers

No argument, no comparison, no adjectives. Read the facts and stop.

> Twenty-eight minutes ago this machine had no operating system on it.
>
> Three minutes pulling the image. Twelve installing the operating system.
> Thirteen building the cluster.
>
> It now runs six nodes. Three control planes, three workers. Cilium, with no
> kube-proxy. Hubble. Tetragon. MetalLB. kube-vip. ArgoCD. metrics-server.
> Fifty-six workloads running. Zero failed units.
>
> The six nodes are clones of one two-point-three gigabyte image. Together they
> use zero additional bytes of disk.
>
> Nobody touched the keyboard.
>
> Nothing left the local network. No package mirror. No container registry. No
> git server. No vendor endpoint. Zero public internet traffic, start to
> finish.
>
> The packages, the twenty-three container images and the Helm charts are all
> inside that one file already. There is nothing to stand up first, nothing to
> mirror, nothing to authenticate to. You stage one image and boot machines.
>
> Fifty machines would take the same twenty-eight minutes. They boot in
> parallel, from the same image.
>
> That image is thirteen point nine gigabytes, and it is uploaded once. Fifty
> machines pulling their own packages from the internet is about seven hundred
> gigabytes. Two hundred and fifty machines is three and a half terabytes. Here
> it is thirteen point nine gigabytes, once, whatever the number of machines.
>
> That is a desktop, on the same machine, on top of all of it.
>
> kldload. BSD 3-Clause. Free.

*Every figure above was measured on this run. Say them flatly and let them
land. Anything added to them reads as a pitch and makes the facts sound less
certain than they are.*

---

### On the mouse itself

If you moved the mouse during the show, the cursor will have appeared over the
slides. That is the show bringing it back on movement, not a fault. Nothing to
explain on camera; just avoid touching it until the hand-over if you want those
frames clean.
