// =============================================================================
// doctor.go — run kldload-doctor and turn its JSON into something paintable.
//
// WHAT IT DOES:
//   Execs kldload-doctor, decodes the JSON it prints on stdout, and exposes the
//   checks grouped and counted. It does NOT reimplement any check.
//
// WHY IT EXISTS:
//   kldload-doctor already answers "is this right, and if not do this" for
//   every subsystem, and its output is already consumed by the web UI and CI.
//   A second implementation of those checks would drift from the first, and
//   the drift would be discovered on the machine that needed them. So this is
//   a decoder, deliberately thin.
//
// INPUTS / OUTPUTS:
//   Execs DoctorBin. Reads nothing else. Writes nothing.
//
// Notes:
//   - Exit status is NOT an error condition here. kldload-doctor exits 1 when
//     any check fails and 2 when one crashes; both still print a full report,
//     and the report is the thing we want. Only a failure to produce decodable
//     JSON is a real error.
// =============================================================================

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"time"
)

// DoctorBin is the health checker this wraps.
const DoctorBin = "/usr/local/bin/kldload-doctor"

// DoctorCheck is one check result. Field names mirror kldload-doctor's own
// record exactly, so the contract between the two is readable in one place.
type DoctorCheck struct {
	Subsystem   string `json:"subsystem"`
	Name        string `json:"name"`
	Status      string `json:"status"` // ok | fail | warn | skip
	Expected    string `json:"expected"`
	Actual      string `json:"actual"`
	Severity    string `json:"severity"` // critical | high | medium | low
	Remediation string `json:"remediation"`
}

// DoctorReport is the whole run.
type DoctorReport struct {
	Version string         `json:"version"`
	Summary map[string]int `json:"summary"`
	Results []DoctorCheck  `json:"results"`
}

// Bad reports the checks an operator must act on, worst first. skip and ok are
// not news; a screen that lists them buries the two lines that matter.
func (r DoctorReport) Bad() []DoctorCheck {
	sevRank := map[string]int{"critical": 4, "high": 3, "medium": 2, "low": 1}
	var out []DoctorCheck
	for _, c := range r.Results {
		if c.Status == "fail" || c.Status == "warn" {
			out = append(out, c)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		// fail before warn, then by severity, then stable by subsystem.
		if (out[i].Status == "fail") != (out[j].Status == "fail") {
			return out[i].Status == "fail"
		}
		if sevRank[out[i].Severity] != sevRank[out[j].Severity] {
			return sevRank[out[i].Severity] > sevRank[out[j].Severity]
		}
		return out[i].Subsystem < out[j].Subsystem
	})
	return out
}

// Count returns how many checks carry the given status.
func (r DoctorReport) Count(status string) int { return r.Summary[status] }

// ParseDoctor decodes a kldload-doctor JSON document.
func ParseDoctor(b []byte) (DoctorReport, error) {
	var r DoctorReport
	if err := json.Unmarshal(b, &r); err != nil {
		return r, fmt.Errorf("kldload-doctor did not produce valid JSON: %w", err)
	}
	return r, nil
}

// RunDoctor executes the health checker and decodes its report.
//
// Args: bin — path to kldload-doctor ("" means DoctorBin); timeout — how long
// to allow. Doctor talks to zfs, libvirt and kubectl, any of which can hang on
// a machine mid-build, which is exactly when this tool runs.
//
// Returns: the decoded report. A non-zero exit is not an error (see Notes);
// only unusable output is.
func RunDoctor(bin string, timeout time.Duration) (DoctorReport, error) {
	if bin == "" {
		bin = DoctorBin
	}
	out, err := runCmd(timeout, bin)
	if len(out) == 0 {
		if err != nil {
			return DoctorReport{}, fmt.Errorf("could not run %s: %w", bin, err)
		}
		return DoctorReport{}, fmt.Errorf("%s produced no output", bin)
	}
	return ParseDoctor(out)
}

// runCmd runs a command with a deadline and returns its stdout.
//
// WHY THE DEADLINE IS NOT OPTIONAL: this tool runs during the post-install
// build, and the helpers it calls talk to zfs, libvirt and kubectl — any of
// which can block indefinitely on a machine whose cluster is still coming up.
// A progress window that freezes because it asked a question is worse than one
// that reports "timed out".
//
// Stdout is returned even when the command exits non-zero: kldload-doctor
// exits 1 when checks fail and kldload-component exits non-zero on a failed
// verb, and in both cases the output is exactly what we want to show.
func runCmd(timeout time.Duration, name string, args ...string) ([]byte, error) {
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, name, args...).Output()
	if ctx.Err() == context.DeadlineExceeded {
		return out, fmt.Errorf("%s timed out after %s", name, timeout)
	}
	return out, err
}
