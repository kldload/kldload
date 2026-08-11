//go:build gui

// gui.go — the native wgxplore window (Fyne), sibling to zxplore's GUI.
//
// A themed console, not a stock-widget form: dark slate chassis, the brand
// teal/amber of the wgxplore mark, and colour used for SEPARATION — health
// states (alive/quiet/stale), the undeclared-peer alarm, and the summary
// chips each own a colour so the eye finds trouble before reading a word.
// Layout is the same two-pane shape as the TUI and as zxplore: estate tree
// on the left, full dossier on the right, interface cards across the top.
//
// Read-only. Mutations stay behind the engine's explicit verbs so every
// change is a visible wg/ip command.
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
	"net/url"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

// ─── palette ─────────────────────────────────────────────────────────────
// One source of truth, shared by the theme and every hand-drawn element.
// Brand colours match the wgxplore mark (teal glyph, amber hub) and the
// health colours match the TUI so the two consoles read as one product.
// TWO palettes — the console honours the OS light/dark preference (it
// shipped perma-dark first; the family standard, set by zxplore, is both).
// The pal* globals are the ACTIVE palette; setPalette flips them and the
// settings listener in RunGUI reacts to live OS theme changes.
type wgxPalette struct {
	bg, panel, raised, line, fg, dim,
	brand, cyan, amber, alive, quiet, stale, alarm, sel color.NRGBA
}

// The FAMILY palette (zxplore / vmxplore / wgxplore share it): a
// near-black steel base with panels lifted just off it, and electric
// accents that survive being small. Only the brand accent differs per
// console — zxplore purple, vmxplore blue, wgxplore cyan — so the three
// read as one product without being interchangeable.
var darkPal = wgxPalette{
	bg:     color.NRGBA{0x08, 0x09, 0x0c, 0xff}, // steel-black base
	panel:  color.NRGBA{0x15, 0x1b, 0x23, 0xff}, // card, floating on the base
	raised: color.NRGBA{0x1c, 0x24, 0x30, 0xff}, // tiles/rows above a card
	line:   color.NRGBA{0x24, 0x30, 0x3b, 0xff},
	fg:     color.NRGBA{0xe3, 0xe9, 0xef, 0xff}, // crisp steel-white
	dim:    color.NRGBA{0x7d, 0x8d, 0x9b, 0xff},
	brand:  color.NRGBA{0x4d, 0xa6, 0xff, 0xff}, // acBlue — the brand accent
	cyan:   color.NRGBA{0x33, 0xe6, 0xe6, 0xff}, // acCyan — the secondary
	amber:  color.NRGBA{0xff, 0xd0, 0x43, 0xff}, // acGold
	alive:  color.NRGBA{0x3d, 0xff, 0x88, 0xff}, // acGreen
	quiet:  color.NRGBA{0xff, 0xd0, 0x43, 0xff}, // acGold — warned, not failed
	stale:  color.NRGBA{0xe2, 0x69, 0x5d, 0xff}, // acRed
	alarm:  color.NRGBA{0xc7, 0x7d, 0xff, 0xff}, // acPurple
	sel:    color.NRGBA{0x2a, 0x3a, 0x48, 0xff}, // steel-blue highlight
}

// Light: same hues, darkened for contrast on paper-white — the teal/amber
// stay recognisably the brand, health colours stay red/amber/green.
var lightPal = wgxPalette{
	bg:     color.NRGBA{0xff, 0xff, 0xff, 0xff},
	panel:  color.NRGBA{0xf7, 0xf4, 0xf3, 0xff},
	raised: color.NRGBA{0xee, 0xea, 0xe8, 0xff},
	line:   color.NRGBA{0xc8, 0xd3, 0xdb, 0xff},
	fg:     color.NRGBA{0x1e, 0x18, 0x18, 0xff},
	dim:    color.NRGBA{0x5c, 0x6b, 0x77, 0xff},
	brand:  color.NRGBA{0x14, 0x66, 0xd8, 0xff}, // acBlue light
	cyan:   color.NRGBA{0x0a, 0x8f, 0x9c, 0xff}, // acCyan light
	amber:  color.NRGBA{0xb0, 0x7d, 0x00, 0xff}, // acGold light
	alive:  color.NRGBA{0x0e, 0x9d, 0x4a, 0xff}, // acGreen light
	quiet:  color.NRGBA{0xb0, 0x7d, 0x00, 0xff},
	stale:  color.NRGBA{0xb8, 0x38, 0x28, 0xff}, // acRed light
	alarm:  color.NRGBA{0x7a, 0x2f, 0xe0, 0xff}, // acPurple light
	sel:    color.NRGBA{0xc5, 0xe6, 0xe3, 0xff},
}

var (
	palBg     = darkPal.bg
	palPanel  = darkPal.panel
	palRaised = darkPal.raised
	palLine   = darkPal.line
	palFg     = darkPal.fg
	palDim    = darkPal.dim
	palBrand  = darkPal.brand
	palAmber  = darkPal.amber
	palAlive  = darkPal.alive
	palQuiet  = darkPal.quiet
	palStale  = darkPal.stale
	palAlarm  = darkPal.alarm
	palSelect = darkPal.sel
	palCyan   = darkPal.cyan
)

