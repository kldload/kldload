# ZFS Lab edition — design brief

Status: **BRIEF** (2026-09-30), written to be designed from. Nothing here is
built. It records what was decided in conversation, what already exists in
the tree (with paths, checked on the day), the gaps, and the open decisions.
Occasion: kldload has a slot at the OpenZFS summit for kldload and the ZFS
test suite.

## 1. What it is

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

"Version X" means packages, not a repo. klab's existing cloud-image goldens
with dev tools (`klab golden-ztest`) are the **package factory**: clone one,
check out the tag or ref (a pull request is just a ref), `make rpm` /
`make deb` for the DKMS variant so the packages are kernel-independent, cache
at `pkgs/<family>/<release>/<zfsver>/`. Built once, reused. The installer
gets one field, `KLDLOAD_ZFS_SOURCE=<url>`, and `bootstrap.sh` installs ZFS
from there instead of the mirror; the netboot server already serves
directories over HTTP. This one piece of plumbing serves both tiers.

This also settles the three-overlapping-tools question: klab's cloud goldens
are the factory, the installer's goldens are the subjects.

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

## 12. Open decisions

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
