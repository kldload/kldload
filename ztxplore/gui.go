//go:build gui

// =============================================================================
// gui.go — the console window: six panes, one question each.
//
// WHAT IT DOES, IN ORDER:
//   1. Builds the frame: a header saying what is under test, and tabs.
//   2. Lab      — the goldens the matrix runs on, and how to build them.
//   3. Run      — pick the OpenZFS, pick the distros, go; output streams here.
//   4. Results  — the matrix, and every run before it.
//   5. Kernel   — the ring buffer, live, with ZFS lines called out.
//   6. Metrics  — ARC, pool I/O, block latency.
//   7. eBPF     — the tracer catalogue, run against this host.
//
// WHY THE TABS ARE IN THIS ORDER:
//   It is the order of the work. You build the lab once, run against it many
//   times, read the result, and then — only when something failed — go
//   looking at the kernel, the metrics and the traces. The first three are
//   the loop; the last three are the investigation.
//
// WHY EVERY PANE REFRESHES ITSELF:
//   The reason this application exists is correlation: a test failing AND the
//   ARC collapsing AND a VERIFY3 in the ring buffer are one event seen three
//   ways. Panes that only update when you click them cannot show that, so
//   each one refreshes on its own timer and keeps doing so while you are
//   looking at another.
//
// Notes:
//   - Fyne is not thread-safe. Every widget touch from a goroutine goes
//     through fyne.Do; the collectors run off-thread and marshal back.
//   - Nothing in this file mutates the lab without a button press.
// =============================================================================

package main

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"image/color"
	"strconv"
	"strings"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

// ── theme ──────────────────────────────────────────────────────────────────
// The family look, ported from zxplore's compactTheme: near-black steel base,
// panels lifted a step off it, tight rows. The accent is OpenZFS blue rather
// than zxplore's teal or vmxplore's red, so the three are distinguishable on
// a taskbar at a glance while still reading as one set.

//go:embed assets/ztxplore.svg
var iconSVG []byte

type labTheme struct{ fyne.Theme }

func (t labTheme) Size(name fyne.ThemeSizeName) float32 {
	switch name {
	case theme.SizeNameInnerPadding:
		return 2 // tight rows: this window is mostly tables and logs
	case theme.SizeNamePadding:
		return 4
	}
	return t.Theme.Size(name)
}

var (
	accent   = color.NRGBA{R: 0x3f, G: 0x8e, B: 0xd6, A: 0xff} // OpenZFS blue
	okGreen  = color.NRGBA{R: 0x4c, G: 0xc3, B: 0x8a, A: 0xff}
	warnGold = color.NRGBA{R: 0xe0, G: 0xa8, B: 0x3c, A: 0xff}
	badRed   = color.NRGBA{R: 0xe0, G: 0x5b, B: 0x5b, A: 0xff}
)

func (t labTheme) Color(name fyne.ThemeColorName, v fyne.ThemeVariant) color.Color {
	dark := v == theme.VariantDark
	switch name {
	case theme.ColorNamePrimary:
		return accent
	case theme.ColorNameBackground:
		if dark {
			return color.NRGBA{R: 0x14, G: 0x16, B: 0x1a, A: 0xff}
		}
	case theme.ColorNameOverlayBackground, theme.ColorNameMenuBackground:
		if dark {
			return color.NRGBA{R: 0x1b, G: 0x1e, B: 0x24, A: 0xff}
		}
	}
	return t.Theme.Color(name, v)
}

// logView is a scrolling, bounded text pane.
//
// BOUNDED IS THE POINT: a full zfs-tests.sh run is hundreds of thousands of
// lines. Appending them all to a widget is how a console eats 8GB and stops
// repainting halfway through the run you were watching.
type logView struct {
	mu    sync.Mutex
	lines []string
	max   int
	text  *widget.Entry
	view  fyne.CanvasObject
	dirty bool
}

func newLogView(max int) *logView {
	e := widget.NewMultiLineEntry()
	e.Wrapping = fyne.TextWrapOff
	l := &logView{max: max, text: e}
	l.view = container.NewScroll(e)
	return l
}

