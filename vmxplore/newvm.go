// newvm.go — the native New VM pipeline: cloud image → disk → cloud-init
// seed → virt-install → persistence.
//
// What it does, in order:
//  1. Resolves the image: an explicit path, a family cache hit
//     (/var/lib/klab/images first — kldload hosts already carry them),
//     or a download into /var/lib/vmxplore/images.
//  2. Builds the disk: a sparse zvol (raw) when a ZFS parent is known,
//     else a qcow2 under /var/lib/libvirt/images.
//  3. Writes a NoCloud seed ISO (mkisofs/xorriso, -volid cidata): user,
//     password, ssh key, growpart — the same shape the kldload webui and
//     klab emit, so guests behave identically.
//  4. virt-install --import with virtio disk/net/video and VNC graphics —
//     the exact flag set the webui settled on (qxl corrupts modern Wayland
//     guests; virtio-gpu does not).
//  5. Re-defines the domain from its own XML: some libvirt builds create
//     --import --noautoconsole domains TRANSIENT, which silently
//     self-undefine on first shutdown (the webui's hard-won CRITICAL fix).
//
// Why: "install KVM and vmxplore does the rest" has to include the first
// VM. This is the generic tier — no kldload tooling required; privileged
// steps go through sudo -n per command and everything is audit-logged.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// CloudImage is one distro preset — URL and libvirt os-variant, lifted
// verbatim from klab's curated catalog (the family source of truth).
type CloudImage struct {
	URL     string
	Variant string
}

var cloudImages = map[string]CloudImage{
	"fedora": {"https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2", "fedora44"},
	"debian": {"https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2", "debian12"},
	"ubuntu": {"https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img", "ubuntu24.04"},
	"centos": {"https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2", "centos-stream9"},
	"rocky":  {"https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2", "centos-stream9"},
	"arch":   {"https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2", "archlinux"},
}

// CloudDistros lists the presets in menu order.
func CloudDistros() []string {
	return []string{"fedora", "debian", "ubuntu", "centos", "rocky", "arch"}
}

// NewVMSpec is everything the dialog collects. Two build modes:
//   - cloud   (ISOPath == ""): import a cloud image + cloud-init seed,
//     boots straight to a configured guest — the fast path.
//   - install (ISOPath != ""): blank disk + installer ISO, boots the
//     distro's own installer in the Graphics tab. You run apt/dnf/pacman
//     the normal way; no cloud-init, no preset user.
type NewVMSpec struct {
	Name      string
	Distro    string // cloud preset key; used only in cloud mode
	ImagePath string // explicit cloud qcow2/raw; wins over Distro (cloud mode)
	ISOPath   string // installer ISO — switches to install mode
	OSVariant string // libvirt os-variant for install mode (best-effort)
	VCPUs     int
	RAMMB     int
	DiskGB    int
	User      string // cloud mode only
	Password  string // cloud mode only
	SSHKey    string // cloud mode only — one authorized_keys line
	PostInst  string // cloud mode only — bash run as root on first boot
}

var vmNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// runStep executes one pipeline command: sudo -n when root work is needed
// and we aren't root, the exact argv echoed to progress, the run
// audit-logged with its exit code — the same contract as the verb plans.
func runStep(progress func(string), root bool, argv ...string) error {
	if root && os.Geteuid() != 0 {
		argv = append([]string{"sudo", "-n"}, argv...)
	}
	progress("$ " + strings.Join(argv, " "))
	out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
	rc := 0
	if err != nil {
		rc = 1
	}
	auditLog(strings.Join(argv, " "), rc)
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if len(msg) > 300 {
			msg = msg[len(msg)-300:]
		}
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s: %s", argv[0], msg)
	}
	return nil
}

func (s NewVMSpec) install() bool { return s.ISOPath != "" }

