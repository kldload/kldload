// =============================================================================
// runner.go — driving the lab, and streaming what it says.
//
// WHAT IT DOES, IN ORDER:
//   1. Builds the argv for a kzfs-test operation from a typed request, so no
//      caller ever assembles a command line by hand.
//   2. Runs it, streaming stdout and stderr line by line to a callback while
//      it runs, and stays cancellable throughout.
//   3. Does the same for the eBPF tools, which are the other thing this
//      console runs on the operator's behalf.
//
// WHY IT EXISTS:
//   A test run is minutes to hours of output. Anything that collects it and
//   prints at the end is useless for the case that matters — watching a run
//   go wrong and stopping it. Everything here streams.
//
// WHY EVERY COMMAND IS AN ARGV:
//   Nothing in this file builds a shell string. The operator supplies a git
//   ref, a tarball path and a bpftrace one-liner; all three would be code if
//   they reached a shell. exec.Command with a fixed argv makes them data.
//   The bpftrace program is the exception that proves it: it is passed as one
//   argument to bpftrace -e, never interpolated.
//
// Notes:
//   - Cancel kills the process group, not the process. kzfs-test spawns
//     virsh and ssh children; killing only the parent leaves a test run going
//     with nothing watching it, which is how a lab ends up with VMs nobody
//     remembers starting.
// =============================================================================

package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// LabBin is the shell tool that owns the machinery.
const LabBin = "kzfs-test"

// RunMode is quick or full, mirroring kzfs-test's flags.
type RunMode string

const (
	ModeQuick RunMode = "--quick"
	ModeFull  RunMode = "--full"
)

// Execution says whether the distros run together or one at a time.
//
// Parallel is the point of the lab — six distros at once on ZFS clones. In
// series exists because a box that is short on RAM will OOM-kill guests
// mid-suite and produce failures that are about the host, not about ZFS.
type Execution string

const (
	ExecParallel Execution = "parallel"
	ExecSeries   Execution = "series"
)

// RunRequest is one "test this ZFS on these distros" instruction.
type RunRequest struct {
	Mode    RunMode
	Exec    Execution
	Distros []string  // empty = the whole matrix
	Source  ZFSSource // which OpenZFS is under test
}

// Validate checks a request before anything is built.
func (r RunRequest) Validate() error {
	if r.Mode != ModeQuick && r.Mode != ModeFull {
		return fmt.Errorf("mode must be quick or full")
	}
	for _, d := range r.Distros {
		if _, ok := DistroByKey(d); !ok {
			return fmt.Errorf("unknown distro %q", d)
		}
	}
	return r.Source.Validate()
}

// Argv renders the request as the command to run.
//
// Returns: argv, and the environment additions it needs. ZFS_SOURCE goes in
// the ENVIRONMENT rather than on the command line because that is the
// interface kzfs-test already reads, and because a git ref on a command line
// ends up in every ps listing on the box.
func (r RunRequest) Argv() (argv []string, env []string) {
	argv = []string{LabBin, "run", string(r.Mode)}
	if len(r.Distros) > 0 {
		argv = append(argv, "--distro", strings.Join(r.Distros, ","))
	}
	if r.Exec == ExecSeries {
		argv = append(argv, "--series")
	}
	env = []string{"ZFS_SOURCE=" + r.Source.String()}
	return argv, env
}

// ─── Running things ──────────────────────────────────────────────────

// Streamer receives one line at a time as a command produces it.
//
// It is called from the reader goroutine, so a GUI implementation must
// marshal to its own thread rather than touching widgets here.
type Streamer func(line string)

// Runner executes one long-running command at a time and can stop it.
//
// One at a time is deliberate: two concurrent test runs share the same
// goldens, the same pool and the same results directory, and the second one
// silently corrupts the first one's answers.
type Runner struct {
	mu      sync.Mutex
	cancel  context.CancelFunc
	running bool
}

// Busy reports whether something is in flight.
func (r *Runner) Busy() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.running
}