func setPalette(v fyne.ThemeVariant) {
	p := darkPal
	if v == theme.VariantLight {
		p = lightPal
	}
	palBg, palPanel, palRaised, palLine = p.bg, p.panel, p.raised, p.line
	palFg, palDim, palBrand, palAmber = p.fg, p.dim, p.brand, p.amber
	palAlive, palQuiet, palStale, palAlarm, palSelect =
		p.alive, p.quiet, p.stale, p.alarm, p.sel
	palCyan = p.cyan
}

func healthColor(h string) color.NRGBA {
	switch h {
	case "alive":
		return palAlive
	case "quiet":
		return palQuiet
	}
	return palStale
}

// ─── theme ───────────────────────────────────────────────────────────────
// wgxTheme forces the console's own dark palette regardless of the desktop
// variant — the estate view is a night console, and health colours are
// calibrated against this background. Fonts/icons/sizes delegate to the
// default theme so text metrics stay platform-correct.
type wgxTheme struct{}

func (wgxTheme) Color(n fyne.ThemeColorName, v fyne.ThemeVariant) color.Color {
	p := darkPal
	// Hover/pressed are OVERLAYS Fyne paints on top of the widget — they
	// must be translucent (an opaque hover blacked out the teal Refresh
	// button, seen .119 2026-08-03) and must darken on light backgrounds.
	hover := color.NRGBA{0xff, 0xff, 0xff, 0x14}
	pressed := color.NRGBA{0xff, 0xff, 0xff, 0x28}
	shadow := color.NRGBA{0x00, 0x00, 0x00, 0x66}
	if v == theme.VariantLight {
		p = lightPal
		hover = color.NRGBA{0x00, 0x00, 0x00, 0x10}
		pressed = color.NRGBA{0x00, 0x00, 0x00, 0x20}
		shadow = color.NRGBA{0x00, 0x00, 0x00, 0x2a}
	}
	switch n {
	case theme.ColorNameBackground:
		return p.bg
	case theme.ColorNameForeground:
		return p.fg
	case theme.ColorNamePrimary, theme.ColorNameFocus, theme.ColorNameHyperlink:
		return p.brand
	case theme.ColorNameButton, theme.ColorNameInputBackground:
		return p.panel
	case theme.ColorNameHover:
		return hover
	case theme.ColorNamePressed:
		return pressed
	case theme.ColorNameSelection:
		return p.sel
	case theme.ColorNameSeparator, theme.ColorNameInputBorder:
		return p.line
	case theme.ColorNamePlaceHolder, theme.ColorNameDisabled:
		return p.dim
	case theme.ColorNameScrollBar:
		return p.line
	case theme.ColorNameSuccess:
		return p.alive
	case theme.ColorNameWarning:
		return p.quiet
	case theme.ColorNameError:
		return p.stale
	case theme.ColorNameHeaderBackground, theme.ColorNameMenuBackground,
		theme.ColorNameOverlayBackground:
		return p.panel
	case theme.ColorNameForegroundOnPrimary:
		return p.bg
	case theme.ColorNameShadow:
		return shadow
	}
	return theme.DefaultTheme().Color(n, v)
}

func (wgxTheme) Font(s fyne.TextStyle) fyne.Resource { return theme.DefaultTheme().Font(s) }
func (wgxTheme) Icon(n fyne.ThemeIconName) fyne.Resource {
	return theme.DefaultTheme().Icon(n)
}

// Compact spacing, matching zxplore and vmxplore: tight rows so a list
// reads as a table, small gutters between regions so the base colour
// shows through as separation rather than as empty space. A console is
// mostly other machines' data — margins are drawn at its expense.
func (wgxTheme) Size(n fyne.ThemeSizeName) float32 {
	switch n {
	case theme.SizeNameInnerPadding:
		// tight rows so the estate reads as a table, matching zxplore
		return 3
	}
	// NB the region gutter is left at the default. zxplore and vmxplore
	// tighten it because their panes are edge-to-edge lists inside cards;
	// wgxplore's header carries chips and buttons that were laid out
	// against the standard gutter, and squeezing it collapsed them
	// together. Same tight ROWS, standard gaps BETWEEN regions.
	return theme.DefaultTheme().Size(n)
}

// ─── the family card treatment ───────────────────────────────────────────
//
// zxplore and vmxplore both float their regions as rounded panels on the
// near-black base, with the base showing through as the gutter. It reads
// as depth rather than as borders, and it is most of why the three
// consoles look like one product. repaintCards re-tints them when the
// desktop flips light/dark, since a canvas rectangle holds its own colour.

var repaintCards []func()

