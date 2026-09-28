# One console: kld and vmxplore become one tool

Status: plan, 2026-09-27. Nothing below is built yet except where it says so.

## Why

The operator, 2026-09-27: "i want kldload that has both the gui and the tui ..
the kld tool is awesome but it doesn't need to be a different tool." Today there
are two:

| | kld | vmxplore |
|---|---|---|
| where | `kld/` in this repo | its own repo, `vmxplore/vmxplore` |
| size | 22 files, ~10,000 lines | 106 files, ~30,700 lines |
| surfaces | TUI (bubbletea); `--gui` is only the TUI in a terminal window | native GUI (Fyne) and a TUI (bubbletea) |
| build | pure Go, `CGO_ENABLED=0`, one static binary | two builds: static TUI, and `-tags gui` with cgo and a vendored GLFW |
| strengths | ten sections, the whole platform: storage, network, cluster, estate, provision | the estate GUI, a real VM screen viewer, appliances, the Factory, selftests |

Two tools means two estate models, two VNC clients (kld's `vnc.go` is
vmxplore's minus Fyne), two sets of verbs to keep in step, and a question every
operator has to answer before they start: which one?

## What "one tool" means here

One binary, `kld`, with every surface:

- **In a terminal:** the TUI, as today.
- **With a display** (a desktop session, or `cage` on a bare console): the
  native GUI, the frame vmxplore has now, organised by kld's ten sections.
- **One VM's screen, nothing else:** `kld console VM`, the console mode just
  added to vmxplore as `--console VM` (feat/console-mode, 6c26146). On a host
  with no desktop, `w` in the TUI runs it under `cage`, which every kldload
  install already carries for the install kiosk. Proven by hand on fiend on
  2026-09-27: a full GNOME desktop of a VM, from a text prompt.

`vmxplore` and `vmx` stay as names that run `kld` with the same flags for at
least one release, and say so on stderr, so nothing that calls them breaks.

## Plan, in order

1. **Bring vmxplore into this repo with its history.** `git subtree add` under
   `vmxplore/`, still building on its own. Nothing moves yet; the point is one
   tree and one review path. The vmxplore repo gets a notice pointing here.
2. **One estate layer.** vmxplore talks to libvirt through its `LV` layer; kld
   shells out to `virsh` and reads the state DB. Pick one and make the other
   call it. I lean to vmxplore's layer for libvirt and kld's for the state DB
   and the estate (kldload-estate, the mesh members files): each is the better
   half of its tool.
3. **One VNC client.** kld's `vnc.go` came from vmxplore's; keep vmxplore's
   (it has the viewer, clipboard and resize) and make kld's cell renderer and
   serial fallback sit on top of it.
4. **The GUI moves under kld.** vmxplore's Fyne frame becomes `kld --gui`, its
   panes mapped onto kld's sections (Machines is most of vmxplore; Storage,
   Network, Cluster, Estate and Provision get GUI panes as they are wanted).
   Build tags as vmxplore has them: `-tags gui` for the full binary,
   `CGO_ENABLED=0` for a static TUI-only fallback.
5. **One TUI.** vmxplore's TUI features that kld does not have yet are ported
   (vmxplore bound fifteen verbs, marks and batch and a Factory pane in its TUI that kld has only partly), then `vmx --tui`
   starts kld.
6. **Console mode as a kld verb:** `kld console VM`, and `w` on a bare VT runs
   `cage -- kld console VM`.
7. **Build and ship one binary.** build-iso.sh builds kld with `-tags gui` for
   Fedora and Debian (the GUI's libraries are already on every install: in a
   bare fedora:44 container with only the kiosk packages, `ldd vmxplore` went
   from 11 missing to 0; Debian not checked), and the static build where cgo
   cannot go. The `vmxplore`/`vmx` names become compatibility wrappers.
8. **Tests follow the code.** vmxplore's selftests and gui_keys tests, kld's
   smoke-console and TestOneUTF8, run from one `go test` and from smoke-build.

## Risks and what would stop it

- **cgo in the ISO builder.** kld builds static today; the GUI build needs cgo
  and GLFW's headers in the builder container. vmxplore already does this for
  the ISO, so the pieces exist; they move.
- **Binary size.** The GUI build is about 40 MB against kld's 13 MB. Fine on a
  host, worth noting for the net image.
- **Debian.** The GUI's libraries are proven present only on Fedora so far.
- **Losing vmxplore's standalone use.** Anyone running vmxplore outside
  kldload keeps the repo at its last release; new work lands here.
- **Size of the change.** Roughly 40,000 lines meet. Each step above is its own
  branch and its own tested merge, not one big move.

## Decisions for the operator

- The binary's name: `kld` (short, already on every install), with `kldload`
  as an alias, or the other way round.
- Whether the vmxplore repo is archived after step 1 or kept for a release.
