package main

// wizard.go — guided builds and clones, one pick at a time.
//
// The operator, 2026-09-28: "the tui for building is so un-intuitive no one
// is ever going to know what commands to enter .. even I don't half of them"
// and "I want it to be simple for people to build images or build their own
// too". So a build is a short chain of pickers -- what kind, which one, the
// options -- ending on a confirm step that shows the exact command, with "run
// it" and "edit it first". Every choice is a list; only a name or a
// post-install command is ever typed, and both come prefilled.
//
// Each step is a function from the choices so far to the next picker, so
// every path can be walked in a test down to the argv it runs
// (wizard_test.go). The commands at the end are the shipped verbs kld already
// runs (klab, kube-cluster, vmxplore, kvm-golden, kvm-win, kimage, kfire);
// nothing here re-implements what they do. Interim toward
// kld/docs/FORMS-DESIGN.md.

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// wizChoices is what has been picked so far.
type wizChoices map[string]string

func (w wizChoices) with(k, v string) wizChoices {
	n := wizChoices{}
	for a, b := range w {
		n[a] = b
	}
	n[k] = v
	return n
}

// pickStep turns a list of labels into palette entries that each continue
// with next(choices + key=value). A value "" opens a prompt for key instead
// ("other…" entries), prefilled with example.
func pickStep(w wizChoices, key string, values []string, labels []string, next func(wizChoices) (string, []palEntry)) []palEntry {
	var es []palEntry
	for i, v := range values {
		v, label := v, labels[i]
		es = append(es, palEntry{text: label, run: func(m model) (tea.Model, tea.Cmd) {
			title, more := next(w.with(key, v))
			return m.openPicker(title, more)
		}})
	}
	return es
}

// askStep is one typed value (a name, a count nobody listed, a command),
// prefilled, validated by check, then on to next.
func askStep(label, prompt, example, key string, w wizChoices, check func(string) error, next func(wizChoices) (string, []palEntry)) palEntry {
	return palEntry{text: label, run: func(m model) (tea.Model, tea.Cmd) {
		m.prompt = prompt + " (enter goes on, ctrl+u clears): "
		m.input = example
		m.pending = func(in string) tea.Cmd {
			in = strings.TrimSpace(in)
			if err := check(in); err != nil {
				return func() tea.Msg { return doneMsg{prompt, err} }
			}
			title, more := next(w.with(key, in))
			return func() tea.Msg { return pickerMsg{title, more} }
		}
		return m, nil
	}}
}

// pickerMsg opens a picker from a command (after a prompt step).
type pickerMsg struct {
	title   string
	entries []palEntry
}

// confirmStep is the end of every path: the command, run as it is or edited.
func confirmStep(label string, argv []string) (string, []palEntry) {
	shown := shellJoin(argv)
	return label + ": " + shown, []palEntry{
		{text: "▶ run it: " + shown, run: func(m model) (tea.Model, tea.Cmd) {
			return m, func() tea.Msg { return jobStartMsg{label: label, argv: argv} }
		}},
		{text: "edit the command first…", run: func(m model) (tea.Model, tea.Cmd) {
			m.prompt = label + " — edit, enter runs: "
			m.input = shown
			m.pending = func(in string) tea.Cmd {
				in = strings.TrimSpace(in)
				if in == "" {
					return func() tea.Msg { return doneMsg{label, errors.New("nothing to run")} }
				}
				// The operator's own edit of their own command, on their own
				// console; sh -c so a --run "..." with spaces survives.
				return func() tea.Msg { return jobStartMsg{label: label, argv: []string{"sh", "-c", in}} }
			}
			return m, nil
		}},
	}
}

// shellJoin prints argv the way a shell would read it back.
func shellJoin(argv []string) string {
	out := make([]string, len(argv))
	for i, a := range argv {
		if a == "" || strings.ContainsAny(a, " \t\"'$`\\|&;<>()*?[]{}") {
			a = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		}
		out[i] = a
	}
	return strings.Join(out, " ")
}

