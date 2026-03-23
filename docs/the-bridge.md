# The Bridge

A document for BSD people coming to Linux, Linux people discovering ZFS, and everyone who's tired of paying for things that should be free.

---

## For BSD people

You already know ZFS. You know boot environments, jails, bhyve, pkg, and the beauty of a base system built and maintained as one cohesive unit. You know what real isolation looks like. You know that FreeBSD's ports tree is one directory with everything in it — no extra repos, no GPG key imports, no third-party package managers.

You've avoided Linux because it's fragmented. Every distro does things differently. There are dozens of package managers. Getting ZFS on root requires fighting DKMS, initramfs, and a bootloader that doesn't understand your filesystem. The documentation assumes you want to use ext4 and be happy about it.

**kldloadOS changes that.**

- ZFS on root, deterministic dataset layout, ZFSBootMenu — you'll feel at home immediately
- `kpkg` wraps both `apt` and `dnf` into a single command — like `pkg` but for Linux
- Offline darksites baked into the ISO — like building from ports, but pre-resolved
- Boot environments work exactly like you'd expect from `beadm` / `bectl`
- WireGuard is in the kernel, not a port — same config files, same behavior
- The installer drops you to a shell if you want to build your own pool layout

**What you give up:** Real jails (Linux containers are not the same — they share a kernel). bhyve's hardware-level isolation (KVM is close but not identical). The simplicity of `rc.conf`.

