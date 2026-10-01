# ZFS Lab edition — design brief

Status: **BRIEF** (2026-09-30), written to be designed from. Nothing here is
built. It records what was decided in conversation, what already exists in
the tree (with paths, checked on the day), the gaps, and the open decisions.
Occasion: kldload has a slot at the OpenZFS summit for kldload and the ZFS
test suite.

## 0. Delivery model (operator, 2026-09-30, supersedes where it conflicts)

One engine, two deliveries, one plan format:

1. **The fifth ISO is a self-driving test appliance.** Boot it on the
   machine under test. It asks the basics (which disks it may wipe, which
   plan: a preset such as "same kernel and ZFS across every distro" or your
   own lines, where results go), then runs the plan unattended, using the
   reinstall as the loop:
   1. the live system takes the next plan item and installs it (distro,
      kernel, ZFS version, extra modules such as NVIDIA, tools such as the
      LSI/Broadcom utilities);
   2. it sets `BootNext` to the installed disk and reboots;
   3. the build's first boot runs the suite, writes results off the disk
      under test, sets `BootNext` back to the stick, reboots;
   4. the live system records the result and takes the next item;
   5. at the end, a report and power-off.
   The plan and results live on a writable partition of the USB stick
   (`kldload burn` creates it), so no second machine is needed. A build
   that does not boot comes back to the stick through the firmware's
   fallback and is recorded as "did not boot": a result, not a dead box
   (build 166's bootloader, 2026-09-30, is exactly that case).
2. **Fleet mode:** a lab host serves the same plan over netboot to any
   number of benches with power control, and collects the results
   centrally (sections 10 and 12).

### Dispatch: plans to benches (operator, 2026-09-30)

Arm many benches with their workloads, press go. Four modes, one plan:

| Mode | Operator says | Behaviour |
|---|---|---|
| pinned | "server 1 gets this, server 2 gets that" | each item to its named bench; all arm at once and run in parallel |
| pool | "these items, these benches" | a queue drained by whichever bench is idle; scaling is adding boxes |
| single | "all of them on this one" | the items in order on one bench, each from a wiped disk (what the appliance ISO does alone) |
| every | "this item on all my benches" | one build across different hardware; the diff between benches is the hardware |

Rules: only enrolled MACs can be armed (abyss); per-bench state idle /
installing / testing / reporting / off / failed; a dead bench is a failed
item, requeued once in pool mode and never forever; power records make a
bench cold-to-cold, otherwise it waits for a button; results are keyed by
build AND bench. Already present: `kldload-netboot-server arm-all <dir>`
arms many MACs from per-MAC answers files, and `tests/estate-sweep.sh` runs
the per-bench loop serially on one MAC. The dispatcher is the layer between
them: plan to per-bench answers, then one sweep loop per bench.

Plan lines, for example:
```
fedora 44  kernel=7.2  zfs=2.4.4  modules=nvidia  tools=lsi  suite=full
*          kernel=7.2  zfs=2.4.4                             suite=quick
```
Impossible pairs are refused at the question stage: ZFS 2.4.4 declares a
kernel maximum of 7.2 (read from its package's Conflicts on 2026-09-30), so
"2.4.4 on 7.3" is offered as 2.4.4 on 7.2 or master on 7.3, never started.

Adds to the build list: `BootNext` handoff with fallback; the results
partition on the stick; hardware extras as plan fields; the kernel axis
(phase 4) and the refusal logic move onto the question screen. The
single-machine appliance is the headline of the download and the easier
summit demo (one stick, one machine, a report); fleet mode is the scale-out.

## 1. What it is

*Checked 2026-09-30 against openzfs/zfs `.github/workflows`:* upstream CI
(`zfs-qemu.yml`) runs on GitHub-hosted Ubuntu runners, each booting a QEMU
VM from a vendor cloud image (AlmaLinux 8/9/10, CentOS Stream 9/10, Debian
11-13, Fedora 43/44, Ubuntu 22/24/26, FreeBSD 14/15/16; Arch and Tumbleweed
available), building the PR and running ZTS, with a manual Fedora kernel
version input and per-step time limits; plus `zloop` (ztest), package
builds, ARM, unit tests and static analysis. So distro breadth and real
distro kernels are already covered. kldload's distinct ground is: ZFS as
the root and the boot path, real hardware, the failing machine kept, a
pinned package set, and multi-boot life cycles. Do not claim more.

A fifth download, dedicated to testing OpenZFS. The operator picks a
distribution (and its release), a kernel and a ZFS version; kldload **builds**
that exact combination as a real installed system with root on ZFS, seals it
as a golden, and runs a tuned test suite against it. Two builds that differ
in one axis are blue and green, and the report is the difference between
them.

The product is the **build**, not the clone. A golden is one unique
combination under test, not a template stamped out many times. Cloning
survives only as a safety detail: each test run gets a throwaway copy of its
golden, so a test that wrecks the root does not cost the build, and a run can
be repeated against the identical starting point.

Nothing like it exists. CI runners boot a kernel they did not choose, with
root on ext4 or xfs, and run the suite on file-backed pools; they cannot test
ZFS as the filesystem a machine boots and runs from, and cannot run the parts
of the suite that manipulate the filesystem under the running system (the gap
an OpenZFS developer described, see memory note on the 2026-09-17 call).
Nobody builds actual distributions per ZFS version and kernel, blue/green
tests them, and runs the suite against each.

The one-line pitch: *the ZFS test suite tells you whether ZFS works; kldload
tells you whether a machine running on ZFS survives.*

## 2. The user flow

1. Fill in the boxes: distros (as many as are supported), each distro's
   release, kernel, ZFS version, optional extras (modules, packages,
   post-install script, ARC size), test tier, fidelity tier. Assign each
   build to blue or green.
2. Press one button.
3. Every combination not already built is built (installed by the kldload
   installer into a VM, root on ZFS) and sealed. Builds are cached by their
   combination; asking again reuses them.
4. The suite runs against each build, on a throwaway copy.
5. Results land in the ZFS Lab Grafana: matrix, live run, history, and the
   blue/green regression diff. A failing run's machine is kept as a snapshot
   that can be handed to someone.

## 3. What already exists (verified 2026-09-30)

| Piece | Where | Note |
|---|---|---|
| Four downloads: full, Fedora workstation, net, core | website `download.html`; `deploy.sh` (`PROFILE`, `EDITION`, `PAYLOAD=full|net`) | the fifth slots in beside them |
| Goldens per distro, instant clones, blue/green deploy / promote / rollback, run the suite, results | `usr/local/bin/klab` (`golden-ztest`, `deploy blue|green`, `test --quick|--full`) | **overlaps** `kzfs-lab` and `kzfs-test`; three tools doing one job |
| Blue/green for ZFS dev specifically | `usr/local/bin/kzfs-lab` | same concept as klab |
| Parallel suite across distros | `usr/local/bin/kzfs-test` | same again |
| Golden = base + your own script, sealed | `usr/local/bin/kvm-golden` (`--post FILE`, `--run`) | the post-install idea exists, for goldens only |
| Install kldload itself headless into a KVM VM (UEFI, answers file, any distro/profile) | `tests/lifecycle.sh` (`deploy.sh smoke-test`) | this is the root-on-ZFS build path; it just never seals the result |
| `zfslab` template and lab-profile handling | `usr/local/sbin/kldload-autoinstall` (`KLDLOAD_TEMPLATE`), `usr/lib/kldload-installer/lib/profiles.sh` | exists as a template of the kvm profile |
| Kernel ceiling derived from a ZFS release (`META: Linux-Maximum`) | `tools/zfs-kernel-pin` | the basis for refusing impossible combinations |
| Released vs testing track (newest kernel, ZFS from git) | `docs/zfs-track-selector.md` | designed, not built |
| NVIDIA drivers | answers `KLDLOAD_NVIDIA_DRIVERS=auto|1|0` | |
| Extra packages | answers `KLDLOAD_EXTRA_PACKAGES=` | a failure is **logged, not fatal** today |
| ARC sizing | installer writes `zfs_arc_max` (`bootloader.sh`, `profiles.sh`, `storage-zfs.sh`) | automatic, not an input |
| Guest double-caching analysis | `klab` (the ZFS-on-ZFS note near `_golden_volblock`) | memory side only |
| ZFS test dashboards | `var/lib/grafana/dashboards/zfs-test-lab/`: Run Matrix (9 panels), VM Debug (7), Live Test Bench (27), Test Lab Metrics (56) | four overlapping boards |
| Storage dashboards | `.../dashboards/storage/`, `.../zfs/`: pool health, compression, scrub history, block I/O latency (eBPF) | keep |
| Exporters | `klab-exporter` (golden kernel + ZFS versions, blue/green, run counts), `arcstats-exporter`, `zpool-scrub-exporter` | man pages exist for each |
| Terminal console / GUI | `kld/` (Go TUI), `vmxplore` | Image Factory tab designed, not built |
| Physical installs over the network | netboot pipeline, `tests/estate-sweep.sh` | the hardware tier |

## 4. Gaps

1. **klab's goldens are not root-on-ZFS.** They are built from each distro's
   cloud image (`klab`, the image URL table): root is ext4/xfs, ZFS is a
   package, and the suite runs on loopback files. That is what CI already
   does. The differentiating golden is the kldload installer installing the
   distro with root on ZFS inside a VM (`lifecycle.sh`'s path) and sealing it.
2. **No way to choose the ZFS version.** Goldens get whatever their repos
   carry. Needed: build OpenZFS from a release tag (or any git ref) into
   packages, cached per distro family, installed by the build.
3. **No way to choose the kernel.** The installer derives and pins it.
   Needed as an input, with the pin logic turned into validation.
4. **The installer takes no post-install script,** and extra packages fail
   soft.
5. **The host throws its mirrors away.** Firstboot's `_darksite_reclaim`
   deletes the offline mirrors after install. A lab host needs them to build
   goldens later, offline.
6. **Three overlapping tools and four overlapping dashboards.**
7. **No per-test result history,** so no regression diff and no flaky-test
   view.

## 5. Build inputs (the installer grows these)

| Input | Proposed answers field | Rule |
|---|---|---|
| Distro and release | existing `KLDLOAD_DISTRO` + a release field | e.g. Rocky 9 or 10, Ubuntu 24.04 or 26.04 |
| Kernel | `KLDLOAD_KERNEL=` | stock, a named version, or "newest"; validated against the ZFS version's declared range **before** building |
| ZFS version | `KLDLOAD_ZFS_VERSION=` | a release tag, or a git ref for unreleased code (pull-request testing) |
| Extra kernel modules | generalise `KLDLOAD_NVIDIA_DRIVERS` | NVIDIA and any other DKMS module, so conflicts surface: build order, rebuild on kernel update, initramfs size |
| Extra packages | `KLDLOAD_EXTRA_PACKAGES=` | **fatal on failure** in a test build: a build missing a package is not the build that was asked for |
| Post-install | new: one hook inside the target before first boot, one at first boot | a script path |
| ARC | new `KLDLOAD_ARC_MAX=` | a fixed size so runs are comparable |

Every build records its full provenance with its results: distro, release,
kernel, ZFS version and source, packages, modules, ARC, host settings and
fidelity tier.

A combination the ZFS version cannot build against is refused in the form,
greyed out, never discovered ten minutes into an install. `zfs-kernel-pin`
already reads the declared range.

**Where kernels come from is the hardest input.** The offline mirrors carry
only the pinned kernel per distro. Arbitrary kernels need either the network
(Fedora's build system, Ubuntu mainline builds, ELRepo for EL) or a curated
set of kernels baked into the edition. ZFS versions are easy by comparison:
source tarballs are small and build anywhere.

## 6. The test suite

The OpenZFS suite (`zfs-tests.sh`, ZTS) already takes runfiles and tags, and
its report script already carries known-failure lists. Tuning means curating,
not writing a framework.

1. **Tiers.** *smoke*: minutes; the build, module and pool work. *quick*: the
   areas people actually break: send/recv, encryption, dRAID, raidz,
   snapshots, zvols. *full*: everything.
2. **Sharding.** Copies of a golden are nearly free, so the full suite splits
   by tag groups across several copies of the same build and runs at once.
   Wall time falls roughly by the shard count. This is still one build under
   test.
3. **Per-distro known failures,** maintained, so red means new breakage and
   not known noise. This is what makes the blue/green diff trustworthy.
4. **A root-on-ZFS suite of kldload's own,** testing what ZTS cannot from
   inside a running system. Each test reboots a copy and checks it came back:
   - booting from this ZFS version;
   - the initramfs importing and unlocking an encrypted root;
   - a kernel update with the module rebuilt, then reboot;
   - rolling back to a boot environment and booting it;
   - upgrading ZFS under a live root, then reboot;
   - ZFSBootMenu selecting a boot environment.

Naming is unsettled: `ztest` is also a separate OpenZFS stress binary, while
the big suite is ZTS. klab's verb `golden-ztest` borrows the former while
installing for the latter. Confirm with the OpenZFS testers which they mean.

## 7. Fidelity: ZFS on ZFS

A guest's disks are zvols on the host, so the host's ZFS sits under the
guest's. **For correctness this mostly does not matter** (ZTS does not care
what is under a vdev; CI uses files). **For anything timing-, cache- or
device-dependent it pollutes results:**

1. **Double caching.** Guest reads are served from the host's ARC; the
   guest's disk is unrealistically fast, which hides latency-dependent bugs
   and makes performance numbers meaningless.
2. **Timeouts.** The host's own write flushes add latency spikes; tests with
   timeouts fail for the host's reasons, which is exactly the noise that
   makes a blue/green diff lie.
3. **Device behaviour.** Sector size (and so ashift), TRIM passthrough and
   flush semantics all come from the virtual disk settings. One wrong setting
   ("unsafe" caching, which ignores flushes) silently invalidates every crash
   consistency test.
4. **Compression and copy-on-write underneath** distort space accounting and
   write patterns.

**Three tiers; every result is labelled with its tier:**

| Tier | Root disk | Test disks | Good for |
|---|---|---|---|
| functional | host zvol | host zvols, tuned: host `primarycache=metadata`, host compression off, no host page cache (`cache=none`, `io=native`), honest logical/physical block sizes, discard passed through | correctness; cheap |
| device | host zvol | whole disks or NVMe passed straight to the VM, bypassing host ZFS | performance, TRIM, flush behaviour |
| hardware | the same build netbooted onto a physical machine | real | firmware, controllers, real boot |

The root on a host zvol is fine in every tier: root-on-ZFS tests are about
booting, importing and unlocking, not speed. What must not sit on host ZFS is
whatever the suite measures. A functional-tier failure on a timing test is
re-run at device tier before anyone calls it a regression.

## 8. Grafana: the ZFS Lab folder only

This edition provisions the ZFS boards and nothing else. The Kubernetes,
Cilium, Tetragon, estate and eBPF-story folders are not installed.

- **Matrix:** distros × ZFS versions × kernels, pass/fail/skip per cell,
  blue beside green.
- **Run:** live progress, the test executing now, per-VM resources, log tail.
- **History:** per-test duration trends, flaky tests (both outcomes on the
  same inputs), and the regression list: passed on blue, failed on green.
- Keep: pool health, ARC, block I/O latency; during a run they explain why a
  test was slow.

The four existing test boards merge into these three.

**Per-test results do not go into Prometheus**: thousands of test cases
across every run is a cardinality problem. One Loki line per test, labelled
run, distro, release, kernel, ZFS version, site, tier, result, duration.
Prometheus keeps counts; History and the regression diff query Loki. Both are
already in the stack.

## 9. The edition

The download is the lab **host**, not the machine under test. The kvm
profile already ships the netboot server (`kldload-netboot-server`, the one
onyx installs fiend with), so one install gives both tiers from one machine:
VM builds locally, hardware builds by netbooting whatever benches are cabled
to it. A bench is never installed by hand; the lab host is the only USB
install, and it is done once.

- kvm profile, `zfslab` template, the terminal console (`kld`), full offline
  payload, the netboot server armed for the benches.
- **No separate netboot.** The netboot server's assemble menu already offers
  profile, then distribution, then security; `zfslab` is one more profile in
  it, and the lab arms a bench with a lab answers file the way the sweep
  arms fiend. The only addition is the ZFS package cache served beside the
  darksite.
- The host **keeps** its offline mirrors (skip `_darksite_reclaim` on this
  edition) so builds work offline, and a set of OpenZFS release tarballs is
  baked in.
- The installer builds the base goldens needed to start at first boot.
- One engine: klab. `kzfs-lab` and `kzfs-test` fold into it or become
  aliases.
- The form lives in `kld`.
- Website: the fifth card on the download page; R2 artefacts under their own
  key; release invariant as for every edition.

## 10. The build loop (decided 2026-09-30)

One idea makes the two tiers one pipeline: **a build is an answers file.**
kldload already installs from one in two ways: `tests/lifecycle.sh` boots the
ISO in a VM, writes an answers file, installs headless and reboots; and
`pxe-arm` + the netboot server install a physical machine from the same kind
of file (the nightly sweep rebuilds fiend this way). Add the lab's fields to
the answers file and both tiers get them.

### The spec is a queue, and hardware runs it one item at a time

Serial, one build on the bench at a time, rebuilt from a wiped disk each
time. This is what `tests/estate-sweep.sh` already does with editions:

- **The install is the teardown.** Nothing survives a reinstall, so there is
  no cleanup step to forget or half-do. Every build starts from nothing.
- **One machine, one result.** No neighbour competing for disks, cache or
  CPU: every number belongs to the build under test, which is the point of
  the hardware tier.
- **The only step that must succeed before teardown is pulling the results.**
  Bundle off, landed and verified, then the next arm. A failed pull stops the
  queue with the machine intact and powered off, to be looked at.

VMs are where breadth runs in parallel, since clones are free. Same spec.

Each queue item is one line, and becomes one answers file:

```
distro=debian release=13 zfs=2.4.5 kernel=stock site=green
packages="fio bpftrace"          # fatal if any is missing
modules="nvidia"                 # extra DKMS modules, for conflicts
post-install=hooks/debian.sh     # in the target, before first boot
first-boot=hooks/suite.sh        # at first boot: the suite, then "done"
arc=4G suite=quick tier=device
```

Blue and green are two lines that differ in one field; the diff is computed
from their two bundles afterwards.

### The hardware loop, per item

1. `kldload-power on` (or `pxe-once` + `cycle` when the box is up); the
   sweep's `power_kick` already does this.
2. `pxe-arm` the bench with the item's answers file; the netboot server
   serves the darksite **and the lab's ZFS package cache** over HTTP.
3. Unattended install; first boot runs the post-install hooks and, as the
   last autodeploy phase, the suite; the machine publishes "done".
4. The controller pulls the bundle (the sweep's redacted bundle plus the
   per-test result lines), verifies it landed.
5. `kldload-power off`, read back as Off.
6. Next item.

A stuck iPXE loop gets a cycle; a box that never reports gets a bounded wait
and a failed report; both exist in the sweep today.

### The VM loop, per item

`lifecycle.sh`'s flow with the disk on a zvol under `rpool/vms/`, sealed
(`kldload-seal`, `@golden`) and named by its combination, so a repeated
combination is not rebuilt. A run clones the golden (throwaway), attaches
test disks per fidelity tier, runs the suite, keeps a failing clone's
snapshot.

### The ZFS-version axis

"Version X" means packages, not a repo. The **package factory** is a
container per family (`fedora:44`, `debian:13`; built 2026-09-30): check out
the tag or ref (a pull request is just a ref), take the build dependencies
from the package's own spec or control file (`dnf builddep` on the source
RPM, `mk-build-deps` on the control), `make rpm-utils rpm-dkms` or
`make native-deb-utils`, write the repository metadata (`createrepo_c`,
`dpkg-scanpackages`), cache at `pkgs/<family>/<release>/<zfsver>/`. DKMS
packages need no kernel, so the kernel stays an axis of its own, and a
container needs no KVM, so the factory runs on a laptop. Built once, reused.
2.4.4 took about eight minutes per family on onyx and produced `zfs-dkms`,
`zfs-test` (the suite from the same ref) and the utilities.

The installer gets one field, `KLDLOAD_ZFS_SOURCE=<url>`. On RPM targets
it is a repo at `priority=1`, which wins even when its version is older than
the mirror's (dnf otherwise takes the newest across every repo; proven both
ways in a container). On deb targets it is a flat repo pinned at 1001 by
origin, and the packages asked for become `openzfs-*`: OpenZFS's native
Debian packaging Conflicts with the distro names rather than Providing
them. The netboot server already serves directories over HTTP, so the same
field works on a bench. This one piece of plumbing serves both tiers.

klab's cloud-image goldens are not part of this; the installer's goldens are
the subjects and the containers are the factory.

### Results

Every `[PASS]/[FAIL]/[SKIP] tests/functional/...` line becomes one Loki
record labelled build, site, tier, test and duration (klab's runner already
greps these lines for its summary). Prometheus keeps counts (klab-exporter
already knows goldens, sites and totals). Matrix, history, flaky tests and
the blue/green diff are Loki queries.

### Phasing

| Phase | Delivers | Proves |
|---|---|---|
| 0. Factory + source field | ZFS packages from a tag via a klab builder; `KLDLOAD_ZFS_SOURCE`; `lifecycle.sh` installing Fedora root-on-ZFS with 2.4.4 and 2.4.5 | the axis works end to end on the cheapest path |
| 1. Golden + run | zvol + seal; run harness; per-test Loki lines; blue/green diff | a regression report from two real builds |
| 2. Hardware loop | the queue through the sweep's loop on fiend, cold to cold | the thing nobody else has |
| 3. Product | post-install hooks in the installer; `kld` form; Grafana folder; the edition (keep mirrors, tarballs baked in, netboot armed, website card, R2) | the fifth download |
| 4. Kernel axis | `KLDLOAD_KERNEL`; koji / mainline / ELRepo sources; impossible pairs refused via `zfs-kernel-pin`'s ceiling | kernel × ZFS |

Phase 0 is days and is the demo's spine; 0 to 2 are the summit story.

### Open for fiend

- **Its power controller.** The only power record today is abyss,
  status-only. fiend needs one for "on" from cold: a BMC, or a switched
  outlet plus Wake-on-LAN (WoL alone cannot choose the boot device; the
  netboot arming decides that).
- **Its sacrificial disks.** One disk takes the install; the device tier
  wants real spare disks for the suite. Which ones.

## 11. Suggested order toward the summit

1. The edition: build flag, keep mirrors, website slot, R2. *Small.*
2. ZFS from a tag into a per-family package cache. *Moderate; the core of
   "version X".*
3. Root-on-ZFS goldens: `lifecycle.sh`'s install path plus seal, with the
   build inputs of §5. *Moderate; the headline.*
4. Spec, run, results, blue/green diff, Loki results, the three boards.
   *Moderate.*
5. The form in `kld`. *Moderate.*

1, 2 and 4 alone already beat CI on ergonomics; 3 is what nobody else has.

## 12. The thesis for the summit

*Built* is in the tree today; *planned* is in this brief. Claim only the
first kind as running.

### Two paragraphs

OpenZFS's CI is serious: every pull request is built and run through the
suite in QEMU VMs on about fourteen systems, FreeBSD included, from the
vendors' cloud images. But every one of those VMs boots from ext4 or xfs and
tests ZFS on pools made of files. That covers ZFS the code. It never touches ZFS the system: the module that
has to build and load before the root exists, the initramfs that has to
import and unlock it, the kernel update that has to rebuild it, the rollback
that has to boot. Those are the paths that break for users, and no runner
can exercise them, because a runner cannot test the filesystem it is running
on. kldload closes that gap: an installer that builds real distributions with
ZFS as the root, offline and reproducibly, on every substrate you support,
including the RHEL kernels that claim to be 4.18. Point it at a version of
ZFS, a kernel and a distribution and it builds that exact machine from
nothing, runs the suite on it, and can hand you the machine at the moment a
test failed.

The second half is hardware. A bench cabled to the lab host is powered on,
netbooted, installed from a wiped disk, tested, reported on and powered off,
one build at a time, so every result belongs to that build and nothing from
the last one survives. Add benches and the queue spreads across them: ZFS
tested against any amount of hardware, around the clock, with nobody in the
room. Blue on 2.4.4, green on 2.4.5, on the same real disks, and the report
is the difference between them. Not a faster CI: a test bed where a build is
a text file, a machine is disposable, and real hardware is one line in a
queue.

### What it excels at

1. **ZFS as the root filesystem, not a package** (built: the installer;
   planned: version choice). Boot, initramfs import, encrypted unlock, module
   rebuild on kernel update, rollback: testable. *"Does 2.4.5 still boot an
   encrypted root on Rocky 10 after a kernel update?" is a queue line, not a
   bug report.*
2. **Real hardware as a disposable resource** (built: netboot, power
   control, the nightly loop on fiend; planned: the lab queue). Wiped disk,
   install, test, report, power off. *A bug that needs a real NVMe's flush
   semantics, invisible on loop files, reproduced cold to cold on demand.*
3. **Any amount of hardware, 24/7** (built: the pieces; planned: the queue
   across benches). Every bench with a power record is a worker; the queue
   is drained by whatever is idle; a bench that dies is a failed report, not
   a stopped lab. *Ten cheap boxes of different vintages run the release
   candidate all weekend and the matrix is waiting on Monday.*
4. **Attribution over speed** (built). Offline mirrors make a build an exact
   package set; a failure maps to a byte-identical install. *An intermittent
   failure comes with the snapshot name of the machine the moment it failed,
   to hand to someone.*
5. **Blue/green as a regression diff** (built in klab for cloud goldens;
   planned for root-on-ZFS builds). *2.4.4 vs 2.4.5 on five distros; the
   output is only the tests that passed on blue and failed on green, known
   per-distro failures subtracted.*
6. **A build is a text file** (built: answers files drive every install;
   planned: the ZFS and kernel fields).
   `distro=debian release=13 zfs=2.4.5 kernel=stock site=green`
   *A maintainer pastes a PR's ref into that line and it is built and tested
   on every distro before merge.*
7. **Every substrate, including the ones that lie** (built). Nine
   substrates, the RHEL family among them. *A configure check that
   version-tests instead of feature-tests fails here on Rocky before it
   fails in the field.*
8. **Instant disposable machines for breadth** (built). Clones in about
   0.2 s. *The full suite sharded across copies of one build, at once, on
   one host.*
9. **Kernel × ZFS, impossible pairs refused** (built: the ceiling check in
   `zfs-kernel-pin`; planned: kernel as an input). *Kernel 7.1 greyed out
   for a release whose maximum is 7.0, not discovered mid-install.*
10. **Observability already wired** (built). Prometheus, Grafana, Loki; ZFS
    pool, ARC, scrub and eBPF block-latency boards. *A test that got slow on
    green has the ARC and latency graphs from the same minute beside it.*

### Hardware compatibility is the bench's second job

Every run is a fresh install onto whatever is in the box, with a chosen
kernel and a chosen ZFS, so the bench is also a hardware rig. The matrix
gains a column: **hardware × kernel × ZFS**. Two benches with different HBAs
run the same spec line; the diff between them is the hardware.

- **HBAs and controllers.** An LSI/Broadcom card is a driver (`mpt3sas`), a
  firmware, and how it answers flushes and resets under load; the three
  interact with the kernel version and surface as scrub timeouts or I/O
  errors that never happen on a laptop. "Works on 6.12, resets under 7.2"
  becomes a row.
- **Disks and NVMe.** Real flush and TRIM semantics, real sector sizes (the
  ashift choice), firmware quirks, SMART during the run (the disk-health
  board already reads it).
- **Memory.** Long runs are when EDAC reports corrected errors; the
  kernel-messages board collects them. "This bench threw corrected errors
  during the test that failed" answers "flaky test or flaky box".
- **NICs, firmware, Secure Boot.** The netboot install is the first test: a
  box that cannot PXE, sign the module, or boot ZFSBootMenu fails before the
  suite starts, and that is a finding.

Limits: the suite is correctness, not stress; "survives a week of scrubs"
is a workload tier (`fio`, repeated scrubs, resilver with a pulled disk;
the tools ship, it is another hook in the queue line). And the bench finds
and reproduces; it does not diagnose. What it hands a vendor or the kernel
list is what they ask for and rarely get: exact kernel, firmware and ZFS,
an identical reinstall that reproduces it, and the logs from that minute.

### eBPF: the failing machine is kept, and it was being watched

Every build carries bcc, bpftrace, libbpf-tools, the eBPF exporter (block
I/O latency, bio tracing), Tetragon and the kernel-forensics boards, because
the profile ships them. So a `[FAIL]` line points at a minute that already
holds per-disk latency histograms, the test process's syscalls and the
kernel messages; nobody reproduces it to start reading.

- **ZFS's own functions are traceable.** It is a module with symbols:
  `bpftrace` hooks `zio_*`, `dmu_*`, `arc_*`, txg sync, `zfs_write` return
  values. "Which call returned EIO, from which stack, at which offset" is a
  one-liner on the real hardware.
- **Hardware and software stop hiding behind each other.** One trace shows
  whether a stall was ZFS waiting on the disk (block-layer latency) or the
  disk waiting on ZFS (txg sync holding writers).
- **The bundle exists.** `klab-vm-debug-bundle` already captures kernel
  stacks, dmesg, zpool events, arcstats and dbgmsg for a failed run; the
  eBPF captures for the failing test's window are its natural extension.

Two tracing tiers, so the tracer does not pollute results: **always on, low
overhead** (the exporters' histograms and counts, on every run, what fills
the panels), and **deep trace on rerun** (a failed test re-run on the same
build with the heavy scripts attached; timing tests are never measured with
a tracer on every function).

The goal is that a failure arrives as a package: build, hardware, trace,
machine. The first two days of every hard bug (reproduce it, instrument it)
are the part this removes; the "why" still needs a mind on it.

*CI gives you a red X. This gives you the machine, the disk latency, the
syscalls and the ZFS call stack from the second it went wrong.*

### The one line

CI tells you whether ZFS works. This tells you whether a machine running on
ZFS survives, on real hardware, from a text file, with the failing machine
kept for you.

### The ask to the room

Which first: a PR on every distro before merge, the root-on-ZFS boot suite,
or hardware reruns of flaky tests? That picks the summit demo.

## 13. Scope review (2026-09-30)

What the sections above miss, found by reading them against the tree.

### Add

1. **Benches are enrolled, never guessed.** The queue wipes disks. A MAC
   must be on an explicit bench list before `pxe-arm` will take a lab
   answers file for it; every other machine is refused. abyss is the
   reason this rule exists (`project_abyss-never-install`): a lab that can
   netboot must not be able to install a production box by typo.
2. **The suite comes from the same ref as the ZFS under test.** The package
   factory builds the test package (`zfs-test`) from the same checkout as
   the module and utilities. A 2.4.5 suite run against 2.4.4 tests the wrong
   thing and reports it with confidence.
3. **Upstream's known failures, not a private list.** ZTS ships
   `zts-report.py` with per-platform known and maybe-failing sets. Use it as
   the baseline and layer kldload's per-distro additions on top, so the
   blue/green diff subtracts what upstream already expects.
4. **A flaky-test classifier.** A failed test is re-run N times on the same
   build (VM: fresh clones; hardware: same box) before it is called a
   regression. "Hardware reruns of flaky tests" is one of the three asks in
   §12; this is it.
5. **Two more build axes the sweep already has:** encrypted root (0/1) and
   Secure Boot (0/1; needs MOK enrolment and netboot with SB off, proven
   2026-09-13 on 6-full-secure). Both are boot paths CI cannot test, so both
   belong in the spec line.
6. **A scheduler, for 24/7.** A queue drained by idle benches is not enough
   on its own; the standing job is "upstream master, nightly, every bench",
   plus on-demand items ahead of it. One timer, one queue, priorities.
7. **Results are a dataset.** Runs live under `rpool/lab/results/<run>`,
   snapshotted when complete, replicable with `zfs send` (the fiend DR
   pattern). The lab host is otherwise the only copy of every result.
8. **Retention.** Goldens per combination and kept failing snapshots eat the
   pool. A policy: keep the last N goldens per distro, every failing
   snapshot until its run is closed, prune on a timer, report space on the
   Run board.
9. **Workload tier.** Beyond correctness: `ztest`/`zloop` (upstream's own
   stress tools), `fio` profiles, repeated scrubs, a resilver with a pulled
   disk. Another hook in the queue line; the tools ship.
10. **Notification and hand-off.** A run ends in a report URL at minimum. For
    PR testing the integration that matters is a GitHub check on the PR;
    design it, ship it after the summit.
11. **Time budget, stated.** From day-165: a fiend install is about ten
    minutes, first boot for a lab template should be under fifteen, and the
    full suite is about two hours. A bench does three or four full runs a
    day, or about twenty quick ones. Write the numbers on the form so the
    queue's promise is honest.

### Confirm

- **VM tier first, hardware second, kernel axis last** stands. The VM tier
  must be excellent alone: most developers have a laptop, not a bench.
- **Serial per bench, parallel across benches and in VMs** stands.
- **Trust is the product.** One false regression loses the room; the
  known-failure baseline, the flaky classifier and the fidelity labels are
  the load-bearing parts, and they come before the form and the boards.

### Out of scope, said aloud

- FreeBSD (OpenZFS runs there; kldload does not install it). Worth naming
  in the room, since FreeBSD people will be in it.
- arm64.
- Multi-user access to the lab host: single operator, the console sign-in.

### The summit cut

Phases 0 to 2, plus items 1, 2, 3 and 4 above, plus the eBPF bundle for a
failed test. Kernel axis, scheduler, GitHub check, workload tier, retention
and the form come after.

## 14. Open decisions

00. **Debian needs Debian's packaging, not OpenZFS's (found 2026-09-30).**
   Phase 0 on Fedora is proven: a VM install took zfs, zfs-dkms and
   zfs-dracut 2.4.4 from the lab's own build (build host = the factory
   container), module 2.4.4 loaded, root on rpool, smoke 61/0. On Debian,
   OpenZFS's native `make native-deb-utils` packages (`openzfs-*`) installed,
   then the profile's `sanoid` (Depends: zfsutils-linux | zfs-fuse) was
   satisfied with zfs-fuse, which Conflicts with openzfs-zfsutils, so apt
   REMOVED the real ZFS userland and zed and never installed the initramfs
   package; the rebuilt initramfs had no ZFS and the machine dropped to
   BusyBox ("bad address 'zfs'"). The openzfs-* names do not Provide the
   distro names. Factory decision: on Debian/Ubuntu rebuild Debian's own
   source package (zfs-linux) at the chosen upstream version, so the
   packages are zfsutils-linux, zfs-dkms, zfs-initramfs, zfs-zed and every
   dependent keeps working; keep openzfs-* only as an explicit variant.
   Also: in lab mode pin zfs-fuse to -1 so a substitution can never be
   silent again.
   Side finding, same evening: the kernel command line after ZBM ends with
   `spl.spl_hostid=0x00bab10c`, appended by ZFSBootMenu, while the
   installer's spl_hostid pin is absent from it: the reason a fresh
   install's first-boot session stamps the pool 0x00bab10c.