// cardTight is card without the inner inset, for content that should reach
// the panel's edge — a list or a console, where every pixel is data.
func cardTight(content fyne.CanvasObject) fyne.CanvasObject {
	r := canvas.NewRectangle(palPanel)
	r.CornerRadius = 8
	repaintCards = append(repaintCards, func() { r.FillColor = palPanel; r.Refresh() })
	return container.NewStack(r, content)
}

// gap gives a card its share of the black gutter.
func gap(o fyne.CanvasObject) fyne.CanvasObject { return container.NewPadded(o) }

// ─── small drawing helpers ───────────────────────────────────────────────

func txt(s string, c color.NRGBA, size float32, style fyne.TextStyle) *canvas.Text {
	t := canvas.NewText(s, c)
	t.TextSize = size
	t.TextStyle = style
	return t
}

// dot renders a fixed-size status circle — the smallest possible unit of
// colour separation; the tree and the cards both lead with one.
func dot(c color.NRGBA) fyne.CanvasObject {
	ci := canvas.NewCircle(c)
	return container.NewCenter(container.NewGridWrap(fyne.NewSize(10, 10), ci))
}

// card wraps content on the panel colour with rounded corners. It
// registers for repaint because a canvas rectangle holds its own fill —
// without this a light/dark flip leaves every panel the old colour.
func card(content fyne.CanvasObject) fyne.CanvasObject {
	bg := canvas.NewRectangle(palPanel)
	bg.CornerRadius = 8
	repaintCards = append(repaintCards, func() { bg.FillColor = palPanel; bg.Refresh() })
	return container.NewStack(bg, container.NewPadded(content))
}

// chip is a compact "value + label" summary tile for the header row.
func chip(value, label string, c color.NRGBA) fyne.CanvasObject {
	bg := canvas.NewRectangle(palRaised)
	bg.CornerRadius = 8
	return container.NewStack(bg, container.NewPadded(container.NewHBox(
		txt(value, c, 14, fyne.TextStyle{Bold: true}),
		txt(label, palDim, 12, fyne.TextStyle{}),
	)))
}

func kv(rows ...[2]string) fyne.CanvasObject {
	var objs []fyne.CanvasObject
	for _, r := range rows {
		objs = append(objs,
			txt(r[0], palDim, 13, fyne.TextStyle{}),
			txt(r[1], palFg, 13, fyne.TextStyle{Monospace: true}))
	}
	return container.New(layout.NewFormLayout(), objs...)
}

type nodeKind int

const (
	nHost nodeKind = iota
	nIface
	nPeer
)

// ─── the window ──────────────────────────────────────────────────────────

