# KVM / libvirt examples

kldload boxes are the hypervisor — libvirt is built in, virt-install
ships, and the kldload kube-cluster tool uses these primitives to
spawn the K8s VMs. These examples show the same primitives the
operator can drive directly.

| File | What it does |
|---|---|
| `01-cloud-image-vm.yml` | Ansible playbook: download a stock cloud image, cloud-init it, boot. Headless serial console. |
| `02-clone-from-golden.sh` | Shell: clone a kldload-built golden image to a new VM via `zfs clone` (sub-second) |
| `03-zfs-disk-attach.yml` | Attach a raw ZFS zvol as a virtio-blk disk to a running VM |
| `04-domain.xml.template` | Hand-written libvirt domain XML — copy as a starting point for custom VM specs |

## Quick reference

```bash
# List all libvirt VMs (kldload + manually-created)
virsh list --all

# Get console of a serial VM (Ctrl-] to detach)
virsh console <name>

# Hard stop / start / destroy
virsh shutdown <name>   # graceful
virsh destroy <name>    # power-pull
virsh undefine <name> --remove-all-storage  # gone forever

# DHCP leases on the kldload default virbr0
virsh net-dhcp-leases default
```

## kldload-shipped goldens

These already exist on every klab/kvm/zfslab install — base them on
instead of downloading from upstream every time:

```bash
ls /var/lib/libvirt/images/   # kldload-*-golden.qcow2
zfs list rpool/klab/goldens   # kldload-managed ZFS-cloned goldens
```