0. **The suite beside a live root pool (verify first).** On bare metal the
   machine's root is itself a ZFS pool, and ZTS creates, imports and exports
   pools on the spare disks. Check the suite's source for anything that acts
   on every pool (import or export of all pools, pool-wide cleanup) before
   promising bare-metal runs; tests that must touch the running system's
   pool belong to the root-on-ZFS suite (a disposable build, rebooted).
   Hardware mode is VM-free and ZFS-on-root throughout; the VM tier stays as
   an optional, labelled lower-fidelity path for developers without benches.
   **Checked 2026-09-30 against openzfs/zfs master:** `zfs-tests.sh` keeps
   every pool already imported out of its cleanup (`KEEP`, default `rpool`,
   passed as `__ZFS_POOL_EXCLUDE`), but eight functional tests use the
   pool-wide forms, and
   `cli_root/zpool_export/zpool_export_parallel_pos.ksh` line 114 runs a
   bare `log_must zpool export -a`: on a ZFS-root host it tries to export
   the busy root pool (a false failure) and exports any other pool present.
   Others: `zpool_import_all_001_pos`, `zpool_import_parallel_pos`,
   `zpool_scrub_multiple_pools`, `zpool_iostat_interval_{all,some}`,
   `mmp_reset_interval`, `cli_user/misc/zpool_import_001_neg` (each to be
   read before classifying). Handling: run them only in the root-on-ZFS
   suite on a disposable build, or list them as not applicable on ZFS-root
   hosts. Upstream contribution for the summit: make them respect `KEEP`.

1. **Summit date.** Decides whether root-on-ZFS builds make the first cut.
2. **ZFS sources:** release tags only, or any commit or pull-request branch?
   Testing a PR across every distro before merge is the one OpenZFS
   developers would want most.
3. **Offline or net** for this edition: full offline is large but demos
   anywhere; net is small but needs the venue's network.
4. **Kernel axis:** stock distro kernels only at first, or also newest and
   mainline (the testing track of `zfs-track-selector.md`)? And for offline,
   which kernels are curated in.
5. **Which distros and releases** are in scope for the first cut, given that
   each distro × release × kernel × ZFS is a real install.
6. **Hardware budget:** how many builds and runs one host takes at once
   (RAM, cores, disks for the device tier), measured, not guessed.
7. **Naming:** ZTS vs `ztest` (§6), and the edition's name on the download
   page.
