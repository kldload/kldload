// vnc.go — a minimal RFB (VNC) client: the wire half of the video console.
//
// What it does, in order:
//  1. vncPort: reads the running domain's XML (virsh dumpxml) for its VNC
//     server port. Autoport domains carry a real port only while running.
//  2. dialRFB: TCP to 127.0.0.1:<port>, RFB 3.8 handshake (security None,
//     qemu's local default), forces 32bpp truecolour, asks for Raw +
//     DesktopSize + ExtendedDesktopSize, then streams framebuffer updates
//     into an image.RGBA and publishes a copy after every complete update.
//  3. pointer/key/cutText: input events to the guest, writes serialised.
//
// Why hand-rolled: the peer is ALWAYS qemu over loopback, so Raw encoding
// costs nothing and the auth surface is None; a general client would be
// dead weight. This is vmxplore's vnc.go with the Fyne widget cut away and
// the frame published by copy, so the renderer never reads a framebuffer
// the read loop is still writing (the Fyne version shared it and the race
// detector said so). Two renderers sit on top: screen.go draws the frame in
// terminal cells inside the TUI, and `kld screen` draws it full-screen in
// sixels or half-blocks.
//
// Notes: there is deliberately NO idle read timeout. RFB is demand-driven;
// an idle desktop legitimately sends nothing for minutes, so TCP keepalive
// (set on dial) is what detects a peer that went away without closing.
package main

