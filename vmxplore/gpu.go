// gpu.go — what graphics hardware the hypervisor has, and what that unlocks.
//
// What it does, in order:
//  1. Lists the display controllers on the machine that runs the VMs, by
//     reading sysfs rather than shelling out to lspci — sysfs is always
//     there, lspci is a package.
//  2. Names them: vendor from the PCI id, model from lspci when it happens
//     to be installed, and the kernel driver bound to each right now.
//  3. Reports whether the IOMMU is on, which is the difference between
//     "there is a GPU here" and "a GPU could be given to a guest".
//
// Why: vmxplore tiers itself by what the host can DO — probes, never
// licence checks or config files (the same rule rules.go follows for the
// kldload toolset). A GPU on the hypervisor is one of those tiers: it is
// what makes an NVIDIA guest worth offering, and offering it on a machine
// with no GPU would be a button that can only disappoint.
//
// Inputs:  the connection target (remote.go) — local sysfs, or the same
//
//	over ssh when driving a remote hypervisor, because the GPU that
//	matters is the one attached to the VMs, not to the laptop.
//
// Outputs: []GPU, and the two questions callers actually ask.
//
// Notes: class 0x03xxxx is "display controller" in the PCI spec — 0x030000
// VGA, 0x030200 3D controller (which is what a headless compute card
// reports). Both count. A card already bound to vfio-pci is not a fault:
// it means somebody has prepared it for passthrough, and saying so is more
// useful than hiding it.
package main

import (
	"os/exec"
	"strings"
)

// GPU is one display controller on the hypervisor.
type GPU struct {
	Addr   string // PCI address, e.g. 0000:3d:00.0
	Vendor string // NVIDIA / AMD / Intel, else the raw id
	Model  string // lspci's name when available, else the device id
	Driver string // kernel driver bound now: nvidia, amdgpu, vfio-pci, none
}

// IsNVIDIA reports whether this is an NVIDIA card. PCI vendor 0x10de.
func (g GPU) IsNVIDIA() bool { return g.Vendor == "NVIDIA" }

// PassedThrough reports whether the card is already bound to vfio-pci,
// i.e. prepared to be handed to a guest rather than driven by the host.
func (g GPU) PassedThrough() bool { return g.Driver == "vfio-pci" }

// pciVendors covers the three that ship display controllers people run
// VMs on. Anything else is reported by its raw id rather than guessed at.
var pciVendors = map[string]string{
	"0x10de": "NVIDIA",
	"0x1002": "AMD",
	"0x8086": "Intel",
}

// hostShell runs a snippet on the machine that runs the VMs: here when the
// target is local, over ssh when it is not. Returns stdout with a trailing
// newline trimmed, and "" on any failure — every caller treats "no answer"
// and "no hardware" the same way, because a probe that cannot answer must
// not invent a capability.
func hostShell(script string) string {
	var cmd *exec.Cmd
	if target.SSHHost == "" {
		cmd = exec.Command("sh", "-c", script)
	} else {
		cmd = exec.Command("ssh", target.SSHHost, "sh", "-c", script)
	}
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

// gpuProbe walks sysfs and prints one "addr vendor device driver" line per
// display controller. It is a shell snippet rather than Go file reads so
// that the identical probe works over ssh against a remote hypervisor.
const gpuProbe = `for d in /sys/bus/pci/devices/*/; do
  c=$(cat "$d/class" 2>/dev/null) || continue
  case "$c" in 0x03*) ;; *) continue ;; esac
  drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
  echo "$(basename "$d") $(cat "$d/vendor") $(cat "$d/device") ${drv:-none}"
done`

// HostGPUs returns the display controllers on the hypervisor, nil when
// there are none or the probe could not run.
func HostGPUs() []GPU {
	out := hostShell(gpuProbe)
	if out == "" {
		return nil
	}
	var gpus []GPU
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		g := GPU{Addr: f[0], Driver: f[3], Model: f[2]}
		if v, ok := pciVendors[f[1]]; ok {
			g.Vendor = v
		} else {
			g.Vendor = f[1]
		}
		gpus = append(gpus, g)
	}
	nameGPUs(gpus)
	return gpus
}

// nameGPUs fills in Model from lspci when that is installed. Best effort by
// design: the PCI device id already identifies the card unambiguously, and
// a missing package must not turn a working probe into an empty one.
func nameGPUs(gpus []GPU) {
	if len(gpus) == 0 {
		return
	}
	out := hostShell("command -v lspci >/dev/null 2>&1 && lspci -mm 2>/dev/null")
	if out == "" {
		return
	}
	// A line reads:
	//   3d:00.0 "VGA compatible controller" "NVIDIA Corporation" \
	//     "GA102 [GeForce RTX 3080]" -ra1 -p00 "EVGA Corporation" "Device 3897"
	// Splitting on the quote character puts the quoted fields at the odd
	// indices, so the device name — the third quoted field — is q[5].
	// WARN: q[7] is the SUBSYSTEM vendor ("EVGA Corporation"), which is the
	// board partner, not the card. Reporting that as the model is how a
	// 3080 comes out named after the company that boxed it.
	for i := range gpus {
		short := strings.TrimPrefix(gpus[i].Addr, "0000:")
		for _, line := range strings.Split(out, "\n") {
			if !strings.HasPrefix(line, short+" ") {
				continue
			}
			if q := strings.Split(line, `"`); len(q) >= 6 {
				gpus[i].Model = strings.TrimSpace(q[5])
			}
			break
		}
	}
}

