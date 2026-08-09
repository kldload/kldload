//go:build gui

// vnc.go — a minimal RFB (VNC) client + Fyne viewer widget: the Screen
// console pane.
//
// What it does, in order:
//  1. vncPort: reads the running domain's XML for its VNC server port.
//  2. dialRFB: TCP to 127.0.0.1:<port>, RFB 3.8 handshake (security None —
//     qemu's local default), forces a 32bpp truecolour pixel format, asks
//     for Raw + DesktopSize encodings, then streams framebuffer updates
//     into an image.RGBA.
//  3. vncViewer: a focusable widget that draws the framebuffer
//     (letterboxed) and forwards pointer/keyboard as RFB events.
//
// Why hand-rolled: no maintained Fyne VNC widget exists, and the peer here
// is ALWAYS qemu over loopback — Raw encoding is free of bandwidth concern
// and the auth surface is None — so a general-purpose client would be all
// dead weight. The webui reaches the same VNC server through
// websockify+noVNC; this is the native path, no bridge.
//
// Notes: writes are mutex-serialised (input events race the update-request
// loop otherwise). DesktopSize reallocates the framebuffer mid-stream —
// guests resize at boot. A read error just closes the loop; the pane shows
// whatever rendered last until the selection moves.
package main

import (
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"image"
	"io"
	"net"
	"sync"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/widget"
)

// vncPort parses the domain's live XML for the VNC graphics port. Autoport
// domains only carry a real port while running (-1 otherwise).
func vncPort(lv *LV, name string) (int, error) {
	x, err := lv.XML(name)
	if err != nil {
		return 0, err
	}
	var d struct {
		Graphics []struct {
			Type string `xml:"type,attr"`
			Port int    `xml:"port,attr"`
		} `xml:"devices>graphics"`
	}
	if err := xml.Unmarshal([]byte(x), &d); err != nil {
		return 0, err
	}
	for _, g := range d.Graphics {
		if g.Type == "vnc" && g.Port > 0 {
			return g.Port, nil
		}
	}
	return 0, fmt.Errorf("%s has no live VNC display", name)
}

// ── the RFB connection ──────────────────────────────────────────────────────

type rfbConn struct {
	c         net.Conn
	mu        sync.Mutex // serialises all writes
	fbW       int
	fbH       int
	imgMu     sync.Mutex // guards img swap on DesktopSize
	img       *image.RGBA
	onFrame   func()            // fired after each complete FramebufferUpdate
	onCutText func(text string) // guest clipboard arrived (ServerCutText)
	err       error
	done      chan struct{}
}

const rfbVersion = "RFB 003.008\n"

// dialRFB connects and completes the handshake through the first update
// request; the read loop then runs until error or Close.
func dialRFB(addr string) (*rfbConn, error) {
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return nil, err
	}
	r := &rfbConn{c: c, done: make(chan struct{})}
	if err := r.handshake(); err != nil {
		c.Close()
		return nil, err
	}
	go r.readLoop()
	r.requestUpdate(false)
	return r, nil
}

