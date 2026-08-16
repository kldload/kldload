package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── Which OpenZFS is under test ─────────────────────────────────────

// TestZFSSourceRoundTrips is the property that matters: whatever the console
// shows must be exactly what kzfs-test is told. A source that renders to one
// string and parses back as another means the run tests something other than
// what the operator picked, and the result is then trusted.
func TestZFSSourceRoundTrips(t *testing.T) {
	cases := []ZFSSource{
		{Kind: SourceRepo},
		{Kind: SourceVersion, Version: "2.4.3"},
		{Kind: SourceVersion, Version: "2.4.3-rc1"},
		{Kind: SourceGit, Repo: "openzfs/zfs", Ref: "master"},
		{Kind: SourceGit, Repo: "openzfs/zfs", Ref: "zfs-2.4.3-staging"},
		{Kind: SourceGit, Repo: "behlendorf/zfs", Ref: "a1b2c3d4"},
		{Kind: SourceTarball, Path: "/root/zfs-2.4.3.tar.gz"},
	}
	for _, want := range cases {
		if err := want.Validate(); err != nil {
			t.Errorf("%+v should be valid: %v", want, err)
			continue
		}
		spec := want.String()
		got, err := ParseZFSSource(spec)
		if err != nil {
			t.Errorf("%q did not parse back: %v", spec, err)
			continue
		}
		if got != want {
			t.Errorf("%q round-tripped to %+v, want %+v", spec, got, want)
		}
	}
}

// TestZFSSourceRejectsNonsense covers the inputs that would otherwise be
// discovered by a guest, mid-build, in a log nobody is reading.
func TestZFSSourceRejectsNonsense(t *testing.T) {
	bad := []ZFSSource{
		{Kind: SourceVersion, Version: "2.4"},             // not three parts
		{Kind: SourceVersion, Version: "v2.4.3"},          // tag, not version
		{Kind: SourceVersion, Version: "master"},          // a branch in the wrong box
		{Kind: SourceGit, Repo: "openzfs", Ref: "master"}, // no owner/repo
		{Kind: SourceGit, Repo: "openzfs/zfs", Ref: ""},   // no ref: would silently mean master
		{Kind: SourceTarball, Path: "zfs.tar.gz"},         // relative
		{Kind: SourceTarball, Path: "/tmp/a b.tar.gz"},    // space
	}
	for _, s := range bad {
		if err := s.Validate(); err == nil {
			t.Errorf("%+v was accepted and should not be", s)
		}
	}
}

// TestZFSSourceRefusesShellMetacharacters is a security property, not a
// style one: these strings reach a command line, and a ref that can close a
// quote is a ref that can run a command.
func TestZFSSourceRefusesShellMetacharacters(t *testing.T) {
	for _, ref := range []string{"master; rm -rf /", "a$(id)", "a`id`", "a|b", "a&b", "a'b"} {
		s := ZFSSource{Kind: SourceGit, Repo: "openzfs/zfs", Ref: ref}
		if err := s.Validate(); err == nil {
			t.Errorf("ref %q was accepted", ref)
		}
	}
	for _, repo := range []string{"openzfs/zfs;id", "../../etc/passwd", "a b/c"} {
		s := ZFSSource{Kind: SourceGit, Repo: repo, Ref: "master"}
		if err := s.Validate(); err == nil {
			t.Errorf("repo %q was accepted", repo)
		}
	}
}

// TestParseZFSSourceRejectsGitWithoutRef pins the deliberate refusal to
// default a missing ref to master — testing something the operator did not
// name is the one thing a test lab must never do.
func TestParseZFSSourceRejectsGitWithoutRef(t *testing.T) {
	if _, err := ParseZFSSource("git:openzfs/zfs"); err == nil {
		t.Error("git source with no ref was accepted")
	}
}

// ─── The run request ─────────────────────────────────────────────────

func TestRunRequestArgv(t *testing.T) {
	r := RunRequest{
		Mode:    ModeFull,
		Exec:    ExecSeries,
		Distros: []string{"debian", "fedora"},
		Source:  ZFSSource{Kind: SourceGit, Repo: "openzfs/zfs", Ref: "master"},
	}
	if err := r.Validate(); err != nil {
		t.Fatalf("valid request rejected: %v", err)
	}
	argv, env := r.Argv()
	joined := strings.Join(argv, " ")
	for _, want := range []string{"kzfs-test", "run", "--full", "--distro", "debian,fedora", "--series"} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv %q is missing %q", joined, want)
		}
	}
	// The git ref must travel in the environment, not on the command line
	// where every ps listing on the box would carry it.
	if strings.Contains(joined, "openzfs/zfs") {
		t.Errorf("the ZFS source leaked onto the command line: %q", joined)
	}
	if len(env) != 1 || env[0] != "ZFS_SOURCE=git:openzfs/zfs@master" {
		t.Errorf("env = %v, want ZFS_SOURCE=git:openzfs/zfs@master", env)
	}
}