var distroLabels = func() ([]string, []string) {
	vals := append([]string{"all"}, klabDistros...)
	labels := append([]string{"all five distros"}, klabDistros...)
	return vals, labels
}

// ── the build wizard ────────────────────────────────────────────────────

func wizBuild(_ model) (string, []palEntry) {
	w := wizChoices{}
	kinds := []string{"os", "desktop", "db", "ztest", "k8s", "appliance", "firecracker", "own", "iso", "windows", "export"}
	labels := []string{
		"an OS golden (lean cloud image, one per distro)",
		"a desktop golden (GNOME, KDE or Xfce)",
		"a database golden (PostgreSQL)",
		"an OpenZFS test golden (ztest, for the ZFS test lab)",
		"a Kubernetes cluster (HA control planes + workers)",
		"an appliance (VDI, RDP, LAMP, web stack, media, …)",
		"a Firecracker golden (seal an appliance for microVM clones)",
		"your own golden (a base + your post-install)",
		"a VM from an ISO (install it by hand, then M seals it)",
		"a Windows golden",
		"this host as an image file (qcow2, raw, …)",
	}
	return "build what?", pickStep(w, "kind", kinds, labels, wizKind)
}

func wizKind(w wizChoices) (string, []palEntry) {
	dv, dl := distroLabels()
	switch w["kind"] {
	case "os":
		return "which distro?", pickStep(w, "distro", dv, dl, wizKlab("golden", "OS golden"))
	case "db":
		return "which distro?", pickStep(w, "distro", dv, dl, wizKlab("golden-db", "database golden"))
	case "ztest":
		return "which distro?", pickStep(w, "distro", dv, dl, wizKlab("golden-ztest", "OpenZFS test golden"))
	case "firecracker":
		return wizFirecracker(w)
	case "iso":
		return wizISO(w)
	case "desktop":
		return "which desktop?", pickStep(w, "de", []string{"golden-desktop", "golden-kde", "golden-xfce"},
			[]string{"GNOME", "KDE Plasma", "Xfce"}, func(w wizChoices) (string, []palEntry) {
				return "which distro?", pickStep(w, "distro", dv, dl, wizKlab(w["de"], "desktop golden"))
			})
	case "k8s":
		return "how many control planes?", pickStep(w, "cps", []string{"3", "1", "5"},
			[]string{"3 (survives losing one — the usual)", "1 (smallest, no HA)", "5 (survives losing two)"}, wizK8sWorkers)
	case "appliance":
		return wizAppliance(w)
	case "own":
		return wizOwnBase(w)
	case "windows":
		return "which Windows?", pickStep(w, "win", []string{"win11", "server"},
			[]string{"Windows 11 (evaluation)", "Windows Server"}, func(w wizChoices) (string, []palEntry) {
				return confirmStep("Windows golden", []string{"kvm-win", "golden", w["win"]})
			})
	case "export":
		return "which format?", pickStep(w, "fmt", []string{"qcow2", "raw", "vhd", "vmdk", "all"},
			[]string{"qcow2 (KVM, OpenStack)", "raw", "vhd (Hyper-V, Azure)", "vmdk (VMware)", "all four"}, func(w wizChoices) (string, []palEntry) {
				return confirmStep("export this host", []string{"kimage", "export", w["fmt"]})
			})
	}
	return "nothing to build for " + w["kind"], nil
}

func wizKlab(verb, what string) func(wizChoices) (string, []palEntry) {
	return func(w wizChoices) (string, []palEntry) {
		return confirmStep(what, []string{"klab", verb, w["distro"]})
	}
}

func wizK8sWorkers(w wizChoices) (string, []palEntry) {
	vals := []string{"3", "0", "1", "2", "4", "6", "9", "12"}
	labels := make([]string, len(vals))
	for i, v := range vals {
		labels[i] = v + " workers"
	}
	labels[0] = "3 workers (the usual)"
	es := pickStep(w, "workers", vals, labels, wizK8sConfirm)
	es = append(es, askStep("another number…", "how many workers, 0-64", "8", "workers", w, func(s string) error {
		if n, err := strconv.Atoi(s); err != nil || n < 0 || n > 64 {
			return errors.New("0 to 64")
		}
		return nil
	}, wizK8sConfirm))
	return "how many workers?", es
}

