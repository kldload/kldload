// =============================================================================
// components.go — list, add and remove optional kldload components.
//
// WHAT IT DOES:
//   Wraps /usr/local/bin/kldload-component. Parses its `list` table, and
//   forwards install/remove/log verbatim.
//
// WHY IT EXISTS (and why it is a wrapper, not a reimplementation):
//   kldload-component already owns the hard parts — component definitions,
//   recorded state under /var/lib/kldload/components, detached workers, work
//   logs, and the "recorded as installed but no longer present" reconciliation.
//   Reimplementing any of that in Go would create a second source of truth
//   about what is installed, and the two would disagree on exactly the machine
//   where it mattered. So this shells out, on purpose.
//
// INPUTS / OUTPUTS:
//   Execs ComponentBin. Mutating verbs need root; see ComponentAction.
//
// Notes:
//   - install/remove are long-running (minutes to hours) and kldload-component
//     detaches by default. We therefore do NOT pass --now: we kick the work off
//     and then follow the component's log, which is what the CLI is designed
//     for and what keeps the UI responsive.
// =============================================================================

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"strings"
	"time"
)

// ComponentBin is the CLI this wraps.
const ComponentBin = "/usr/local/bin/kldload-component"

// ComponentState is the vocabulary kldload-component reports. Kept identical
// to its STATES section so the two can be compared by eye.
type ComponentState string

const (
	CompAbsent      ComponentState = "absent"
	CompInstalled   ComponentState = "installed"
	CompMissing     ComponentState = "missing"
	CompRunning     ComponentState = "running"
	CompInterrupted ComponentState = "interrupted"
	CompFailed      ComponentState = "failed"
)

// Busy reports whether work is in flight, in which case the UI must not offer
// install/remove buttons for this component.
func (s ComponentState) Busy() bool { return s == CompRunning }

// NeedsAttention reports the states that are neither cleanly present nor
// cleanly absent — the ones worth colouring.
func (s ComponentState) NeedsAttention() bool {
	return s == CompMissing || s == CompInterrupted || s == CompFailed
}

// Component is one row of `kldload-component list`.
type Component struct {
	Name    string
	State   ComponentState
	Approx  string // "~15m" — the CLI's own cost estimate
	Summary string
}

// ParseComponentList decodes the `kldload-component list` table.
//
// The table is `%-12s %-12s %-8s %s` with a NAME/STATE/APPROX/SUMMARY header.
// Splitting on whitespace is therefore safe for the first three columns, and
// the remainder is the summary — which contains spaces and must not be split.
//
// Returns: one Component per data row. Unparseable rows are skipped rather
// than guessed at; a row we cannot read is not a component we should offer to
// remove.
func ParseComponentList(b []byte) []Component {
	var out []Component
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		line := sc.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 || fields[0] == "NAME" {
			continue
		}
		c := Component{
			Name:   fields[0],
			State:  ComponentState(fields[1]),
			Approx: fields[2],
		}
		// Summary is everything after the third column. Recover it by index so
		// internal spacing survives.
		if idx := strings.Index(line, fields[2]); idx >= 0 {
			c.Summary = strings.TrimSpace(line[idx+len(fields[2]):])
		}
		out = append(out, c)
	}
	return out
}

// ListComponents runs `kldload-component list`.
func ListComponents(bin string, timeout time.Duration) ([]Component, error) {
	if bin == "" {
		bin = ComponentBin
	}
	out, err := runCmd(timeout, bin, "list")
	if len(out) == 0 && err != nil {
		return nil, fmt.Errorf("could not list components: %w", err)
	}
	return ParseComponentList(out), nil
}

// ComponentAction starts an install or remove.
//
// Args: verb — "install" or "remove"; name — the component.
//
// Returns: the command's combined output. Because kldload-component detaches
// by default, this returns as soon as the worker is launched — it does NOT
// block for the minutes or hours the work takes. Follow ComponentLogPath to
// show progress.
//
// Failure modes the caller must handle: this needs root. Run unprivileged it
// returns a permission error, which the UI must show rather than swallow —
// a button that silently does nothing is worse than one that explains itself.
func ComponentAction(bin, verb, name string, timeout time.Duration) ([]byte, error) {
	if bin == "" {
		bin = ComponentBin
	}
	switch verb {
	case "install", "remove":
	default:
		return nil, fmt.Errorf("refusing unknown component verb %q", verb)
	}
	return runCmd(timeout, bin, verb, name)
}

// ComponentLogPath is where kldload-component writes a component's work log.
func ComponentLogPath(name string) string {
	return "/var/log/kldload/component-" + name + ".log"
}