func TestRunRequestRejectsUnknownDistro(t *testing.T) {
	r := RunRequest{Mode: ModeQuick, Distros: []string{"plan9"}}
	if err := r.Validate(); err == nil {
		t.Error("unknown distro was accepted")
	}
}

// ─── eBPF ────────────────────────────────────────────────────────────

// TestEBPFProgramIsOneArgument is the injection property. A bpftrace
// one-liner is full of characters a shell would act on; it must arrive as a
// single argv element and never be concatenated.
func TestEBPFProgramIsOneArgument(t *testing.T) {
	prog := `kprobe:zfs_read { @[comm] = count(); } /* ; rm -rf / */`
	argv, err := EBPFRequest{Tool: "bpftrace", Program: prog}.Argv()
	if err != nil {
		t.Fatal(err)
	}
	if len(argv) != 3 || argv[0] != "bpftrace" || argv[1] != "-e" {
		t.Fatalf("argv = %v, want [bpftrace -e <program>]", argv)
	}
	if argv[2] != prog {
		t.Errorf("the program was altered on its way to argv:\n got %q\nwant %q", argv[2], prog)
	}
}

func TestEBPFRequiresAProgramWhereOneIsNeeded(t *testing.T) {
	for _, tool := range []string{"bpftrace", "trace"} {
		if _, err := (EBPFRequest{Tool: tool}).Argv(); err == nil {
			t.Errorf("%s was accepted with no program", tool)
		}
	}
}

func TestEBPFDurationBecomesAPositionalArgument(t *testing.T) {
	argv, err := EBPFRequest{Tool: "biolatency", Duration: 10}.Argv()
	if err != nil {
		t.Fatal(err)
	}
	if len(argv) != 2 || argv[0] != "biolatency" || argv[1] != "10" {
		t.Errorf("argv = %v, want [biolatency 10]", argv)
	}
}

func TestEBPFRejectsUnknownTool(t *testing.T) {
	if _, err := (EBPFRequest{Tool: "rm"}).Argv(); err == nil {
		t.Error("an unknown tool was accepted, which would run an arbitrary binary")
	}
}

// ─── Results ─────────────────────────────────────────────────────────

