# CLAUDE.md — kldload

Rules and context for Claude when working in this repo. Keep this file
short and load-bearing; if something isn't true day-to-day, take it out.

---

## 1. Identity & git workflow

**Commit identity (non-negotiable):**

There are **exactly two** identities that may ever appear as the
author, committer, co-author, or any other "who-did-this" field in
any commit, tag, PR description, PR comment, issue, or release note
on any kldload-owned repository:

| Identity | When it's used |
|---|---|
| `kldload <anthony@kldload.com>` | Default — every commit Claude prepares, every commit the operator makes from a kldload checkout. Repo-local `.git/config` is already set to this. |
| `anthony <anthony@unixbox.net>` | The operator's personal identity, used only when explicitly requested. Rare. |

**Claude must never appear anywhere.** That means:

- **No `Co-Authored-By: Claude ...` trailer** in any commit message. Ever.
- **No `🤖 Generated with Claude Code` footer** in commits, PR
  bodies, PR comments, issues, or release notes.
- **No `Assisted-By:` / `Reviewed-By:` / `Helped-By:` / any other
  trailer** naming Claude, Anthropic, an LLM, an AI, a model name,
  or any variant thereof.
- **No author rewriting** via `git commit --author` to insert Claude
  or any third name. The `--author` flag is forbidden in this repo
  for that reason.
- **No mentions in body text either** — don't write "with help from
  Claude," "AI-assisted," "generated via," or anything equivalent.

If any of the above ever lands, it's a defect and must be rewritten
before the next push (use `git rebase -i` on local-only commits; for
already-pushed commits raise it with the operator before acting,
since rewriting published history is otherwise forbidden). The
GitHub Contributors panel must only ever show `kldload` and
optionally `anthony@unixbox.net` — nothing else.

Don't override identity with `--global` or per-commit `--author`. PR
descriptions follow the same rule.

**Remote / auth:**

- `origin` → `git@github.com:kldload/kldload.git` (SSH)
- Auth via `~/.ssh/id_kldload` (routed by `~/.ssh/config` Host stanza)
- Sanity check: `ssh -T git@github.com` should say *"Hi kldload!"*

**Branching & pushing:**

- Work on `main` for routine fixes; branch for anything that touches
  the installer, partitioning, or ZFS layout (those break the matrix).
- **Never `--force` push to `main`.** Force-push allowed only to your
  own topic branches, never to anything CI watches.
- Don't commit unless explicitly asked. The default is to leave
  changes uncommitted so the user can review the diff first.

---

## 2. What's in this repo

| Path | What |
|---|---|
| `deploy.sh` | One entry point. Build, smoke, burn, deploy. Read its `case` block to see all subcommands. |
| `builder/` | Container image (Fedora 44 + lorax) that builds the ISO. `build-iso.sh` is the lorax driver. |
| `live-build/` | Debian live-build cache & output. `.gitignore`d. |
| `build/` | Per-distro darksite mirror build scripts. Output goes to `live-build/`. |
| `profiles/` | `desktop.yaml`, `server.yaml`. Profile = package set + post-install hook bundle. |
| `tests/` | Smoke tests. `smoke-build.sh` validates the built ISO. `lifecycle.sh` + `smoke-{core,server,kvm,desktop,auto}.sh` validate an installed VM. |
| `ci/` | Nightly matrix runner (`kldload-ci-run`). Runs on `fiend.unixbox.net`. See `ci/README.md`. |
| `tools/icons/gen_icons.py` | The only Python in the tree. |

Language mix: ~19 bash scripts, 1 Dockerfile, 1 Python, 3 YAML, plus
assets. **Bash is the project language** — write new code in bash
unless there's a strong reason not to.

---

## 3. Verify before you call it done

The rule: **don't claim a change works until you've run the matching
check.** Pick the cheapest level that actually exercises your change.

| Change touches… | Run this first |
|---|---|
| Any `*.sh` | `bash -n <file>` then `shellcheck -S error <file>` |
| Anything inside `builder/`, `build/`, `live-build/config/` | `./deploy.sh smoke-build` (fast, no VM) |
| Installer, partitioning, post-install hooks, profile package lists | `sudo ./deploy.sh smoke-test <distro> <profile>` (25–35 min in KVM) |
| Profile-wide / cross-distro changes | Bump it into the nightly CI matrix — see `ci/README.md` |
| `tools/icons/gen_icons.py` | Run it; diff the output SVGs |

**`smoke-build` runs two hard gates on shell code:**

1. **`shellcheck -S error`** against a curated list (`kube-cluster`,
   `kube-init`, `kube-setup`, `kzfs-lab`, `profiles.sh`,
   `build-iso.sh`). When you add a new top-level script, extend that
   list rather than letting it drift unverified.