func wizK8sConfirm(w wizChoices) (string, []palEntry) {
	return confirmStep("Kubernetes cluster", []string{"kube-cluster", "bootstrap", "--control-planes", w["cps"], "--workers", w["workers"]})
}

// wizAppliance lists the catalog as vmx prints it: the catalog is vmx's,
// never a copy here. `vmx --appliances` prints a static list and returns at
// once, so asking it on the keystroke is not the kfire-on-the-UI-thread
// mistake.
func wizAppliance(w wizChoices) (string, []palEntry) {
	out, _ := run(5*time.Second, "vmxplore", "--appliances") // empty on failure: the list then says so
	var names []string
	for _, l := range strings.Split(out, "\n") {
		if l != "" && l[0] >= 'A' && l[0] <= 'Z' {
			names = append(names, strings.TrimSpace(l))
		}
	}
	if len(names) == 0 {
		return "no appliance catalog (vmxplore --appliances printed nothing)", nil
	}
	vals := append([]string{"*all*"}, names...)
	labels := append([]string{"every appliance in the catalog"}, names...)
	return "which appliance?", pickStep(w, "app", vals, labels, func(w wizChoices) (string, []palEntry) {
		if w["app"] == "*all*" {
			return confirmStep("appliances", []string{"vmxplore", "--build-all"})
		}
		return confirmStep("appliance "+w["app"], []string{"vmxplore", "--build-all", "--only", w["app"]})
	})
}

// wizOwnBase: a golden of your own is kvm-golden's base -- a golden that
// already exists on this host (a distro name means klab-golden-<distro>,
// which `klab golden <distro>` builds) -- a name, and a post-install.
func wizOwnBase(w wizChoices) (string, []palEntry) {
	var vals, labels []string
	for _, g := range hostGoldens() {
		if d, ok := strings.CutPrefix(g, "klab-golden-"); ok {
			vals, labels = append(vals, d), append(labels, d+" (the lean "+d+" golden)")
			continue
		}
		vals, labels = append(vals, g), append(labels, g)
	}
	if len(vals) == 0 {
		return "no golden to start from yet", []palEntry{{text: "build an OS golden first: b, then 'an OS golden'", run: func(m model) (tea.Model, tea.Cmd) {
			title, es := wizBuild(m)
			return m.openPicker(title, es)
		}}}
	}
	return "start from which golden?", pickStep(w, "base", vals, labels, wizOwnName)
}

func wizOwnName(w wizChoices) (string, []palEntry) {
	ex := "my-" + strings.TrimPrefix(strings.TrimPrefix(w["base"], "klab-golden-"), "klab-")
	return "name it", []palEntry{askStep("name: "+ex+" (enter to change it)", "name for the new golden", ex, "name", w, func(s string) error {
		if !nameOK(s) {
			return errors.New("letters, digits, - and _ only")
		}
		return nil
	}, wizOwnPost)}
}

// postInstallDirs is where the wizard looks for post-installers to offer:
// the host's shared folder, kldload's config, and the operator's own. The
// same postinstall.sh an install runs (kldload.com/build/postinstallers)
// works here: kvm-golden streams it to bash -s in the guest as root.
var postInstallDirs = []string{"/srv/postinstallers", "/etc/kldload/postinstallers", "~/postinstallers"}

func postInstallers() []string {
	var out []string
	for _, d := range postInstallDirs {
		if strings.HasPrefix(d, "~/") {
			h, err := os.UserHomeDir()
			if err != nil {
				continue
			}
			d = filepath.Join(h, d[2:])
		}
		fs, _ := filepath.Glob(filepath.Join(d, "*.sh")) // a folder that is not there offers nothing
		out = append(out, fs...)
	}
	return out
}