func (r *rfbConn) handshake() error {
	buf := make([]byte, 12)
	if _, err := io.ReadFull(r.c, buf); err != nil {
		return fmt.Errorf("version: %w", err)
	}
	if _, err := r.c.Write([]byte(rfbVersion)); err != nil {
		return err
	}
	// security: qemu offers None locally; anything else is out of scope
	var n [1]byte
	if _, err := io.ReadFull(r.c, n[:]); err != nil {
		return fmt.Errorf("security count: %w", err)
	}
	if n[0] == 0 {
		return fmt.Errorf("server refused: %s", r.readReason())
	}
	types := make([]byte, n[0])
	if _, err := io.ReadFull(r.c, types); err != nil {
		return err
	}
	hasNone := false
	for _, t := range types {
		if t == 1 {
			hasNone = true
		}
	}
	if !hasNone {
		return fmt.Errorf("VNC server requires auth (types %v) — only None is supported", types)
	}
	if _, err := r.c.Write([]byte{1}); err != nil {
		return err
	}
	var res [4]byte
	if _, err := io.ReadFull(r.c, res[:]); err != nil {
		return err
	}
	if binary.BigEndian.Uint32(res[:]) != 0 {
		return fmt.Errorf("VNC auth failed: %s", r.readReason())
	}
	if _, err := r.c.Write([]byte{1}); err != nil { // ClientInit: shared
		return err
	}
	init := make([]byte, 24)
	if _, err := io.ReadFull(r.c, init); err != nil {
		return fmt.Errorf("server init: %w", err)
	}
	r.fbW = int(binary.BigEndian.Uint16(init[0:2]))
	r.fbH = int(binary.BigEndian.Uint16(init[2:4]))
	nameLen := binary.BigEndian.Uint32(init[20:24])
	if _, err := io.CopyN(io.Discard, r.c, int64(nameLen)); err != nil {
		return err
	}
	r.img = image.NewRGBA(image.Rect(0, 0, r.fbW, r.fbH))

	// SetPixelFormat: 32bpp truecolour BGRX little-endian — one fixed
	// format so the blit below never branches
	pf := []byte{0, 0, 0, 0, // type + pad
		32, 24, 0, 1, // bpp, depth, big-endian, true-colour
		0, 255, 0, 255, 0, 255, // r/g/b max
		16, 8, 0, // r/g/b shift
		0, 0, 0} // pad
	if _, err := r.c.Write(pf); err != nil {
		return err
	}
	// SetEncodings: Raw + DesktopSize (pseudo) — loopback needs nothing more
	enc := []byte{2, 0, 0, 2,
		0, 0, 0, 0, // Raw
		0xff, 0xff, 0xff, 0x21} // -223 DesktopSize
	_, err := r.c.Write(enc)
	return err
}

// readReason drains an RFB failure-reason string (best effort, for errors).
func (r *rfbConn) readReason() string {
	var l [4]byte
	if _, err := io.ReadFull(r.c, l[:]); err != nil {
		return "unknown"
	}
	n := binary.BigEndian.Uint32(l[:])
	if n > 4096 {
		return "unknown"
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r.c, b); err != nil {
		return "unknown"
	}
	return string(b)
}

func (r *rfbConn) requestUpdate(incremental bool) {
	inc := byte(0)
	if incremental {
		inc = 1
	}
	msg := make([]byte, 10)
	msg[0] = 3
	msg[1] = inc
	binary.BigEndian.PutUint16(msg[6:8], uint16(r.fbW))
	binary.BigEndian.PutUint16(msg[8:10], uint16(r.fbH))
	r.mu.Lock()
	_, _ = r.c.Write(msg)
	r.mu.Unlock()
}

func (r *rfbConn) readLoop() {
	defer close(r.done)
	hdr := make([]byte, 4)
	rect := make([]byte, 12)
	for {
		if _, err := io.ReadFull(r.c, hdr[:1]); err != nil {
			r.err = err
			return
		}
		switch hdr[0] {
		case 0: // FramebufferUpdate
			if _, err := io.ReadFull(r.c, hdr[1:4]); err != nil {
				r.err = err
				return
			}
			rects := int(binary.BigEndian.Uint16(hdr[2:4]))
			for i := 0; i < rects; i++ {
				if _, err := io.ReadFull(r.c, rect); err != nil {
					r.err = err
					return
				}
				x := int(binary.BigEndian.Uint16(rect[0:2]))
				y := int(binary.BigEndian.Uint16(rect[2:4]))
				rw := int(binary.BigEndian.Uint16(rect[4:6]))
				rh := int(binary.BigEndian.Uint16(rect[6:8]))
				enc := int32(binary.BigEndian.Uint32(rect[8:12]))
				switch enc {
				case 0: // Raw BGRX
					if err := r.blitRaw(x, y, rw, rh); err != nil {
						r.err = err
						return
					}
				case -223: // DesktopSize: guest resized its framebuffer
					r.imgMu.Lock()
					r.fbW, r.fbH = rw, rh
					r.img = image.NewRGBA(image.Rect(0, 0, rw, rh))
					r.imgMu.Unlock()
				default:
					r.err = fmt.Errorf("unrequested encoding %d", enc)
					return
				}
			}
			if r.onFrame != nil {
				r.onFrame()
			}
			r.requestUpdate(true)
		case 1: // SetColourMapEntries — can't happen in truecolour; drain
			var h [5]byte
			if _, err := io.ReadFull(r.c, h[:]); err != nil {
				r.err = err
				return
			}
			n := int64(binary.BigEndian.Uint16(h[3:5]))
			if _, err := io.CopyN(io.Discard, r.c, n*6); err != nil {
				r.err = err
				return
			}
		case 2: // Bell — ignore
		case 3: // ServerCutText — the guest's clipboard, forwarded up
			var h [7]byte
			if _, err := io.ReadFull(r.c, h[:]); err != nil {
				r.err = err
				return
			}
			n := int64(binary.BigEndian.Uint32(h[3:7]))
			if n > 1<<20 { // a clipboard, not a firehose
				if _, err := io.CopyN(io.Discard, r.c, n); err != nil {
					r.err = err
					return
				}
				continue
			}
			b := make([]byte, n)
			if _, err := io.ReadFull(r.c, b); err != nil {
				r.err = err
				return
			}
			if r.onCutText != nil {
				r.onCutText(string(b)) // RFB cut text is latin-1; close enough
			}
		default:
			r.err = fmt.Errorf("unknown server message %d", hdr[0])
			return
		}
	}
}

