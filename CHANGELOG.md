# Changelog

Operator-facing changes. Newest first. Everything under 1.4.0 is cumulative
since **v1.3.1** (2026-06-16) — 291 commits.

Format: what changed, and what it means for you. Internal refactors and
lint sweeps are omitted unless they change behaviour.

---

## 1.4.0 — unreleased (building as 1.4.0-rc7)

**The largest release the project has had.** 291 commits over two months,
and it changes what kldload *is*: 1.3.x was an installer that left you at a
desktop. 1.4 is a complete operating system with its own applications.

Three things happened at once.

**Native applications.** Three Go consoles — **vmxplore** for KVM and
libvirt, **zxplore** for ZFS, **wgxplore** for WireGuard — plus
**kldload-buildmon** and **kldload-sysdiag**. These are not web pages in a
frame: they are native binaries that ship their own manuals, run on a
headless box over ssh as readily as on the desktop, and share one visual
language so the family reads as one product. Every one of them works on a
stock Linux host and unlocks more where the substrate provides more.

**The desktop refocused into an OS.** One coherent application grid instead
of an accumulation of launchers; the consoles, the AI stack and the
Kubernetes tooling given a real place in it; browsers, media and games
sorted out; dock and folders that are defaults rather than locks. The
result is a machine you can hand to somebody, not a toolkit you have to
already know.

**Quality.** 128 of these commits are fixes, several of them the kind that
cost a rebuild or a disk — data-loss, unbootable installs, silently
disabled GPUs. Those are called out first below, deliberately.

And an AI stack that works with no network at all.

### ⚠️ Fixes you should read before upgrading

These are the ones with an incident behind them.

- **Storage cleanup only touches the target disk.** A wipe could reach a
  disk that was not the install target. This was a data-loss defect; if you
  are running any 1.3.x installer, stop using it for new installs.
- **The boot medium can never be auto-picked as an install target** — the
  installer could offer to install onto the USB stick it booted from.
- **The target-disk wipe must succeed, not be swallowed.** A failed wipe
  used to continue silently and install onto a dirty disk.
- **An optional package can no longer take the kernel with it.**
  `steam-installer` sat in the same apt transaction as `linux-image-amd64`;
  it is in `contrib`, the darksite mirror carries `main`, and one
  `E: Unable to locate` aborted the batch. Two machines installed
  "cleanly", reached ZFSBootMenu, took the passphrase, and had no kernel to
  load. Optional packages now get their own transaction, and the install
  asserts a kernel is actually present on the target before it calls itself
  done.
- **Secure Boot no longer silently disables the GPU**, and the akmods
  signing key is enrolled with the right owner — a correct key with the
  wrong owner fails exactly as hard as no key at all.
- **The ZFS passphrase prompt is visible on encrypted installs**, and the
  interactive console is ordered last so an encrypted root can actually be
  typed into.

### Consoles

- **vmxplore — the KVM/libvirt console.** New in this cycle and the largest
  single addition: an estate tree of every VM with live state, in-app serial
  and VNC consoles, full-screen guest view, right-click verbs
  (start/stop/reboot/suspend/delete), snapshots and rollback, **golden
  images and instant ZFS clones**, batch multi-select, and a remote mode
  that drives a headless hypervisor over ssh. `--setup` turns a bare machine
  into a hypervisor. Guests come up at 2560x1440 with the console included.
  It ships its own manual inside the binary.
- **Appliances** — push-button self-hosted apps: pick one, fill a short
  form, get a configured VM. WriteFreely (plain and a "writing desktop"
  variant that boots straight into the editor), plus the home-lab set:
  Jellyfin, Plex, Gitea, AdGuard Home and Syncthing. Repository-based
  entries verify the signing key against a pinned fingerprint; binary
  entries verify a pinned SHA-256.
- **zxplore — the ZFS console** (formerly z9fs/zexplore) is now installed
  from its own repository: dual-pane commander, remembered replication
  targets, multi-vdev pool design wizard, full property and permission
  detail, and point-and-shoot replication.
- **wgxplore** — a read-only WireGuard estate lens, reporting by network
  plane. The half that minted keys was deliberately removed.
- **kldload-sysdiag** and a k9s dressed in the same skin, so the family
  looks like one product.

### The AI stack

- **It is Ollama and Open WebUI**, installed and configured, not a branded
  wrapper. The interface people already recognise, shipped offline.
- **No model is downloaded by default.** The runtime is installed and ready;
  you pull the weights you want. A build-time checkbox bakes a model into
  the ISO for a fully air-gapped install.
- **The OpenAI-compatible API is published** and the UI sits behind TLS.
  Text-to-speech is available. Models can be loaded and unloaded from VRAM
  from the interface.

### Kubernetes

- **Clusters are born HA**: three control planes by default, with a floating
  VIP proven to survive control-plane failure. Control planes can be added
  on command.
- Day-2 operations in the web UI: port-forward, edit existing resources,
  events, StatefulSets/DaemonSets, config, NetworkPolicies, Ingress, Cilium
  and MetalLB.

### Install and first boot

- **kldload-buildmon** — a native window (with a terminal fallback) that
  says what the post-install build is doing, whether it worked, and what to
  do about it: phase progress, an install audit that reads the logs for you,
  health checks, and component add/remove.
- **First boot no longer does every heavy thing at once.** Cluster
  bootstrap, golden images and model pulls used to converge on boot #1 and
  reboot-cycle the machine; the work is staggered, and the scaffolding VMs
  power down when their build is finished.
- **`kldload-component`** — one verb set for optional capabilities, with a
  catalogue that now actually ships to the target.
- Profiles reduced to five, with AI offered on desktop profiles only.
- A Fedora install with no network still finishes.

### Boot

- **A 5-second boot menu.** It was hidden with a zero timeout, which made
  the ZFS boot environment you keep for rollback unreachable without knowing
  the key and hitting it blind.
- ZFSBootMenu has a timeout for the same reason.

### Build and darksite

- **The kernel pin is derived from the ZFS package** rather than remembered
  or read off GitHub — the pin cannot drift from what the module can build
  against.
- Real EL10 base mirror; the Debian and Ubuntu mirrors now honour their
  package lists (they were short by 93 of the packages the installer asks
  for); the Ubuntu darksite mirror is retired — Ubuntu installs require a
  network.
- `KLDLOAD_ZFS_GIT` builds ZFS from git with an unpinned kernel, opt-in.
- Declaring a package is no longer enough to ship it — the build verifies.

### Desktop

- One application grid with no duplicates: folders, dock pins and the
  console family in their own place. The dock is a default, not a lock.
- Both browsers ship and both are pinned; Firefox on the dock, Chrome in the
  drawer.
- Steam installs natively (deduplicated against the Flatpak) with gamescope.

---

## 1.3.1 — 2026-06-16

See the git history for releases prior to this changelog.
