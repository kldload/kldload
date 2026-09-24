package main

import (
	"errors"
	"testing"
)

// The ZFS dot is the one probe whose wrong answer is dangerous: green over
// an UNAVAIL pool is how a console tells an operator not to look.
func TestZfsHealth(t *testing.T) {
	cases := []struct {
		name string
		out  string
		err  error
		want health
	}{
		{"one online pool", "ONLINE", nil, hOK},
		{"two online pools", "ONLINE\nONLINE\n", nil, hOK},
		{"online plus unavail", "ONLINE\nUNAVAIL", nil, hBad},
		{"online plus degraded", "ONLINE\nDEGRADED", nil, hBad},
		{"online plus offline", "ONLINE\nOFFLINE", nil, hBad},
		{"faulted alone", "FAULTED", nil, hBad},
		{"no pools", "", nil, hNone},
		{"whitespace only", "\n \n", nil, hNone},
		{"command failed", "", errors.New("exit status 1"), hBad},
		{"command failed with output", "ONLINE", errors.New("timed out"), hBad},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := zfsHealth(c.out, c.err); got != c.want {
				t.Fatalf("zfsHealth(%q, %v) = %v, want %v", c.out, c.err, got, c.want)
			}
		})
	}
}

// runCmd must hand back the failure, not swallow it: the display layer and
// the probes both key on it.
func TestRunCmdReturnsTheError(t *testing.T) {
	out, err := runCmd("echo hi; exit 3", 2e9)
	if err == nil || out != "hi" {
		t.Fatalf("got out=%q err=%v, want out=hi and a non-nil error", out, err)
	}
	if _, err := runCmd("true", 2e9); err != nil {
		t.Fatalf("true returned %v", err)
	}
}