// RunGUI opens the console: summary chips and one card per interface across
// the top, the expandable estate tree on the left (host → interface → peer),
// a full dossier for the selection on the right.
func RunGUI() error {
	a := app.NewWithID("ca.wgxplore")
	a.Settings().SetTheme(wgxTheme{})
	// The hand-drawn elements (tree cells, cards, chips, verdicts) capture
	// the pal* globals, so the active palette must match the OS variant
	// BEFORE any widget is built. Live WM switches are handled by the
	// settings listener registered below, after reload() exists.
	setPalette(a.Settings().ThemeVariant())
	a.SetIcon(theme.ComputerIcon())
	w := a.NewWindow("wgxplore")
	w.Resize(fyne.NewSize(1180, 740))

	var (
		devs []Device
		// hosts are opened once, on the first scan that returns anything;
		// after that the tree stays exactly as the operator left it
		didOpenHosts bool
		// which view is on screen — the key handler pages the manual only
		manualOpen bool
		// header: brand + build left, summary chips right — rebuilt per load
		chips   = container.NewHBox()
		status  = txt("scanning estate…", palDim, 13, fyne.TextStyle{Italic: true})
		cards   = container.NewVBox() // one card per interface
		dossier = container.NewVBox() // right pane, rebuilt on select
		kids    = map[string][]string{}
		kind    = map[string]nodeKind{}
		ref     = map[string][2]int{} // uid → {device idx, peer idx(-1)}
	)

	reindex := func() {
		kids = map[string][]string{}
		kind = map[string]nodeKind{}
		ref = map[string][2]int{}
		hostSeen := map[string]bool{}
		for di, d := range devs {
			h := d.Host
			if h == "" {
				h = "local"
			}
			hu := "h:" + h
			if !hostSeen[h] {
				hostSeen[h] = true
				kids[""] = append(kids[""], hu)
				kind[hu] = nHost
				ref[hu] = [2]int{di, -1}
			}
			if d.Err != "" || d.Name == "" {
				continue // unreachable or no-WireGuard marker: host row only
			}
			iu := fmt.Sprintf("i:%d", di)
			kids[hu] = append(kids[hu], iu)
			kind[iu] = nIface
			ref[iu] = [2]int{di, -1}
			for pi := range d.Peers {
				pu := fmt.Sprintf("p:%d:%d", di, pi)
				kids[iu] = append(kids[iu], pu)
				kind[pu] = nPeer
				ref[pu] = [2]int{di, pi}
			}
		}
	}

	// ── tree: every row is dot + name + detail + alarm badge ─────────────
	tree := widget.NewTree(
		func(uid widget.TreeNodeID) []widget.TreeNodeID { return kids[uid] },
		func(uid widget.TreeNodeID) bool { return len(kids[uid]) > 0 },
		func(branch bool) fyne.CanvasObject {
			return container.NewHBox(
				dot(palDim),
				txt("node", palFg, 13, fyne.TextStyle{}),
				txt("", palDim, 12, fyne.TextStyle{}),
				txt("", palAlarm, 12, fyne.TextStyle{Bold: true}),
			)
		},
		func(uid widget.TreeNodeID, branch bool, o fyne.CanvasObject) {
			box := o.(*fyne.Container)
			mark := box.Objects[0].(*fyne.Container).Objects[0].(*fyne.Container).Objects[0].(*canvas.Circle)
			name := box.Objects[1].(*canvas.Text)
			det := box.Objects[2].(*canvas.Text)
			badge := box.Objects[3].(*canvas.Text)
			badge.Text = ""
			r, ok := ref[uid]
			if !ok {
				name.Text = uid
				name.Refresh()
				return
			}
			d := devs[r[0]]
			switch kind[uid] {
			case nHost:
				// The host is KNOWN by its name (fqdn); the ssh target is
				// the detail. Sorting uses the same key, so rows read in
				// the order they appear to be named.
				name.Text = HostDisplay(d)
				name.Color = palBrand
				name.TextStyle = fyne.TextStyle{Bold: true}
				switch {
				case d.Err != "":
					mark.FillColor = palStale
					det.Text = strings.TrimSpace(hostTarget(d) + " · unreachable")
					det.Color = palStale
				case d.Name == "":
					mark.FillColor = palDim
					det.Text = strings.TrimSpace(hostTarget(d) + " · no WireGuard")
					det.Color = palDim
				default:
					mark.FillColor = palBrand
					det.Text = hostTarget(d)
					det.Color = palDim
				}
			case nIface:
				name.Text = d.Name
				name.Color = palFg
				name.TextStyle = fyne.TextStyle{Bold: true}
				mark.FillColor = ifaceMark(d)
				det.Text = fmt.Sprintf("%s · %d peers", ifaceAddr(d), len(d.Peers))
				det.Color = palDim
			case nPeer:
				p := d.Peers[r[1]]
				mark.FillColor = healthColor(p.Health())
				key := p.PublicKey
				if len(key) > 12 {
					key = key[:12] + "…"
				}
				if p.Label != "" {
					key = p.Label // declared peers show as network/member
				}
				name.Text = key
				name.Color = palFg
				name.TextStyle = fyne.TextStyle{Monospace: true}
				det.Text = firstIP(p.AllowedIPs) + " · " + p.Age()
				det.Color = palDim
				if !p.Declared && d.Managed {
					badge.Text = "⚠"
				}
			}
			mark.Refresh()
			name.Refresh()
			det.Refresh()
			badge.Refresh()
		},
	)

	setDossier := func(objs ...fyne.CanvasObject) {
		dossier.Objects = objs
		dossier.Refresh()
	}

	tree.OnSelected = func(uid widget.TreeNodeID) {
		r, ok := ref[uid]
		if !ok {
			return
		}
		d := devs[r[0]]
		switch kind[uid] {
		case nPeer:
			setDossier(guiPeerDossier(d, d.Peers[r[1]])...)
		case nHost:
			setDossier(guiHostDossier(devs, d.Host)...)
		default:
			setDossier(guiDeviceDossier(d)...)
		}
	}

	// ── interface cards — the zpool-bar analogue, one card per interface ─
	rebuildCards := func() {
		cards.Objects = nil
		for _, d := range devs {
			if d.Err != "" {
				cards.Objects = append(cards.Objects, card(container.NewHBox(
					dot(palStale),
					txt(HostDisplay(d), palFg, 13, fyne.TextStyle{Bold: true}),
					txt("unreachable: "+d.Err, palStale, 12, fyne.TextStyle{}),
				)))
				continue
			}
			// No-WireGuard marker: a card row too, but dim and honest — the
			// first cut fell through to the interface template and painted a
			// GREEN "host:" card with 0 peers for hosts that have no
			// interface at all (goldens on .119, 2026-08-03).
			if d.Name == "" {
				cards.Objects = append(cards.Objects, card(container.NewHBox(
					dot(palDim),
					txt(HostDisplay(d), palDim, 13, fyne.TextStyle{Bold: true}),
					txt("no WireGuard interfaces", palDim, 12, fyne.TextStyle{Italic: true}),
				)))
				continue
			}
			var alive, undecl int
			var rx, tx int64
			for _, p := range d.Peers {
				if p.Health() == "alive" {
					alive++
				}
				if d.Managed && !p.Declared {
					undecl++
				}
				rx += p.RxBytes
				tx += p.TxBytes
			}
			name := d.Name
			if d.Host != "" {
				name = HostDisplay(d) + ":" + d.Name
			}
			aliveCol := palAlive
			if alive == 0 {
				aliveCol = palDim
			}
			row := container.NewHBox(
				dot(ifaceMark(d)),
				txt(name, palFg, 13, fyne.TextStyle{Bold: true}),
				txt(ifaceAddr(d), palBrand, 12, fyne.TextStyle{Monospace: true}),
				layout.NewSpacer(),
				txt(fmt.Sprintf("%d peers", len(d.Peers)), palDim, 12, fyne.TextStyle{}),
				txt(fmt.Sprintf("%d alive", alive), aliveCol, 12, fyne.TextStyle{Bold: true}),
				txt("port "+orDash(d.ListenPort), palDim, 12, fyne.TextStyle{Monospace: true}),
				txt("rx "+human(rx)+" · tx "+human(tx), palDim, 12, fyne.TextStyle{Monospace: true}),
			)
			if undecl > 0 {
				row.Add(txt(fmt.Sprintf("⚠ %d undeclared", undecl), palAlarm, 12,
					fyne.TextStyle{Bold: true}))
			}
			cards.Objects = append(cards.Objects, card(row))
		}
		if len(cards.Objects) == 0 {
			cards.Objects = []fyne.CanvasObject{card(
				txt("no WireGuard interfaces found", palDim, 13, fyne.TextStyle{Italic: true}))}
		}
		cards.Refresh()
	}

	rebuildChips := func() {
		h, i, p, alive, undeclared := Totals(devs)
		chips.Objects = []fyne.CanvasObject{
			chip(fmt.Sprint(h), "hosts", palFg),
			chip(fmt.Sprint(i), "interfaces", palFg),
			chip(fmt.Sprint(p), "peers", palFg),
			chip(fmt.Sprint(alive), "alive", palAlive),
		}
		if undeclared > 0 {
			chips.Objects = append(chips.Objects,
				chip(fmt.Sprint(undeclared), "UNDECLARED", palAlarm))
		}
		chips.Refresh()
	}

	reload := func() {
		status.Text = "scanning estate…"
		status.Refresh()
		go func() {
			// Re-read the inventory EVERY scan — hosts added to
			// ~/.config/wgx/hosts (or ssh config) while the console is
			// open must appear on the next Refresh, not after an app
			// restart (operator hit exactly that on .119, 2026-08-03).
			d := CollectEstate(sshHosts())
			Analyse(d)
			fyne.Do(func() {
				devs = d
				reindex()
				rebuildChips()
				rebuildCards()
				status.Text = fmt.Sprintf("scanned %s", time.Now().Format("15:04:05"))
				status.Refresh()
				tree.Refresh()
				// Open the hosts ONCE, on the first scan that returns
				// anything. Doing it on every scan fought the operator:
				// collapse a branch and the next tick reopened it, which
				// made "Collapse all" look broken when it had worked
				// perfectly for two seconds.
				if !didOpenHosts && len(kids[""]) > 0 {
					didOpenHosts = true
					for _, hu := range kids[""] {
						tree.OpenBranch(hu)
					}
				}
			})
		}()
	}

	refresh := widget.NewButtonWithIcon("Refresh", theme.ViewRefreshIcon(), reload)
	refresh.Importance = widget.HighImportance
	// One button, both directions — a separate "collapse all" would sit
	// there greyed out half the time, and the operator already knows which
	// state the tree is in by looking at it.
	var expand *widget.Button
	expanded := false
	setExpandLabel := func() {
		if expanded {
			expand.SetText("Collapse all")
			expand.SetIcon(theme.MenuDropUpIcon())
			return
		}
		expand.SetText("Expand all")
		expand.SetIcon(theme.MenuDropDownIcon())
	}
	expand = widget.NewButtonWithIcon("Expand all", theme.MenuDropDownIcon(), func() {
		expanded = !expanded
		for uid := range kids {
			if expanded {
				tree.OpenBranch(uid)
			} else {
				tree.CloseBranch(uid)
			}
		}
		setExpandLabel()
	})

	// ── manual: the embedded wgx(1), full window, "?" or the button ──────
	// The console ships its own documentation so a static binary on a
	// stranger's box is never undocumented (zxplore does the same).
	var showEstate, showManual func()
	manualBtn := widget.NewButtonWithIcon("Manual", theme.HelpIcon(), func() { showManual() })

	brand := container.NewHBox(
		txt("wgxplore", palBrand, 20, fyne.TextStyle{Bold: true}),
		txt(versionFull(), palDim, 12, fyne.TextStyle{Monospace: true}),
		txt("·", palLine, 12, fyne.TextStyle{}),
		status,
	)
	head := container.NewBorder(nil, nil, brand,
		container.NewHBox(chips, expand, manualBtn, refresh))
	top := container.NewVBox(container.NewPadded(head), cards, widget.NewSeparator())

	split := container.NewHSplit(
		gap(cardTight(tree)),
		gap(card(container.NewVScroll(dossier))))
	split.Offset = 0.42
	estateView := container.NewBorder(top, nil, nil, nil, split)

	// ── manual page: the family front page, zxplore's exactly ────────────
	//
	// Same shape as zxplore's and vmxplore's so the three read as one
	// product: a full-window page on the base colour, a centred mark with
	// the wordmark stacked beside it, the manual body centred so the
	// fixed-width page floats mid-window instead of hugging the left edge,
	// and a footer that credits the substrate and closes the page.
	// Only the icon and the accent belong to this console.
	pageColor := func() color.Color { return palBg }
	pageBG := canvas.NewRectangle(pageColor())
	repaintCards = append(repaintCards, func() {
		pageBG.FillColor = pageColor()
		pageBG.Refresh()
	})

	pageLogo := canvas.NewImageFromResource(
		fyne.NewStaticResource("wgxplore.svg", iconSVG))
	pageLogo.FillMode = canvas.ImageFillContain
	pageLogo.SetMinSize(fyne.NewSize(96, 96))
	pageTitle := txt("w g x p l o r e", palBrand, 26, fyne.TextStyle{Bold: true})
	pageSub := txt("the WireGuard estate console — wgx(1)", palCyan, 13,
		fyne.TextStyle{})
	pageVer := txt("v"+versionFull(), palAmber, 12, fyne.TextStyle{})
	pageHead := container.NewCenter(container.NewHBox(
		pageLogo, container.NewVBox(pageTitle, pageSub, pageVer)))

	manualBody := widget.NewRichText(manualSegments(renderManual())...)
	manualBody.Wrapping = fyne.TextWrapOff
	manScroll := container.NewScroll(container.NewCenter(manualBody))

	siteU, _ := url.Parse("https://kldload.com")
	powered := widget.NewHyperlink("powered by kldload.com", siteU)
	backBtn := widget.NewButtonWithIcon("Close  ⏎", theme.ConfirmIcon(),
		func() { showEstate() })
	backBtn.Importance = widget.HighImportance
	manualFooter := container.NewBorder(nil, nil, powered, backBtn, nil)

	manualView := container.NewStack(pageBG, container.NewBorder(
		container.NewPadded(pageHead), container.NewPadded(manualFooter),
		nil, nil, manScroll))

	showEstate = func() { manualOpen = false; w.SetContent(estateView) }
	showManual = func() { manualOpen = true; w.SetContent(manualView) }
	showEstate()

	// "?" opens the manual from anywhere; Esc leaves it.
	w.Canvas().SetOnTypedRune(func(r rune) {
		if r == '?' {
			showManual()
		}
	})
	// A container.Scroll answers the wheel and nothing else, so a long
	// manual could only be read by dragging. The page drives its own
	// offset: 0.9 of a screen per page leaves two lines of overlap, which
	// is what stops a reader losing their place across a jump.
	manScrollBy := func(frac float32) {
		max := manScroll.Content.MinSize().Height - manScroll.Size().Height
		if max < 0 {
			max = 0
		}
		o := manScroll.Offset
		o.Y += manScroll.Size().Height * frac
		if o.Y < 0 {
			o.Y = 0
		}
		if o.Y > max {
			o.Y = max
		}
		manScroll.Offset = o
		manScroll.Refresh()
	}
	w.Canvas().SetOnTypedKey(func(k *fyne.KeyEvent) {
		if !manualOpen {
			return
		}
		switch k.Name {
		case fyne.KeyPageDown, fyne.KeySpace:
			manScrollBy(0.9)
		case fyne.KeyPageUp:
			manScrollBy(-0.9)
		case fyne.KeyDown:
			manScrollBy(0.1)
		case fyne.KeyUp:
			manScrollBy(-0.1)
		case fyne.KeyHome:
			manScroll.ScrollToTop()
		case fyne.KeyEnd:
			manScroll.ScrollToBottom()
		case fyne.KeyEscape, fyne.KeyReturn, fyne.KeyEnter:
			showEstate()
		}
	})

	setDossier(
		txt("estate", palBrand, 16, fyne.TextStyle{Bold: true}),
		txt("select a host, interface or peer", palDim, 13, fyne.TextStyle{Italic: true}),
	)

	// Follow the WM/OS light-dark preference LIVE: when the variant flips,
	// swap the active palette and rebuild everything colour-carrying —
	// widget chrome re-themes itself via wgxTheme.Color(variant).
	lastVariant := a.Settings().ThemeVariant()
	a.Settings().AddListener(func(s fyne.Settings) {
		v := s.ThemeVariant()
		if v == lastVariant {
			return
		}
		lastVariant = v
		fyne.Do(func() {
			setPalette(v)
			// Repaint from the data already in memory — NO rescan. The
			// first cut called reload() here, so the cards kept the old
			// palette for the 2-3s the ssh sweep took (seen .119): colour
			// changes must be instant, data refreshes have their own tick.
			rebuildChips()
			rebuildCards()
			// the rounded panels hold their own fill colour, so they have
			// to be told the variant changed as well
			for _, f := range repaintCards {
				f()
			}
			tree.Refresh()
			setDossier(
				txt("estate", palBrand, 16, fyne.TextStyle{Bold: true}),
				txt("select a host, interface or peer", palDim, 13, fyne.TextStyle{Italic: true}),
			)
		})
	})

	reload()
	go func() {
		for range time.Tick(30 * time.Second) {
			fyne.Do(reload)
		}
	}()

	w.ShowAndRun()
	return nil
}

