//go:build gui

// =============================================================================
// gui.go — the build & audit window.
//
// WHAT IT SHOWS, top to bottom:
//   1. one verdict line, colour-coded, that answers "can I use this machine";
//   2. a progress bar with the phase count, while a build is running;
//   3. four tabs — Progress, Audit, Doctor, Components.
//
// WHY IT EXISTS:
//   The previous progress display was a bash script painting a terminal by
//   homing the cursor and overwriting the last frame. It required being the
//   only writer on that screen, and on 2026-08-15 it was not: a screenshot from
//   .145 showed one pane painted by two instances 23 minutes apart, with
//   duplicated Phase/Elapsed/Progress blocks, half-overwritten words
//   ("doneing", "done12s") and a banner smeared into itself. A GUI cannot
//   collide with itself that way, and it can show four different kinds of
//   information without any of them fighting for the same 30 rows.
//
// WHY FYNE: wgx and vmx already ship Fyne GUIs built by builder/build-iso.sh
// with CGO_ENABLED=1 -tags gui, so the toolchain, the runtime libraries on the
// target and the build pattern all exist already.
//
// Notes:
//   - Refresh is on a ticker, and every refresh rebuilds from a fresh Snapshot.
//     There is no incremental repaint anywhere, precisely because incremental
//     repaint is what produced the display this replaces.
//   - Doctor is NOT run on the fast ticker. It shells out to zfs/libvirt/
//     kubectl, which is far too slow for a 2s loop, so it runs on demand and on
//     a much slower timer.
// =============================================================================

package main