2. **`shfmt -l -i 4`** across **every** tracked `*.sh` and
   `ci/kldload-ci-run`. Any drift from `shfmt -i 4` formatting fails
   the smoke. The codebase was bulk-reformatted in 2026 to establish
   the baseline; the rule from here is *zero new drift*.

**Before committing any new or modified shell script:**

```bash
shfmt -w -i 4 path/to/script.sh        # fix formatting in place
shellcheck -S error path/to/script.sh  # at minimum; -S warning is better
bash -n path/to/script.sh              # syntax sanity
```

**If the tools aren't installed** (fresh host):

```bash
# Fedora / RHEL 10 (needs EPEL)
dnf install -y ShellCheck
curl -fsSL -o /usr/local/bin/shfmt \
  "https://github.com/mvdan/sh/releases/download/v3.13.1/shfmt_v3.13.1_linux_amd64"
chmod +x /usr/local/bin/shfmt

# Debian
apt-get install -y shellcheck
# shfmt: same curl as above, or `go install mvdan.cc/sh/v3/cmd/shfmt@latest`
```

`smoke-build` emits a warning (not a failure) when either tool is
missing — **don't rely on that silence as a green light.** Install
the tool and re-run.

If you can't run a check (no KVM, no network, missing tool), **say so
explicitly** in your reply rather than claiming the change is verified.

---

## 4. Bash coding rules

- **Formatting is mechanical**: `shfmt -i 4` decides. Don't argue
  with the formatter; run it before you commit. See §3 for the
  rationale and the install line.
- `#!/usr/bin/env bash` + `set -Eeuo pipefail` at the top of every
  script. No exceptions.
- Quote every expansion: `"$var"`, `"${arr[@]}"`. Unquoted globs are
  bugs waiting to happen on USB paths with spaces.
- Use `[[ ]]` not `[ ]`. Use `(( ))` for arithmetic.
- Prefer `mktemp -d` + `trap 'rm -rf "$tmp"' EXIT` over hand-rolled
  cleanup. The installer runs as root — leaking temp dirs in `/tmp`
  on a live ISO is a real problem.
- When sourcing a sibling: `# shellcheck source=lib-test.sh` so
  shellcheck can follow the include (see `tests/smoke-javaapi-rollback.sh`).
- Log with the existing `_section / _pass / _fail / _warn` helpers in
  `tests/lib-test.sh` rather than inventing a new logger.

**Don't:**

- Don't add `|| true` to silence a failing command — investigate why
  it's failing. Real installer regressions hide behind swallowed errors.
- Don't `eval` on data derived from `cmdline.txt`, the user's
  hostname, or anything pulled off network. Use `bash -c` with a
  fixed argv if you need a sub-shell.
- Don't introduce a new dependency without adding it to the
  `builder/Dockerfile` (build-time) or the relevant profile YAML
  (runtime). A working dev box hides missing deps; CI catches them
  noisily and late.

---

## 5. Building & deploying

The full ISO build (~30–60 min on `onyx`):

```bash
PROFILE=desktop ./deploy.sh build      # or PROFILE=server / core / kvm
```

Other useful subcommands (read `deploy.sh`'s `case` block for the
full list):

```bash
./deploy.sh clean                       # nuke live-build/ + cached output
./deploy.sh smoke-build                 # validate the built ISO
./deploy.sh burn /dev/sdX               # write ISO to USB (asks first)
sudo ./deploy.sh smoke-test debian desktop   # full lifecycle in KVM
./deploy.sh kvm-deploy                  # boot the ISO in a throwaway VM
```

The build runs containers via podman with the **ZFS storage driver**
backed by the `rpool/var/lib/containers/storage/zfs` dataset. If a
clean host complains *"cannot open 'rpool/var/lib/containers/storage/zfs':
dataset does not exist"*, create the dataset chain (parents with
`canmount=off`):

```bash
zfs create -o canmount=off rpool/var/lib/containers
zfs create -o canmount=off rpool/var/lib/containers/storage
zfs create rpool/var/lib/containers/storage/zfs
```

---

## 6. CI

Nightly matrix runs on `fiend.unixbox.net` at 03:00 local. Results in
`/opt/kldload-ci/results/<run-id>/SUMMARY.md`. **CI is the airbag,
hardware install is the seatbelt** — it catches installer/content
regressions but misses firmware quirks, real-NIC drivers, NVIDIA
driver-vs-kernel races, MOK/Secure Boot NVRAM behaviour.

Before pushing a change that touches the installer or profile package
sets, eyeball the last `SUMMARY.md` — if the matrix is already red on
something unrelated, your push will land on top of noise.

Full operator handbook: `ci/README.md`.

---

## 7. Things to never do