// IOMMUEnabled reports whether the hypervisor booted with an IOMMU, which
// is the gate on handing a card to a guest at all. Without it a GPU can
// still drive the host, and the guest can still get the driver installed —
// it just has nothing to drive.
func IOMMUEnabled() bool {
	return hostShell(`ls /sys/kernel/iommu_groups 2>/dev/null | head -1`) != ""
}

// NVIDIAHost reports whether the hypervisor has an NVIDIA card at all —
// the one question the New VM dialog asks before offering the guest driver
// layer, since installing several hundred megabytes of driver on a machine
// that will never see a GPU is only a way to waste ten minutes.
func NVIDIAHost(gpus []GPU) bool {
	for _, g := range gpus {
		if g.IsNVIDIA() {
			return true
		}
	}
	return false
}

// ─── the guest side ──────────────────────────────────────────────────
//
// nvidiaGuestScript makes a Debian guest ready to drive an NVIDIA card.
// It is a LAYER: composed onto whatever post-install the operator or an
// appliance already supplies, exactly as the writing desktop is composed
// onto the WriteFreely server script.
//
// The order matters and each step earned its place:
//
//  1. The cloud image ships "Components: main" only — verified on a live
//     Debian 13 guest, where nvidia-driver has no installation candidate
//     at all until contrib and non-free are enabled.
//  2. The driver is a kernel module built by DKMS, so it needs headers
//     that match the RUNNING kernel. The cloud kernel flavour has no DRM
//     and is the wrong host for a GPU driver, so the generic kernel and
//     its headers go on together.
//  3. grub prefers the cloud kernel (same version, and its name sorts
//     later), so the generic entry is named explicitly or the machine
//     reboots straight back into a kernel the driver cannot load into.
//     This is the same trap the writing desktop hit; see appliances.go.
//  4. One reboot, then nvidia-smi is the proof. Its output lands in the
//     cloud-init log and on both consoles.
//
// WARN: this installs from Debian's non-free component. Nothing is
// redistributed here — the guest fetches it from Debian — but the
// operator is accepting NVIDIA's licence, and a catalog entry that uses
// this layer should say so in its notes.
//
// WARN: DKMS rebuilds on every kernel update, which is where a VM comes
// back without its GPU after an unattended upgrade. Seal a golden and
// clone from it rather than running this per machine.
const nvidiaGuestScript = `
# ─── NVIDIA drivers ──────────────────────────────────────────────────
if ! command -v apt-get >/dev/null 2>&1; then
    echo "WARN: NVIDIA layer supports Debian/Ubuntu guests only — skipping" >&2
else
    export DEBIAN_FRONTEND=noninteractive

    # deb822 sources on trixie: widen Components in place. The older
    # one-line format is handled too, since an Ubuntu image may use it.
    for src in /etc/apt/sources.list.d/*.sources; do
        [ -e "$src" ] || continue
        sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' "$src"
    done
    if [ -f /etc/apt/sources.list ]; then
        sed -i 's/^\(deb .*main\)$/\1 contrib non-free non-free-firmware/' \
            /etc/apt/sources.list
    fi
    apt-get update

    nv_arch="$(dpkg --print-architecture)"
    apt-get install -y "linux-image-$nv_arch" "linux-headers-$nv_arch"
    apt-get install -y nvidia-driver firmware-misc-nonfree

    # Boot the kernel the driver was built for. Both flavours carry the
    # same version and grub's sort prefers the cloud one, so the generic
    # entry is named outright, by ids read from the generated grub.cfg.
    nv_gen=""
    for nv_k in /boot/vmlinuz-*; do
        case "$nv_k" in *-cloud-*) continue ;; esac
        nv_gen="$nv_k"
    done
    nv_ver="${nv_gen#/boot/vmlinuz-}"
    nv_sub="$(grep -o 'gnulinux-advanced-[a-f0-9-]*' /boot/grub/grub.cfg | head -1)"
    nv_ent="$(grep -o "gnulinux-$nv_ver-advanced-[a-f0-9-]*" /boot/grub/grub.cfg | head -1)"
    if [ -n "$nv_ver" ] && [ -n "$nv_sub" ] && [ -n "$nv_ent" ]; then
        sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
        echo "GRUB_DEFAULT=\"$nv_sub>$nv_ent\"" >>/etc/default/grub
        apt-get purge -y "linux-image-cloud-$nv_arch" ||
            echo "WARN: could not drop the cloud kernel meta package" >&2
        update-grub
    else
        echo "WARN: could not pin grub to the generic kernel — the driver" >&2
        echo "      will not load until the right kernel is booted" >&2
    fi

    echo "NVIDIA drivers installed — rebooting to load them"
    echo "(after the reboot, 'nvidia-smi' proves it; with no card passed"
    echo " through to this VM it will correctly report no devices)"
    systemctl reboot
fi
`