// ─── dossiers — structured panels, not markdown ──────────────────────────
// Each dossier is a title, a key/value block, and a coloured verdict card:
// green wash = declared/healthy, pink wash = the undeclared alarm, red =
// unreachable. The verdict carries the "so what", the kv block the facts.

func verdict(c color.NRGBA, lines ...string) fyne.CanvasObject {
	bg := canvas.NewRectangle(color.NRGBA{c.R, c.G, c.B, 0x22})
	bg.CornerRadius = 8
	var objs []fyne.CanvasObject
	for i, l := range lines {
		st := fyne.TextStyle{}
		col := palFg
		if i == 0 {
			st = fyne.TextStyle{Bold: true}
			col = c
		}
		objs = append(objs, txt(l, col, 13, st))
	}
	return container.NewStack(bg, container.NewPadded(container.NewVBox(objs...)))
}

func guiHostDossier(devs []Device, host string) []fyne.CanvasObject {
	var ifaces, peers, alive, undecl int
	for _, d := range devs {
		if d.Host != host {
			continue
		}
		if d.Err != "" {
			return []fyne.CanvasObject{
				txt("host "+hostLabel(host), palBrand, 16, fyne.TextStyle{Bold: true}),
				verdict(palStale, "UNREACHABLE", d.Err),
			}
		}
		ifaces++
		for _, p := range d.Peers {
			peers++
			if p.Health() == "alive" {
				alive++
			}
			if !p.Declared {
				undecl++
			}
		}
	}
	rows := [][2]string{}
	for _, d := range devs {
		if d.Host == host && d.HostFQDN != "" {
			rows = append(rows, [2]string{"fqdn", d.HostFQDN})
			if d.HostAddr != "" {
				rows = append(rows, [2]string{"reached at", d.HostAddr})
			}
			break
		}
	}
	rows = append(rows,
		[2]string{"interfaces", fmt.Sprint(ifaces)},
		[2]string{"peers", fmt.Sprint(peers)},
		[2]string{"handshaking", fmt.Sprint(alive)},
	)
	objs := []fyne.CanvasObject{
		txt("host "+hostLabel(host), palBrand, 16, fyne.TextStyle{Bold: true}),
		kv(rows...),
	}
	if undecl > 0 {
		objs = append(objs, verdict(palAlarm,
			fmt.Sprintf("⚠ %d peer(s) not in any declaration", undecl),
			"Someone with root added them. Investigate."))
	}
	return objs
}