// Start runs argv, streaming output until it exits or is stopped.
//
// Args:    argv, the command; extraEnv, KEY=VALUE additions; out, the sink.
// Returns: an error if something is already running, if the tool is missing,
// or the command's own exit error.
//
// Blocks until the command finishes. Callers run it on their own goroutine;
// doing that here would hide the completion, and completion is the thing a
// caller most needs to know.
// resolveBCCTool maps a bcc tool's logical name to what it is actually called
// on this system.
//
// WHY: bcc installs its tools under a different name on every distro family,
// and none of them is the bare name the catalogue uses:
//
//	Debian/Ubuntu   /usr/sbin/execsnoop-bpfcc      (a "-bpfcc" suffix)
//	RHEL/Fedora     /usr/share/bcc/tools/execsnoop (not on PATH at all)
//
// So `execsnoop` resolves nowhere on either family, and every bcc-backed entry
// in the Trace panel failed while the packages sat installed and working. Only
// bpftrace worked, because bpftrace is a real binary on PATH — which is what
// made it look like eBPF was missing rather than misnamed (operator report,
// 2026-08-17).
//
// Returns the resolved path, or the name unchanged when nothing matches, so
// the failure still surfaces as a normal "not found" from exec rather than as
// a silent no-op here.
func resolveBCCTool(name string) string {
	// bpftrace is a real binary and takes no suffix.
	if name == "bpftrace" {
		return name
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	if p, err := exec.LookPath(name + "-bpfcc"); err == nil {
		return p
	}
	for _, dir := range []string{"/usr/share/bcc/tools", "/usr/sbin", "/usr/bin"} {
		for _, cand := range []string{name, name + "-bpfcc", name + ".py"} {
			full := filepath.Join(dir, cand)
			if fi, err := os.Stat(full); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
				return full
			}
		}
	}
	return name
}

func (r *Runner) Start(argv []string, extraEnv []string, out Streamer) error {
	if len(argv) == 0 {
		return fmt.Errorf("nothing to run")
	}
	if _, err := exec.LookPath(argv[0]); err != nil {
		return fmt.Errorf("%s is not installed on this host", argv[0])
	}

	r.mu.Lock()
	if r.running {
		r.mu.Unlock()
		return fmt.Errorf("something is already running — stop it first")
	}
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel, r.running = cancel, true
	r.mu.Unlock()

	defer func() {
		r.mu.Lock()
		r.running, r.cancel = false, nil
		r.mu.Unlock()
		cancel()
	}()

	// Resolve here rather than in Argv(): Argv stays pure and testable,
	// and the name it returns is the logical one the catalogue uses.
	cmd := exec.CommandContext(ctx, resolveBCCTool(argv[0]), argv[1:]...)
	cmd.Env = append(os.Environ(), extraEnv...)
	// Its own process group, so Stop can take the children with it.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Kill the GROUP. Without this, cancelling leaves virsh and ssh
	// children running a test suite that nothing is watching.
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return nil
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}

	var wg sync.WaitGroup
	wg.Add(2)
	// stderr is interleaved rather than separated: kzfs-test writes progress
	// to one and warnings to the other, and reading them apart puts the
	// warning nowhere near the step that caused it.
	go func() { defer wg.Done(); pump(stdout, out) }()
	go func() { defer wg.Done(); pump(stderr, out) }()
	wg.Wait()

	return cmd.Wait()
}

// Stop terminates whatever is running. Safe to call when nothing is.
func (r *Runner) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		r.cancel()
	}
}

