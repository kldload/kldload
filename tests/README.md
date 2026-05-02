# kldloadOS Smoke Tests

Automated verification at three layers:

1. **Build-time** (`smoke-build.sh`) — sanity-check the just-built ISO file
2. **Install lifecycle** (`lifecycle.sh`) — boot the ISO in a throwaway KVM
   VM, drive the installer headlessly, reboot, run the post-install suite
3. **Post-install** (`smoke-{auto,core,server,kvm,desktop}.sh`) — verify
   the booted system

Layer 2 closes the loop. Run it before every USB burn.

## Quickstart

```bash
# After ./deploy.sh build, validate the ISO (fast, no VM)
./deploy.sh smoke-build

# Full lifecycle smoke (boot → install → reboot → verify) — ~25-35 min
sudo ./deploy.sh smoke-test centos server
sudo ./deploy.sh smoke-test debian desktop
sudo KEEP_VM=1 ./deploy.sh smoke-test fedora kvm   # keep VM on success
sudo SB_ON=1 ./deploy.sh smoke-test centos server  # boot with Secure Boot on
```

On failure the VM is left running; inspect with `virsh console <name>`
or VNC (`virsh vncdisplay <name>`). On success it's destroyed unless
`KEEP_VM=1`.

## Test matrix

| | CentOS 9 | Debian 13 | Ubuntu 24.04 | Fedora 44 | Rocky 9 | RHEL 9 | Arch |
|---|---|---|---|---|---|---|---|
| **Desktop** | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh |
| **Server**  | smoke-server.sh  | smoke-server.sh  | smoke-server.sh  | smoke-server.sh  | smoke-server.sh  | smoke-server.sh  | smoke-server.sh  |
| **KVM**     | smoke-kvm.sh     | smoke-kvm.sh     | smoke-kvm.sh     | smoke-kvm.sh     | smoke-kvm.sh     | smoke-kvm.sh     | smoke-kvm.sh     |
| **Core**    | smoke-core.sh    | smoke-core.sh    | smoke-core.sh    | smoke-core.sh    | smoke-core.sh    | smoke-core.sh    | smoke-core.sh    |

## Manual post-install runs

```bash
# Run on a freshly installed kldloadOS system
sudo bash /path/to/tests/smoke-core.sh       # ZFS, SSH, network basics
sudo bash /path/to/tests/smoke-server.sh     # + tools, sanoid, WireGuard, eBPF
sudo bash /path/to/tests/smoke-kvm.sh        # + KVM, libvirt, virbr0, K8s tools, kzfs-lab
sudo bash /path/to/tests/smoke-desktop.sh    # + GNOME, GDM, Firefox

# Auto-detect profile and run appropriate test
sudo bash /path/to/tests/smoke-auto.sh
```

## What gets tested

### All profiles (core)
- ZFS pool health (ONLINE, no errors)
- ZFS dataset hierarchy
- ZFS module loaded, bootfs set
- EFI partition mounted, ZFSBootMenu present
- SSH running, network connectivity
- Hostid, OS branding

### Server + KVM + Desktop
- k* tools (kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery)
- kldload-help, kldload-overview, kube-demo
- Sanoid timer + config + defaults.conf
- Snapshot automation (kpkg triggers snapshot)
- Boot environments (kbe create/list/delete)
- WireGuard module + tools
- eBPF (bpftrace, bcc-tools, BTF)
- NVIDIA (if installed)
- Build ID + profile marker

### KVM profile
- libvirtd running, virsh, virt-install, qemu-img
- virbr0 active + autostart
- KVM tools (kvm-create, kvm-clone, kvm-snap, kvm-delete, kvm-list, kvm-demo)
- Kubernetes tools (kube-cluster, kube-init, kube-join, kube-network, kube-setup, etc.)
- kzfs-lab (ZFS dev lab)
- sshpass (SSH automation)
- Podman
- K8s cluster verification (if deployed): nodes, pods, Cilium

### Desktop
- GNOME session, GDM running, Firefox
- Display manager target = graphical

## Adding tests

All tests use `lib-test.sh` helpers:
- `test_cmd "label" "command"` — check command exists
- `test_file "label" "/path"` — check file exists
- `test_dir "label" "/path"` — check directory exists
- `test_service_active "label" "unit"` — check systemd service active
- `test_service_enabled "label" "unit"` — check systemd service enabled
- `test_succeeds "label" "command"` — check command exits 0
- `test_output_contains "label" "command" "string"` — check output contains string
- `_pass "msg"`, `_fail "label" "detail"`, `_warn "label" "detail"` — manual pass/fail/warn

## When to add a check

Every regression that bites on hardware should result in a new check
here so the next regression is caught in `smoke-test` before the burn.
Concrete heuristic: when you fix a bug and write a commit message that
describes a failure mode (boot loop, crash loop, missing module, wrong
service state, signature rejection, etc.), grep for the relevant check
in `smoke-{core,server,kvm,desktop}.sh` — if it isn't there, add it
before closing the bug.

Examples of checks added because they bit us first:
- `mokutil --sb-state enabled` + `mokutil --list-enrolled | grep kldload`
  (caught the empty-MOK-list bug)
- `lsmod | grep -q '^zfs'` + `zpool list -H` (caught the stamp-mismatch
  hostid bug)
- `systemctl is-active gdm` + `! grep TRAP` in journal (caught the GDM
  crash loop on missing nvidia.ko)
- `[[ -e /sys/class/drm/card0 ]]` (would have caught the nouveau-blacklist-
  with-no-nvidia-module case before it shipped)
