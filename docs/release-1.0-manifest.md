# kldload — the 1.0 review and project manifest

Written 24 September 2026 against build 66 (`73ef64df`, branch
`feat/netboot-override`), after the full-tree release review of 23 September
and the estate sweep that followed it. This is the document to argue with: what
kldload is, what it demonstrably does today, what it must do before it is
called 1.0, and what should be added, cut, or left alone to get there.

"1.0" here means the first release an outside enterprise could adopt on the
strength of the documentation and the test evidence alone — not the first
release that works. 1.5.0 works. The gap is proof, scope and support.

---

## 1. What kldload is

A reproducible, multi-distribution, ZFS-on-root installer and the substrate
above it: one image installs Fedora, Debian or RHEL onto ZFS (encrypted or
not, Secure Boot or not), and the installed machine comes up as a workstation,
a server, a KVM hypervisor with sealed golden images, a Kubernetes cluster, a
storage server or an AI box — offline, from the image, with the first boot
explaining itself on screen. Every machine carries the same tools, the same
observability, the same mesh, and can provision the next machine over PXE.

The positioning that has held up for a year:

- **Layer 0.** The layer the IaC stack (Packer, Terraform, Ansible) assumes
  exists and never provides. Not a distribution; an opinionated assembly of
  proven parts.
- **Reproducible, not immutable.** Deterministic and air-gapped at deployment;
  a full mutable Linux afterwards. Recovery, upgrade and install are the same
  mechanism: the image.
- **Looks like vanilla RHEL on purpose.** The capability is one command behind
  familiar chrome.
- **Backups are a property of the filesystem, not a product.**

## 2. Inventory at build 66

| Surface | Count | Notes |
|---|---|---|
| Install targets in the installer | 9 bootstraps | dnf (Fedora, RHEL, Rocky, CentOS), apt (Debian, Ubuntu), pacman (Arch), apk (Alpine), FreeBSD, OpenBSD, GhostBSD, illumos, Windows |
| Install targets offered by the image | 2 + 2 | Fedora and Debian on the full/net menu; RHEL and Arch on the net menu only (Arch demoted) |
| Profiles | 7 offered (core server desktop kvm k8s storage ai) | profiles.sh also carries master, monitoring, vdi, client — none offered, vdi/rdp reverted before 1.5.0 |
| ISO editions | 4 | full (15.6 GiB), net (2.0 GB), core, fedora |
| Shipped tools | 158 in usr/{local/,}{bin,sbin} | 77 `kldload-*`, 13 `kube-*`, 8 `kvm-*`, klab, kfire, kbe, ksnap, kpkg, rollback, kupgrade … |
| Go consoles | 4 modules | wgx (WireGuard estate), ztxplore (ZFS test lab), buildmon, sysdiag; zxplore and vmxplore built from their own repos |
| Python | 21 files by shebang | kldload-webui (12 k lines), kldload-doctor, kldload-db, kldload-estate, kldload-inventory, zexplore-api, klab-exporter … |
| systemd units | 48 | |
| Test scripts | 31 | smoke-build (build gate, ~155 checks), smoke-* (installed machine), estate-sweep + estate-lifecycle (the matrix), profile-report, check-* gates |
| Ansible | 18 playbooks + dynamic inventory | |
| Grafana dashboards | 36 | |
| Man pages | 4 | kfire(8), kldload-vm-snapshot(8), wgx(1), ztxplore(1) |
| Design docs | 15 in docs/ | several describe things that were never built (master profile, HA control plane, zexplore console) |

## 3. What is proven, and how

The evidence standard is the estate sweep: install an edition on real hardware
from the netboot payload, confirm the machine's own manifest and build commit,
run the smoke suites and the doctor on it, and for a hypervisor clone **every**
golden and prove the clone reaches libvirt, the state DB, the Ansible
inventory, both WireGuard planes and Prometheus, runs the shipped playbooks,
has one address, and comes off all of them when deleted.

Proven on build 66, real hardware (fiend):

| Edition | Result | Evidence |
|---|---|---|
| fedora/kvm (3-kvm) | PASS | 197 checks, 9 of 10 goldens through the full lifecycle (Rocky desktop joined the mesh late — test timing, fixed) |
| debian/kvm (deb-3-kvm) | install fine | 194 checks, **10 of 10 goldens** through the lifecycle; the one red check was the test's own alias bug (fixed) |
| fedora/k8s, debian/k8s | install fine | cluster Ready, workloads answering through MetalLB, k8s golden through the lifecycle; the red check was the doctor's lease lookup (fixed) |
| fedora/server, debian/server | PASS / install fine | 193 / 191 checks |
| fedora/desktop, debian/desktop | PASS / install fine | 255 / 255 checks |
| debian/storage | **open** | installs; first boot did not finish in 40 min with everything optional off |
| fedora/storage, ai ×2, core ×2, rhel/desktop | not reached | bench went dark after the storage first boot; 7 editions to re-run |

