# kld forms — pick, don't type (design)

Captured 2026-09-28 from the operator after driving kld for a VDI wall on
onyx: "the problem with the tui is it's not auto filling stuff in, or there's
no easy way to select stuff ... take all the yuck out of the commands ... fill
in an editable command ... having command history would be nice ... I want to
make it as fast as possible and intuitive." Status: **design, not
implemented**.

## One sentence

Enter on anything kld can run opens a form: every option is a menu or a
number you nudge, prefilled with a working example; the command it will run is
shown live underneath, editable; Enter runs it; the last runs are one key away.

## What it replaces

| Today | Why it is yuck |
|---|---|
| Build tab: `x` runs the row's fixed `cmd`, `X` asks for ONE free-text argument ("X: one distro", "X: N, default 3", "X: <image> <count>") | the options are in the row's description text; the operator has to read, remember and type them |
| verb prompts: `kfire clone <golden> [options]: `, `clone {} as <name> [count] [--snap @name]`, `kvm-create <name> [--ram MB] [--cpus N] [--disk GB] [--iso path]` | a man-page synopsis as a prompt; nothing is filled in, nothing is chosen from what exists |
| no history | the same `kfire clone app-vdi-deskto -n 2 --wait` typed again from scratch |

The microVMs tab on 2026-09-28 is the case in point: the operator saw an empty
tab, had to be told the golden's name (`app-vdi-deskto`, a truncated slug
nobody would guess), and to type `-n 2 --wait` from memory.

## The model

A **form** is attached to a Build row or a verb. It has:

- **fields**, each one of:
  - `choice` — a menu. Choices come from a **live source** (the goldens kfire
    has, klab distros, VMs, images in /srv/images, networks, pools) or a
    static list (1/3/5 control planes; qcow2/raw/vhd/vmdk). Never typed when
    it can be picked.
  - `number` — `+`/`-` or type; bounds and a unit (count, MB, GiB, vCPUs).
    Where it matters the form shows the arithmetic (see Admission).
  - `name` — text, prefilled with a unique suggestion (`vdi-3` when vdi-1
    and vdi-2 exist), validated as you type (kld's nameOK).
  - `toggle` — on/off (`--wait`, "rebuild the golden first").
  - `path` — a file, with completion from the filesystem.
- a **command template** that turns the fields into argv — the one place the
  command's syntax lives.
- an **example**: the defaults ARE a runnable command, so Enter-Enter works.

## The screen

```
 kubernetes: build the HA cluster ─────────────────────────────────────
   control planes    [ 1   3   5 ]        ← → to pick
   workers           [ 3 ]  (0-12)        + - or type
   worker RAM        [ 4096 ] MB
   rebuild golden    [ no ]
 ──────────────────────────────────────────────────────────────────────
 $ kube-cluster bootstrap --control-planes 3 --workers 3
   needs ~19 GB (6 × ~3 GB + host 1 GB); 14.4 GB free now  ← admission
 ──────────────────────────────────────────────────────────────────────
 ↑↓ field · ←→ choose · tab: edit the command · ctrl+r history · enter run · esc
```

- **Enter on a Build row opens its form** (the operator: "the what-it-builds
  becomes the menu"). `x` keeps "run it now with the defaults"; `X` becomes
  an alias for the form, so nobody's muscle memory breaks (core §5c.7).
- **The command line is live and editable.** Changing a field rewrites it;
  `tab` moves into it for anything the form does not model; once edited by
  hand it stops following the fields and says so ("edited — fields no longer
  drive it; ctrl+z to go back").
- **History:** `ctrl+r` (and ↑ in the command line) walks this form's previous
  runs, newest first, with when and the outcome (exit 0 / failed).
  Per form, persisted in `~/.local/state/kld/history.jsonl` (the operator's
  own, 0600), capped (500 entries). Never stores a field marked secret (the
  zfs load-key passphrase, RHEL credentials).
- **Verbs get the same forms:** clone (`c`: count, name prefix, snapshot to
  clone from, picked from that VM's snapshots), microVM clone (golden from
  kfire's list, count, RAM, `--wait`), new VM (`n`: distro/ISO picked, sizes),
  vcpus/memory (`v`), grow disk (`+`). One component, used everywhere.

## Admission and help, in the form

The form knows what the command costs before it runs, where that is cheap to
compute: VMs × RAM against MemAvailable (the 50-VDI question — onyx had 14 GB
free once the ARC was capped, fiend's ARC is allowed 31 GB); a clone count
against the free DHCP range; disk against the pool's free space. It warns, it
does not refuse: the operator decides. Each field has one line of help (why
3 control planes: "survives losing one").

## Forms for the Build tab (first set)

| Row | Fields -> command |
|---|---|
| klab golden / desktop / kde / xfce / db / ztest | distro [all, centos, rocky, fedora, debian, ubuntu] -> `klab <verb> <distro>` |
| kubernetes golden | rebuild [no/yes] -> `kube-cluster golden` |
| kubernetes: build the HA cluster | CPs [1,3,5], workers [0-12], worker RAM, rebuild golden -> `kube-cluster bootstrap --control-planes N --workers M` |
| kubernetes: add workers | how many [1-12] -> `kube-cluster scale N` |
| kubernetes: control planes | [1,3,5] -> `kube-cluster scale --control-planes N` |
| all appliances / one appliance | tiles (multi-select from `vmx --appliances`) -> `vmxplore --build-all --only A,B` |
| export this host's image | format [qcow2, raw, vhd, vmdk, all] -> `kimage export F` |
| deploy VMs from an image | image (from /srv/images), count -> `kimage deploy I N` |
| build your own golden / VM | name, base [distro or VM], post-install [file or command] -> `kvm-golden …` |
| verify the goldens | distro -> `klab verify D` |

## Implementation notes (for later)

- Where it lives: a `form` type in kld (fields, source funcs, template),
  rendered as an overlay like today's input line; `buildRow` and `verb` gain a
  `form` field; `arg`/`prompt` stay as the fallback until every row has one.
- Live sources reuse the collectors kld already has (kfire goldens, VMs,
  networks, pools) — no second way of listing the same thing.
- Tests: each form's defaults render the documented example command; a
  template never emits an empty or unquoted field; history never records a
  secret field (a fixture asserts the file does not contain it).
- The TUI is driven the way smoke-console drives it (tmux, keystrokes, read
  the screen): Enter on a row opens the form, defaults + Enter runs the
  example.

## Open decisions (operator)

1. `x` = run with defaults at once, Enter = form (as above), or Enter = form
   and drop `x`?
2. History: per form (above) or one shared list across kld?
3. Should vmxplore's TUI get the same forms, or is kld the one console
   (ONE-CONSOLE.md) and vmxplore's TUI frozen?
