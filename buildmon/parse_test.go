package main

import "testing"

// The exact table kldload-component list prints (%-12s %-12s %-8s %s).
const componentTable = `NAME         STATE        APPROX   SUMMARY
ai           installed    ~25m     Ollama + Open WebUI, offline models
k8s          absent       ~20m     Single-node Kubernetes with Cilium
klab         missing      ~40m     Windows lab VMs and domain controller
kvm          running      ~15m     libvirt, golden images, virtual networks
zfslab       failed       ~10m     OpenZFS development lab
`

func TestParseComponentList(t *testing.T) {
	got := ParseComponentList([]byte(componentTable))

	if len(got) != 5 {
		t.Fatalf("parsed %d components, want 5", len(got))
	}
	if got[0].Name != "ai" || got[0].State != CompInstalled {
		t.Errorf("row 0 = %+v", got[0])
	}
	// The summary contains spaces and must survive intact.
	if want := "Ollama + Open WebUI, offline models"; got[0].Summary != want {
		t.Errorf("summary = %q, want %q", got[0].Summary, want)
	}
	if got[3].State != CompRunning || !got[3].State.Busy() {
		t.Errorf("kvm should be running/busy, got %+v", got[3])
	}
	for _, c := range got {
		if c.State == CompMissing || c.State == CompFailed {
			if !c.State.NeedsAttention() {
				t.Errorf("%s (%s) should need attention", c.Name, c.State)
			}
		}
	}
}

func TestParseComponentListSkipsJunk(t *testing.T) {
	got := ParseComponentList([]byte("NAME STATE APPROX SUMMARY\n\nbroken\n"))
	if len(got) != 0 {
		t.Errorf("expected no components from a header and a junk row, got %+v", got)
	}
}

func TestComponentActionRefusesUnknownVerb(t *testing.T) {
	// A typo must never reach the CLI — "purge" is not a verb it has, and
	// forwarding it blindly would produce a confusing error at the wrong layer.
	if _, err := ComponentAction("/bin/true", "purge", "ai", 0); err == nil {
		t.Error("expected an error for an unknown verb")
	}
}

// A trimmed-down but structurally exact kldload-doctor document.
const doctorJSON = `{
  "version": "1.0",
  "summary": {"ok": 2, "fail": 1, "warn": 1, "skip": 0},
  "subsystems": {},
  "results": [
    {"subsystem":"zfs","name":"pool online","status":"ok","expected":"rpool ONLINE",
     "actual":"rpool ONLINE","severity":"critical","remediation":""},
    {"subsystem":"ai","name":"model present","status":"warn","expected":"a chat model",
     "actual":"none","severity":"low","remediation":"ollama pull llama3.2:3b"},
    {"subsystem":"boot","name":"kernel installed","status":"fail","expected":"vmlinuz in /boot",
     "actual":"none","severity":"critical","remediation":"reinstall linux-image-amd64"},
    {"subsystem":"k8s","name":"nodes ready","status":"skip","expected":"","actual":"",
     "severity":"low","remediation":""}
  ]
}`

func TestParseDoctorAndRanking(t *testing.T) {
	r, err := ParseDoctor([]byte(doctorJSON))
	if err != nil {
		t.Fatal(err)
	}
	if r.Count("fail") != 1 || r.Count("ok") != 2 {
		t.Errorf("summary counts wrong: %+v", r.Summary)
	}

	bad := r.Bad()
	// ok and skip are not news; only fail+warn surface.
	if len(bad) != 2 {
		t.Fatalf("Bad() returned %d, want 2 (the fail and the warn)", len(bad))
	}
	// fail outranks warn regardless of the order they appeared in.
	if bad[0].Status != "fail" || bad[0].Name != "kernel installed" {
		t.Errorf("first bad check = %+v, want the critical failure", bad[0])
	}
	if bad[0].Remediation == "" {
		t.Error("a failing check must carry its remediation — that is the point of doctor")
	}
}

func TestParseDoctorRejectsGarbage(t *testing.T) {
	if _, err := ParseDoctor([]byte("not json at all")); err == nil {
		t.Error("expected an error for non-JSON input")
	}
}