Proven on earlier 1.5.0 builds and not regressed by anything since: storage
serving NFS/SMB/iSCSI to real clients (build 30), 6-node HA control plane
(build 23), Secure Boot + encryption install (6-full-secure, 13 September),
netboot provisioning end to end, Firecracker microVMs (45 in four minutes),
USB burn and boot on a laptop (build 63).

## 4. The 1.0 bar

Seven gates. Each is a yes/no with a named artefact; none is "mostly".

1. **Security baseline holds.** No shared credential in any image; no secret
   on a command line, a kernel command line, a log or a support bundle; every
   network listener authenticated or loopback; every package source signed;
   TLS verified everywhere; every `StrictHostKeyChecking=no` carries its
   reason. *Status: met at build 66 for everything the review found. Not yet
   met: the web UI treats any loopback client as the operator (see 5.1).*
2. **The matrix is the contract.** Every distro × profile the image offers is
   installed and verified by the sweep on every release build, plus one
   Secure-Boot-with-encryption edition, one upgrade-from-previous-release, one
   restore-from-replica, one net-ISO install. Anything not in the matrix is not
   offered. *Status: 14 + RHEL editions in the sweep; SB+encryption, upgrade,
   restore and net-ISO are not automated.*
3. **Every tool has a contract.** `--help` accurate and exit 0, usage error
   exit 2, a man page in mdoc for every stable operator tool, installed on the
   target. *Status: help gate passes; 4 of ~30 man pages exist; none installed.*
4. **Failure is loud.** No uncommented error swallow on the install, first-boot
   or cluster path; every outcome asserted, not inferred. *Status: install path
   clean; 432 uncommented swallows remain in build-iso.sh, klab, kube-cluster,
   kube-setup, kube-init, autodeploy.*
5. **Documented for a stranger.** README, INSTALL, the answers template, the
   CHANGELOG and the website agree with the code and with each other; the
   design docs describe what shipped, not what was imagined. *Status: README,
   INSTALL, TEMPLATE, RELEASING, ci/README corrected at build 66; docs/ still
   carries unbuilt designs.*
6. **Supportable.** A support bundle that carries no secret and enough to
   diagnose; a doctor whose every check can fail; a versioned upgrade path with
   a tested rollback; a stated support window per distro. *Status: bundle and
   doctor fixed; kupgrade has no rollback; no support statement exists.*
7. **Release mechanics are one command.** Tag at the built commit, four ISOs
   at that commit, R2 keys, website, man pages, CHANGELOG and brain all
   agreeing, checked by `tools/check-release-consistency.sh`. *Status: the
   check exists and reads embedded commits now; the website step is manual.*

## 5. Issues — what is wrong or unproven today

Ordered by what it would cost an adopter.

### 5.1 Security and trust

- **Web UI: loopback is identity.** Any local process (a container with host
  networking, the kiosk user, a compromised exporter) that reaches
  `wss://127.0.0.1:8443` through nginx gets root actions without a credential.
  Bounded to the unix-socket mode at build 66; the model itself predates the
  review. For 1.0: the physical console authenticates by peer credential on a
  root-only socket, and everything else presents PAM or the token. Open WebUI
  on AI installs must not share the host network with that endpoint.
- **Netboot answers are served to the LAN.** An armed answers file — carrying
  the login password and the ZFS passphrase — is a 0644 file fetched by MAC
  name with no expiry. For 1.0: serve to the armed client only, one fetch,
  then delete; 0640 to the web server group.
- **Golden streams have no integrity check.** `kldload-restore-machine`
  receives a `zfs send` over HTTP with no digest. Publish a sha256 per stream
  and refuse a mismatch.
- **RHEL credentials persist on the hypervisor** after a golden build until
  the new shred call runs; the activation-key path should be the only one
  documented.
- **Bob.** A model that reads cluster events and runs `shell=True` as root
  is a liability in an enterprise image even with autonomy off by default.
  Either ship it with an allow-list and approval only, or move it out of the
  default profiles (the docs/bob-deprecation.md note already argues this).
- **Prometheus, exporters, Ollama** are on loopback now; there is still no
  host firewall outside the master role. 1.0 needs nftables on every profile
  with the mesh and the LAN as the only allowed sources.
- **SELinux** is `selinux=0` on the direct-boot command line. A RHEL-shaped
  product that disables SELinux will be rejected by the audiences the
  positioning targets. Enforcing, or a documented permissive with the path to
  enforcing, is a 1.0 item.