func guiDeviceDossier(d Device) []fyne.CanvasObject {
	if d.Err != "" {
		return []fyne.CanvasObject{
			txt(hostLabel(d.Host), palBrand, 16, fyne.TextStyle{Bold: true}),
			verdict(palStale, "UNREACHABLE", d.Err),
		}
	}
	var alive, undeclared int
	for _, p := range d.Peers {
		if p.Health() == "alive" {
			alive++
		}
		if d.Managed && !p.Declared {
			undeclared++
		}
	}
	objs := []fyne.CanvasObject{
		txt("interface "+d.Name, palBrand, 16, fyne.TextStyle{Bold: true}),
		kv(
			[2]string{"host", hostLabel(d.Host)},
			[2]string{"address", orDash(d.Addr)},
			[2]string{"public key", d.PublicKey},
			[2]string{"listen port", orDash(d.ListenPort)},
			[2]string{"peers", fmt.Sprintf("%d (%d handshaking)", len(d.Peers), alive)},
			[2]string{"routes", ifaceSubnet(d)},
		),
	}
	switch {
	case !d.Managed:
		objs = append(objs, verdict(palDim,
			"untracked — not managed by any wgxplore declaration",
			"Peers here are shown for inventory, not judged."))
	case undeclared > 0:
		objs = append(objs, verdict(palAlarm,
			fmt.Sprintf("⚠ %d peer(s) not in any declaration", undeclared),
			"Someone with root added them. Investigate."))
	case len(d.Peers) > 0:
		objs = append(objs, verdict(palAlive, "✓ all peers declared"))
	}
	return objs
}