// Add appends a line. Safe from any goroutine; the widget is only touched by
// flush, on the UI thread.
func (l *logView) Add(s string) {
	l.mu.Lock()
	l.lines = append(l.lines, s)
	if len(l.lines) > l.max {
		l.lines = l.lines[len(l.lines)-l.max:]
	}
	l.dirty = true
	l.mu.Unlock()
}

// Set replaces the whole buffer.
func (l *logView) Set(lines []string) {
	l.mu.Lock()
	l.lines = append(l.lines[:0], lines...)
	if len(l.lines) > l.max {
		l.lines = l.lines[len(l.lines)-l.max:]
	}
	l.dirty = true
	l.mu.Unlock()
}

// flush repaints if anything changed. Called on a timer from the UI thread:
// repainting per line makes a fast-producing run unusable, because the widget
// spends all its time laying out text nobody has read yet.
func (l *logView) flush() {
	l.mu.Lock()
	if !l.dirty {
		l.mu.Unlock()
		return
	}
	body := strings.Join(l.lines, "\n")
	l.dirty = false
	l.mu.Unlock()
	l.text.SetText(body)
	l.text.CursorRow = strings.Count(body, "\n")
}

// RunGUI opens the console.
func RunGUI(resultsDir string) error {
	a := app.NewWithID("com.kldload.ztxplore")
	a.Settings().SetTheme(labTheme{Theme: theme.DefaultTheme()})
	a.SetIcon(fyne.NewStaticResource("ztxplore.svg", iconSVG))
	w := a.NewWindow(windowTitle)
	w.Resize(fyne.NewSize(1280, 860))

	runner := &Runner{}

	// ── the header: what is under test ──────────────────────────────
	// It sits above the tabs and never scrolls away, because every number
	// in every pane is meaningless without it.
	source := ZFSSource{Kind: SourceRepo}
	sourceLabel := widget.NewLabel("")
	sourceLabel.TextStyle = fyne.TextStyle{Bold: true}
	setSource := func(s ZFSSource) {
		source = s
		sourceLabel.SetText("Under test:  " + s.Describe())
	}
	setSource(source)

	status := widget.NewLabel("ready")
	status.Wrapping = fyne.TextWrapWord

	// ── Run pane ────────────────────────────────────────────────────
	runLog := newLogView(20000)

	mode := widget.NewSelect([]string{"quick", "full"}, nil)
	mode.SetSelected("quick")
	execSel := widget.NewSelect([]string{"parallel", "series"}, nil)
	execSel.SetSelected("parallel")

	// One checkbox per distro rather than a dropdown: choosing three of six
	// is the normal case when you are chasing one platform's failure.
	distroChecks := map[string]*widget.Check{}
	var distroBoxes []fyne.CanvasObject
	for _, d := range Distros {
		c := widget.NewCheck(d.Label, nil)
		distroChecks[d.Key] = c
		distroBoxes = append(distroBoxes, c)
	}
	selectedDistros := func() []string {
		var out []string
		for _, d := range Distros {
			if distroChecks[d.Key].Checked {
				out = append(out, d.Key)
			}
		}
		return out
	}

	srcKind := widget.NewSelect([]string{
		"distro packages", "release version", "git branch or tag", "local tarball",
	}, nil)
	srcVersion := widget.NewEntry()
	srcVersion.SetPlaceHolder("2.4.3")
	srcRepo := widget.NewEntry()
	srcRepo.SetText("openzfs/zfs")
	srcRef := widget.NewEntry()
	srcRef.SetPlaceHolder("master, a tag, or a commit")
	srcPath := widget.NewEntry()
	srcPath.SetPlaceHolder("/root/zfs-2.4.3.tar.gz")

	srcRows := container.NewVBox(
		container.NewGridWithColumns(2, widget.NewLabel("version"), srcVersion),
		container.NewGridWithColumns(2, widget.NewLabel("repo"), srcRepo),
		container.NewGridWithColumns(2, widget.NewLabel("ref"), srcRef),
		container.NewGridWithColumns(2, widget.NewLabel("tarball"), srcPath),
	)
	// Show only the fields the chosen kind uses: a version box beside a git
	// ref box invites filling both and wondering which one won.
	applyKind := func(string) {
		srcVersion.Hide()
		srcRepo.Hide()
		srcRef.Hide()
		srcPath.Hide()
		switch srcKind.Selected {
		case "release version":
			srcVersion.Show()
		case "git branch or tag":
			srcRepo.Show()
			srcRef.Show()
		case "local tarball":
			srcPath.Show()
		}
		srcRows.Refresh()
	}
	srcKind.OnChanged = applyKind
	srcKind.SetSelected("distro packages")
	applyKind("")

	// buildSource turns the form into a validated ZFSSource.
	buildSource := func() (ZFSSource, error) {
		var s ZFSSource
		switch srcKind.Selected {
		case "release version":
			s = ZFSSource{Kind: SourceVersion, Version: strings.TrimSpace(srcVersion.Text)}
		case "git branch or tag":
			s = ZFSSource{Kind: SourceGit,
				Repo: strings.TrimSpace(srcRepo.Text), Ref: strings.TrimSpace(srcRef.Text)}
		case "local tarball":
			s = ZFSSource{Kind: SourceTarball, Path: strings.TrimSpace(srcPath.Text)}
		default:
			s = ZFSSource{Kind: SourceRepo}
		}
		return s, s.Validate()
	}

	var runBtn, stopBtn *widget.Button
	setBusy := func(busy bool) {
		if busy {
			runBtn.Disable()
			stopBtn.Enable()
		} else {
			runBtn.Enable()
			stopBtn.Disable()
		}
	}

	// stream runs argv and pumps its output into a pane.
	stream := func(argv []string, env []string, into *logView, what string) {
		if runner.Busy() {
			dialog.ShowError(fmt.Errorf("something is already running — stop it first"), w)
			return
		}
		into.Add("")
		into.Add("$ " + strings.Join(argv, " "))
		setBusy(true)
		status.SetText(what + " — running")
		go func() {
			err := runner.Start(argv, env, func(line string) { into.Add(line) })
			fyne.Do(func() {
				setBusy(false)
				if err != nil {
					into.Add("!! " + err.Error())
					status.SetText(what + " — failed: " + err.Error())
					return
				}
				status.SetText(what + " — finished")
			})
		}()
	}

	runBtn = widget.NewButtonWithIcon("Run the test suite", theme.MediaPlayIcon(), func() {
		s, err := buildSource()
		if err != nil {
			dialog.ShowError(err, w)
			return
		}
		setSource(s)
		m := ModeQuick
		if mode.Selected == "full" {
			m = ModeFull
		}
		ex := ExecParallel
		if execSel.Selected == "series" {
			ex = ExecSeries
		}
		req := RunRequest{Mode: m, Exec: ex, Distros: selectedDistros(), Source: s}
		if err := req.Validate(); err != nil {
			dialog.ShowError(err, w)
			return
		}
		// Refuse a run that would test nothing. kzfs-test warns per missing
		// golden and then completes in about a second with an empty results
		// directory, which reads as a pass — see GoldenGap.
		domains, derr := ListDomains()
		if derr != nil {
			dialog.ShowError(derr, w)
			return
		}
		present, missing := GoldenState(req.Distros, domains)
		if gap := GoldenGap(present, missing); gap != nil {
			// Partial coverage is the operator's call: they may genuinely
			// want the four distros that are ready. Nothing to run is not.
			if len(present) == 0 {
				dialog.ShowError(gap, w)
				return
			}
			dialog.ShowConfirm("Some distros have no golden",
				gap.Error()+"\n\nRun on the "+strconv.Itoa(len(present))+
					" that are ready?",
				func(ok bool) {
					if !ok {
						return
					}
					req.Distros = present
					argv, env := req.Argv()
					stream(argv, env, runLog, "test run")
				}, w)
			return
		}
		argv, env := req.Argv()
		stream(argv, env, runLog, "test run")
	})
	runBtn.Importance = widget.HighImportance

	stopBtn = widget.NewButtonWithIcon("Stop", theme.MediaStopIcon(), func() {
		runner.Stop()
		status.SetText("stopping — the whole process group is being told to quit")
	})
	stopBtn.Disable()

	runForm := container.NewVBox(
		widget.NewLabelWithStyle("Which OpenZFS", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		srcKind, srcRows,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Which distros", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewLabel("none ticked = the whole matrix"),
		container.NewGridWithColumns(4, distroBoxes...),
		widget.NewSeparator(),
		container.NewGridWithColumns(2,
			container.NewVBox(widget.NewLabel("mode"), mode),
			container.NewVBox(widget.NewLabel("execution"), execSel)),
		container.NewGridWithColumns(2, runBtn, stopBtn),
	)
	runPane := container.NewBorder(runForm, nil, nil, nil, runLog.view)

	// ── Lab pane ────────────────────────────────────────────────────
	labLog := newLogView(8000)
	labStatus := widget.NewLabel("press Status to ask the lab what it has")

	labPane := container.NewBorder(
		container.NewVBox(
			widget.NewLabelWithStyle("The lab", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
			widget.NewLabel("Goldens are built once per distro and cloned per run. "+
				"Building the full set takes a while; destroying keeps the goldens "+
				"unless you say otherwise."),
			labStatus,
			container.NewGridWithColumns(4,
				widget.NewButtonWithIcon("Status", theme.SearchIcon(), func() {
					stream([]string{LabBin, "status"}, nil, labLog, "lab status")
				}),
				widget.NewButtonWithIcon("Verify", theme.ConfirmIcon(), func() {
					stream([]string{LabBin, "verify", "all"}, nil, labLog, "verify")
				}),
				widget.NewButtonWithIcon("Build goldens", theme.StorageIcon(), func() {
					dialog.ShowConfirm("Build every golden?",
						"This builds one VM per distro and installs the ZFS under test "+
							"in each. It takes a long time and a lot of disk.\n\nGo ahead?",
						func(ok bool) {
							if !ok {
								return
							}
							s, err := buildSource()
							if err != nil {
								dialog.ShowError(err, w)
								return
							}
							setSource(s)
							stream([]string{LabBin, "golden", "all"},
								[]string{"ZFS_SOURCE=" + s.String()}, labLog, "golden build")
						}, w)
				}),
				widget.NewButtonWithIcon("Destroy test VMs", theme.DeleteIcon(), func() {
					dialog.ShowConfirm("Destroy the test VMs?",
						"The per-run clones are destroyed. The goldens are kept.",
						func(ok bool) {
							if ok {
								stream([]string{LabBin, "destroy"}, nil, labLog, "destroy")
							}
						}, w)
				}),
			),
		), nil, nil, nil, labLog.view)

	// ── Results pane ────────────────────────────────────────────────
	resultsBox := container.NewVBox()
	resultsScroll := container.NewScroll(resultsBox)
	runPicker := widget.NewSelect(nil, nil)

	renderRun := func(run Run) {
		resultsBox.Objects = nil
		head := widget.NewLabelWithStyle("Run "+run.ID, fyne.TextAlignLeading,
			fyne.TextStyle{Bold: true})
		resultsBox.Add(head)
		resultsBox.Add(widget.NewLabel(run.Verdict()))
		resultsBox.Add(widget.NewSeparator())
		hdr := container.NewGridWithColumns(6,
			boldLabel("DISTRO"), boldLabel("PASS"), boldLabel("FAIL"),
			boldLabel("SKIP"), boldLabel("TOTAL"), boldLabel("STATUS"))
		resultsBox.Add(hdr)
		for _, d := range run.Results {
			st, col := "pass", okGreen
			switch {
			case d.Incomplete:
				st, col = "did not finish", warnGold
			case d.Fail > 0:
				st, col = "FAIL", badRed
			}
			resultsBox.Add(container.NewGridWithColumns(6,
				widget.NewLabel(d.Distro),
				widget.NewLabel(strconv.Itoa(d.Pass)),
				widget.NewLabel(strconv.Itoa(d.Fail)),
				widget.NewLabel(strconv.Itoa(d.Skip)),
				widget.NewLabel(strconv.Itoa(d.Total)),
				colouredLabel(st, col)))
		}
		resultsBox.Refresh()
	}

	refreshRuns := func() {
		runs, err := ListRuns(resultsDir)
		if err != nil {
			resultsBox.Objects = nil
			resultsBox.Add(widget.NewLabel(err.Error()))
			resultsBox.Refresh()
			return
		}
		ids := make([]string, 0, len(runs))
		byID := map[string]Run{}
		for _, r := range runs {
			ids = append(ids, r.ID)
			byID[r.ID] = r
		}
		runPicker.Options = ids
		runPicker.OnChanged = func(id string) {
			if r, ok := byID[id]; ok {
				renderRun(r)
			}
		}
		runPicker.Refresh()
		if len(ids) > 0 {
			runPicker.SetSelected(ids[0])
		} else {
			resultsBox.Objects = nil
			resultsBox.Add(widget.NewLabel("No runs recorded yet."))
			resultsBox.Refresh()
		}
	}

	resultsPane := container.NewBorder(
		container.NewBorder(nil, nil,
			widget.NewLabel("run"), widget.NewButtonWithIcon("", theme.ViewRefreshIcon(), refreshRuns),
			runPicker),
		nil, nil, nil, resultsScroll)

	// ── Kernel pane ─────────────────────────────────────────────────
	kernLog := newLogView(5000)
	onlyZFS := widget.NewCheck("only ZFS, warnings and worse", nil)
	onlyZFS.SetChecked(true)

	var kernMu sync.Mutex
	var kernLines []KernelLine
	renderKern := func() {
		kernMu.Lock()
		defer kernMu.Unlock()
		out := make([]string, 0, len(kernLines))
		for _, l := range kernLines {
			if onlyZFS.Checked && l.Severity == KernNormal {
				continue
			}
			tag := "    "
			switch l.Severity {
			case KernCritical:
				tag = "CRIT"
			case KernWarn:
				tag = "WARN"
			case KernZFS:
				tag = "zfs "
			}
			out = append(out, tag+"  "+l.Text)
		}
		if len(out) == 0 {
			out = append(out, "nothing matching in the recent buffer")
		}
		kernLog.Set(out)
	}
	onlyZFS.OnChanged = func(bool) { renderKern() }

	kernPane := container.NewBorder(
		container.NewVBox(
			widget.NewLabelWithStyle("Kernel ring buffer", fyne.TextAlignLeading,
				fyne.TextStyle{Bold: true}),
			widget.NewLabel("Live. VERIFY/ASSERT/BUG and taints are flagged CRIT; "+
				"ZFS threads and functions are flagged zfs."),
			onlyZFS,
		), nil, nil, nil, kernLog.view)

	// ── Metrics pane ────────────────────────────────────────────────
	arcBox := container.NewVBox()
	poolBox := container.NewVBox()
	latBox := container.NewVBox()
	promBox := container.NewVBox()
	// The dashboards themselves. Grafana renders these better than a window
	// can, and — the actual point — it is where a developer EDITS them. The
	// numbers below work headless and when Grafana is down; this is for
	// sitting down and reading, or for adding your own panel.
	dashSel := widget.NewSelect(DashboardTitles(), nil)
	dashSel.SetSelected(DashboardTitles()[0])
	dashNote := widget.NewLabel("")
	dashNote.Wrapping = fyne.TextWrapWord
	updateDashNote := func(string) {
		for _, d := range ZFSDashboards {
			if d.Title == dashSel.Selected {
				dashNote.SetText(d.Why)
				return
			}
		}
	}
	dashSel.OnChanged = updateDashNote
	updateDashNote("")
	openDash := func(kiosk bool) {
		for _, d := range ZFSDashboards {
			if d.Title != dashSel.Selected {
				continue
			}
			if up, why := GrafanaUp(3 * time.Second); !up {
				dialog.ShowError(errors.New(why), w)
				return
			}
			if err := OpenInBrowser(d.URL(kiosk)); err != nil {
				dialog.ShowError(err, w)
			}
			return
		}
	}
	dashBox := container.NewVBox(
		widget.NewLabelWithStyle("Dashboards", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		dashSel, dashNote,
		container.NewGridWithColumns(2,
			widget.NewButtonWithIcon("Open to read", theme.VisibilityIcon(),
				func() { openDash(true) }),
			// NOT kiosk: editing is the reason these ship, and kiosk mode
			// hides the controls that make it possible.
			widget.NewButtonWithIcon("Open to edit", theme.DocumentCreateIcon(),
				func() { openDash(false) })),
		widget.NewSeparator(),
	)

	metricsPane := container.NewScroll(container.NewVBox(
		dashBox,
		// The dashboard readings first: they carry rate() and history, which
		// is what shows the ARC moving during a run. The /proc sections below
		// are the fallback that works with no monitoring stack at all.
		widget.NewLabelWithStyle("ZFS — the Grafana dashboard queries",
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		promBox,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("ARC (read straight from the kernel)",
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		arcBox,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Pool I/O", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		poolBox,
		widget.NewSeparator(),
		widget.NewLabelWithStyle("Block latency (eBPF)", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		latBox,
	))

	// ── eBPF pane ───────────────────────────────────────────────────
	bpfLog := newLogView(10000)
	toolNames := make([]string, 0, len(EBPFTools))
	toolByLabel := map[string]EBPFTool{}
	for _, t := range EBPFTools {
		label := t.Name + " — " + t.Desc
		toolNames = append(toolNames, label)
		toolByLabel[label] = t
	}
	toolSel := widget.NewSelect(toolNames, nil)
	toolSel.SetSelected(toolNames[0])
	bpfDur := widget.NewEntry()
	bpfDur.SetText("10")
	bpfProg := widget.NewMultiLineEntry()
	bpfProg.SetPlaceHolder(`kprobe:zfs_read { @[comm] = count(); }`)
	bpfProg.Hide()
	toolSel.OnChanged = func(l string) {
		if t, ok := toolByLabel[l]; ok && t.NeedsProgram {
			bpfProg.Show()
			return
		}
		bpfProg.Hide()
	}

	bpfPane := container.NewBorder(
		container.NewVBox(
			widget.NewLabelWithStyle("eBPF", fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
			widget.NewLabel("Runs against THIS host — the hypervisor the guests are on."),
			toolSel,
			container.NewGridWithColumns(2,
				container.NewVBox(widget.NewLabel("seconds (0 = until stopped)"), bpfDur),
				container.NewVBox(widget.NewLabel(""), widget.NewButtonWithIcon(
					"Trace", theme.MediaRecordIcon(), func() {
						t, ok := toolByLabel[toolSel.Selected]
						if !ok {
							return
						}
						d, _ := strconv.Atoi(strings.TrimSpace(bpfDur.Text))
						req := EBPFRequest{Tool: t.Name, Program: bpfProg.Text, Duration: d}
						argv, err := req.Argv()
						if err != nil {
							dialog.ShowError(err, w)
							return
						}
						stream(argv, nil, bpfLog, "trace "+t.Name)
					}))),
			bpfProg,
		), nil, nil, nil, bpfLog.view)

	// ── frame ───────────────────────────────────────────────────────
	tabs := container.NewAppTabs(
		container.NewTabItem("   Lab   ", labPane),
		container.NewTabItem("   Run   ", runPane),
		container.NewTabItem("   Results   ", resultsPane),
		container.NewTabItem("   Kernel   ", kernPane),
		container.NewTabItem("   Metrics   ", metricsPane),
		container.NewTabItem("   eBPF   ", bpfPane),
	)

	header := container.NewVBox(
		container.NewBorder(nil, nil, nil,
			widget.NewLabel("ztxplore "+version+" b"+buildNum), sourceLabel),
		widget.NewSeparator(),
	)
	w.SetContent(container.NewBorder(header,
		container.NewVBox(widget.NewSeparator(), status), nil, nil, tabs))

	// ── the collectors ──────────────────────────────────────────────
	// Each pane's data is gathered off-thread and applied on the UI thread.
	// They keep running whichever tab is in front, because the whole point is
	// that the panes agree about one moment in time.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := FollowKernelLog(ctx, func(l KernelLine) {
		kernMu.Lock()
		kernLines = append(kernLines, l)
		if len(kernLines) > 5000 {
			kernLines = kernLines[len(kernLines)-5000:]
		}
		kernMu.Unlock()
	}); err != nil {
		kernLog.Set([]string{err.Error()})
	}
	// Seed from the existing buffer so the pane is not empty until something
	// new happens — on a healthy box that could be hours.
	go func() {
		if seed, err := ReadKernelLog(2000, 5*time.Second); err == nil {
			kernMu.Lock()
			kernLines = append(seed, kernLines...)
			kernMu.Unlock()
			fyne.Do(renderKern)
		}
	}()

	go func() {
		for {
			arc := ReadARC("")
			pools, poolErr := ReadPoolIO(5 * time.Second)
			lat := ReadLatency(3 * time.Second)
			promOK, promWhy := PromAvailable(3 * time.Second)
			var panels []PromReading
			if promOK {
				panels = ReadZFSPanels(4 * time.Second)
			}
			fyne.Do(func() {
				promBox.Objects = nil
				if !promOK {
					promBox.Add(colouredLabel(promWhy, warnGold))
				} else {
					for _, r := range panels {
						v := r.Render()
						c := okGreen
						if !r.OK {
							c = warnGold
							v = "no data"
						}
						promBox.Add(container.NewGridWithColumns(2,
							widget.NewLabel(r.Label), colouredLabel(v, c)))
					}
				}
				promBox.Refresh()

				arcBox.Objects = nil
				if !arc.Available {
					arcBox.Add(colouredLabel(arc.Why, warnGold))
				} else {
					arcBox.Add(widget.NewLabel(fmt.Sprintf(
						"size %s   target %s   max %s",
						humanBytes(arc.Size), humanBytes(arc.Target), humanBytes(arc.Max))))
					hr := arc.HitRate()
					c := okGreen
					if hr < 80 {
						c = warnGold
					}
					arcBox.Add(colouredLabel(fmt.Sprintf(
						"hit rate %.1f%%   (%d hits, %d misses)", hr, arc.Hits, arc.Misses), c))
					arcBox.Add(widget.NewLabel(fmt.Sprintf("mfu %s   mru %s",
						humanBytes(arc.MFUSize), humanBytes(arc.MRUSize))))
				}
				arcBox.Refresh()

				poolBox.Objects = nil
				if poolErr != nil {
					poolBox.Add(colouredLabel(poolErr.Error(), warnGold))
				}
				for _, p := range pools {
					poolBox.Add(widget.NewLabel(fmt.Sprintf(
						"%-10s  read %d ops %s/s   write %d ops %s/s   alloc %s of %s",
						p.Pool, p.ReadOps, humanBytes(p.ReadBW),
						p.WriteOps, humanBytes(p.WriteBW),
						humanBytes(p.Alloc), humanBytes(p.Alloc+p.Free))))
				}
				poolBox.Refresh()

				latBox.Objects = nil
				if !lat.Available {
					latBox.Add(colouredLabel(lat.Why, warnGold))
				} else {
					// A text histogram, because the shape is the reading: a
					// tail creeping right is what a developer is looking for.
					max := uint64(1)
					for _, b := range lat.Buckets {
						if b.Count > max {
							max = b.Count
						}
					}
					for _, b := range lat.Buckets {
						bars := int(b.Count * 40 / max)
						latBox.Add(widget.NewLabel(fmt.Sprintf("%-8s %-40s %d",
							"≤"+b.Bound(), strings.Repeat("█", bars), b.Count)))
					}
				}
				latBox.Refresh()
			})
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
	}()

	// One repaint timer for every log pane. Per-line repainting makes a
	// fast-producing test run unusable.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(500 * time.Millisecond):
				fyne.Do(func() {
					runLog.flush()
					labLog.flush()
					bpfLog.flush()
					kernLog.flush()
					renderKern()
				})
			}
		}
	}()

	refreshRuns()
	w.ShowAndRun()
	return nil
}

func boldLabel(s string) *widget.Label {
	return widget.NewLabelWithStyle(s, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
}

// colouredLabel renders text in a specific colour.
//
// WHY canvas.Text AND NOT widget.Label: a Label takes its colour from the
// theme and cannot be told otherwise, and RichTextStyle only accepts a theme
// COLOUR NAME — neither can say "this row is red because this distro
// failed". canvas.Text takes a colour directly, which is the whole
// requirement here.
func colouredLabel(s string, c color.Color) fyne.CanvasObject {
	t := canvas.NewText(s, c)
	t.TextSize = theme.TextSize()
	return t
}