### 5.2 Correctness — open

- **Debian storage first boot does not finish** (build 66, everything optional
  off). The log is on the bench.
- **Live image: one PXE boot went dark after the squashfs download** (build
  66, 11-storage). Same image booted nine times that day; needs the console
  to say whether it was the machine or the image.
- **MetalLB drift.** kube-init installs chart 0.14.9 from upstream while the
  build locks and mirrors 0.16.1; a bootstrap needs the network for it.
- **klab reports "ready" with zero goldens** when there is no `rpool/vms`
  (memory: klab-zero-goldens). Same class as the failures the sweep now
  catches on the hypervisor; the klab-firstboot path needs the same count.
- **Autodeploy on boot #1** converges KVM + k8s + images + a 9 GB AI pull at
  once and can reboot-cycle. Stagger by unit ordering and record progress so
  a second boot continues rather than restarts.
- **Two package lists.** RPM installs read `_dnf_pkgs`, not
  `k_profile_packages`; storage, monitoring, ai and master on RPM are whatever
  that list happens to carry. One list, one reader.
- **Arch** panics at boot when encrypted (initcpio ZFS hook); demoted.
  **Alpine, FreeBSD, OpenBSD, GhostBSD, illumos, Windows** bootstraps exist
  in the installer and have no test, no menu entry and no documentation.

### 5.3 Quality debt with a number on it

| Debt | Measure | 1.0 target |
|---|---|---|
| Uncommented `\|\| true` in scope | 432 (build-iso.sh 77, klab 149, kube-cluster 92, kube-setup 27, kube-init 21, autodeploy 16, deploy.sh 17) | 0 on install, first-boot and cluster paths; build-iso.sh and deploy.sh may keep commented ones |
| build-iso.sh strict mode | `set -e` only | `set -Eeuo pipefail` — needs a full build to prove, which is the only honest test |
| mypy --strict | webui 910, doctor 241, gen_icons 144 | webui < 100 with an explicit ignore list; doctor 0; new code 0 |
| ruff E-class | webui 311 | 0 (mechanical) |
| `except Exception: pass` | webui 160 | each one named or removed |
| Man pages | 4 | every tool in §7's "keep" list |
| Go tests | wg 24, buildmon 29, ztxplore 33, sysdiag 10 | keep; add a table test per probe in sysdiag and an estate-parsing test in wg |
| Unit tests for bash | smoke-unit.sh (47 cases) | grow it with every fix — a fix without a guard is one refactor from undone |

### 5.4 Coverage — what a green sweep still does not prove

| Claim | Automated today | Needed for 1.0 |
|---|---|---|
| Secure Boot + encryption install | no (all sweep editions have both off) | one `-secure` edition in every sweep; a VM with OVMF + swtpm for CI |
| TPM unlock (PCR 7) | stubs only | the same VM, sealed, rebooted, unlocked |
| Boot environment rollback | `kbe` create/list/delete | create, activate, reboot, assert `findmnt /`, roll back — on the bench |
| Restore from replica | `tests/dr-drill.sh`, uncalled | one restore per sweep, into a VM |
| Upgrade from the previous release | none | install N-1, `kupgrade`, sweep it |
| kube-bluegreen | none | cluster tier on 4-k8s |
| kfire microVMs | squashfs presence | stamp, enrol, tear down, like estate-lifecycle |
| Net ISO for Fedora/Debian | not in the sweep | 7-net edition |
| core and fedora ISOs | never smoke-built or booted | smoke-build all four; install core once |
| USB burn + live web-UI install | none | manual checklist per release, signed off by name and date |
| Ubuntu, CentOS, Rocky | klab goldens only | decide (§7); if kept, in the matrix |

## 6. Features — add before 1.0

Small list, on purpose. Each one closes a gap an adopter would hit in the
first week.

1. **`kldload-support`**: one command that runs the doctor, collects the
   redacted bundle, and prints what to send and where. The pieces exist.
2. **Upgrade with rollback**: `kupgrade` takes a boot-environment snapshot,
   upgrades, and on a failed DKMS or a failed reboot boots the previous BE.
   `kbe` and `rollback` already do the halves.
3. **Answers-file validator**: `kldload-answers check FILE` — the loader plus
   every default and every cross-key rule (encryption needs a passphrase,
   RHEL needs credentials, k8s needs kvm), before a machine is armed. The
   netboot server does part of this at arm time; make it a tool.
4. **One-fetch, one-client answers serving** on the netboot server (5.1).
5. **Host firewall on every profile** (5.1).
6. **Signed golden streams** (5.1).
7. **Support statement**: which distros, which releases, for how long, what
   "supported" means (security updates via the substrate's pins; rebuild for
   the rest). A page on the website and in the README.