// blitRaw copies one Raw rectangle (BGRX) into the RGBA framebuffer.
func (r *rfbConn) blitRaw(x, y, w, h int) error {
	row := make([]byte, w*4)
	r.imgMu.Lock()
	img := r.img
	r.imgMu.Unlock()
	for j := 0; j < h; j++ {
		if _, err := io.ReadFull(r.c, row); err != nil {
			return err
		}
		if y+j >= img.Bounds().Dy() {
			continue // rect from a stale size — drain but don't write
		}
		off := img.PixOffset(x, y+j)
		for i := 0; i < w && x+i < img.Bounds().Dx(); i++ {
			img.Pix[off+i*4+0] = row[i*4+2] // R ← B position swap
			img.Pix[off+i*4+1] = row[i*4+1]
			img.Pix[off+i*4+2] = row[i*4+0]
			img.Pix[off+i*4+3] = 0xff
		}
	}
	return nil
}

func (r *rfbConn) pointer(mask uint8, x, y int) {
	msg := []byte{5, mask, 0, 0, 0, 0}
	binary.BigEndian.PutUint16(msg[2:4], uint16(x))
	binary.BigEndian.PutUint16(msg[4:6], uint16(y))
	r.mu.Lock()
	_, _ = r.c.Write(msg)
	r.mu.Unlock()
}