func (s NewVMSpec) validate() error {
	if !vmNameRE.MatchString(s.Name) {
		return fmt.Errorf("VM name must be alphanumeric with . _ - only")
	}
	if s.VCPUs < 1 || s.RAMMB < 256 || s.DiskGB < 2 {
		return fmt.Errorf("need at least 1 vcpu, 256 MB RAM, 2 GB disk")
	}
	if s.install() {
		// install mode: just need the ISO to exist; the guest's own
		// installer collects everything else (user, packages, layout)
		if _, err := os.Stat(s.ISOPath); err != nil {
			return fmt.Errorf("installer ISO: %v", err)
		}
		return nil
	}
	// cloud mode
	if s.ImagePath == "" {
		if _, ok := cloudImages[s.Distro]; !ok {
			return fmt.Errorf("pick a distro preset, an image, or an installer ISO")
		}
	} else if _, err := os.Stat(s.ImagePath); err != nil {
		return fmt.Errorf("image: %v", err)
	}
	if s.User == "" || strings.ContainsAny(s.User, " :") {
		return fmt.Errorf("user must be a plain unix name")
	}
	return nil
}

// imageCaches is the lookup order for already-downloaded cloud images —
// the family caches first so a kldload host never downloads twice.
var imageCaches = []string{
	"/var/lib/klab/images",
	"/var/lib/kube-cluster/images",
	"/var/lib/vmxplore/images",
}

func cachedImage(distro, url string) string {
	base := filepath.Base(url)
	var candidates []string
	if distro != "" {
		// the webui's cache names by distro, not by URL basename
		candidates = append(candidates,
			"/var/lib/kldload/cloud-init/"+distro+"-cloud.qcow2")
	}
	for _, d := range imageCaches {
		candidates = append(candidates, filepath.Join(d, base))
	}
	for _, p := range candidates {
		if fi, err := os.Stat(p); err == nil && fi.Size() > 0 {
			return p
		}
	}
	return ""
}

// isoTool picks the NoCloud seed builder present on this host.
func isoTool(out, ud, md string) ([]string, error) {
	if _, err := exec.LookPath("mkisofs"); err == nil {
		return []string{"mkisofs", "-output", out, "-volid", "cidata",
			"-joliet", "-rock", ud, md}, nil
	}
	if _, err := exec.LookPath("genisoimage"); err == nil {
		return []string{"genisoimage", "-output", out, "-volid", "cidata",
			"-joliet", "-rock", ud, md}, nil
	}
	if _, err := exec.LookPath("xorriso"); err == nil {
		return []string{"xorriso", "-as", "mkisofs", "-output", out,
			"-volid", "cidata", "-joliet", "-rock", ud, md}, nil
	}
	return nil, fmt.Errorf("no mkisofs/genisoimage/xorriso — install one for cloud-init seeds")
}

// userData renders the #cloud-config the seed carries. Same behaviours as
// the family tools: named sudo user, password auth on, growpart.
func userData(s NewVMSpec) string {
	var b strings.Builder
	b.WriteString("#cloud-config\n")
	fmt.Fprintf(&b, "hostname: %s\n", s.Name)
	b.WriteString("ssh_pwauth: true\n")
	b.WriteString("growpart:\n  mode: auto\n  devices: ['/']\n")
	fmt.Fprintf(&b, "users:\n  - name: %s\n", s.User)
	b.WriteString("    sudo: ALL=(ALL) NOPASSWD:ALL\n")
	b.WriteString("    shell: /bin/bash\n")
	b.WriteString("    lock_passwd: false\n")
	if s.SSHKey != "" {
		fmt.Fprintf(&b, "    ssh_authorized_keys:\n      - %s\n",
			strings.TrimSpace(s.SSHKey))
	}
	if s.Password != "" {
		b.WriteString("chpasswd:\n  expire: false\n  users:\n")
		fmt.Fprintf(&b, "    - {name: %s, password: %s, type: text}\n",
			s.User, s.Password)
	}
	// the custom post-installer: the operator's bash, written to a script
	// and run once as root on first boot via runcmd — output lands in the
	// guest's /var/log/cloud-init-output.log. This is what turns a stock
	// cloud image into somebody's own appliance (then Make Golden → clone).
	if strings.TrimSpace(s.PostInst) != "" {
		b.WriteString("write_files:\n")
		b.WriteString("  - path: /var/lib/vmxplore-postinstall.sh\n")
		b.WriteString("    permissions: '0755'\n")
		b.WriteString("    content: |\n")
		b.WriteString("      #!/usr/bin/env bash\n")
		b.WriteString("      set -Eeuo pipefail\n")
		for _, line := range strings.Split(s.PostInst, "\n") {
			// 6-space indent puts each line inside the YAML block scalar
			b.WriteString("      " + line + "\n")
		}
		b.WriteString("runcmd:\n")
		b.WriteString("  - [ bash, /var/lib/vmxplore-postinstall.sh ]\n")
	}
	return b.String()
}