func guiPeerDossier(d Device, p Peer) []fyne.CanvasObject {
	h := p.Health()
	objs := []fyne.CanvasObject{
		container.NewHBox(
			dot(healthColor(h)),
			txt("peer", palBrand, 16, fyne.TextStyle{Bold: true}),
			txt(h+" · "+p.Age(), healthColor(h), 13, fyne.TextStyle{Bold: true}),
		),
		kv(func() [][2]string {
			rows := [][2]string{}
			if p.Label != "" {
				rows = append(rows, [2]string{"declared as", p.Label})
			}
			return append(rows,
				[2]string{"public key", p.PublicKey},
				[2]string{"on", hostLabel(d.Host) + " · " + d.Name},
				[2]string{"endpoint", orDash(p.Endpoint)},
				[2]string{"allowed-ips", p.AllowedIPs},
				[2]string{"traffic", "rx " + human(p.RxBytes) + " · tx " + human(p.TxBytes)},
				[2]string{"keepalive", orDash(p.Keepalive)},
			)
		}()...),
	}
	switch {
	case p.Declared:
		objs = append(objs, verdict(palAlive,
			"✓ declared — this peer is in a wgxplore network"))
	case !d.Managed:
		objs = append(objs, verdict(palDim,
			"untracked — "+d.Name+" is not managed by any declaration",
			"Declare this network to arm the undeclared-peer alarm."))
	default:
		objs = append(objs, verdict(palAlarm,
			"⚠ UNDECLARED — no declaration lists this key",
			"A peer cannot appear by accident: cryptokey routing",
			"means someone with root on "+d.Name+" added it. Investigate."))
	}
	return objs
}