// writeSummary builds the fixture kzfs-test would have written.
func writeSummary(t *testing.T, dir, distro string, pass, fail, skip int) {
	t.Helper()
	body := "distro=" + distro + "\n" +
		"pass=" + itoa(pass) + "\nfail=" + itoa(fail) + "\nskip=" + itoa(skip) +
		"\ntotal=" + itoa(pass+fail+skip) + "\n"
	if err := os.WriteFile(filepath.Join(dir, distro+".summary"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}

func TestReadRunParsesTheMatrix(t *testing.T) {
	dir := t.TempDir()
	writeSummary(t, dir, "debian", 1382, 0, 44)
	writeSummary(t, dir, "fedora", 1300, 7, 50)

	run := ReadRun(dir)
	if len(run.Results) != 2 {
		t.Fatalf("got %d results, want 2", len(run.Results))
	}
	if run.Failed() != 1 {
		t.Errorf("Failed() = %d, want 1", run.Failed())
	}
	p, f, s := run.Totals()
	if p != 2682 || f != 7 || s != 94 {
		t.Errorf("totals = %d/%d/%d, want 2682/7/94", p, f, s)
	}
	if !strings.Contains(run.Verdict(), "1 of 2 distros failed") {
		t.Errorf("verdict = %q", run.Verdict())
	}
}

// TestTruncatedSummaryIsNotAPass is the one that matters most. A run killed
// while writing a summary leaves a file with a distro name and no counts;
// reporting that as 0 failures would be the worst possible lie this tool
// could tell.
func TestTruncatedSummaryIsNotAPass(t *testing.T) {
	dir := t.TempDir()
	writeSummary(t, dir, "debian", 1382, 0, 44)
	if err := os.WriteFile(filepath.Join(dir, "fedora.summary"),
		[]byte("distro=fedora\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := ReadRun(dir)
	if run.Incomplete() != 1 {
		t.Fatalf("Incomplete() = %d, want 1", run.Incomplete())
	}
	for _, r := range run.Results {
		if r.Distro == "fedora" && r.OK() {
			t.Error("a truncated summary reported as OK")
		}
	}
	if !strings.Contains(run.Verdict(), "did not finish") {
		t.Errorf("verdict = %q, want it to lead with the unfinished distro", run.Verdict())
	}
}

// TestSummaryIsNotExecuted proves the parser reads the file rather than
// sourcing it. These files live in a root-owned directory that a test run
// writes to; `source`-ing one would execute whatever it contained.
func TestSummaryIsNotExecuted(t *testing.T) {
	dir := t.TempDir()
	canary := filepath.Join(dir, "canary")
	body := "distro=debian\npass=1\nfail=0\nskip=0\ntotal=1\n" +
		"$(touch " + canary + ")\n`touch " + canary + "`\n"
	if err := os.WriteFile(filepath.Join(dir, "debian.summary"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	run := ReadRun(dir)
	if len(run.Results) != 1 || run.Results[0].Pass != 1 {
		t.Fatalf("the readable fields were not parsed: %+v", run.Results)
	}
	if _, err := os.Stat(canary); err == nil {
		t.Fatal("the summary file was EXECUTED — a run directory can now run code")
	}
}

func TestListRunsIsNewestFirstAndSkipsLatestSymlink(t *testing.T) {
	root := t.TempDir()
	for _, id := range []string{"20260101-000000", "20260815-235900", "20260601-120000"} {
		d := filepath.Join(root, id)
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
		writeSummary(t, d, "debian", 1, 0, 0)
	}
	if err := os.Symlink(filepath.Join(root, "20260815-235900"),
		filepath.Join(root, "latest")); err != nil {
		t.Fatal(err)
	}
	runs, err := ListRuns(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 3 {
		t.Fatalf("got %d runs, want 3 (the latest symlink must not be listed twice)", len(runs))
	}
	if runs[0].ID != "20260815-235900" {
		t.Errorf("newest run is %q, want 20260815-235900", runs[0].ID)
	}
}

// ─── Kernel classification ───────────────────────────────────────────

func TestClassifyKernelLine(t *testing.T) {
	cases := []struct {
		line string
		want KernelSeverity
		zfs  bool
	}{
		{"VERIFY3(sa.sa_magic == SA_MAGIC) failed", KernCritical, false},
		{"PANIC at dbuf.c:2151:dbuf_free_range()", KernCritical, false},
		{"kernel BUG at fs/zfs/dmu.c:114!", KernCritical, true},
		{"Call Trace:", KernCritical, false},
		{"ZFS: Loaded module v2.4.3-1", KernZFS, true},
		{"spl: loading out-of-tree module taints kernel.", KernWarn, true},
		{"INFO: task txg_sync:1234 blocked for more than 120 seconds.", KernWarn, true},
		// zvol block devices. On a lab box that clones zvols per test run
		// these are the dominant ZFS traffic in the buffer, and none of the
		// obvious keywords appear in them (fiend, 2026-08-15).
		{" zd528: p1 p14 p15", KernZFS, true},
		{"zd0: detected capacity change from 0 to 41943040", KernZFS, true},
		{"usb 1-1: new high-speed USB device", KernNormal, false},
	}
	for _, c := range cases {
		got := ClassifyKernelLine(c.line)
		if got.Severity != c.want {
			t.Errorf("%q → severity %d, want %d", c.line, got.Severity, c.want)
		}
		if c.zfs && !got.IsZFS {
			t.Errorf("%q was not recognised as a ZFS line", c.line)
		}
	}
}

// ─── ARC ─────────────────────────────────────────────────────────────

func TestReadARCParsesKstat(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "arcstats")
	// The real file's shape: two header lines, then name/type/data.
	body := `13 1 0x01 154 41888 5023491533 141905527673623
name                            type data
hits                            4    900
misses                          4    100
size                            4    8589934592
c                               4    8589934592
c_max                           4    17179869184
mfu_size                        4    4294967296
mru_size                        4    2147483648
l2_hits                         4    0
l2_misses                       4    0
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	arc := ReadARC(path)
	if !arc.Available {
		t.Fatalf("not available: %s", arc.Why)
	}
	if arc.Hits != 900 || arc.Misses != 100 {
		t.Errorf("hits/misses = %d/%d, want 900/100", arc.Hits, arc.Misses)
	}
	if got := arc.HitRate(); got != 90 {
		t.Errorf("HitRate() = %v, want 90", got)
	}
	if arc.Size != 8589934592 {
		t.Errorf("size = %d", arc.Size)
	}
}

// TestReadARCSaysWhyWhenZFSIsAbsent — on a test-lab host, "the module is not
// loaded" is the single most interesting reading there is, so it must be a
// sentence and not an empty struct.
func TestReadARCSaysWhyWhenZFSIsAbsent(t *testing.T) {
	arc := ReadARC(filepath.Join(t.TempDir(), "does-not-exist"))
	if arc.Available {
		t.Fatal("reported available with no kstat file")
	}
	if !strings.Contains(arc.Why, "not loaded") {
		t.Errorf("Why = %q, want it to name the missing module", arc.Why)
	}
}
