# kldload CI — operator handbook

This directory holds the CI runner script. **Read this before touching the
test infrastructure.** Goal: anyone landing on this cold — a new operator,
a future-self, an SRE on rotation — can pick up the test environment, know
what's running, what's broken, and how to drive a fix to verification.

---

## 1. What CI does for kldload

It builds an ISO, installs that ISO into 15 throwaway KVM VMs (5 distros
× 3 profiles), runs a post-install validation suite against each
installed system, and records pass/fail with diffable per-combo logs.

The point is **catching regressions cheap**: each kldload commit can
re-light the matrix in ~2 hours and tell you exactly which distro ×
profile broke. The framework caught 8 latent bugs in a single overnight
run on 2026-05-06. That's the loop.

CI is **not** a substitute for hardware testing. It runs in OVMF VMs on
libvirt's default network — it catches installer/content/framework
regressions, but **misses firmware quirks, real-NIC drivers, NVIDIA
driver-vs-kernel races, MOK/Secure Boot NVRAM behaviour**, etc. Treat CI
as the airbag and hardware install as the seatbelt.

---

## 2. Where everything lives

**Build host (`onyx`, the dev workstation):**

| Path | What |
|---|---|
| `/home/anthony/kldload/` | The kldload git checkout. Edit + commit here. |
| `/home/anthony/kldload/ci/kldload-ci-run` | Source-of-truth for the matrix runner. |
| `/home/anthony/kldload/ci/kldload-netboot-run` | The 1.5.0 release sweep: one unattended netboot install, end to end, with a report. Finds the checkout from its own location; `KLDLOAD_REPO` overrides. |
| `/home/anthony/kldload/tests/` | Smoke tests (`lifecycle.sh`, `smoke-*.sh`, `lib-test.sh`). |

**CI host (`fiend.unixbox.net`, 10.100.10.225):**