// BuildNewVM runs the pipeline. progress gets one line per step (safe to
// call from any goroutine); every external command is audit-logged with
// its exit code, exactly like the verb plans.
func BuildNewVM(s NewVMSpec, zfsParent string, progress func(string)) error {
	if err := s.validate(); err != nil {
		return err
	}
	run := func(root bool, argv ...string) error {
		return runStep(progress, root, argv...)
	}

	// ── install mode: blank disk + installer ISO, boot the installer ────
	// No cloud image, no seed — the guest's own installer runs in the
	// Graphics tab and you drive apt/dnf/pacman the normal way. Any
	// installer ISO works: Debian, Fedora, an Arch live ISO, a RHEL DVD.
	if s.install() {
		var diskArg string
		if zfsParent != "" {
			ds := zfsParent + "/" + s.Name
			if err := run(true, "zfs", "create", "-s", "-V",
				fmt.Sprintf("%dG", s.DiskGB), ds); err != nil {
				return err
			}
			diskArg = "path=/dev/zvol/" + ds + ",bus=virtio,format=raw"
		} else {
			f := "/var/lib/libvirt/images/" + s.Name + ".qcow2"
			if err := run(true, "qemu-img", "create", "-f", "qcow2", f,
				fmt.Sprintf("%dG", s.DiskGB)); err != nil {
				return err
			}
			diskArg = "path=" + f + ",bus=virtio,format=qcow2"
		}
		osArg := []string{"--osinfo", "detect=on,require=off"}
		if s.OSVariant != "" {
			osArg = []string{"--os-variant", s.OSVariant}
		}
		argv := append([]string{"virt-install", "--connect", "qemu:///system",
			"--name", s.Name,
			"--memory", fmt.Sprint(s.RAMMB),
			"--vcpus", fmt.Sprint(s.VCPUs),
			"--disk", diskArg,
			"--cdrom", s.ISOPath}, osArg...)
		argv = append(argv,
			"--network", "network=default,model=virtio",
			"--graphics", "vnc,listen=0.0.0.0",
			"--video", "virtio",
			"--noautoconsole")
		if err := run(false, argv...); err != nil {
			return err
		}
		progress(s.Name + " created — open the Graphics tab and run the installer")
		return nil
	}

	// 1 — the image
	img := s.ImagePath
	variant := "linux2022"
	if img == "" {
		ci := cloudImages[s.Distro]
		variant = ci.Variant
		if c := cachedImage(s.Distro, ci.URL); c != "" {
			progress("image: cache hit " + c)
			img = c
		} else {
			img = filepath.Join("/var/lib/vmxplore/images", filepath.Base(ci.URL))
			if err := run(true, "mkdir", "-p", "/var/lib/vmxplore/images"); err != nil {
				return err
			}
			progress("downloading " + s.Distro + " cloud image (once — cached after)")
			if err := run(true, "curl", "-L", "--fail", "-o", img, ci.URL); err != nil {
				return err
			}
		}
	}

	// 2 — the disk
	var diskArg string
	if zfsParent != "" {
		ds := zfsParent + "/" + s.Name
		if err := run(true, "zfs", "create", "-s", "-V",
			fmt.Sprintf("%dG", s.DiskGB), ds); err != nil {
			return err
		}
		if err := run(true, "qemu-img", "convert", "-O", "raw", img,
			"/dev/zvol/"+ds); err != nil {
			return err
		}
		diskArg = "path=/dev/zvol/" + ds + ",bus=virtio,format=raw"
	} else {
		f := "/var/lib/libvirt/images/" + s.Name + ".qcow2"
		if err := run(true, "qemu-img", "convert", "-O", "qcow2", img, f); err != nil {
			return err
		}
		if err := run(true, "qemu-img", "resize", f,
			fmt.Sprintf("%dG", s.DiskGB)); err != nil {
			return err
		}
		diskArg = "path=" + f + ",bus=virtio,format=qcow2"
	}

	// 3 — the NoCloud seed
	tmp, err := os.MkdirTemp("", "vmx-seed-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	ud := filepath.Join(tmp, "user-data")
	md := filepath.Join(tmp, "meta-data")
	if err := os.WriteFile(ud, []byte(userData(s)), 0600); err != nil {
		return err
	}
	meta := fmt.Sprintf("instance-id: %s\nlocal-hostname: %s\n", s.Name, s.Name)
	if err := os.WriteFile(md, []byte(meta), 0600); err != nil {
		return err
	}
	tmpISO := filepath.Join(tmp, s.Name+"-seed.iso")
	isoArgv, err := isoTool(tmpISO, ud, md)
	if err != nil {
		return err
	}
	if err := run(false, isoArgv...); err != nil {
		return err
	}
	seedISO := "/var/lib/libvirt/images/" + s.Name + "-seed.iso"
	if err := run(true, "cp", tmpISO, seedISO); err != nil {
		return err
	}

	// 4 — virt-install (the webui's exact device choices). The catalog's
	// os-variant can be newer than this host's osinfo-db (the klab
	// resolver problem — E2E caught fedora44 unknown on onyx): retry with
	// osinfo detection, which never hard-fails.
	installArgs := func(osinfo ...string) []string {
		argv := []string{"virt-install", "--connect", "qemu:///system",
			"--name", s.Name,
			"--memory", fmt.Sprint(s.RAMMB),
			"--vcpus", fmt.Sprint(s.VCPUs),
			"--disk", diskArg,
			"--disk", "path=" + seedISO + ",device=cdrom,bus=sata",
			"--import"}
		argv = append(argv, osinfo...)
		return append(argv,
			"--network", "network=default,model=virtio",
			"--graphics", "vnc,listen=0.0.0.0",
			"--video", "virtio",
			"--noautoconsole")
	}
	err = run(false, installArgs("--os-variant", variant)...)
	if err != nil && strings.Contains(err.Error(), "Unknown OS name") {
		progress("os-variant " + variant + " unknown to this host's osinfo-db — using detection")
		err = run(false, installArgs("--osinfo", "detect=on,require=off")...)
	}
	if err != nil {
		return err
	}

	// 5 — persistence: re-define from live XML (see banner)
	xmlOut, err := exec.Command("virsh", "-c", "qemu:///system",
		"dumpxml", s.Name).Output()
	if err != nil {
		return fmt.Errorf("dumpxml after install: %v", err)
	}
	xf := filepath.Join(tmp, s.Name+".xml")
	if err := os.WriteFile(xf, xmlOut, 0600); err != nil {
		return err
	}
	if err := run(false, "virsh", "-c", "qemu:///system", "define", xf); err != nil {
		return err
	}
	progress(s.Name + " is up — cloud-init finishes the first boot (1–3 min)")
	return nil
}

// ZFSVMParent derives where VM zvols live on this host from the estate
// itself — the most common parent among existing VM-backing datasets.
// Empty means "no ZFS home for VMs here" and the pipeline goes qcow2.
func ZFSVMParent(rows []Row) string {
	counts := map[string]int{}
	for _, r := range rows {
		if r.DS == nil {
			continue
		}
		if i := strings.LastIndexByte(r.DS.Name, '/'); i > 0 {
			counts[r.DS.Name[:i]]++
		}
	}
	best, n := "", 0
	for p, c := range counts {
		if c > n {
			best, n = p, c
		}
	}
	return best
}