- Don't commit anything under `live-build/config/includes.chroot/root/darksite/`
  — that's the regenerated package mirror and it's in `.gitignore`
  for a reason (gigs of `.deb`/`.rpm`).
- Don't commit secrets. The `.gitignore` has a `# Secrets` section;
  if you add a new credential path, extend it.
- Don't bypass git hooks with `--no-verify`. If a hook fails,
  investigate.
- Don't rewrite published history on `main`.

---

## 8. Expertise expectations

kldload sits at the intersection of Linux distro mechanics, ZFS storage,
NVIDIA driver lifecycle, WireGuard meshes, eBPF observability, and
release engineering across nine substrates. Code in this repo should
read as if written by someone who has shipped each of those in
production and felt the failure modes personally. That's the standard;
the rules below are how to enforce it on every change.

### Domain depth assumed

- **Linux userland + kernel boundary** — systemd unit semantics
  (Type=oneshot vs notify vs simple, After= vs Wants= vs Requires=,
  PartOf, BindsTo), dracut module structure, udev rule precedence,
  cgroup v2, namespace primitives, the ELF + dynamic linker contract.
- **OpenZFS** — pool layout, `zpool create` flags that actually matter
  (ashift, autoexpand, autotrim, feature@…), `zfs send -R` incremental
  semantics, dataset properties that affect boot (`canmount=noauto`,
  `mountpoint=legacy`, `org.zfsbootmenu:…`), DKMS-vs-kmod tradeoffs,
  the kernel/zfs/spl ABI matrix that breaks installs.
- **NVIDIA proprietary stack** — kmod vs DKMS install, signed module
  signing chain under Secure Boot, the kernel-uname-r exclusion games
  every distro plays, how `nvidia-persistenced` and `nvidia-uvm`
  actually load, why a kernel bump on Tuesday can wedge X for a week.
- **WireGuard** — kernel-module vs `wireguard-go`, key rotation
  cadence, `AllowedIPs` as routing table (not ACL), mesh topology
  patterns (hub/spoke, full mesh, transit), Linux netns isolation.
- **Distro release engineering** — lorax, live-build, mkosi,
  debootstrap, archroot, kickstart, preseed, mirror semantics,
  `dnf install --installroot`, the difference between repo metadata
  expiring and a transaction being broken.
- **Package managers — *all* of them** — `dnf` (4 and 5), `apt`,
  `pacman`, `zypper`, `xbps`, `apk`. On BSDs: `pkg` (FreeBSD),
  `pkg_add` (OpenBSD), `pkgsrc` (NetBSD). Know each one's
  transactional semantics, what `--skip-broken` actually skips, why
  `apt install` and `apt-get install` differ in scripts.
- **Performance + observability** — `perf`, `bpftrace`, `bcc`,
  Tetragon, `iostat -xtm 1`, `vmstat -SM 1`, `ss -tlnp`, `nft` vs
  `iptables-nft`, where `numactl` actually helps.
- **The BSDs** (because the kldload posture borrows from them) —
  FreeBSD jails, dtrace, ZFS-the-FreeBSD-way, OpenBSD pf + relayd,
  NetBSD's `pkgsrc` portability. Don't pretend a Linux-only solution
  when an equivalent BSD feature would clarify the design.
- **GUI craft** — typography (system fonts, fallbacks, monospace
  rendering, kerning, fractional scaling at 1.25x/1.5x/2x), icon
  systems (hicolor index, scalable SVG vs raster sizes, symbolic vs
  full-color), color theory (light/dark theme matching, contrast
  ratios meeting WCAG AA), spacing rhythm (4 / 8 / 16 px grid),
  accessibility (keyboard-only navigation, screen-reader semantics,
  focus rings that don't lie), motion (transitions ≤ 200 ms or you
  feel laggy), and the Wayland app_id contract that decides whether a
  window groups correctly in the dock. Bad GUI hides good engineering.