| Path | What |
|---|---|
| `/opt/kldload-ci/kldload-free/` | Working copy of the repo (rsync'd from onyx). |
| `/opt/kldload-ci/results/<run-id>/` | Per-run artifacts (build.log, smoke-*.log, SUMMARY.md). |
| `/opt/kldload-ci/history.sqlite` | Run × combo × status table. |
| `/opt/kldload-ci/.run.lock` | flock — only one matrix at a time. |
| `/usr/local/bin/kldload-ci-run` | Installed copy of the runner. |
| `/etc/systemd/system/kldload-ci.timer` | Nightly fire at 03:00 local. |
| `/etc/systemd/system/kldload-ci.service` | The unit the timer triggers. |
| `/var/log/kldload-ci-bootstrap.log` | The bootstrap log (one-off manual runs). |

**Fiend's hardware:** 24c / 62 GB / 2 TB NVMe / RTX 3080. SSH:
`admin@fiend.unixbox.net` password in `$CI_PW` (set it &mdash; not committed), sudo NOPASSWD via
`/etc/sudoers.d/95-kldload-ci`.

---

## 3. The matrix

| | core | server | desktop |
|---|---|---|---|
| centos | ✅ | ✅ | ✅ |
| rocky | ✅ | ✅ | ✅ |
| fedora | ✅ | ✅ | ✅ |
| debian | ✅ | ✅ | ✅ |
| ubuntu | ✅ | ✅ | ✅ |

15 combos, from `MATRIX_DISTROS` / `MATRIX_PROFILES` in `kldload-ci-run`.
That list is wider than what the release claims: the web UI offers Fedora and
Debian, the netboot menu offers `NETBOOT_DISTROS` (default `fedora`), and
RHEL and Arch are sent the net image. A green centos, rocky or ubuntu cell is
a network install, not the offline product.

Workload templates (`kvm`/`k8s`/`klab`/`zfslab`) are NOT in the matrix.
`tests/smoke-kvm.sh` exists; `smoke-klab.sh` and `smoke-zfslab.sh` do not,
and `smoke-auto.sh` falls back to `smoke-core.sh` for a profile with no
wrapper — so a klab or zfslab install run through this matrix would be graded
by the core suite and read as a pass.

Profile semantics (per project rules):

- **core** — ZFS-on-root + stock distro + WireGuard + eBPF + diagnostic
  tools (`kldload-debug-bundle`, `kldload-recovery`). NO kldload-webui,
  NO sanoid, NO k* feature tools. The smoke test verifies these are
  ABSENT.
- **server** — core + k* tools + sanoid + webui + observability stack.
  The smoke test verifies they're PRESENT.
- **desktop** — server + GNOME + GDM + Firefox.

---

## 4. What each test checks

### `tests/smoke-build.sh` (pre-install)
Validates the ISO file: size > expected, sha256 matches, mounts cleanly,
contains squashfs, EFI dir present, GRUB present, sane manifest.

### `tests/smoke-core.sh` (51 tests, runs on every profile)
Baseline that every install must pass:

- **ZFS** — userspace tools, kernel module loaded, `rpool` exists +
  ONLINE + zero errors, scrub runs.
- **Datasets** — `rpool/ROOT`, `home`, `var`, `var/log`, `srv` exist;
  ≥10 datasets total; root mountpoint, compression enabled, bootfs set.
- **Boot** — `/etc/kldload/boot-environment` marker, EFI partition.
- **Network** — interface up, DNS resolves, sshd active, hostid
  matches initramfs.
- **Universal markers** — `/etc/kldload-build-sha`,
  `/etc/kldload/edition`, `/etc/kldload/profile`.
- **Core-specific** — `kst`/`ksnap`/`kbe`/`kclone`/`kdf`/`kdir`/`kpkg`/
  `kupgrade`/`kexport`/`krecovery`/`kldload-webui`/`sanoid` all ABSENT;
  webui + sanoid services NOT running.
- **Snapshots** — create/verify/destroy a test snapshot end-to-end.
- **Debug bundle** — `kldload-debug-bundle` present + `--help` works.

### `tests/smoke-server.sh` (extends smoke-core)
- All k* tools PRESENT.
- sanoid binary + service.
- WireGuard userspace.
- eBPF tools (`bpftrace` family).
- NVIDIA driver if GPU detected.

### `tests/smoke-desktop.sh` (extends smoke-server)
- GNOME session present.
- GDM service.
- Firefox installed.

### `tests/smoke-auto.sh` (dispatcher)
Reads `/etc/kldload/profile` on the running system and dispatches to the
matching `smoke-{core,server,desktop,kvm}.sh`; a profile with no wrapper
falls back to `smoke-core.sh` (and says so on stderr). Called by
`lifecycle.sh` on the freshly-installed VM.

### `tests/lifecycle.sh` (the per-combo driver)
This is what `deploy.sh smoke-test <distro> <profile>` invokes. Per
combo:

1. Spawn KVM VM with OVMF + boot-from-ISO (`virt-install`).
2. Wait up to 15 min for live env DHCP + sshd (`wait_for_ssh live live`).
3. Compose answers env file (distro/profile/disk/hostname/...) and SCP
   to the live env.
4. Kick `kldload-install-target --config /tmp/answers.env` headlessly
   via `setsid nohup`. Poll for completion with
   `pgrep -f "[/]usr/sbin/kldload-install-target"` (bracket trick — see
   gotchas).
5. Verify "Install completed successfully" in the installer log.
6. Shut down the VM, switch boot order to disk-first, restart.
7. Wait up to 15 min for the installed system to come up
   (`wait_for_ssh admin admin`).
8. SCP `tests/` to the installed target, run `smoke-auto.sh` there.
9. Pass if smoke-auto reports zero failures; fail otherwise.
10. On failure, leave the VM defined for `virsh console` inspection
    and dump the installer log + `/tmp/install.log` + storage log into
    the smoke combo log.

> **Credentials:** export `CI_PW` to the lab CI password before running these commands; it is deliberately not committed.

### `ci/kldload-ci-run` (the matrix orchestrator)
Wraps the per-combo driver in a loop, builds the ISO once at the start,
records every result in SQLite, captures per-failure VM console.

---

## 5. Driving the tests

**Run a single combo (fastest dev-loop):**

```bash
# On fiend:
sudo kldload-ci-run --only fedora-core --skip-build
# Total: ~25 min (no build, install + post-install).
```

**Run the full matrix:**

```bash
# On fiend:
sudo kldload-ci-run                    # build + 15 combos, ~2-3 hr
sudo kldload-ci-run --skip-build       # use last-built ISO, ~1.5-2 hr
```

**Re-run only what failed last time:**

```bash
sudo kldload-ci-run --diff-last
```

**Status / reports:**

```bash
sudo kldload-ci-run --status                      # last 10 runs
sudo kldload-ci-run --report 2026-05-06-044342    # specific run
# Or query SQLite directly:
sudo sqlite3 /opt/kldload-ci/history.sqlite \
  "SELECT distro, profile, status, fail_reason
   FROM results WHERE run_id='2026-05-06-044342'"
```

**Run via systemd-run** (so it survives your SSH disconnect):

```bash
sudo systemctl reset-failed kldload-ci-bootstrap 2>/dev/null
sudo systemd-run --unit=kldload-ci-bootstrap --collect \
  --property=StandardOutput=append:/var/log/kldload-ci-bootstrap.log \
  --property=StandardError=inherit \
  --property=TimeoutStartSec=12h \
  bash -c 'env CI_SYNC_CMD="" /usr/local/bin/kldload-ci-run 2>&1'
sudo systemctl is-active kldload-ci-bootstrap   # 'active' = running
```

**Watch live progress:**

```bash
sudo tail -f /var/log/kldload-ci-bootstrap.log
# or for a specific combo:
sudo tail -f /opt/kldload-ci/results/<run-id>/smoke-fedora-core.log
```

**Inspect a failed VM:**

```bash
# VMs are LEFT on failure (KEEP_VM=1 also keeps on success).
sudo virsh list --all | grep smoke
sudo virsh console kldload-smoke-fedora-core
# Or SSH:
mac=$(sudo virsh domiflist kldload-smoke-fedora-core | awk 'NR>2 {print $5; exit}')
ip=$(sudo virsh net-dhcp-leases default | awk -v m="$mac" 'tolower($3)==tolower(m){print $5}' | cut -d/ -f1)
sshpass -p admin ssh admin@${ip}    # installed system, profile=core/server/desktop
sshpass -p live ssh live@${ip}      # if VM is still in live env (install aborted)
```

---

## 6. The fix loop (how to land + verify a bug fix)

This is the cycle every matrix-found bug should follow:

```
edit source on onyx (in /home/anthony/kldload/...)
   ↓
git commit -m "fix(...): explanation of bug + commit-id of CI run that caught it"
   ↓
rsync source to fiend:
   sshpass -p "${CI_PW}" rsync -av \
     -e 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' \
     /home/anthony/kldload/<changed-file> \
     admin@fiend.unixbox.net:/opt/kldload-ci/kldload-free/<same-path>
   ↓
trigger a matrix run on fiend (next ISO build will include the fix):
   ssh admin@fiend.unixbox.net 'sudo systemd-run --unit=kldload-ci-bootstrap ...'
   ↓
wait ~2 hr, check --status / --report
   ↓
fail count should drop. If a NEW failure surfaces, that's the next layer
of bug. Iterate.
```

**Important:** an ISO build started **before** the rsync will NOT have
the fix. Always rsync **before** kicking off the run.

---

## 7. Current state (2026-09-23, 1.5.0)

The KVM matrix above is `kldload-ci-run`'s and still runs as described. The
1.5.0 release sweep — every edition installed on the same real machine —
goes through **`ci/kldload-netboot-run`** instead: one unattended netboot
install, end to end, with a report. Its phases run in this order; each checks
its own outcome and stops the run with a reason, and `--from PHASE` resumes:

| Phase | What it does |
|---|---|
| `build` | `./deploy.sh build` (only with `--build`) |
| `smoke` | `./deploy.sh smoke-build`; any failure other than the two known repository ratchets stops the run |
| `stage` | copy kernel, initrd, root image and VERSION out of the new ISO into the netboot payload, verify them, restart `kldload-netboot` |
| `arm` | `kldload-netboot-server arm-install <mac> <answers file>` |
| `boot` | on a reachable target: one-time network boot, reboot; otherwise wait for someone to power the machine on |
| `watch` | follow the netboot log — armed snippet, root image, answers file — and **disarm** the moment the answers file has been fetched |
| `installed` | wait for ssh from the freshly installed system |
| `ready` | wait for first-boot convergence to finish |
| `verify` | check the installed machine against what the answers file asked for, and write `report.md` |

Run it as a transient unit so it outlives the terminal:

```bash
sudo systemd-run --unit kldload-netboot-run --collect \
    /home/anthony/kldload/ci/kldload-netboot-run \
    --answers live-build/pxe/matrix/<edition>/<mac>.env --build
journalctl -fu kldload-netboot-run          # or tail -f <report dir>/run.log
```

Output lands in `/var/log/kldload-netboot-run/<run id>/{run.log,phase,report.md,smoke.out}`.
Exit 0 is verified, 1 a phase failed (see `report.md`), 2 usage. `--iso PATH`
stages a specific ISO instead of the newest full one; `--net-iso PATH` also
stages the net image the menu serves to `NETBOOT_NET_DISTROS` (rhel, arch),
refused unless its VERSION records the same clean commit as the full ISO's.
An encrypted target stops at the ZFSBootMenu passphrase prompt on every boot
and a Secure Boot target stops at MokManager once; the run waits and says so
in the log.

---

## 8. Bootstrap a fresh CI host (after nuking fiend, etc.)

When fiend is reinstalled (or replaced), reproduce the CI infrastructure:

```bash
# 1. Install kldload (klab template) on the box, get static IP/hostname.

# 2. From onyx, prepare:
#    - sshpass / sudoers / git / shellcheck / sqlite / jq / qemu-img on fiend
ssh admin@fiend 'echo "${CI_PW}" | sudo -S dnf install -y \
  git ShellCheck sqlite jq qemu-img sshpass'

# 3. Layout:
ssh admin@fiend 'sudo mkdir -p /opt/kldload-ci/{results,bin}; \
  sudo chown -R admin:admin /opt/kldload-ci'

# 4. ZFS dataset for podman storage (kldload doesn't create this):
ssh admin@fiend 'sudo zfs create -p \
  -o mountpoint=/var/lib/containers/storage \
  rpool/var/lib/containers/storage; \
  sudo zfs create rpool/var/lib/containers/storage/zfs'

# 5. Podman: permissive short-name resolution (non-TTY builds):
ssh admin@fiend 'echo "short-name-mode = \"permissive\"
unqualified-search-registries = [\"docker.io\",\"quay.io\",\"registry.fedoraproject.org\"]" \
  | sudo tee /etc/containers/registries.conf.d/00-kldload-ci-permissive.conf'

# 6. Rsync source from onyx (excludes build output, caches, and local config):
sshpass -p "${CI_PW}" rsync -av --delete \
  --exclude='live-build/output' \
  --exclude='live-build/output-pass*' \
  --exclude='live-build/cache' \
  --exclude='live-build/darksite-ollama-cache.disabled' \
  --exclude='live-build/logs' \
  --exclude='.claude' \
  --exclude='design-mockups' \
  -e 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' \
  /home/anthony/kldload/ \
  admin@fiend.unixbox.net:/opt/kldload-ci/kldload-free/

# 7. Install runner + sudoers:
sshpass -p "${CI_PW}" ssh admin@fiend '
  echo "${CI_PW}" | sudo -S install -m 0755 \
    /opt/kldload-ci/kldload-free/ci/kldload-ci-run \
    /usr/local/bin/kldload-ci-run
  echo "admin ALL=(ALL) NOPASSWD: /usr/local/bin/kldload-ci-run, \
    /opt/kldload-ci/kldload-free/deploy.sh" | sudo tee \
    /etc/sudoers.d/95-kldload-ci > /dev/null
  sudo chmod 0440 /etc/sudoers.d/95-kldload-ci'

# 8. Systemd unit + nightly timer:
ssh admin@fiend 'sudo tee /etc/systemd/system/kldload-ci.service > /dev/null <<UNIT
[Unit]
Description=kldload CI — nightly build + smoke-test matrix
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=12h
ExecStart=/usr/local/bin/kldload-ci-run
StandardOutput=append:/var/log/kldload-ci.log
StandardError=inherit
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=4
UNIT
sudo tee /etc/systemd/system/kldload-ci.timer > /dev/null <<TIMER
[Unit]
Description=Run kldload CI nightly at 03:00 local time (OnCalendar carries no zone)

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15min
Persistent=true
Unit=kldload-ci.service

[Install]
WantedBy=timers.target
TIMER
sudo systemctl daemon-reload
sudo systemctl enable --now kldload-ci.timer'

# 9. First run to verify:
ssh admin@fiend 'sudo kldload-ci-run --only fedora-core --skip-build'
# (no ISO present yet, will trip the no-ISO error — that's fine. Then:)
ssh admin@fiend 'sudo kldload-ci-run --only fedora-core'   # full cycle
```

After that, `--status` will list the run, and the timer fires nightly.

---

## 9. Gotchas (the buried landmines, in commit-order)

These are non-obvious things that bit us. Each one is a comment in the
relevant source file too — but knowing they exist saves a debugging
session.

**a. F44 zram-generator and kubelet (`kube-setup` setup_kernel)**
Fedora 44 cloud images ship `zram-generator-defaults` which auto-creates
`/dev/zram0` swap on every boot. kubelet refuses to start with swap on.
`swapoff -a` is not enough — need to also mask
`systemd-zram-setup@zram0.service` and remove the package. Without this,
kubelet fails → kubeadm init retries → 2nd init fails on existing
manifests → cluster silently never converges.

**b. AI ERR trap fires on missing GPU (`kldload-autodeploy` ai phase)**
`nvidia-smi` exits 1 if no NVIDIA GPU. With `set -e` + pipefail, this
trips the ai-pull subshell's ERR trap and marks `ai-failed` even though
the install would skip AI gracefully. Wrap the GPU probe with
`set +e`/`set -e`.

**c. Core profile leaks kldload-webui via TWO copy sites**
- `profiles.sh:649` copies `/usr/local/bin/kldload-webui` to target.
- `kldload-install-target:925` does `for f in /usr/local/sbin/kldload-*`
  which catches kldload-webui (the live env has it in BOTH bin and sbin).
Both sites need a profile gate.

**d. Universal install markers (build-sha, edition, boot-environment)**
Are written deep inside the non-core branch of `k_install_system_files`.
Move them BEFORE the core early-return — every install needs them for
self-identification + smoke-test acceptance.

**e. Diagnostic tools belong on every install**
`kldload-debug-bundle` and `kldload-recovery` are incident-response
plumbing, not features. Install them in core too.

**f. `pgrep -f X` matches its own SSH session if X is in the cmdline**
Bash invoked by sshd has the literal pattern in its argv. Even
`pgrep -f /usr/sbin/X` doesn't help (the SSH session has the full path
as a literal arg too). Use the bracket trick:
`pgrep -f "[/]usr/sbin/X"`. The brackets are a regex char class —
matches `/usr/sbin/X` but NOT the literal string `[/]usr/sbin/X` in
the SSH session's argv.

