package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// walk follows a wizard the way the operator does: from the entries shown,
// choose the one whose text contains want; a prompt step is answered with
// typed; the last choice must produce a job, whose argv is returned.
func walk(t *testing.T, title string, es []palEntry, steps ...string) []string {
	t.Helper()
	m := newModel(0, 0, 120)
	for i := 0; i < len(steps); i++ {
		want := steps[i]
		var picked *palEntry
		for j := range es {
			if strings.Contains(es[j].text, want) {
				picked = &es[j]
				break
			}
		}
		if picked == nil {
			var shown []string
			for _, e := range es {
				shown = append(shown, e.text)
			}
			t.Fatalf("at %q: no entry containing %q in %q", title, want, shown)
		}
		nm, cmd := picked.run(m)
		m = nm.(model)
		if m.prompt != "" { // an ask step: the next step string is what is typed
			i++
			if i >= len(steps) {
				t.Fatalf("at %q: a prompt %q with nothing left to type", title, m.prompt)
			}
			cmd = m.pending(steps[i])
			m.prompt = ""
		}
		if cmd == nil {
			title, es = m.pickTitle, m.pick
			continue
		}
		switch msg := cmd().(type) {
		case jobStartMsg:
			if i != len(steps)-1 {
				t.Fatalf("a job started before the walk ended: %v", msg.argv)
			}
			return msg.argv
		case pickerMsg:
			title, es = msg.title, msg.entries
		case doneMsg:
			t.Fatalf("at %q: %v", title, msg.err)
		default:
			t.Fatalf("unexpected %T", msg)
		}
	}
	t.Fatalf("walk ended without starting a job (last picker %q)", title)
	return nil
}

func TestWizardPaths(t *testing.T) {
	m := newModel(0, 0, 120)
	title, es := wizBuild(m)
	check := func(name string, got, want []string) {
		t.Helper()
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: ran %q, want %q", name, got, want)
		}
	}
	check("OS golden", walk(t, title, es, "an OS golden", "fedora", "run it"), []string{"klab", "golden", "fedora"})
	check("KDE desktop", walk(t, title, es, "a desktop golden", "KDE", "fedora", "run it"), []string{"klab", "golden-kde", "fedora"})
	check("all distros", walk(t, title, es, "an OS golden", "all five", "run it"), []string{"klab", "golden", "all"})
	check("k8s", walk(t, title, es, "Kubernetes", "3 (survives", "3 workers", "run it"),
		[]string{"kube-cluster", "bootstrap", "--control-planes", "3", "--workers", "3"})
	check("k8s typed", walk(t, title, es, "Kubernetes", "5 (survives", "another number", "8", "run it"),
		[]string{"kube-cluster", "bootstrap", "--control-planes", "5", "--workers", "8"})

	// your own golden: bases are what the Build tab's loader saw
	hostGoldensMu.Lock()
	hostGoldensSeen = map[string]bool{"klab-golden-fedora": true, "web-golden": true}
	hostGoldensMu.Unlock()
	post := filepath.Join(t.TempDir(), "postinstall.sh")
	if err := os.WriteFile(post, []byte("#!/bin/sh\ntrue\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	check("own, nothing", walk(t, title, es, "your own golden", "fedora", "name:", "my-fedora", "nothing", "run it"),
		[]string{"kvm-golden", "my-fedora", "--from", "fedora"})
	check("own, script", walk(t, title, es, "your own golden", "web-golden", "name:", "web2", "another path", post, "run it"),
		[]string{"kvm-golden", "web2", "--from", "web-golden", "--post", post})
	check("own, command", walk(t, title, es, "your own golden", "fedora", "name:", "tools", "a command", "dnf -y install htop", "run it"),
		[]string{"kvm-golden", "tools", "--from", "fedora", "--run", "dnf -y install htop"})

	check("ztest", walk(t, title, es, "OpenZFS test", "debian", "run it"), []string{"klab", "golden-ztest", "debian"})
	hostGoldensMu.Lock()
	appVMsSeen = []string{"app-vdi-deskto", "app-lamp-stack"}
	hostGoldensMu.Unlock()
	check("firecracker", walk(t, title, es, "a Firecracker golden", "app-vdi-deskto", "run it"), []string{"kfire", "golden", "app-vdi-deskto"})
	iso := filepath.Join(t.TempDir(), "Rocky-10.iso")
	if err := os.WriteFile(iso, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	check("iso", walk(t, title, es, "from an ISO", "another path", iso, "name:", "rocky10", "run it"),
		[]string{"kvm-create", "rocky10", "--iso", iso, "--ram", "4096", "--cpus", "2", "--disk", "40"})

	// the clone wizard: every option picked
	goldensMu.Lock()
	goldensSeen = []string{"app-rdp-deskto", "app-vdi-deskto"}
	goldensMu.Unlock()
	ct, ce := wizClone(m)
	check("50 VDI", walk(t, ct, ce, "app-vdi-deskto", "50 of them", "1 GB", "yes:", "run it"),
		[]string{"kfire", "clone", "app-vdi-deskto", "-n", "50", "--ram", "1024", "--wait"})
	check("2 RDP default size", walk(t, ct, ce, "app-rdp-deskto", "2 of them", "golden's own size", "no:", "run it"),
		[]string{"kfire", "clone", "app-rdp-deskto", "-n", "2"})
}

// A bad typed value stops the walk with the reason instead of running.
func TestWizardRejects(t *testing.T) {
	m := newModel(0, 0, 120)
	_, es := wizBuild(m)
	var k8s palEntry
	for _, e := range es {
		if strings.Contains(e.text, "Kubernetes") {
			k8s = e
		}
	}
	nm, _ := k8s.run(m)
	mm := nm.(model)
	for _, e := range mm.pick {
		if strings.Contains(e.text, "3 (survives") {
			nm, _ = e.run(mm)
			mm = nm.(model)
		}
	}
	for _, e := range mm.pick {
		if strings.Contains(e.text, "another number") {
			nm, _ = e.run(mm)
			mm = nm.(model)
		}
	}
	msg := mm.pending("99")()
	if d, ok := msg.(doneMsg); !ok || d.err == nil {
		t.Fatalf("99 workers was accepted: %#v", msg)
	}
}
