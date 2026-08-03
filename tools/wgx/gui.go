//go:build gui

// gui.go — the native wgxplore window (Fyne), sibling to zxplore's GUI.
//
// Same two-pane shape as the TUI and as zxplore: the estate on the left, a
// full dossier on the right. Read-only; mutations stay behind the engine's
// explicit verbs so every change is a visible wg/ip command.
//
// Window title is EXACTLY the app name: GLFW derives the X11 WM_CLASS from
// the title at window creation, and the shell maps WM_CLASS → .desktop for
// the dock icon. zxplore shipped a pretty title once and every desktop
// showed a generic fallback icon (fixed there 2026-08-02, e6c6e0f); do not
// repeat it here. The launcher's GenericName carries the descriptive text.
package main

import (
	"fmt"
	"image/color"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

var (
	colAlive = color.NRGBA{0x4c, 0xb9, 0x8a, 0xff}
	colQuiet = color.NRGBA{0xe6, 0xa5, 0x5f, 0xff}
	colStale = color.NRGBA{0xdc, 0x48, 0x48, 0xff}
	colAlarm = color.NRGBA{0xff, 0x5c, 0xd6, 0xff}
)

type guiRow struct {
	dev  int
	peer int // -1 = the interface line
}

// RunGUI opens the console window.
func RunGUI() error {
	a := app.NewWithID("ca.wgxplore")
	a.SetIcon(theme.ComputerIcon())
	w := a.NewWindow("wgxplore")
	w.Resize(fyne.NewSize(1100, 700))

	var (
		devs    []Device
		rows    []guiRow
		hosts   = sshHosts()
		summary = widget.NewLabel("scanning estate…")
		dossier = widget.NewRichTextFromMarkdown("")
	)
	dossier.Wrapping = fyne.TextWrapWord

	list := widget.NewList(
		func() int { return len(rows) },
		func() fyne.CanvasObject { return widget.NewLabel("row") },
		func(i widget.ListItemID, o fyne.CanvasObject) {
			if i >= len(rows) {
				return
			}
			r := rows[i]
			d := devs[r.dev]
			lbl := o.(*widget.Label)
			if r.peer < 0 {
				host := d.Host
				if host == "" {
					host = "local"
				}
				lbl.TextStyle = fyne.TextStyle{Bold: true}
				if d.Err != "" {
					lbl.SetText(fmt.Sprintf("%s — unreachable", host))
				} else {
					lbl.SetText(fmt.Sprintf("%s   %s", host, d.Name))
				}
				return
			}
			p := d.Peers[r.peer]
			lbl.TextStyle = fyne.TextStyle{Monospace: true}
			dot := map[string]string{"alive": "●", "quiet": "●", "stale": "○", "never": "○"}[p.Health()]
			flag := " "
			if !p.Declared {
				flag = "!"
			}
			key := p.PublicKey
			if len(key) > 14 {
				key = key[:14] + "…"
			}
			lbl.SetText(fmt.Sprintf("   %s%s %s  %s", dot, flag, key, p.Age()))
		},
	)

	rebuild := func() {
		rows = nil
		for di, d := range devs {
			rows = append(rows, guiRow{dev: di, peer: -1})
			for pi := range d.Peers {
				rows = append(rows, guiRow{dev: di, peer: pi})
			}
		}
		h, i, p, al, un := Totals(devs)
		s := fmt.Sprintf("%d hosts · %d interfaces · %d peers · %d alive", h, i, p, al)
		if un > 0 {
			s += fmt.Sprintf("   ⚠ %d UNDECLARED", un)
		}
		summary.SetText(s)
		list.Refresh()
	}

	reload := func() {
		summary.SetText("scanning estate…")
		go func() {
			d := CollectEstate(hosts)
			MarkDeclared(d)
			fyne.Do(func() {
				devs = d
				rebuild()
			})
		}()
	}

	list.OnSelected = func(i widget.ListItemID) {
		if i >= len(rows) {
			return
		}
		r := rows[i]
		d := devs[r.dev]
		if r.peer < 0 {
			dossier.ParseMarkdown(guiDeviceDossier(d))
		} else {
			dossier.ParseMarkdown(guiPeerDossier(d, d.Peers[r.peer]))
		}
	}

	refresh := widget.NewButtonWithIcon("Refresh", theme.ViewRefreshIcon(), reload)
	top := container.NewBorder(nil, nil, nil, refresh, summary)
	split := container.NewHSplit(list, container.NewVScroll(dossier))
	split.Offset = 0.34
	w.SetContent(container.NewBorder(top, nil, nil, nil, split))

	reload()
	// Live handshake ages: refresh the estate on a slow tick so "alive"
	// actually means alive while the window sits open.
	go func() {
		for range time.Tick(30 * time.Second) {
			reload()
		}
	}()

	w.ShowAndRun()
	return nil
}

func guiDeviceDossier(d Device) string {
	host := d.Host
	if host == "" {
		host = "local"
	}
	if d.Err != "" {
		return fmt.Sprintf("## %s\n\n**UNREACHABLE**\n\n```\n%s\n```\n", host, d.Err)
	}
	var alive, undeclared int
	for _, p := range d.Peers {
		if p.Health() == "alive" {
			alive++
		}
		if !p.Declared {
			undeclared++
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "## interface %s\n\n", d.Name)
	fmt.Fprintf(&b, "| | |\n|---|---|\n")
	fmt.Fprintf(&b, "| host | %s |\n", host)
	fmt.Fprintf(&b, "| public key | `%s` |\n", d.PublicKey)
	fmt.Fprintf(&b, "| listen port | %s |\n", orDash(d.ListenPort))
	fmt.Fprintf(&b, "| peers | %d (%d handshaking) |\n", len(d.Peers), alive)
	if undeclared > 0 {
		fmt.Fprintf(&b, "\n**⚠ %d peer(s) are not in any declaration.**\n", undeclared)
	}
	return b.String()
}

func guiPeerDossier(d Device, p Peer) string {
	var b strings.Builder
	fmt.Fprintf(&b, "## peer\n\n")
	fmt.Fprintf(&b, "| | |\n|---|---|\n")
	fmt.Fprintf(&b, "| public key | `%s` |\n", p.PublicKey)
	fmt.Fprintf(&b, "| on | %s |\n", d.Name)
	fmt.Fprintf(&b, "| endpoint | %s |\n", orDash(p.Endpoint))
	fmt.Fprintf(&b, "| allowed-ips | `%s` |\n", p.AllowedIPs)
	fmt.Fprintf(&b, "| handshake | **%s** (%s) |\n", p.Age(), p.Health())
	fmt.Fprintf(&b, "| traffic | rx %s / tx %s |\n", human(p.RxBytes), human(p.TxBytes))
	fmt.Fprintf(&b, "| keepalive | %s |\n", orDash(p.Keepalive))
	if p.Declared {
		fmt.Fprintf(&b, "\n✓ **Declared** — this peer belongs to a wgxplore network.\n")
	} else {
		fmt.Fprintf(&b, "\n⚠ **UNDECLARED** — no declaration lists this key.\n\n")
		fmt.Fprintf(&b, "A peer cannot appear by accident: cryptokey routing means "+
			"someone with root on `%s` added it. Investigate.\n", d.Name)
	}
	return b.String()
}