**g. `virsh domifaddr --source agent` returns 127.0.0.1 first**
qemu-guest-agent emits ALL interfaces including `lo`. Filter with
`grep -vE '^(127\.|169\.254\.|0\.0\.0\.0$)'` before consuming. Without
this, smoke-test's `wait_for_ssh` SSHes to loopback forever and times
out at 15 min while the VM was actually fine on its real IP.

**h. `scp` without `sshpass` falls back to pubkey auth**
The live ISO has no SSH key for the smoke-test host. `scp` silently
fails. Always wrap with `sshpass -p live scp ...` (or
`sshpass -p admin scp ...` for the installed system).

**i. `printf` with format string starting with `-` fails**
`printf '---x---'` gets parsed as flags. Use `printf '%s' '---x---'`
or `printf -- '---x---'`.

**j. `zfs get rpool/ROOT/*` rejects '*' as invalid character**
ZFS dataset names can't contain `*`. Use `-r rpool/ROOT` to recurse.
The shell's pathname expansion doesn't apply because nothing matches
the glob (the path doesn't exist as a filesystem path).

**k. Concurrent runs race the VM name**
The flock at `/opt/kldload-ci/.run.lock` prevents two `kldload-ci-run`
invocations stepping on each other. But orphan `podman` build
containers persist past their parent shell — kill them explicitly when
recovering from a stuck state.

**l. Podman short-name-mode = enforcing kills non-TTY builds**
Default Fedora setting prompts for confirmation when pulling
`docker.io/library/fedora:44`. The CI runner has no TTY → fails.
`/etc/containers/registries.conf.d/00-kldload-ci-permissive.conf`
fixes it.

**m. Podman ZFS storage driver wants the dataset to pre-exist**
`rpool/var/lib/containers/storage` and `.../storage/zfs` must exist
as datasets BEFORE first podman invocation. The kldload installer
does NOT create them.

---

## 10. Checklist for the next session

When picking this up:

- [ ] Read this file.
- [ ] `ssh admin@fiend.unixbox.net sudo kldload-ci-run --status` — what's
      the latest run, did it pass/fail?
- [ ] If a run is in progress: `tail -f /var/log/kldload-ci-bootstrap.log`
      or just wait for it.
- [ ] If anything failed: `sudo kldload-ci-run --report <run-id>`, then
      drill into per-combo logs at
      `/opt/kldload-ci/results/<run-id>/smoke-<distro>-<profile>.log`
      and the `failures/<combo>/` artifact dir.
- [ ] For each unique failure pattern: identify the root cause, fix in
      source on onyx, rsync to fiend, trigger a matrix run, watch the
      fail count change.
- [ ] If the fix works (failure flips to pass), commit + push to git.
- [ ] If a new failure surfaces, treat it as the next layer (this is the
      design — CI surfaces bugs in cascading layers).
- [ ] Phase-2 work (when basic matrix is fully green): write
      `tests/smoke-{klab,zfslab}.sh` to extend the matrix to cover the
      remaining workload templates (`smoke-kvm.sh` exists).

---

## 11. What this is NOT

- **Not a hardware test substitute.** Fiend's own boot regression on the
  new USB earlier this session is invisible to CI (real-firmware UEFI
  quirks, NOT installer bugs). For release validation, burn USB and
  install on real metal.
- **Not a workload-template tester.** The current matrix only covers
  `core`/`server`/`desktop` (the generic profiles). Of the workload
  templates only `kvm` has a wrapper (`tests/smoke-kvm.sh`); `klab` and
  `zfslab` still need theirs — phase-2. The 1.5.0 editions were verified
  by `kldload-netboot-run` on real hardware instead (section 7).
- **Not multi-host.** Fiend is the only CI runner. If you bring up a
  second box, share the source via git or per-host rsync; the SQLite
  history is per-host.
- **Not public.** No GitHub Actions integration, no PR commenter. Add
  later if it becomes useful.
