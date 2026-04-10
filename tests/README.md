# kldloadOS Smoke Tests

Automated post-install verification for every distro x profile combination. Run on a freshly installed system to verify everything works.

## Test Matrix

| | CentOS 9 | Debian 13 | Ubuntu 24.04 | Fedora 41 | Rocky 9 | RHEL 9 | Arch |
|---|---|---|---|---|---|---|---|
| **Desktop** | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh | smoke-desktop.sh |
| **Server** | smoke-server.sh | smoke-server.sh | smoke-server.sh | smoke-server.sh | smoke-server.sh | smoke-server.sh | smoke-server.sh |
| **KVM** | smoke-kvm.sh | smoke-kvm.sh | smoke-kvm.sh | smoke-kvm.sh | smoke-kvm.sh | smoke-kvm.sh | smoke-kvm.sh |
| **Core** | smoke-core.sh | smoke-core.sh | smoke-core.sh | smoke-core.sh | smoke-core.sh | smoke-core.sh | smoke-core.sh |

## Usage

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
