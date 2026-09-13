//go:build gui

// =============================================================================
// gui.go — the same tree, in a window.
//
// One model, two front ends, exactly as zxplore and ztxplore do it: the tree
// in tree.go is the product, and this file and render.go are two ways of
// looking at it. Nothing here knows what a metric is.
//
// WHY FYNE: it is what the rest of the console family already links, so the
// image carries one toolkit rather than three, and the GL/Wayland stack it
// needs is already present on any profile that ships a desktop.
//
// The window is deliberately plain for now. The paned-tab interface the
// operator asked for is the next piece of work, and it wants the model to
// have settled first — building a layout around a shape that is still moving
// is how you end up with a layout that owns the shape.
// =============================================================================

package main

import (
	"fmt"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

// RunGUI opens the explorer window and blocks until it closes.
//
// Rebuilds the tree on an interval rather than on a signal: every source here
// is a scrape that already happened, so there is nothing to subscribe to and
// polling at the scrape interval is the honest cadence.
func RunGUI(q Querier, host string) error {
	a := app.NewWithID("com.kldload.mxplore")
	w := a.NewWindow(fmt.Sprintf("mxplore — %s", host))
	w.Resize(fyne.NewSize(1100, 800))

	// The tree widget reads from this snapshot; the refresh loop replaces it.
	// Guarded by the fact that Fyne drives both from the main goroutine.
	var root *Node
	var errs []error

	uidToNode := map[widget.TreeNodeID]*Node{}

	rebuild := func() {
		root, errs = Build(q, host, Views())
		uidToNode = map[widget.TreeNodeID]*Node{"": root}
		var index func(prefix widget.TreeNodeID, n *Node)
		index = func(prefix widget.TreeNodeID, n *Node) {
			for i, c := range n.Children {
				id := widget.TreeNodeID(fmt.Sprintf("%s/%d", prefix, i))
				uidToNode[id] = c
				index(id, c)
			}
		}
		index("", root)
	}
	rebuild()

	tree := widget.NewTree(
		func(id widget.TreeNodeID) []widget.TreeNodeID {
			n, ok := uidToNode[id]
			if !ok {
				return nil
			}
			out := make([]widget.TreeNodeID, len(n.Children))
			for i := range n.Children {
				out[i] = widget.TreeNodeID(fmt.Sprintf("%s/%d", id, i))
			}
			return out
		},
		func(id widget.TreeNodeID) bool {
			n, ok := uidToNode[id]
			return ok && len(n.Children) > 0
		},
		func(branch bool) fyne.CanvasObject {
			return container.NewHBox(widget.NewLabel("name"), widget.NewLabel("value"))
		},
		func(id widget.TreeNodeID, branch bool, o fyne.CanvasObject) {
			n, ok := uidToNode[id]
			if !ok {
				return
			}
			row := o.(*fyne.Container)
			name := row.Objects[0].(*widget.Label)
			value := row.Objects[1].(*widget.Label)
			name.SetText(n.Name)
			name.TextStyle = fyne.TextStyle{Bold: branch}
			switch {
			case n.Detail != "":
				value.SetText(n.Detail)
			default:
				value.SetText(n.Value)
			}
		},
	)

	status := widget.NewLabel("")
	setStatus := func() {
		if len(errs) == 0 {
			status.SetText(fmt.Sprintf("%s — %d rows, every branch answered", time.Now().Format("15:04:05"), root.Count()))
			return
		}
		// Name the count, not the first one: "3 branches unavailable" sends
		// the operator to look, one error message sends them to fix the wrong
		// exporter.
		status.SetText(fmt.Sprintf("%s — %d rows, %d branches unavailable", time.Now().Format("15:04:05"), root.Count(), len(errs)))
	}
	setStatus()

	refresh := widget.NewButtonWithIcon("Refresh", theme.ViewRefreshIcon(), func() {
		rebuild()
		tree.Refresh()
		setStatus()
	})

	w.SetContent(container.NewBorder(
		container.NewHBox(refresh), status, nil, nil, tree))

	// Open the four views, so the window does not start as four closed rows.
	for i := range root.Children {
		tree.OpenBranch(widget.TreeNodeID(fmt.Sprintf("/%d", i)))
	}

	stop := make(chan struct{})
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				fyne.Do(func() {
					rebuild()
					tree.Refresh()
					setStatus()
				})
			case <-stop:
				return
			}
		}
	}()
	w.SetOnClosed(func() { close(stop) })

	w.ShowAndRun()
	return nil
}