import (
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"image"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// RFB message types and encodings, named so the wire handling reads as
// protocol rather than as magic numbers.
const (
	msgFramebufferUpdate   = 0 // server → client
	msgSetColourMapEntries = 1
	msgBell                = 2
	msgServerCutText       = 3

	msgSetPixelFormat       = 0 // client → server
	msgSetEncodings         = 2
	msgFramebufferUpdateReq = 3
	msgKeyEvent             = 4
	msgPointerEvent         = 5
	msgClientCutText        = 6
	msgSetDesktopSize       = 251 // please become this size

	encRaw         = 0
	encDesktopSize = -223 // pseudo-encoding: the guest resized
	// encExtendedDesktopSize is the two-way version: the server announces
	// support by sending one such rect, and a client that asked for it may
	// then send SetDesktopSize to drive the guest's resolution. Without it
	// a 1280x720 guest stays 1280x720 however big the terminal is.
	encExtendedDesktopSize = -308

	// handshakeTimeout bounds the whole pre-stream conversation: DialTimeout
	// covers only the TCP connect, and a peer that accepts then stalls would
	// otherwise hang the caller forever.
	handshakeTimeout = 10 * time.Second
	rfbVersion       = "RFB 003.008\n"
)

// vncPort parses the domain's live XML for its VNC port. First vnc display
// wins, as virt-viewer does.
func vncPort(name string) (int, error) {
	x, err := run(15*time.Second, "virsh", "dumpxml", name)
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
	return 0, fmt.Errorf("%s has no live VNC display (is it running?)", name)
}

// rfbConn is one VNC session. The read loop owns img; pub is the published
// copy every consumer reads under pubMu; frames counts published updates so
// a renderer can tell "new frame" from "same frame" without a callback.
type rfbConn struct {
	c       net.Conn
	mu      sync.Mutex // serialises all writes
	img     *image.RGBA
	fbW     int
	fbH     int
	pubMu   sync.Mutex
	pub     *image.RGBA
	frames  atomic.Uint64
	errMu   sync.Mutex
	err     error
	closing bool // Close() was called: later errors are expected
	done    chan struct{}
	scratch []byte // blitRaw's row buffer, reused; only the read loop touches it
	extMu   sync.Mutex
	extOK   bool // server sent an ExtendedDesktopSize rect: it accepts resizes
	screen  uint32
	flags   uint32
	cutMu   sync.Mutex
	cut     string // the guest's last clipboard text (ServerCutText)
}

// dialRFB connects and completes the handshake through the first update
// request; the read loop then runs until an error or Close.
func dialRFB(addr string) (*rfbConn, error) {
	// keepalive, not a read deadline: see the banner. 30s idle / 10s
	// probes / 3 failures ends a dead peer in about a minute.
	d := &net.Dialer{
		Timeout: 3 * time.Second,
		KeepAliveConfig: net.KeepAliveConfig{
			Enable: true, Idle: 30 * time.Second, Interval: 10 * time.Second, Count: 3,
		},
	}
	c, err := d.Dial("tcp", addr)
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
	if err := r.c.SetDeadline(time.Now().Add(handshakeTimeout)); err != nil {
		return err
	}
	// error ignored: clearing the deadline fails only on a dead connection,
	// which the read loop reports on its first read
	defer func() { _ = r.c.SetDeadline(time.Time{}) }()
	buf := make([]byte, 12)
	if _, err := io.ReadFull(r.c, buf); err != nil {
		return fmt.Errorf("version: %w", err)
	}
	if _, err := r.c.Write([]byte(rfbVersion)); err != nil {
		return err
	}
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
		return fmt.Errorf("VNC server requires auth (types %v); only None is supported", types)
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
	// SetPixelFormat: 32bpp truecolour BGRX little-endian, one fixed format
	// so the blit never branches
	pf := []byte{msgSetPixelFormat, 0, 0, 0,
		32, 24, 0, 1, // bpp, depth, big-endian, true-colour
		0, 255, 0, 255, 0, 255, // r/g/b max
		16, 8, 0, // r/g/b shift
		0, 0, 0}
	if _, err := r.c.Write(pf); err != nil {
		return err
	}
	// built from the constants, never hand-written: -308 spelled by hand as
	// 0xfffffed4 is -300, and the resize feature was inert for a month
	want := []int32{encRaw, encDesktopSize, encExtendedDesktopSize}
	enc := make([]byte, 4+4*len(want))
	enc[0] = msgSetEncodings
	binary.BigEndian.PutUint16(enc[2:4], uint16(len(want)))
	for i, e := range want {
		binary.BigEndian.PutUint32(enc[4+i*4:8+i*4], uint32(e))
	}
	_, err := r.c.Write(enc)
	return err
}

// readReason drains an RFB failure-reason string (best effort).
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

// frame returns the published framebuffer and its sequence number; the
// caller must not write to it, and must not hold it across a publish (the
// buffer is reused when the size is unchanged, so read it under the lock
// via withFrame when consistency matters).
func (r *rfbConn) withFrame(f func(img *image.RGBA)) uint64 {
	r.pubMu.Lock()
	defer r.pubMu.Unlock()
	if r.pub != nil {
		f(r.pub)
	}
	return r.frames.Load()
}

// publish copies the working framebuffer out for the renderers. ~4 MB at
// 1280x800; a memcpy per update is cheaper than any lock the renderer would
// otherwise hold across a blit.
func (r *rfbConn) publish() {
	r.pubMu.Lock()
	if r.pub == nil || r.pub.Bounds() != r.img.Bounds() {
		r.pub = image.NewRGBA(r.img.Bounds())
	}
	copy(r.pub.Pix, r.img.Pix)
	r.pubMu.Unlock()
	r.frames.Add(1)
}

// size is the working framebuffer size, read-loop only.
func (r *rfbConn) size() (int, int) { return r.fbW, r.fbH }

func (r *rfbConn) setErr(err error) {
	if err == nil {
		return
	}
	r.errMu.Lock()
	if r.err == nil && !r.closing {
		r.err = err
	}
	r.errMu.Unlock()
}

// Err is why the connection ended, or nil if it ended on request (or has
// not ended). Read it after done closes.
func (r *rfbConn) Err() error {
	r.errMu.Lock()
	defer r.errMu.Unlock()
	return r.err
}

// write serialises every outbound message and captures the failure: before
// this, a broken pipe left the last frame on screen and swallowed every
// keystroke, which reads as "the console froze".
func (r *rfbConn) write(b []byte) {
	r.mu.Lock()
	_, err := r.c.Write(b)
	r.mu.Unlock()
	r.setErr(err)
}

func (r *rfbConn) requestUpdate(incremental bool) {
	inc := byte(0)
	if incremental {
		inc = 1
	}
	w, h := r.size()
	msg := make([]byte, 10)
	msg[0] = msgFramebufferUpdateReq
	msg[1] = inc
	binary.BigEndian.PutUint16(msg[6:8], uint16(w))
	binary.BigEndian.PutUint16(msg[8:10], uint16(h))
	r.write(msg)
}

// requestSize asks the guest to become w×h. Meaningful only once the server
// has announced ExtendedDesktopSize and the guest's video driver can change
// mode (virtio-gpu can; legacy VGA text mode cannot); both cases are silent
// no-ops, because this optimises the view and is never a precondition for it.
func (r *rfbConn) requestSize(w, h int) {
	if w <= 0 || h <= 0 || w > 0xffff || h > 0xffff {
		return
	}
	r.extMu.Lock()
	ok, id, flags := r.extOK, r.screen, r.flags
	r.extMu.Unlock()
	if !ok {
		return
	}
	r.pubMu.Lock()
	same := r.pub != nil && r.pub.Bounds().Dx() == w && r.pub.Bounds().Dy() == h
	r.pubMu.Unlock()
	if same {
		return // a redundant mode change flickers the guest
	}
	b := make([]byte, 8+16)
	b[0] = msgSetDesktopSize
	binary.BigEndian.PutUint16(b[2:4], uint16(w))
	binary.BigEndian.PutUint16(b[4:6], uint16(h))
	b[6] = 1 // one screen
	binary.BigEndian.PutUint32(b[8:12], id)
	binary.BigEndian.PutUint16(b[16:18], uint16(w))
	binary.BigEndian.PutUint16(b[18:20], uint16(h))
	binary.BigEndian.PutUint32(b[20:24], flags)
	r.write(b)
}

func (r *rfbConn) readLoop() {
	defer close(r.done)
	hdr := make([]byte, 4)
	rect := make([]byte, 12)
	for {
		if _, err := io.ReadFull(r.c, hdr[:1]); err != nil {
			r.setErr(err)
			return
		}
		switch hdr[0] {
		case msgFramebufferUpdate:
			if _, err := io.ReadFull(r.c, hdr[1:4]); err != nil {
				r.setErr(err)
				return
			}
			rects := int(binary.BigEndian.Uint16(hdr[2:4]))
			for i := 0; i < rects; i++ {
				if _, err := io.ReadFull(r.c, rect); err != nil {
					r.setErr(err)
					return
				}
				x := int(binary.BigEndian.Uint16(rect[0:2]))
				y := int(binary.BigEndian.Uint16(rect[2:4]))
				rw := int(binary.BigEndian.Uint16(rect[4:6]))
				rh := int(binary.BigEndian.Uint16(rect[6:8]))
				enc := int32(binary.BigEndian.Uint32(rect[8:12]))
				switch enc {
				case encRaw:
					if err := r.blitRaw(x, y, rw, rh); err != nil {
						r.setErr(err)
						return
					}
				case encDesktopSize:
					r.fbW, r.fbH = rw, rh
					r.img = image.NewRGBA(image.Rect(0, 0, rw, rh))
				case encExtendedDesktopSize:
					// x carries the reason and y the result; the payload
					// MUST be drained whatever we do with it, or every rect
					// after this one is misread
					var sh [4]byte
					if _, err := io.ReadFull(r.c, sh[:]); err != nil {
						r.setErr(err)
						return
					}
					layout := make([]byte, 16*int(sh[0]))
					if _, err := io.ReadFull(r.c, layout); err != nil {
						r.setErr(err)
						return
					}
					r.extMu.Lock()
					r.extOK = true
					if len(layout) >= 16 {
						r.screen = binary.BigEndian.Uint32(layout[0:4])
						r.flags = binary.BigEndian.Uint32(layout[12:16])
					}
					r.extMu.Unlock()
					if y == 0 { // success or server-initiated; a refusal leaves it as it was
						r.fbW, r.fbH = rw, rh
						r.img = image.NewRGBA(image.Rect(0, 0, rw, rh))
					}
				default:
					r.setErr(fmt.Errorf("unrequested encoding %d", enc))
					return
				}
			}
			r.publish()
			r.requestUpdate(true)
		case msgSetColourMapEntries: // cannot happen in truecolour; drain
			var h [5]byte
			if _, err := io.ReadFull(r.c, h[:]); err != nil {
				r.setErr(err)
				return
			}
			n := int64(binary.BigEndian.Uint16(h[3:5]))
			if _, err := io.CopyN(io.Discard, r.c, n*6); err != nil {
				r.setErr(err)
				return
			}
		case msgBell:
		case msgServerCutText:
			var h [7]byte
			if _, err := io.ReadFull(r.c, h[:]); err != nil {
				r.setErr(err)
				return
			}
			n := int64(binary.BigEndian.Uint32(h[3:7]))
			if n > 1<<20 { // a clipboard, not a firehose
				if _, err := io.CopyN(io.Discard, r.c, n); err != nil {
					r.setErr(err)
					return
				}
				continue
			}
			b := make([]byte, n)
			if _, err := io.ReadFull(r.c, b); err != nil {
				r.setErr(err)
				return
			}
			r.cutMu.Lock()
			r.cut = string(b) // RFB cut text is latin-1; close enough
			r.cutMu.Unlock()
		default:
			r.setErr(fmt.Errorf("unknown server message %d", hdr[0]))
			return
		}
	}
}

// blitRaw copies one Raw rectangle (BGRX) into the working framebuffer.
func (r *rfbConn) blitRaw(x, y, w, h int) error {
	if need := w * 4; len(r.scratch) < need {
		r.scratch = make([]byte, need)
	}
	row := r.scratch[:w*4]
	img := r.img
	for j := 0; j < h; j++ {
		if _, err := io.ReadFull(r.c, row); err != nil {
			return err
		}
		if y+j >= img.Bounds().Dy() {
			continue // rect from a stale size: drain but do not write
		}
		off := img.PixOffset(x, y+j)
		for i := 0; i < w && x+i < img.Bounds().Dx(); i++ {
			img.Pix[off+i*4+0] = row[i*4+2]
			img.Pix[off+i*4+1] = row[i*4+1]
			img.Pix[off+i*4+2] = row[i*4+0]
			img.Pix[off+i*4+3] = 0xff
		}
	}
	return nil
}

func (r *rfbConn) pointer(mask uint8, x, y int) {
	msg := []byte{msgPointerEvent, mask, 0, 0, 0, 0}
	binary.BigEndian.PutUint16(msg[2:4], uint16(x))
	binary.BigEndian.PutUint16(msg[4:6], uint16(y))
	r.write(msg)
}

func (r *rfbConn) key(sym uint32, down bool) {
	d := byte(0)
	if down {
		d = 1
	}
	msg := []byte{msgKeyEvent, d, 0, 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(msg[4:8], sym)
	r.write(msg)
}

// tap presses and releases one keysym.
func (r *rfbConn) tap(sym uint32) { r.key(sym, true); r.key(sym, false) }

// cutText hands text to the guest's clipboard (ClientCutText); guests with
// qemu-vdagent pick it up.
func (r *rfbConn) cutText(s string) {
	b := []byte(s)
	msg := make([]byte, 8, 8+len(b))
	msg[0] = msgClientCutText
	binary.BigEndian.PutUint32(msg[4:8], uint32(len(b)))
	r.write(append(msg, b...))
}

// Close ends the session; the flag goes up first so the read loop's "use of
// closed network connection" is a detach, not a fault.
func (r *rfbConn) Close() {
	r.errMu.Lock()
	r.closing = true
	r.errMu.Unlock()
	// error ignored: closing an already-dead socket has no recovery
	_ = r.c.Close()
}

// X11 keysyms for the keys a terminal can deliver. Letters and symbols map
// to themselves (latin-1); anything above U+00FF uses the Unicode plane.
const (
	ksBackSpace = 0xff08
	ksTab       = 0xff09
	ksReturn    = 0xff0d
	ksEscape    = 0xff1b
	ksDelete    = 0xffff
	ksHome      = 0xff50
	ksLeft      = 0xff51
	ksUp        = 0xff52
	ksRight     = 0xff53
	ksDown      = 0xff54
	ksPageUp    = 0xff55
	ksPageDown  = 0xff56
	ksEnd       = 0xff57
	ksInsert    = 0xff63
	ksF1        = 0xffbe
	ksShiftL    = 0xffe1
	ksControlL  = 0xffe3
	ksAltL      = 0xffe9
)

// runeKeysym maps a character to its keysym.
func runeKeysym(c rune) uint32 {
	switch c {
	case '\r', '\n':
		return ksReturn
	case '\t':
		return ksTab
	case 0x7f, '\b':
		return ksBackSpace
	case 0x1b:
		return ksEscape
	}
	if c > 0xff {
		return 0x01000000 + uint32(c)
	}
	return uint32(c)
}

// typeText types a string into the guest, one press/release per rune, with
// Shift held for the characters a keyboard needs it for. qemu maps keysyms
// to scancodes itself, so plain 'A' arrives as 'a' with Shift already.
func (r *rfbConn) typeText(s string) {
	for _, c := range s {
		r.tap(runeKeysym(c))
	}
}