8. **`kldload-doctor --json` as the machine contract** for monitoring: every
   check with an id, so an alert can say which one.

## 7. Features — cut, demote or keep

The single most effective thing for 1.0 is a smaller surface that is entirely
proven. Proposed:

**Cut from the tree** (delete, with a CHANGELOG line; the git history keeps
them):

- The FreeBSD, OpenBSD, GhostBSD, illumos and Windows bootstraps in
  `bootstrap.sh` — 1,400 lines with no test, no menu entry and no
  documentation. The BSD "posture" was a talking point, not a product.
- Alpine, unless someone wants to own it: no test, no menu entry.
- The master, monitoring, client and vdi profile remnants in profiles.sh and
  the design docs that describe them (master-profile-architecture,
  HA-CONTROL-PLANE-DESIGN as a separate profile, REBRAND-PLAYBOOK,
  zfs-track-selector). What of them shipped is the k8s profile.
- Bob's autonomous shell (keep chat and read-only tools if the AI profile
  stays); `kldload-rag-index` is already gone.
- The PRO hub path (`hub.env`, `KLDLOAD_HUB_*`) unless the hub exists.
- Salt (`kldload-salt-*`, minion install on Debian storage): Ansible is the
  configuration path the tests prove; two is one too many.

**Demote to "experimental, not in the image"**: Arch (until the initcpio
hook is fixed and it is back in the matrix), Ubuntu/CentOS/Rocky as install
targets (keep them as klab goldens, which are tested).

**Keep, and finish**: the seven offered profiles; Fedora, Debian and RHEL;
netboot provisioning; goldens and the lifecycle; kfire; kube-cluster +
bluegreen; the storage profile; the four consoles; the show; the observability
stack; the answers file as the one interface.

## 8. Improvements — the work list

Grouped so each group is one branch and one CHANGELOG paragraph.

**A. Security (5.1)** — webui auth model; netboot answers serving; signed
streams; firewall; SELinux decision; Bob scope; RHEL credential path.

**B. Ratchet to zero on the critical paths (5.3)** — klab, kube-cluster,
kube-setup, kube-init, autodeploy first; build-iso.sh strict mode last, with a
full build as its test.

**C. Tool contracts (§4.3)** — man pages for the keep list, generated from
one source per tool where the `--help` text can be shared; install them on
the target; `kupgrade` rollback; the answers validator.

**D. Matrix completion (5.4)** — the secure edition, upgrade, restore,
net-ISO and core-ISO editions in the sweep; a VM-based CI leg (OVMF + swtpm)
so Secure Boot and TPM stop depending on one machine and one person.

**E. Python** — ruff E-class to zero mechanically; mypy on the doctor to
zero; the webui's 160 silent excepts named; split the webui (12 k lines) into
a package with the handlers, the installer bridge and the Bob code in
separate modules — the review found three distinct security models inside
one file.

**F. Documentation** — prune docs/ to what shipped; a page per profile
saying what it installs and what the sweep proves; the support statement;
a "what a green sweep means" page, because that is the product's evidence.

**G. Consolidation** — one package list; one seal (klab's two seal sites,
seal-golden.yml and kldload-seal do the same job three ways); one enrol
(kldload-enroll and kube-network overlap on peer management); one place
where versions come from (the stack lock) with every literal removed.

## 9. Naming and cadence

The tree is versioned 1.5.0 and has shipped 1.2 through 1.4.2. Calling the
GA "1.0" now would confuse every existing tag, download key and release
page. Two honest options:

- **Ship 1.5.0 as-is** (after build 67's re-sweep) as the last of the 1.x
  line, and call the GA that meets §4 **2.0**.
- **Ship 1.5.0, then 1.6, 1.7 …** as the §8 groups land, and call the
  release that closes every gate **1.0 GA** in the *marketing* sense while
  the version string keeps counting. Confusing; not recommended.

Recommendation: 1.5.0 now; the §4 gates define **2.0**; each §8 group ships
in a 1.x point release with its matrix run, so 2.0 is an accumulation of
verified pieces rather than a big bang. Nothing in §8 needs a rewrite; the
risk is only in doing it all at once, which is what the review found
1.5.0's own history warning against.

## 10. Immediate next steps (this week)

1. Read fiend's `firstboot.log` from the Debian storage install; fix; find
   out why the live image went dark on the following boot.
2. Build 67 with the three test fixes; re-sweep the seven remaining editions.
3. Tag 1.5.0 at that commit; R2; website; brain. The release video first, as
   planned.
4. Open one issue per §8 group with the numbers from §5.3 as the exit
   criteria, so the ratchet is visible.