// hostTarget renders the "how we reach it" detail for a host row: the ssh
// target (when it differs from the display name) plus the underlay IP.
func hostTarget(d Device) string {
	var parts []string
	if t := hostLabel(d.Host); t != HostDisplay(d) {
		parts = append(parts, t)
	}
	if d.HostAddr != "" {
		parts = append(parts, d.HostAddr)
	}
	return strings.Join(parts, " · ")
}

// ifaceMark is THE health colour of an interface, shared by the overview
// cards and the tree so one interface never wears two colours: dim when it
// has no peers at all (inert, not healthy), quiet when peers exist but none
// handshake, alive otherwise.
func ifaceMark(d Device) color.NRGBA {
	if len(d.Peers) == 0 {
		return palDim
	}
	alive := 0
	for _, p := range d.Peers {
		if p.Health() == "alive" {
			alive++
		}
	}
	if alive == 0 {
		return palQuiet
	}
	return palAlive
}

// ifaceAddr prefers the interface's OWN address (what you point things at);
// hosts we could not read addresses from fall back to the subnet guess.
func ifaceAddr(d Device) string {
	if d.Addr != "" {
		return d.Addr
	}
	return ifaceSubnet(d)
}

// ifaceSubnet summarises what an interface routes, e.g. "10.250.0.0/24",
// so a branch reads like a network rather than a device name.
func ifaceSubnet(d Device) string {
	seen := map[string]bool{}
	var nets []string
	for _, p := range d.Peers {
		for _, cidr := range strings.Split(p.AllowedIPs, ",") {
			cidr = strings.TrimSpace(cidr)
			if cidr == "" {
				continue
			}
			ip := strings.Split(cidr, "/")[0]
			parts := strings.Split(ip, ".")
			if len(parts) != 4 {
				continue
			}
			n := fmt.Sprintf("%s.%s.%s.0/24", parts[0], parts[1], parts[2])
			if !seen[n] {
				seen[n] = true
				nets = append(nets, n)
			}
		}
	}
	if len(nets) == 0 {
		return "—"
	}
	if len(nets) > 2 {
		return strings.Join(nets[:2], " ") + fmt.Sprintf(" +%d", len(nets)-2)
	}
	return strings.Join(nets, " ")
}

func firstIP(allowed string) string {
	f := strings.Split(allowed, ",")[0]
	return strings.TrimSpace(f)
}

// manualSegments colours the rendered manual for RichText: section headers in
// brand teal and bold, body in the foreground colour, everything monospace so
// the man(1) indentation survives.
// manualSegments colours the rendered manual for RichText, in zxplore's
// exact shape.
//
// WARN: the segments must be Inline with a SEPARATE newline segment. A
// non-inline segment is a PARAGRAPH block, and RichText puts paragraph
// spacing between blocks — one block per line doubled the leading and made
// the same manual read half as dense as zxplore's beside it.
func manualSegments(text string) []widget.RichTextSegment {
	mono := fyne.TextStyle{Monospace: true}
	seg := func(s string, cn fyne.ThemeColorName, bold bool) *widget.TextSegment {
		st := mono
		st.Bold = bold
		return &widget.TextSegment{Text: s, Style: widget.RichTextStyle{
			Inline: true, TextStyle: st, ColorName: cn}}
	}
	var out []widget.RichTextSegment
	for _, line := range strings.Split(text, "\n") {
		if line != "" && manHeadRE.MatchString(strings.TrimRight(line, " ")) {
			out = append(out, seg(line, theme.ColorNamePrimary, true))
		} else {
			out = append(out, seg(line, theme.ColorNameForeground, false))
		}
		out = append(out, seg("\n", theme.ColorNameForeground, false))
	}
	return out
}