import (
	"fmt"
	"image/color"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

// Palette. Deliberately few colours: one per meaning, so a glance at the
// banner is enough and nothing else on screen competes with it.
var (
	colBuilding = color.NRGBA{R: 0xE0, G: 0xA0, B: 0x30, A: 0xFF} // amber
	colReady    = color.NRGBA{R: 0x34, G: 0xD3, B: 0x99, A: 0xFF} // green
	colProblem  = color.NRGBA{R: 0xE0, G: 0x5A, B: 0x5A, A: 0xFF} // red
	colMuted    = color.NRGBA{R: 0x90, G: 0x9A, B: 0xA6, A: 0xFF}
)

func levelColour(l Level) color.NRGBA {
	switch l {
	case LevelReady:
		return colReady
	case LevelProblem:
		return colProblem
	default:
		return colBuilding
	}
}

// gui holds the widgets that get refreshed. Keeping them on a struct means the
// refresh path updates values in place rather than rebuilding the widget tree,
// which would lose scroll position on every tick.
type gui struct {
	win fyne.Window
	opt GatherOpts

	banner   *canvas.Text
	sub      *widget.Label
	bar      *widget.ProgressBar
	barLabel *widget.Label

	phaseList *widget.List
	phases    []Phase

	auditList *widget.List
	findings  []Finding

	doctorBox  *fyne.Container
	doctorBtn  *widget.Button
	compBox    *fyne.Container
	logView    *widget.Entry
	lastDoctor time.Time
}

// RunGUI opens the window and blocks until it is closed.
func RunGUI(opt GatherOpts) error {
	// NewWithID, not New(): the sisters do the same (dev.vmxplore,
	// ca.wgxplore). Without a stable id the toolkit cannot key preferences
	// or window identity, and the desktop entry's StartupWMClass has
	// nothing dependable to match — which shows up as a generic icon and a
	// duplicate dock entry.
	a := app.NewWithID("com.kldload.buildmon")
	w := a.NewWindow("kldload — System Build & Audit")
	w.Resize(fyne.NewSize(980, 720))

	g := &gui{win: w, opt: opt}

	g.banner = canvas.NewText("Checking this system…", colMuted)
	g.banner.TextStyle = fyne.TextStyle{Bold: true}
	g.banner.TextSize = 20

	g.sub = widget.NewLabel("")
	g.sub.Wrapping = fyne.TextWrapWord

	g.bar = widget.NewProgressBar()
	g.barLabel = widget.NewLabel("")

	head := container.NewVBox(
		g.banner,
		g.sub,
		container.NewBorder(nil, nil, nil, g.barLabel, g.bar),
		widget.NewSeparator(),
	)

	tabs := container.NewAppTabs(
		container.NewTabItemWithIcon("Progress", theme.MediaPlayIcon(), g.buildProgressTab()),
		container.NewTabItemWithIcon("Audit", theme.WarningIcon(), g.buildAuditTab()),
		container.NewTabItemWithIcon("Doctor", theme.QuestionIcon(), g.buildDoctorTab()),
		container.NewTabItemWithIcon("Components", theme.StorageIcon(), g.buildComponentsTab()),
	)
	tabs.SetTabLocation(container.TabLocationTop)

	w.SetContent(container.NewBorder(head, nil, nil, nil, tabs))

	// Fast loop for the cheap sources. Doctor and components are slow and are
	// refreshed on their own tabs' buttons plus a slow timer.
	go func() {
		g.refresh(true)
		// Ask for the foreground once, after the first paint has something to
		// show. This window's whole job during an install is saying "do not
		// reboot", which it cannot do from behind a browser. Once only: a
		// window that keeps stealing focus every refresh is malware behaviour,
		// and the operator has to be able to work while the build runs.
		fyne.Do(func() { w.RequestFocus() })
		for range time.Tick(2 * time.Second) {
			g.refresh(false)
		}
	}()

	w.ShowAndRun()
	return nil
}

// buildProgressTab: the phase checklist plus the live log tail.
func (g *gui) buildProgressTab() fyne.CanvasObject {
	g.phaseList = widget.NewList(
		func() int { return len(g.phases) },
		func() fyne.CanvasObject {
			return container.NewBorder(nil, nil,
				widget.NewLabel("•"), widget.NewLabel("pending"),
				widget.NewLabel("phase"))
		},
		func(i widget.ListItemID, o fyne.CanvasObject) {
			if i >= len(g.phases) {
				return
			}
			p := g.phases[i]
			row := o.(*fyne.Container)
			icon := row.Objects[1].(*widget.Label)
			right := row.Objects[2].(*widget.Label)
			name := row.Objects[0].(*widget.Label)

			name.SetText(p.Name)
			switch p.State {
			case StateDone:
				icon.SetText("✓")
				right.SetText("done")
			case StateRunning:
				icon.SetText("▶")
				right.SetText(fmtDur(p.Elapsed))
			case StateFailed:
				icon.SetText("✗")
				right.SetText("FAILED")
			default:
				icon.SetText("·")
				right.SetText("pending")
			}
		},
	)

	g.logView = widget.NewMultiLineEntry()
	g.logView.TextStyle = fyne.TextStyle{Monospace: true}
	g.logView.Wrapping = fyne.TextWrapOff

	split := container.NewVSplit(g.phaseList, container.NewBorder(
		widget.NewLabelWithStyle("/var/log/kldload/autodeploy.log", fyne.TextAlignLeading,
			fyne.TextStyle{Bold: true}),
		nil, nil, nil, g.logView))
	split.SetOffset(0.45)
	return split
}

// buildAuditTab: the install audit, worst first.
func (g *gui) buildAuditTab() fyne.CanvasObject {
	g.auditList = widget.NewList(
		func() int { return len(g.findings) },
		func() fyne.CanvasObject {
			sev := widget.NewLabel("SEV")
			sev.TextStyle = fyne.TextStyle{Bold: true}
			msg := widget.NewLabel("message")
			msg.TextStyle = fyne.TextStyle{Monospace: true}
			why := widget.NewLabel("why")
			why.Wrapping = fyne.TextWrapWord
			return container.NewVBox(container.NewHBox(sev, widget.NewLabel("src")), msg, why,
				widget.NewSeparator())
		},
		func(i widget.ListItemID, o fyne.CanvasObject) {
			if i >= len(g.findings) {
				return
			}
			f := g.findings[i]
			box := o.(*fyne.Container)
			hdr := box.Objects[0].(*fyne.Container)
			hdr.Objects[0].(*widget.Label).SetText(f.Severity.String())
			where := f.Source
			if f.Line > 0 {
				where = fmt.Sprintf("%s:%d", f.Source, f.Line)
			}
			hdr.Objects[1].(*widget.Label).SetText(where)
			box.Objects[1].(*widget.Label).SetText(f.Message)
			box.Objects[2].(*widget.Label).SetText(f.Why)
		},
	)
	return g.auditList
}

func (g *gui) buildDoctorTab() fyne.CanvasObject {
	g.doctorBox = container.NewVBox(widget.NewLabel("Not run yet."))
	g.doctorBtn = widget.NewButtonWithIcon("Run health checks", theme.ViewRefreshIcon(), func() {
		g.doctorBtn.Disable()
		g.doctorBox.Objects = []fyne.CanvasObject{widget.NewLabel("Running kldload-doctor…")}
		g.doctorBox.Refresh()
		go func() {
			rep, err := RunDoctor(g.opt.DoctorBin, 90*time.Second)
			fyne.Do(func() {
				g.renderDoctor(rep, err)
				g.doctorBtn.Enable()
			})
		}()
	})
	return container.NewBorder(g.doctorBtn, nil, nil, nil, container.NewVScroll(g.doctorBox))
}

func (g *gui) renderDoctor(rep DoctorReport, err error) {
	if err != nil {
		g.doctorBox.Objects = []fyne.CanvasObject{
			widget.NewLabel("kldload-doctor could not run:\n" + err.Error()),
		}
		g.doctorBox.Refresh()
		return
	}
	objs := []fyne.CanvasObject{
		widget.NewLabelWithStyle(fmt.Sprintf("%d ok · %d warn · %d fail · %d skipped",
			rep.Count("ok"), rep.Count("warn"), rep.Count("fail"), rep.Count("skip")),
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true}),
		widget.NewSeparator(),
	}
	bad := rep.Bad()
	if len(bad) == 0 {
		objs = append(objs, widget.NewLabel("Every check passed."))
	}
	for _, c := range bad {
		title := widget.NewLabelWithStyle(
			fmt.Sprintf("[%s] %s / %s", strings.ToUpper(c.Status), c.Subsystem, c.Name),
			fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
		body := widget.NewLabel(fmt.Sprintf("expected: %s\nactual:   %s", c.Expected, c.Actual))
		body.TextStyle = fyne.TextStyle{Monospace: true}
		objs = append(objs, title, body)
		if c.Remediation != "" {
			fix := widget.NewLabel("fix: " + c.Remediation)
			fix.TextStyle = fyne.TextStyle{Monospace: true}
			fix.Wrapping = fyne.TextWrapWord
			objs = append(objs, fix)
		}
		objs = append(objs, widget.NewSeparator())
	}
	g.doctorBox.Objects = objs
	g.doctorBox.Refresh()
}

func (g *gui) buildComponentsTab() fyne.CanvasObject {
	g.compBox = container.NewVBox(widget.NewLabel("Loading components…"))
	refresh := widget.NewButtonWithIcon("Refresh", theme.ViewRefreshIcon(), func() {
		go g.refreshComponents()
	})
	go g.refreshComponents()
	return container.NewBorder(refresh, nil, nil, nil, container.NewVScroll(g.compBox))
}

func (g *gui) refreshComponents() {
	comps, err := ListComponents(g.opt.ComponentBin, 30*time.Second)
	fyne.Do(func() {
		var objs []fyne.CanvasObject
		switch {
		case err != nil:
			objs = append(objs, widget.NewLabel("kldload-component could not run:\n"+err.Error()))
		case len(comps) == 0:
			// Seen on .145: the CLI ships but /usr/lib/kldload/components/ does
			// not, so `list` returns a bare header. Say so rather than showing
			// an empty pane that looks like "nothing to install".
			objs = append(objs, widget.NewLabel(
				"No components are defined on this system.\n\n"+
					"kldload-component is installed but /usr/lib/kldload/components/ is\n"+
					"empty or missing, so there is nothing for it to manage."))
		}
		for _, c := range comps {
			c := c
			state := widget.NewLabel(string(c.State))
			if c.State.NeedsAttention() {
				state.TextStyle = fyne.TextStyle{Bold: true}
			}
			name := widget.NewLabelWithStyle(c.Name, fyne.TextAlignLeading,
				fyne.TextStyle{Bold: true})
			summary := widget.NewLabel(c.Summary + "   (" + c.Approx + ")")
			summary.Wrapping = fyne.TextWrapWord

			var action *widget.Button
			switch {
			case c.State.Busy():
				action = widget.NewButton("working…", nil)
				action.Disable()
			case c.State == CompInstalled:
				action = widget.NewButtonWithIcon("Remove", theme.DeleteIcon(), func() {
					g.componentAction("remove", c.Name)
				})
			default:
				action = widget.NewButtonWithIcon("Install", theme.ContentAddIcon(), func() {
					g.componentAction("install", c.Name)
				})
			}
			objs = append(objs,
				container.NewBorder(nil, nil, container.NewHBox(name, state), action, summary),
				widget.NewSeparator())
		}
		g.compBox.Objects = objs
		g.compBox.Refresh()
	})
}

// componentAction confirms first — install and remove are minutes-to-hours of
// work and remove takes things away, so neither should happen on a stray click.
func (g *gui) componentAction(verb, name string) {
	dialog.ShowConfirm(strings.Title(verb)+" "+name+"?",
		fmt.Sprintf("This runs `kldload-component %s %s`, which detaches and can take a while.\nFollow it in %s",
			verb, name, ComponentLogPath(name)),
		func(ok bool) {
			if !ok {
				return
			}
			go func() {
				out, err := ComponentAction(g.opt.ComponentBin, verb, name, 60*time.Second)
				fyne.Do(func() {
					if err != nil {
						dialog.ShowError(fmt.Errorf("%s %s failed: %w\n%s", verb, name, err, out), g.win)
					}
					g.refreshComponents()
				})
			}()
		}, g.win)
}

// refresh repaints from a fresh snapshot. full=true also refreshes the slow
// sources.
func (g *gui) refresh(full bool) {
	o := g.opt
	o.SkipDoctor = true // never on the 2s path; see the file header
	snap := Gather(o)
	tail := logTail("/var/log/kldload/autodeploy.log", 200)

	fyne.Do(func() {
		lvl, msg := snap.Verdict()
		g.banner.Text = msg
		g.banner.Color = levelColour(lvl)
		g.banner.Refresh()

		switch {
		case lvl == LevelProblem:
			g.sub.SetText("Open the Audit tab for the detail. The machine may still be usable, " +
				"but something here needs a person.")
		case lvl == LevelBuilding:
			g.sub.SetText("The desktop is ready early on purpose — the system is still working. " +
				"Do not reboot or power off until this finishes.")
		default:
			g.sub.SetText("All build phases finished and nothing was flagged.")
		}

		if f, ok := snap.Progress.Fraction(); ok {
			g.bar.SetValue(f)
			g.barLabel.SetText(fmt.Sprintf("%d of %d phases",
				snap.Progress.Done(), len(snap.Progress.Phases)))
		} else {
			g.bar.SetValue(0)
			g.barLabel.SetText("no phase plan")
		}

		g.phases = snap.Progress.Phases
		g.phaseList.Refresh()

		g.findings = snap.Findings
		g.auditList.Refresh()

		if g.logView.Text != tail {
			g.logView.SetText(tail)
			g.logView.CursorRow = strings.Count(tail, "\n")
		}
	})
}

func fmtDur(d time.Duration) string {
	if d <= 0 {
		return ""
	}
	d = d.Round(time.Second)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	if h > 0 {
		return fmt.Sprintf("%dh %02dm", h, m)
	}
	return fmt.Sprintf("%dm %02ds", m, s)
}
