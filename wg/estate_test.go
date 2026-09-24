// estate_test.go — the one thing CollectEstate must never do is wait
// forever on a host. ConnectTimeout bounds the connect only; a host that
// accepts and then hangs used to hold the goroutine and the ssh child
// until the process exited. This drives the real code path against a
// fake ssh that sleeps.
package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCollectEstateCutsOffAHungSSH(t *testing.T) {
	// A fake ssh on PATH that accepts anything and never answers. The
	// TMPDIR default (/tmp) is noexec on kldload hosts, so the fake lives
	// under the build cache when that is set, and the test says so if it
	// cannot make an executable at all rather than passing on nothing.
	base := os.Getenv("GOCACHE")
	if base == "" {
		base = os.TempDir()
	}
	dir, err := os.MkdirTemp(base, "wgx-fake-ssh-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	fake := filepath.Join(dir, "ssh")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	old := sshDeadline
	sshDeadline = 1 * time.Second
	defer func() { sshDeadline = old }()

	start := time.Now()
	devs := CollectEstate([]string{"hung-host"})
	took := time.Since(start)
	if took > 10*time.Second {
		t.Fatalf("CollectEstate took %s against a hung ssh; the deadline did not fire", took)
	}
	var found bool
	for _, d := range devs {
		if d.Host == "hung-host" {
			found = true
			if d.Err == "" {
				t.Fatalf("hung host came back without an error: %+v", d)
			}
		}
	}
	if !found {
		t.Fatalf("hung host vanished from the estate: %+v", devs)
	}
}