func wizOwnPost(w wizChoices) (string, []palEntry) {
	es := []palEntry{{text: "nothing: seal it as it is", run: func(m model) (tea.Model, tea.Cmd) {
		title, es := wizOwnConfirm(w)
		return m.openPicker(title, es)
	}}}
	for _, f := range postInstallers() {
		f := f
		es = append(es, palEntry{text: "run " + f, run: func(m model) (tea.Model, tea.Cmd) {
			title, es := wizOwnConfirm(w.with("postfile", f))
			return m.openPicker(title, es)
		}})
	}
	es = append(es,
		askStep("run a command as root…", "command to run in it as root", "dnf -y install htop || apt-get -y install htop", "post", w,
			func(s string) error {
				if s == "" {
					return errors.New("empty: choose 'nothing' instead")
				}
				return nil
			}, wizOwnConfirm),
		askStep("run a script from another path…", "path to a post-install script", "/root/postinstall.sh", "postfile", w,
			func(s string) error {
				if st, err := os.Stat(s); err != nil || st.IsDir() {
					return errors.New("no such file: " + s)
				}
				return nil
			}, wizOwnConfirm),
	)
	title := "install anything in it first? (post-installers: " + strings.Join(postInstallDirs, " ") + ")"
	return title, es
}

func wizOwnConfirm(w wizChoices) (string, []palEntry) {
	argv := []string{"kvm-golden", w["name"], "--from", w["base"]}
	switch {
	case w["postfile"] != "":
		argv = append(argv, "--post", w["postfile"])
	case w["post"] != "":
		argv = append(argv, "--run", w["post"])
	}
	return confirmStep("your golden "+w["name"], argv)
}

// hostGoldensSeen is the set of sealed goldens (a @golden snapshot under
// rpool/vms) the Build tab's loader last read, in the background. The wizard
// reads it; listing snapshots here, in the key handler, took seconds on onyx.
var (
	hostGoldensMu   sync.Mutex
	hostGoldensSeen map[string]bool
	appVMsSeen      []string // the app-* VMs, for sealing Firecracker goldens
)

// hostGoldens is the goldens on this host a golden of your own can start
// from, sorted; empty until the Build tab has loaded once.
func hostGoldens() []string {
	hostGoldensMu.Lock()
	defer hostGoldensMu.Unlock()
	gs := make([]string, 0, len(hostGoldensSeen))
	for g := range hostGoldensSeen {
		gs = append(gs, g)
	}
	sort.Strings(gs)
	return gs
}

// wizFirecracker seals an appliance VM (app-*) as a Firecracker golden, the
// F verb: the VM must be shut off, which kfire checks and says.
func wizFirecracker(w wizChoices) (string, []palEntry) {
	hostGoldensMu.Lock()
	vms := append([]string(nil), appVMsSeen...)
	hostGoldensMu.Unlock()
	if len(vms) == 0 {
		return "no appliance VMs yet", []palEntry{{text: "build an appliance first: b, then 'an appliance'", run: func(m model) (tea.Model, tea.Cmd) {
			title, es := wizBuild(m)
			return m.openPicker(title, es)
		}}}
	}
	return "seal which appliance? (it must be shut off)", pickStep(w, "vm", vms, vms, func(w wizChoices) (string, []palEntry) {
		return confirmStep("Firecracker golden "+w["vm"], []string{"kfire", "golden", w["vm"]})
	})
}

// isoDirs is where the wizard looks for installer ISOs to offer.
var isoDirs = []string{"/var/lib/libvirt/isos", "/srv/isos", "~/Downloads"}