func (r *rfbConn) key(sym uint32, down bool) {
	d := byte(0)
	if down {
		d = 1
	}
	msg := []byte{4, d, 0, 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(msg[4:8], sym)
	r.mu.Lock()
	_, _ = r.c.Write(msg)
	r.mu.Unlock()
}

// cutText hands text to the server's clipboard buffer (ClientCutText) —
// guests with clipboard integration (qemu-vdagent) pick it up.
func (r *rfbConn) cutText(s string) {
	b := []byte(s)
	msg := make([]byte, 8, 8+len(b))
	msg[0] = 6
	binary.BigEndian.PutUint32(msg[4:8], uint32(len(b)))
	msg = append(msg, b...)
	r.mu.Lock()
	_, _ = r.c.Write(msg)
	r.mu.Unlock()
}

func (r *rfbConn) Close() { r.c.Close() }

// ── the viewer widget ───────────────────────────────────────────────────────

// vncViewer draws the framebuffer letterboxed and forwards input. Click to
// focus (keys flow to the guest until focus moves).
type vncViewer struct {
	widget.BaseWidget
	conn *rfbConn
	img  *canvas.Image
	mask uint8
}

func newVNCViewer(conn *rfbConn) *vncViewer {
	v := &vncViewer{conn: conn}
	v.img = canvas.NewImageFromImage(conn.img)
	v.img.FillMode = canvas.ImageFillContain
	v.img.ScaleMode = canvas.ImageScaleFastest
	conn.onFrame = func() {
		fyne.Do(func() {
			conn.imgMu.Lock()
			v.img.Image = conn.img // DesktopSize may have swapped it
			conn.imgMu.Unlock()
			v.img.Refresh()
		})
	}
	v.ExtendBaseWidget(v)
	return v
}

func (v *vncViewer) CreateRenderer() fyne.WidgetRenderer {
	return widget.NewSimpleRenderer(v.img)
}

func (v *vncViewer) MinSize() fyne.Size { return fyne.NewSize(320, 240) }

// fbCoords maps a widget position onto framebuffer pixels through the
// letterbox (FillContain keeps aspect; the margins must not scroll the
// guest cursor off into the void).
func (v *vncViewer) fbCoords(p fyne.Position) (int, int) {
	sz := v.Size()
	fw, fh := float32(v.conn.fbW), float32(v.conn.fbH)
	if fw == 0 || fh == 0 || sz.Width == 0 || sz.Height == 0 {
		return 0, 0
	}
	scale := sz.Width / fw
	if s := sz.Height / fh; s < scale {
		scale = s
	}
	ox := (sz.Width - fw*scale) / 2
	oy := (sz.Height - fh*scale) / 2
	x := int((p.X - ox) / scale)
	y := int((p.Y - oy) / scale)
	x = max(0, min(x, v.conn.fbW-1))
	y = max(0, min(y, v.conn.fbH-1))
	return x, y
}

func (v *vncViewer) focus() {
	if c := fyne.CurrentApp().Driver().CanvasForObject(v); c != nil {
		c.Focus(v)
	}
}

// Tapped exists so the widget is tappable — focus follows the click; the
// press itself already went through MouseDown.
func (v *vncViewer) Tapped(*fyne.PointEvent) { v.focus() }

func (v *vncViewer) MouseDown(e *desktop.MouseEvent) {
	v.focus()
	v.mask |= mouseBit(e.Button)
	x, y := v.fbCoords(e.Position)
	v.conn.pointer(v.mask, x, y)
}

func (v *vncViewer) MouseUp(e *desktop.MouseEvent) {
	v.mask &^= mouseBit(e.Button)
	x, y := v.fbCoords(e.Position)
	v.conn.pointer(v.mask, x, y)
}

func (v *vncViewer) MouseIn(*desktop.MouseEvent) {}
func (v *vncViewer) MouseOut()                   {}
func (v *vncViewer) MouseMoved(e *desktop.MouseEvent) {
	x, y := v.fbCoords(e.Position)
	v.conn.pointer(v.mask, x, y)
}

// Scrolled sends wheel as RFB buttons 4/5 (press+release), the protocol's
// scroll idiom.
func (v *vncViewer) Scrolled(e *fyne.ScrollEvent) {
	btn := uint8(1 << 3) // wheel up
	if e.Scrolled.DY < 0 {
		btn = 1 << 4
	}
	x, y := v.fbCoords(e.Position)
	v.conn.pointer(v.mask|btn, x, y)
	v.conn.pointer(v.mask, x, y)
}

func mouseBit(b desktop.MouseButton) uint8 {
	switch b {
	case desktop.MouseButtonSecondary:
		return 1 << 2
	case desktop.MouseButtonTertiary:
		return 1 << 1
	}
	return 1 // primary
}

// ── keyboard: Fyne events → X11 keysyms ─────────────────────────────────────
// TypedRune carries characters (down+up pairs), TypedKey the specials,
// KeyDown/KeyUp ONLY the modifiers (sending both TypedRune and KeyDown for
// a letter would double-type it — the fyne-io/terminal split).

// TypedShortcut handles paste (Ctrl+V): the clipboard goes to the guest
// twice over — as RFB cut text (guests with clipboard integration take
// it) and typed as keystrokes (works everywhere, boot consoles included).
func (v *vncViewer) TypedShortcut(s fyne.Shortcut) {
	if p, ok := s.(*fyne.ShortcutPaste); ok {
		v.pasteText(p.Clipboard.Content())
	}
}

// pasteText is the paste itself, split out so a button can reach it as
// well as Ctrl+V. Both routes are always taken: cut text is instant and
// exact for a guest running a clipboard agent, and the typed fallback
// works on everything else — a boot console, a firmware menu, a fresh
// cloud image with no agent installed at all.
func (v *vncViewer) pasteText(text string) {
	if text == "" {
		return
	}
	v.conn.cutText(text)
	go v.typeString(text)
}

// typeString feeds text as paced key events — outrunning a guest's boot
// console drops characters, 3ms per key does not.
func (v *vncViewer) typeString(text string) {
	for _, r := range text {
		sym := uint32(r)
		switch r {
		case '\n', '\r':
			sym = 0xff0d
		case '\t':
			sym = 0xff09
		default:
			if r > 0xff {
				sym = 0x01000000 + uint32(r)
			}
		}
		v.conn.key(sym, true)
		v.conn.key(sym, false)
		time.Sleep(3 * time.Millisecond)
	}
}

func (v *vncViewer) FocusGained() {}
func (v *vncViewer) FocusLost() {
	// release anything held so the guest doesn't see stuck modifiers
	for _, sym := range modSyms {
		v.conn.key(sym, false)
	}
}

func (v *vncViewer) TypedRune(r rune) {
	sym := uint32(r)
	if r > 0xff {
		sym = 0x01000000 + uint32(r) // X11 Unicode keysym plane
	}
	v.conn.key(sym, true)
	v.conn.key(sym, false)
}

func (v *vncViewer) TypedKey(e *fyne.KeyEvent) {
	if _, mod := modKeysyms[e.Name]; mod {
		return // KeyDown/KeyUp own the modifiers
	}
	if sym, ok := specialKeysyms[e.Name]; ok {
		v.conn.key(sym, true)
		v.conn.key(sym, false)
	}
}

func (v *vncViewer) KeyDown(e *fyne.KeyEvent) {
	if sym, ok := modKeysyms[e.Name]; ok {
		v.conn.key(sym, true)
	}
}

func (v *vncViewer) KeyUp(e *fyne.KeyEvent) {
	if sym, ok := modKeysyms[e.Name]; ok {
		v.conn.key(sym, false)
	}
}

var modKeysyms = map[fyne.KeyName]uint32{
	desktop.KeyShiftLeft:    0xffe1,
	desktop.KeyShiftRight:   0xffe2,
	desktop.KeyControlLeft:  0xffe3,
	desktop.KeyControlRight: 0xffe4,
	desktop.KeyAltLeft:      0xffe9,
	desktop.KeyAltRight:     0xffea,
	desktop.KeySuperLeft:    0xffeb,
	desktop.KeySuperRight:   0xffec,
	desktop.KeyCapsLock:     0xffe5,
}

var modSyms = []uint32{0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe9, 0xffea, 0xffeb, 0xffec}

var specialKeysyms = map[fyne.KeyName]uint32{
	fyne.KeyReturn: 0xff0d, fyne.KeyEnter: 0xff8d, fyne.KeyEscape: 0xff1b,
	fyne.KeyTab: 0xff09, fyne.KeyBackspace: 0xff08, fyne.KeyDelete: 0xffff,
	fyne.KeyInsert: 0xff63, fyne.KeyHome: 0xff50, fyne.KeyEnd: 0xff57,
	fyne.KeyPageUp: 0xff55, fyne.KeyPageDown: 0xff56,
	fyne.KeyLeft: 0xff51, fyne.KeyUp: 0xff52, fyne.KeyRight: 0xff53,
	fyne.KeyDown: 0xff54,
	fyne.KeyF1:   0xffbe, fyne.KeyF2: 0xffbf, fyne.KeyF3: 0xffc0,
	fyne.KeyF4: 0xffc1, fyne.KeyF5: 0xffc2, fyne.KeyF6: 0xffc3,
	fyne.KeyF7: 0xffc4, fyne.KeyF8: 0xffc5, fyne.KeyF9: 0xffc6,
	fyne.KeyF10: 0xffc7, fyne.KeyF11: 0xffc8, fyne.KeyF12: 0xffc9,
}