- **Video — editing, encoding, mastering** — ffmpeg pipelines
  (filter_complex, hwaccel paths: NVENC / VAAPI / QSV), codec choice
  (h264 baseline for compatibility, h265/HEVC for archive, AV1 for
  shipping, VP9 for legacy web), container semantics (mkv = the
  honest container, mp4 = streamer requirement, webm = browser
  fallback), color spaces (Rec.709 SDR, Rec.2020 PQ/HLG HDR — don't
  flatten one to the other), bitrate ladders (CRF for archival,
  capped CRF for delivery, ABR ladders for streaming), audio tracks
  (don't lose 5.1 down-mixing to stereo without an explicit pass).
- **Audio — production, post, mastering** — PipeWire as the modern
  default with PulseAudio/JACK compat shims; ALSA at the kernel
  boundary; sample-rate (44.1k/48k/96k) and bit-depth (16/24/32f)
  choices matched to source; gain staging (peaks no higher than
  -3 dBFS pre-master); the mastering chain (EQ → multiband comp →
  limiter); LUFS targets (-14 streaming, -23 broadcast, -16 podcast);
  metadata correctness (BWAV timestamps, ID3, Vorbis comments). On
  Linux: Carla / qpwgraph for routing, JACK transport for sync,
  LV2/VST3/CLAP plugin formats.
- **Music production on Linux** — Ardour and REAPER as the
  professional DAWs; Bitwig for modern workflows; MIDI 2.0 awareness;
  soundfonts (sf2/sf3) and SFZ; sample libraries via LinuxSampler;
  the LADSPA → LV2 → CLAP plugin evolution. Real-time kernels
  (`kernel-rt`) and CPU isolation matter when latency goes below
  10 ms. Know when low-latency posture costs more than it earns.

### Rigor rules — non-negotiable

These exist because the failure mode for kldload is *"the install
succeeds, the operator reboots into a brick, three hours of homelab
time lost."* Every rule below has a real incident behind it from this
repo's history.

1. **Fail loud, not silent.** No `|| true`, no `--skip-broken`,
   no `2>/dev/null` unless you can write the one-line reason in a
   comment naming a specific failure case it's covering. b652 silently
   dropped `webkitgtk6.0` from the install because `--skip-broken` ate
   the package — that's exactly the kind of "convenience" flag that
   creates ghost installs.
2. **`set -Eeuo pipefail` at the top of every script. No exceptions.**
   `-E` so traps fire inside functions, `-u` so unbound variables die
   before they corrupt state, `-o pipefail` so a failed `dnf install`
   piped through `grep` doesn't return 0.
3. **Verify before claiming done.** A change isn't done because the
   string is in the file. It's done when:
   - `shellcheck -S error` and `shfmt -d -i 4` are clean,
   - `bash -n` passes,
   - the smallest possible smoke test that actually exercises the
     change has run and passed, and
   - on the install/build path: the artifact has been inspected
     (mount the squashfs, grep the rootfs, dd the USB).
   If any of those can't be done in this environment, say so
   explicitly and don't claim it's done. The b652 "I verified the
   string is in profiles.sh" without checking the actual dnf install
   succeeded is the failure mode this rule prevents.
4. **No package install path that can silently skip.** Any deps
   required for `kldload-webview` / `kldload-webui` / boot-critical
   code paths must install with no `--skip-broken`, with a clearly
   logged FATAL on failure, AND must have a `kldload-firstboot`
   healing net that re-attempts and logs. Two independent failsafes.
   That's the b653 pattern; copy it for anything else of the same
   class.
5. **Distro-portable by default, distro-specific by intent.** When
   the kldload matrix has nine substrates (RHEL/Rocky/CentOS Stream/
   Fedora/Debian/Ubuntu/Arch + Windows klab + the implied BSD posture),
   a change that only works on one of them must be inside an explicit
   `case "$distro" in` (or equivalent) with sensible behaviour for the
   others. Don't hardcode `dnf` when `apt`/`pacman` users will hit it.
6. **Think about the failure surface before writing the code.**
   Before changing anything that touches boot, storage, or networking:
   *"What if the disk is failing? The kernel just bumped? The repo is
   404? The user is reinstalling? Secure Boot is on / off? The package
   was renamed in this release?"* If you can't answer those, you don't
   understand the change yet.
7. **Use the right tool. Know why.** `bash` is the project default,
   but it isn't the right tool for stream processing of MB of text
   (use `awk`/`jq`), atomic file replacement (`mv` not `>`),
   or anything needing structured concurrency. `python3` is acceptable
   for the webui + installer-control plane; not for new shell scripts.
8. **Comment the *why*, never the *what*.** `# install nginx` adds
   noise; `# nginx because the webui needs an HTTP/2 reverse proxy
   that survives a hot-reload on cert rotation` is load-bearing.
9. **Never invent. Look it up, read the source, ask.** When you don't
   know the dnf exit-code semantics or whether `zfs set
   compression=zstd` works on a 2.1 pool — find out before guessing.
   Inventing API surfaces is how `WebKit.WebView.new_with_user_content_manager`
   crashed every kldload launcher on .139 b651.
10. **Tooling parity across kldload-supported distros.** If you add a
    feature that needs a package on Fedora, list its equivalent on
    Debian (`apt search` syntax differs), Arch (`pacman -Ss`), and at
    minimum note FreeBSD's `pkg search`. The matrix isn't theoretical;
    operators run all of these.

### What "good code" means in this repo

- **An SRE colleague reads it once and knows what it does, what
  fails, and what to grep for in the log.** No clever one-liners that
  hide the failure mode. No "smart" defaults that mask a missing
  config.
- **Every error path is at least logged.** Silent recovery is allowed
  *only* when you can name the specific harmless case the recovery is
  for (and you've commented it).
- **The script tells you exactly which line / which command died.**
  `set -E` + `trap 'echo "FAIL at line $LINENO running: $BASH_COMMAND"
  >&2' ERR` is a one-liner that turns a mystery exit-1 into an
  actionable bug report.
- **The change is reversible.** If something might be wrong, leave a
  breadcrumb (`/var/log/kldload/*.log`, an off-by-default flag, a
  ZFS snapshot pre-mutation). Operators should be able to undo a
  bad firstboot decision without reinstalling.

The bar isn't "passes the linter." It's *"the operator who finds the
log entry at 3am can fix it without paging anyone."* That's the
quality threshold; the lint rules just keep us honest while we aim
for it.

### The optimization / perfection mindset

Strive for the right thing done well, not the fastest thing done now.

- **Measure before optimizing**, then optimize what the measurement
  surfaced. No "I bet this loop is hot" — wire up `perf record`,
  `bpftrace`, `time`, `pv`, or a stopwatch + grep. Premature
  optimization is real, but so is the opposite failure mode of
  shrugging at a 4× slowdown that a 10-line patch would fix.
- **Right data structure, right algorithm, right syscall.** A
  Python set instead of a list comprehension. A `for f in dir/*` loop
  versus a `find … -exec`. `xargs -P` versus a serial chain. Be
  fluent enough that you don't have to think hard to pick correctly.
- **Polish the human-facing surface.** Error messages name the file
  and line that died. Progress lines distinguish *"working"* from
  *"hung."* `--help` is accurate, complete, and never lies. UI:
  icons match `StartupWMClass`, dark/light follows GNOME, focus rings
  are visible, fractional scaling doesn't rasterize text. Audio
  pipelines are gain-staged so nothing clips a master bus. Video
  bitrate ladders match the content's motion budget. Polish is what
  makes the difference between *competent* and *the operator's
  default tool.*
- **Optimization spans the stack, not just the hot function.**
  ZFS pool layout decisions cost or save GB-per-hour of throughput.
  systemd unit `After=` ordering decides whether boot is 8 s or
  35 s. Choosing TLS 1.3-only on the proxy buys an entire RTT back.
  CPU isolation + `kernel-rt` is what makes a DAW usable. Think one
  layer up and one layer down from where you're editing.
- **Perfection is a direction, not a destination.** Ship what's
  honestly correct, log every place that's *good enough for now*,
  and circle back. The honest log entry beats the half-true claim
  every time.

---

## 9. Documentation standard — OpenBSD-grade

OpenBSD's reputation isn't an accident: their man pages and source
comments are so thorough that future-them (or any operator paged at
3am) can act with confidence and without paging anyone else.

> **Undocumented code is a bug. Same severity as a wrong result.**

That's the principle behind everything in this section. A clever
script that works but nobody can safely modify is a liability waiting
to be triggered. Every script, function, config, and CLI tool in
this repo earns its keep by being explainable.

### The rule, plainly

> **Every file, every major section, every non-trivial function
> carries documentation that lets a stranger read it once and act on
> it correctly. Every operator-facing CLI tool ships with a man page
> that has at least one worked example per option. If the comment +
> the man page would let an operator hold the runbook on a single
> page, it's done. If it wouldn't, write more.**

That's the bar. The specifics below are how to hit it.

### What every shell script gets

1. **File header banner.** ASCII-ruled block at the top with:
   - One-line *what this script does* (no marketing words).
   - Numbered *what it does in order* — the operational story.
   - **Why** the script exists (the design intent — the thing that
     reading the code can't tell you).
   - Targets / inputs / outputs (paths, env vars, expected state
     before, expected state after).
   - **Notes** subsection for non-obvious behavior or invariants
     that bit us in production.
2. **Section header comments.** Every logical section opens with a
   `# ─── Name ─── ...` rule and 2–4 lines explaining the section's
   purpose and the design choice behind it. No "# install nginx" —
   instead "# nginx because the webui needs an HTTP/2 reverse proxy
   that survives `nginx -s reload` on cert rotation."
3. **Function preambles.** Every non-trivial function gets a comment
   block before its definition explaining: purpose, arguments
   (positional or named), return convention (stdout? exit code?
   global side-effect?), failure modes that callers need to handle,
   and an example invocation when the call site isn't obvious.
4. **Inline comments only when load-bearing.** A line of code that
   reads obviously gets no comment. A line that does something
   surprising (a workaround, a magic offset, a guarded race condition)
   gets a sentence explaining *why this and not the obvious thing*.

### What every Python script gets

Same posture in Python idiom:

- Module-level docstring at top with the same content as the shell
  header banner.
- Class and function docstrings in Google or numpy style — purpose,
  Args, Returns, Raises, Example.
- Section header comments inside long functions, using
  `# ── Name ── ...` so they visually align with the shell convention.
- Type hints everywhere (PEP 484). Type hints are documentation that
  the runtime + the IDE both consume.

### What every CLI tool gets — a man page

If it lives in `/usr/local/bin/`, `/usr/local/sbin/`, or `/usr/sbin/`
and an operator might invoke it directly, it ships with a man page
in mdoc format. Section 1 (`/usr/share/man/man1/<tool>.1`) for user
tools, section 8 (`/usr/share/man/man8/<tool>.8`) for sysadmin tools.
`--help` text is not a substitute — the man page is the contract.

#### Required sections (in OpenBSD order)

1. `NAME` — `<tool> – one-line summary`. The em-dash is a literal `\(en` or `–`.
2. `SYNOPSIS` — every invocation form, every flag, every positional arg.
3. `DESCRIPTION` — what it does, *why* it exists, and the design
   choices a reader would otherwise have to reverse-engineer.
4. **`OPTIONS`** — every flag listed with `.It Fl <flag>` and a full
   description. **Every option carries at least one worked example
   in EXAMPLES.** This is non-negotiable; an undocumented option is
   an undocumented behaviour.
5. `EXAMPLES` — minimum one worked example per option, plus a
   "common workflow" example combining the most-used flags. Show
   real-ish paths and outputs, not `foo`/`bar`.
6. `EXIT STATUS` (or `DIAGNOSTICS`) — every exit code the tool can
   return, what each one means, and what the operator does about it.
7. `FILES` — every path the tool reads or writes, with one line of
   purpose each.
8. `ENVIRONMENT` — every env var the tool consults, with a default
   value and an explanation of when overriding is appropriate.
9. `SEE ALSO` — related kldload tools, upstream man pages, RFCs,
   relevant CLAUDE.md sections.
10. `HISTORY` — when the tool was introduced (kldload release / build
    number), notable behaviour changes, with the incident or ticket
    that produced each one when it exists.
11. `AUTHORS` — `kldload <anthony@kldload.com>` plus credits where
    earned.
12. `CAVEATS` / `BUGS` — known limitations, race conditions, footguns
    the operator needs to know about. Empty is allowed only if you
    are certain there are none.

#### Mechanics

- mdoc(7) macros, not man(7). OpenBSD style. `mandoc -T lint <file>`
  must run clean before commit.
- Cross-references use `.Xr name 1` so `man -k` can index them.
- The man page commits in the same PR as the code change. *"I'll
  document it later"* is not in the workflow — it's a closed bug
  the moment it ships.
- When the tool changes behavior, the man page changes in the same
  commit. Stale man pages are worse than missing ones because they
  actively mislead.

#### Smell test (man-page specific)

Hand the man page to an SRE who has never touched the tool. They
should be able to:

1. Run the most-common invocation correctly on the first try.
2. Predict what every flag will do *before* trying it.
3. Diagnose a non-zero exit code without reading source.
4. Know which file or env var to change to alter behaviour.

If any of those fails, expand the relevant section.

### What every config file gets

For `.conf`, `.ini`, `.yaml`, `.toml`, `.repo`, `.service`, `.json`
(if comments are supported) and similar:

- File-top comment with the role of the file, what reads it, what
  writes it (if anything dynamic), and the consequence if it's
  missing.
- Comments above every non-default value explaining *why this value*
  and where the default would be wrong. The next operator should
  never have to grep documentation to know why we set
  `proxy_buffering off` here specifically.

### Note callouts

For non-obvious behavior worth setting apart from the surrounding
prose, use a labelled callout that future-greps will find:

```
# NOTE: this only runs when /etc/kldload/edition is missing — the
#       firstboot path writes that file, so subsequent boots take
#       the fast path. Don't add a force-rerun flag without also
#       handling the half-finished state in /var/lib/kldload/.
```

Other valid labels: `# WHY:`, `# WARN:`, `# SAFETY:`, `# PERF:`,
`# AUDIT:`, `# HISTORY:` (link to the incident that produced the
line). Operators learn to grep these.

### What you do NOT do

- **Don't repeat what the code says.** `# loop over files` above
  `for f in *.sh; do` is noise. Either delete the comment or upgrade
  it to explain *why this iteration order* or *why these files and
  not others.*
- **Don't paste a comment block that's already wrong.** Stale
  documentation is worse than no documentation. When you change
  behaviour, fix the comment in the same commit.
- **Don't doc-bomb to look thorough.** Every comment is a maintenance
  liability. A short, true, load-bearing sentence beats a paragraph
  of plausible-sounding filler.

### The smell test

Hand the file to a competent SRE who has never seen this codebase.
Five minutes later they should be able to answer:

1. What does this do?
2. When does it run / who calls it?
3. What fails it, and how does the failure look in the log?
4. What change would I make to bend it to a new use case?

If they can't, you didn't document enough — or you documented the
wrong things.

---

## 10. Automated checks — non-negotiable defaults

Linting, syntax checking, formatting verification, and the smallest
realistic smoke test happen **by default**, on every change, before
any "done" claim. Not a step the operator has to ask for. Not a
"when I remember" thing. Default.

The defaults below run automatically as part of the
*verify-before-done* loop in §8 rule 3. If a check can't run in this
environment (missing tool, no network), it's called out explicitly
in the response — never silently skipped.

### By file type — what fires every time

| File type | Mandatory checks | Optional but encouraged |
|-----------|-------------------|-------------------------|
| `*.sh`, `*.bash`, anything with `#!/usr/bin/env bash` | `shellcheck -S error` (must pass clean), `shfmt -d -i 4` (no drift), `bash -n` (syntax sanity) | `shellcheck -S warning` (extra signal), `shellcheck -x` if sourcing siblings |
| `*.py` | `python3 -m py_compile` (syntax), `ruff check --select=E,F,W,I` if available (else `pyflakes`), `mypy --strict` for new code, line-length cap at 100 | `black --check` if the repo uses black, `pylint` for deep audits |
| `*.yaml`, `*.yml` | `yq '.' file >/dev/null` (parse check) or `python3 -c 'import yaml; yaml.safe_load(open("..."))'` | `yamllint` if installed |
| `*.json` | `jq '.' file >/dev/null` (must round-trip) | `jsonschema` validation against a schema if one exists |
| `*.toml` | `python3 -c 'import tomllib; tomllib.load(open("...","rb"))'` (3.11+) | none |
| `*.service`, `*.timer`, `*.path` | `systemd-analyze verify <file>` (in chroot when target is install root) | `systemd-analyze security <unit>` for any unit with privilege |
| `*.desktop` | `desktop-file-validate <file>` (must be clean, zero errors) | `gtk-update-icon-cache --validate` when icons are referenced |
| `.repo`, `.list`, package list files | URL reachability check (`curl -sI` or apt-cache policy) | gpg signature spot-check |
| `Dockerfile` / `Containerfile` | `hadolint` (lint), `podman build --no-cache` of a smoke variant when feasible | `dive` for layer audit |
| `*.html`, `*.css` (the kldload SPA) | `tidy -q -e` for HTML, `csslint` if available | grep for the SPA wiring keys we know matter (`live_mode`, `kld-app`, `_kldSwitchView`) |
| `*.md` | `markdownlint` if installed (warn-only); spell-check optional | link-check on internal links |
| Configs in `.conf` / `.ini` syntax | a parser-equivalent that round-trips | grep for any obvious secret pattern |

### What runs *in addition* before claiming a build/installer change

Beyond the per-file checks above, install-path and build-path edits
get extra gates:

- **Build-iso.sh / kldload-install-target / kldload-firstboot:**
  shellcheck the whole tree of edited files, then `./deploy.sh
  smoke-build` if available, then mount the resulting squashfs and
  grep for the change you claimed to make (the b652 lesson).
- **Source `.desktop` files:** `desktop-file-validate`, **plus** an
  immediate cross-check that the `StartupWMClass` value matches the
  `app_id` your wrapper actually emits at runtime.
- **Anything install-time installs a package:** confirm the package
  resolves in the target's repo *now* (`dnf info`, `apt-cache
  policy`, `pacman -Si`). A dependency that resolved last week
  shouldn't be assumed to resolve today.
- **Webview / SPA changes:** sync `index.html` ↔ `free/index.html`,
  verify both shas match, and grep both for the new identifiers.

### The fail-fast posture

A check that *fails* aborts the work and the failure is reported.
No "I'll just commit and fix the lint in a follow-up." No
`shellcheck disable=...` to silence a real warning without naming
the specific reason it's safe to suppress here. The lint baseline
goes one direction: cleaner.

### When the tool isn't installed

If a required check tool (e.g., `shellcheck`, `hadolint`,
`desktop-file-validate`) isn't on the host, **install it** — the
defaults aren't optional. For RHEL/Fedora install via `dnf`; for
Debian via `apt`; for Arch via `pacman`. If the install requires
sudo and isn't authorized, that's a stop condition: report the
missing tool, explain the impact, ask for permission. Don't
proceed with "looks fine to me."

---

## 11. Documentation & website sync — every change, every release

Documentation, the public website, and git **stay in lockstep**.
Drift between any two of them is a defect at the same severity as
a wrong result (§9 already says undocumented code is a bug; this
section extends that to artifacts the user-facing world sees).

The rule, stated once: **if a change alters behavior, capabilities,
defaults, dependencies, or anything an operator would Google,
update the documentation and the website in the same change-set
that ships the change.** Not in a follow-up. Not "I'll batch the
docs at end of week." In the same change-set.

### What "in sync" means concretely

| Surface | Lives at | Owner of truth | Sync trigger |
|---|---|---|---|
| Repo `CLAUDE.md` | `~/kldload/CLAUDE.md` | the kldload repo | every commit that changes a rule, identity, build path, or workflow Claude relies on |
| Repo `README.md` and `ci/README.md` | the kldload repo | the kldload repo | every commit that changes setup, command names, env vars, or operator-visible flags |
| Tool man pages (`man/man*/*`) | the kldload repo | the kldload repo | every commit that changes a CLI option, exit status, env var, or file path |
| In-script `--help` banners | the kldload repo | the kldload repo | every commit that changes a flag's behavior (the banner is the contract) |
| `claude-brain` repo (`CLAUDE.md` + memories) | `git@github.com:kldload/claude-brain.git` | mirror of kldload `CLAUDE.md` + Claude's memory | every commit that edits the source-of-truth `CLAUDE.md` or any persistent memory |
| Public website | the kldload website repo / hosted source | matches the latest stable release | every release tag, every changelog entry, every UI screenshot affected |
| Release notes / changelog | wherever the release is published | the release commit | every release build |
| R2 (object storage) artifacts | `kldload` R2 bucket(s) | matches the release tag exactly | every release build pushed to R2 |

### The release-build invariant (R2 included)

A release build is **not done** until *all* of these are true in
the same change-set or the immediately-following release commit:

1. **Tag exists** on the kldload repo at the exact commit the ISO
   was built from. No "release built off a dirty tree."
2. **Changelog** at the tag explains, in operator terms, every
   user-visible change since the previous tag — new features,
   removed packages, changed defaults, deprecations, known issues.
3. **Website pages** for any changed screen / capability /
   installer flow are updated. If a UI element moved or a default
   flipped, the page that describes it is edited in the same
   release commit. Screenshots refreshed when they no longer
   reflect the build.
4. **Man pages** for any tool whose options changed are updated,
   and `mandoc -T lint` is clean on all of them.
5. **R2 artifacts** (ISO, sha256, sig if signed, release notes) are
   uploaded under the same version key the website and changelog
   point at. The website's download link MUST resolve to the
   artifact published in step 5 — no "release notes say b660, R2
   has b659" mismatch. R2 is the public artifact source of truth;
   if it's stale, the operator's download is wrong.
6. **claude-brain** has the new `CLAUDE.md` and any new memories
   committed and pushed. If a release introduces a workflow rule
   Claude needs to know about, the brain isn't allowed to lag.
7. **Smoke verification** that all of the above are consistent:
   the changelog version, the ISO filename, the website download
   button, and the R2 key all reference the same build id.

### When a non-release change still moves the docs

Most commits aren't release commits, but they still might move
documentation. The guardrail:

- **New CLI option or env var** → man page + `--help` banner in
  the same commit. No "documented later."
- **Renamed / removed flag** → search the website, README, and
  changelog for references; update or replace each occurrence.
- **Changed default** (e.g., USB device, model, profile) → call it
  out in the changelog AND the relevant doc page, even if the new
  default seems harmless. Operators rely on defaults.
- **Removed or renamed file/path** → grep the kldload repo, the
  website repo, and `claude-brain/memory/` for references; fix all
  of them in the same change.
- **Rule added to `CLAUDE.md`** (like this one) → mirror the change
  into `claude-brain/CLAUDE.md` and push both, otherwise the
  durable brain forgets the rule on the next restore.

### How to check sync before declaring done

A change-set is in sync when the answers below are all "yes":

1. Every operator-visible change in the diff has a corresponding
   docs/site edit in the same change-set?
2. Every man page for a touched CLI passes `mandoc -T lint` clean?
3. Every `--help` banner reflects the actual code path?
4. The website's relevant page reflects the new state (or has a
   queued edit in the website repo before the release tag lands)?
5. The release tag, changelog, website download link, and R2 key
   all reference the same build id (release commits only)?
6. `claude-brain` contains the same `CLAUDE.md` as the kldload
   repo and any new memory the change implies?

If any answer is no, the change isn't done — finish the sync work
or carve out an explicit follow-up commit / issue before claiming
otherwise. "Forgot to update the docs" is the same kind of bug
report as "forgot to update the code."

### The cheap-shortcut to avoid

Don't squirrel doc updates into "we'll do a docs pass before the
release." That pass never happens cleanly because nobody
remembers every change. The discipline is: write the doc edit
*while you have the change in your head*, in the same commit that
makes the code edit. The cost is low; the cost of the alternative
is the website drifting weeks behind the binary the operator just
downloaded.