func wizISO(w wizChoices) (string, []palEntry) {
	var es []palEntry
	for _, d := range isoDirs {
		if strings.HasPrefix(d, "~/") {
			h, err := os.UserHomeDir()
			if err != nil {
				continue
			}
			d = filepath.Join(h, d[2:])
		}
		fs, _ := filepath.Glob(filepath.Join(d, "*.iso")) // a folder that is not there offers nothing
		for _, f := range fs {
			f := f
			es = append(es, palEntry{text: filepath.Base(f) + "  (" + filepath.Dir(f) + ")", run: func(m model) (tea.Model, tea.Cmd) {
				title, es := wizISOName(w.with("iso", f))
				return m.openPicker(title, es)
			}})
		}
	}
	es = append(es, askStep("an ISO at another path…", "path to the .iso", "/var/lib/libvirt/isos/", "iso", w, func(s string) error {
		if st, err := os.Stat(s); err != nil || st.IsDir() {
			return errors.New("no such file: " + s)
		}
		return nil
	}, wizISOName))
	return "install from which ISO? (looked in " + strings.Join(isoDirs, " ") + ")", es
}

func wizISOName(w wizChoices) (string, []palEntry) {
	ex := strings.TrimSuffix(filepath.Base(w["iso"]), ".iso")
	ex = strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' {
			return r
		}
		if r >= 'A' && r <= 'Z' {
			return r + 32
		}
		return '-'
	}, ex)
	if len(ex) > 20 {
		ex = ex[:20]
	}
	return "name the VM", []palEntry{askStep("name: "+ex+" (enter to change it)", "name for the VM", ex, "name", w, func(s string) error {
		if !nameOK(s) {
			return errors.New("letters, digits, - and _ only")
		}
		return nil
	}, func(w wizChoices) (string, []palEntry) {
		return confirmStep("VM "+w["name"]+" from "+filepath.Base(w["iso"]), []string{"kvm-create", w["name"], "--iso", w["iso"], "--ram", "4096", "--cpus", "2", "--disk", "40"})
	})}
}

// ── the microVM clone wizard ─────────────────────────────────────────────

func wizClone(_ model) (string, []palEntry) {
	w := wizChoices{}
	gs := goldensCached()
	if len(gs) == 0 {
		return "no Firecracker goldens yet", []palEntry{{text: "seal a shut-off appliance with F on Machines/VMs", run: func(m model) (tea.Model, tea.Cmd) { return m, nil }}}
	}
	return "clone microVMs from which golden?", pickStep(w, "golden", gs, prefixAll("clone ", gs), wizCloneCount)
}

func prefixAll(p string, xs []string) []string {
	out := make([]string, len(xs))
	for i, x := range xs {
		out[i] = p + x
	}
	return out
}

func wizCloneCount(w wizChoices) (string, []palEntry) {
	vals := []string{"2", "1", "5", "10", "15", "25", "50"}
	es := pickStep(w, "n", vals, suffixAll(vals, " of them"), wizCloneRAM)
	es = append(es, askStep("another number…", "how many, 1-64", "20", "n", w, func(s string) error {
		if n, err := strconv.Atoi(s); err != nil || n < 1 || n > 64 {
			return errors.New("1 to 64")
		}
		return nil
	}, wizCloneRAM))
	return "how many " + w["golden"] + "?", es
}

func suffixAll(xs []string, s string) []string {
	out := make([]string, len(xs))
	for i, x := range xs {
		out[i] = x + s
	}
	return out
}

func wizCloneRAM(w wizChoices) (string, []palEntry) {
	return "memory for each?", pickStep(w, "ram", []string{"", "512", "1024", "2048", "4096"},
		[]string{"the golden's own size", "512 MB", "1 GB", "2 GB", "4 GB"}, wizCloneWait)
}

func wizCloneWait(w wizChoices) (string, []palEntry) {
	return "wait for them to answer?", pickStep(w, "wait", []string{"yes", "no"},
		[]string{"yes: time each one to its first answer and enrol it (mesh, CA, inventory)", "no: start them and return"}, wizCloneConfirm)
}

func wizCloneConfirm(w wizChoices) (string, []palEntry) {
	argv := []string{"kfire", "clone", w["golden"], "-n", w["n"]}
	if w["ram"] != "" {
		argv = append(argv, "--ram", w["ram"])
	}
	if w["wait"] == "yes" {
		argv = append(argv, "--wait")
	}
	return confirmStep("clone "+w["golden"], argv)
}