// ansiRE matches a real escape sequence (ESC [ ... letter) and the literal
// two-character form "\033[...m" that kzfs-test writes into its own log file.
//
// Both have to go. kzfs-test colours its output for a terminal, and a GUI
// text widget renders those bytes literally: the Lab pane came up full of
// "?1;32mREADY" and "?0m", with the ESC byte drawn as the replacement glyph
// (fiend, 2026-08-15). The tool is not misbehaving — it is talking to a
// terminal that is not there.
var ansiRE = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]|\\0[0-9]{2}\[[0-9;?]*[a-zA-Z]`)

// stripANSI removes terminal colour codes from a line.
//
// Applied on the way IN rather than at render time so every pane, and any
// future consumer of a Streamer, gets clean text without having to remember.
func stripANSI(s string) string {
	if !strings.ContainsAny(s, "\x1b\\") {
		return s // the overwhelmingly common case, no allocation
	}
	return ansiRE.ReplaceAllString(s, "")
}

// pump forwards lines, tolerating the very long ones a test suite emits.
func pump(rc io.Reader, out Streamer) {
	sc := bufio.NewScanner(rc)
	// zfs-tests.sh prints stack traces and command echoes that blow past
	// bufio's default 64KB and would otherwise silently truncate the run's
	// output at the most interesting moment.
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		out(stripANSI(sc.Text()))
	}
}

// ─── eBPF ────────────────────────────────────────────────────────────
//
// The tool list is the one the web console already offers, so an operator
// moving to this app finds what they had. bpftrace is last because it is the
// escape hatch: everything above it is a named question, and it is "ask your
// own".

// EBPFTool is one tracer the console can run.
type EBPFTool struct {
	Name string
	Desc string
	// NeedsProgram marks the tools that take an operator-written program
	// rather than flags, which the UI must present as a text box.
	NeedsProgram bool
}

// EBPFTools mirrors the web console's catalogue.
var EBPFTools = []EBPFTool{
	{"biolatency", "block I/O latency histogram", false},
	{"biosnoop", "block I/O events, one line each", false},
	{"cachestat", "page cache hit/miss", false},
	{"filetop", "top files by I/O", false},
	{"ext4slower", "slow filesystem operations", false},
	{"execsnoop", "new process execution", false},
	{"opensnoop", "file opens", false},
	{"syscount", "syscall frequency", false},
	{"funccount", "function call counts", false},
	{"pidstat", "per-process CPU and I/O", false},
	{"runqlat", "scheduler run-queue latency", false},
	{"cpudist", "on-CPU time distribution", false},
	{"tcplife", "TCP session lifetimes", false},
	{"tcpconnect", "outbound connections", false},
	{"tcpaccept", "inbound connections", false},
	{"tcpretrans", "TCP retransmits", false},
	{"tcpdrop", "TCP drops, with stack trace", false},
	{"trace", "custom function tracing", true},
	{"bpftrace", "your own one-liner", true},
}

// EBPFToolByName looks one up.
func EBPFToolByName(n string) (EBPFTool, bool) {
	for _, t := range EBPFTools {
		if t.Name == n {
			return t, true
		}
	}
	return EBPFTool{}, false
}

// EBPFRequest is one tracing run.
type EBPFRequest struct {
	Tool     string
	Program  string // for trace/bpftrace: the operator's own program
	Duration int    // seconds; 0 = until stopped
}

// Argv renders the tracing command.
//
// Returns: argv, or an error for an unknown tool or a missing program.
//
// SAFETY: Program is passed as ONE argv element to -e. It is never
// concatenated into a shell string, so a one-liner containing a semicolon,
// a backtick or a $( is a bpftrace program and not a command the host runs.
func (e EBPFRequest) Argv() ([]string, error) {
	tool, ok := EBPFToolByName(e.Tool)
	if !ok {
		return nil, fmt.Errorf("unknown eBPF tool %q", e.Tool)
	}
	if tool.NeedsProgram && strings.TrimSpace(e.Program) == "" {
		return nil, fmt.Errorf("%s needs a program to run", e.Tool)
	}
	if e.Duration < 0 {
		return nil, fmt.Errorf("duration cannot be negative")
	}

	switch e.Tool {
	case "bpftrace":
		return []string{"bpftrace", "-e", e.Program}, nil
	case "trace":
		// BCC's trace takes its probe spec as one argument too.
		argv := []string{"trace"}
		if e.Duration > 0 {
			argv = append(argv, "-d", strconv.Itoa(e.Duration))
		}
		return append(argv, e.Program), nil
	}

	// The BCC tools take a bare duration as their final positional argument
	// and exit on their own, which is what makes a timed sample possible
	// without the console having to kill them.
	argv := []string{e.Tool}
	if e.Duration > 0 {
		argv = append(argv, strconv.Itoa(e.Duration))
	}
	return argv, nil
}

// ListGoldenSnapshots returns every ZFS snapshot name on the host.
//
// Returns: the names, or an error when zfs is missing or the pool is unreadable.
// Paired with GoldenSealed to answer "which goldens are actually finished"
// without parsing kzfs-test's coloured status table, which is a display and
// not an API.
func ListGoldenSnapshots() ([]string, error) {
	out, err := runCapture(15*time.Second, "zfs", "list", "-H", "-o", "name", "-t", "snapshot")
	if err != nil {
		return nil, fmt.Errorf("cannot ask zfs what is snapshotted: %w", err)
	}
	var names []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			names = append(names, l)
		}
	}
	return names, nil
}

// ListDomains returns every domain libvirt knows, running or not.
//
// Returns: the names, or an error when virsh is missing or cannot connect.
// Used to answer "does this distro have a golden" without parsing
// kzfs-test's coloured status table, which is a display and not an API.
func ListDomains() ([]string, error) {
	out, err := runCapture(10*time.Second, "virsh", "list", "--all", "--name")
	if err != nil {
		return nil, fmt.Errorf("cannot ask libvirt what exists: %w", err)
	}
	var names []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			names = append(names, l)
		}
	}
	return names, nil
}