**What you gain:** Hardware support (Linux drivers cover everything). eBPF (the 'e' that BSD doesn't have — kernel-level tracing and packet processing that FreeBSD's BPF can't match). NVIDIA CUDA support. The entire Docker/Kubernetes ecosystem. Package availability — every open source project ships Linux packages first.

---

## For Linux people

You've been running Linux for years. You know `apt` or `dnf`. You've heard of ZFS but never used it because no distro ships it on root. You think containers are isolated (they're not — they share a kernel). You've been paying for log collection, mesh networking, monitoring, and backup tools that are literally one-liners in disguise.

**kldloadOS shows you what you've been missing.**

### ZFS redefines Linux

Most Linux users have never experienced a filesystem that:

- **Snapshots everything instantly** — not LVM snapshots (which are slow and fragile), real copy-on-write snapshots that cost nothing
- **Checksums every block** — silent data corruption is impossible. ext4 doesn't even know when your data rots
- **Compresses transparently** — lz4 compression saves 30-50% on typical Linux files with zero CPU overhead you'd notice
- **Replicates natively** — `zfs send | ssh remote zfs receive` moves datasets between machines. No rsync, no proprietary backup tool, no agent
- **Has boot environments** — upgrade your kernel, it breaks? Reboot, pick the previous environment from the menu. 30 seconds. No reinstall
- **Clones instantly** — need a copy of a 500GB database for testing? `zfs clone` — done in milliseconds, uses zero extra space until you change something

This isn't a feature list. This is a fundamental change in how you operate Linux. Once you have ZFS on root, you can't go back to ext4. It's like going from manual backups to version control — you wonder how you ever lived without it.

### What kldloadOS makes obsolete

Every item below is something you've either paid for, spent hours configuring, or accepted as "just how Linux works":

| What you're paying for | What it actually is |
|------------------------|---------------------|
| Enterprise VPN ($99/mo) | `wg-quick up wg0` — 20 lines of config |
| Enterprise mesh ($999/mo) | WireGuard + a for loop |
| Log collection ($299/mo) | `tar` piped over SSH |
| Backup solution ($X/mo) | `syncoid -r rpool backup:tank` |
| Snapshot manager | `zfs snapshot -r rpool@today` |
| Disk encryption | ZFS native — AES-256-GCM, per-dataset |
| LVM + mdadm + fsck | ZFS — one tool replaces three |
| Boot recovery | `kbe activate before-upgrade && reboot` |
| Image registry | `zfs clone` + `kexport qcow2` |
| Multi-distro management | `kpkg install nginx` — Debian and CentOS |
| Network monitoring ($5K) | `execsnoop`, `tcplife` — already installed |
| IDS/IPS appliance ($15K) | XDP + eBPF — line-rate packet filtering |
| SIEM ($50K+/yr) | LogHog + ZFS snapshots |
| Config management | SSH + WireGuard + a for loop |
| Certificate management | `certbot renew` — one cron job |
| Service discovery | `/etc/hosts` on ZFS, replicated |
| Secrets vault | `zfs create -o encryption=on rpool/secrets` |
| Disaster recovery | `syncoid -r rpool offsite:tank/dr` |
| Load balancer ($10K) | HAProxy — 50 lines of config |
| NFS appliance ($5K) | `zfs set sharenfs=on rpool/share` |
| Replication ($X/seat) | `zfs send \| ssh remote zfs recv` |

The enterprise software industry has built a $500 billion business selling you things that are one-liners on a properly configured Linux system. kldloadOS configures that system for you.

### The real example

Enterprise mesh network — $9,999/month:

```bash
# What you're paying for:
PRIV=$(wg genkey) && printf "[Interface]\nAddress=10.99.0.2/24\nPrivateKey=$PRIV\n\n[Peer]\nPublicKey=HUB_PUBKEY\nEndpoint=HUB_IP:51820\nAllowedIPs=10.99.0.0/24\nPersistentKeepalive=25\n" | ssh root@PEER "cat>/etc/wireguard/wg0.conf && wg-quick up wg0"
```

That's it. One command. Encrypted mesh node joined. The $9,999/month product is a UI wrapper around that command.

Log collection — $299/month:

```bash
# What you're paying for:
tar -czf - /var/log/ | curl -sST- -H "X-Token: $TOKEN" https://your-server/ingest
```

`tar` was literally created to stream bits of data the same way magnetic tapes stored it. You can "stream" data because that's what tapes used to do. Now you can move up from tape to ZFS replication — for free.

---

## Linux vs BSD — the real question

Every "VS" comparison you've ever read is asking the wrong question. It's not Linux **VS** BSD. It's Linux **OR** BSD. The correct question is: what does each do well?

### What Linux is good at

| Strength | Why |
|----------|-----|
| Hardware support | Every driver, every chipset, every GPU. Linux runs on everything. |
| eBPF | Kernel-level tracing, network filtering, security monitoring. BSD has classic BPF but not extended BPF (yet) — the 'e' matters. |
| NVIDIA / CUDA | Full GPU compute support. Machine learning, rendering, video encoding. |
| Docker / Kubernetes | The entire container ecosystem assumes Linux. |
| Package availability | Every open source project ships Linux packages. |
| Performance | Linux's scheduler, I/O subsystem, and network stack are heavily optimized for throughput. |
| Community size | More users, more answers, more packages, more drivers. |

### What BSD is good at

| Strength | Why |
|----------|-----|
| Real isolation (jails) | Not containers sharing a kernel — actual isolated userlands with their own process trees. |
| bhyve | Hardware-level VM isolation. Every VM is built from individual components. Hardware is a text file. |
| Simplicity | One base system. One package manager. One way to configure services (`rc.conf`). One ports tree. |
| Security model | Capsicum capability framework, pledge/unveil-style sandboxing, conservative defaults. Base system is audited as a whole. |
| ZFS (native) | First-class citizen since 2007. No DKMS. No kernel module dance. Just there. |
| Documentation | The FreeBSD Handbook is the gold standard. Everything is documented, organized, and correct. |
| Stability | Release engineering is conservative. Things don't break between updates. |

### The bridge

kldloadOS sits in the middle:

- **ZFS on root** — makes Linux feel like BSD to storage people
- **WireGuard in the kernel** — same simplicity as BSD's network stack
- **eBPF** — the one thing BSD genuinely lacks
- **`kpkg`** — one package manager, like `pkg` but for both Debian and CentOS
- **Offline darksites** — ship your artifacts in a bootstrapped ISO, like building from ports
- **Boot environments** — `beadm`/`bectl` equivalent on Linux
- **Core profile** — just ZFS on root, stock distro, nothing added — the BSD philosophy applied to Linux

You don't have to choose one forever. Use Linux where you need hardware support, eBPF, and NVIDIA. Use FreeBSD where you need real isolation, bhyve, and simplicity. Use kldloadOS when you want the best of both — ZFS on Linux with the tools to actually use it.

---

## The point

Linux and BSD are apples and pitchforks. Don't expect BSD-level isolation from Linux containers. Don't expect Linux hardware support from FreeBSD. They're different tools built on different philosophies — and that's the point. Learn the limitations of each. Use them together with purpose.

And don't expect OpenZFS to magically fix your problems. Every workload is different. The defaults are just that — defaults. If you don't understand how to tune recordsize for your database, or when to use zstd over lz4, or why your ARC is eating all your RAM — you're going to have a bad time. Not because ZFS is wrong, but because your expectations are. ZFS gives you the knobs. Learning which ones to turn is on you.

Code is free. Code is what you make of it. If you want to pay for a tool, a service, or a function — that's your choice. But there should be no incentive for companies to charge $999/month for a WireGuard config file wrapped in a UI.

kldloadOS includes everything you need to build secure-by-default environments on hostile hardware in a way that wasn't previously possible on Linux. Secure networking, eBPF observability, ZFS replication, boot environments — these are core required components, not optional bolt-ons.

Do you want to pay for it, or build it? kldloadOS gives you the option to actually choose.

If you like shiny enterprise dashboards and don't mind the bill — go for it. But if you want to understand how the machine actually works, and build something that's yours, with no strings attached — the tools are here. Free. Open source. Auditable.

**Learn the primitives. Understand the real computer. Because if it leaves the kernel — it's dead.**

---

## A few words from Anthony

I've been a staunch supporter of free and open source since before Wikipedia was built. I've been deprived of useful tools because of licensing squabbles for years. My answer to that has always been: get better, learn how, and teach others.

Every tutorial, every recipe, every one-liner in this project is the result of that answer. 70,000+ pages of personal notes. Decades of running real infrastructure. Distilled into something you can boot from a USB stick in two minutes.

It's yours. Do what you want with it.

ZFS on Linux is going to enable awesome things. The tradeoff of a monolithic kernel is real — slower replication, higher overhead than FreeBSD. But the hardware support is unmatched, the ecosystem is massive, and understanding that cost makes you a better engineer.

The shift from "log into every machine and fix things" to "snapshot, replicate, rebuild" changes everything. Cattle, not pets. I'm just happy that anyone can now run OpenZFS on Linux, using only their nose. Getting the most out of nothing. That's always been the game.

And I can't wait to see what's next.

A scene release done right.

Built by someone who's been assembling disc images since before ISO 9660 had a Wikipedia page. BBS sysop, scene contributor, one of the original Threewave CTF server operators — Vancouver, 604, early '90s. The darksite concept isn't new. Self-contained packages with no external dependencies have been the standard in certain communities for thirty years. The tools changed. The philosophy didn't.

— Anthony
Blackthorn · 604 · kldload.com · 2026
