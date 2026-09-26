// console.go — the consoles that live INSIDE the TUI: a VM's screen (VNC),
// its serial line (virsh console) and a terminal on it (ssh), drawn in the
// body of the Machines section with the rail and status line still around
// them, so the operator never leaves kld to reach a machine.
//
// What it does, in order:
//  1. openConsole: dials the VNC display (screen) or spawns the child in a
//     pty behind a terminal emulator (serial, ssh).
//  2. view: renders the framebuffer as half-block cells (two pixels per
//     cell, truecolour, so it works over tmux and on tty1) or the emulator's
//     screen with a cursor, cached per frame so a redraw costs nothing when
//     nothing changed.
//  3. key/mouse: every key goes to the guest — as X keysyms over RFB, or as
//     the bytes a terminal would send down the pty — except ctrl+], which
//     opens a one-line menu: detach, switch console, ctrl+alt+del, redraw.
//
// Why in-tree and not a window: the operator's platform is Sway plus TUIs,
// and a headless core profile has no window at all. vmxplore's Fyne screen
// pane and its Serial tab are the model; the wire client is vnc.go and the
// emulator is charmbracelet/x/vt.
//
// Notes: the child of a serial or ssh console runs under sudo -n like every
// other verb (virsh console needs root; ssh uses the host's root key, the
// one kldload-enroll installed). ctrl+] is also virsh's own escape, so the
// menu's ] key forwards it for the one time that is wanted.
package main

import (
	"errors"
	"fmt"
	"image"
	"image/color"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/vt"
	"golang.org/x/sys/unix"
)

type consoleKind int

const (
	conNone consoleKind = iota
	conScreen
	conSerial
	conSSH
)

func (k consoleKind) String() string {
	return [...]string{"", "screen", "serial", "ssh"}[k]
}

// console is one open session. Exactly one is open at a time (model.con).
type console struct {
	kind  consoleKind
	vm    string
	addr  string // the ssh target, for conSSH
	rfb   *rfbConn
	pty   *os.File
	cmd   *exec.Cmd
	vt    *vt.Emulator
	vtMu  sync.Mutex
	seq   atomic.Uint64 // bumps on every new frame / pty read
	exit  atomic.Pointer[error]
	cols  int
	rows  int
	menu  bool
	mask  uint8 // mouse buttons held (screen)
	cache struct {
		seq  uint64
		w, h int
		menu bool
		s    string
	}
	// where the last screen frame landed, for the mouse: cell offsets and
	// the framebuffer-pixels-per-cell scale
	offX, offY int
	scale      float64
	fbW, fbH   int
}

type conTickMsg struct{}

func conTick() tea.Cmd {
	return tea.Tick(80*time.Millisecond, func(time.Time) tea.Msg { return conTickMsg{} })
}

// openConsole starts a session of the kind on the VM named by the row. The
// ssh kind needs the row's address (column 4 of Machines/VMs).
func openConsole(kind consoleKind, vm, addr string, cols, rows int) (*console, error) {
	c := &console{kind: kind, vm: vm, addr: addr, cols: max(cols, 20), rows: max(rows, 5)}
	switch kind {
	case conScreen:
		port, err := vncPort(vm)
		if err != nil {
			return nil, err
		}
		r, err := dialRFB("127.0.0.1:" + strconv.Itoa(port))
		if err != nil {
			return nil, fmt.Errorf("vnc :%d: %w", port, err)
		}
		c.rfb = r
		go func() {
			<-r.done
			e := r.Err()
			if e == nil {
				e = errors.New("the display closed")
			}
			c.exit.Store(&e)
		}()
	case conSerial:
		if err := c.spawn("sudo", "-n", "virsh", "console", vm); err != nil {
			return nil, err
		}
	case conSSH:
		if addr == "" || addr == "-" {
			return nil, errors.New("no address for " + vm + " yet")
		}
		// the guest changes every rebuild, so its host key is not pinned
		if err := c.spawn("sudo", "-n", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "root@"+addr); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("no such console")
	}
	return c, nil
}

// spawn runs argv in a fresh pty with the emulator sized like the pane.
func (c *console) spawn(argv ...string) error {
	master, slave, err := openPTY()
	if err != nil {
		return err
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true}
	if err := cmd.Start(); err != nil {
		master.Close()
		slave.Close()
		return err
	}
	slave.Close()
	c.pty, c.cmd = master, cmd
	c.vt = vt.NewEmulator(c.cols, c.rows)
	c.setWinsize()
	go func() { // pty → emulator
		buf := make([]byte, 32*1024)
		for {
			n, err := master.Read(buf)
			if n > 0 {
				c.vtMu.Lock()
				// error ignored: the emulator's Write never fails on bytes
				// it does not understand, it drops them
				_, _ = c.vt.Write(buf[:n])
				c.vtMu.Unlock()
				c.seq.Add(1)
			}
			if err != nil {
				_ = cmd.Wait()
				e := fmt.Errorf("%s ended", argv[len(argv)-1])
				if cmd.ProcessState != nil && !cmd.ProcessState.Success() {
					e = fmt.Errorf("%s ended: %s", argv[len(argv)-1], cmd.ProcessState)
				}
				c.exit.Store(&e)
				return
			}
		}
	}()
	go func() { // emulator → pty: replies to queries (DA, cursor reports)
		buf := make([]byte, 4096)
		for {
			n, err := c.vt.Read(buf)
			if n > 0 {
				if _, werr := master.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
			if n == 0 {
				time.Sleep(20 * time.Millisecond)
			}
		}
	}()
	return nil
}

// openPTY opens a master/slave pair by hand: /dev/ptmx, unlock, and the
// slave's number. Twenty lines against a dependency.
func openPTY() (master, slave *os.File, err error) {
	master, err = os.OpenFile("/dev/ptmx", os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, err
	}
	if err := unix.IoctlSetPointerInt(int(master.Fd()), unix.TIOCSPTLCK, 0); err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("unlock pty: %w", err)
	}
	n, err := unix.IoctlGetInt(int(master.Fd()), unix.TIOCGPTN)
	if err != nil {
		master.Close()
		return nil, nil, fmt.Errorf("pty number: %w", err)
	}
	slave, err = os.OpenFile("/dev/pts/"+strconv.Itoa(n), os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	return master, slave, nil
}

func (c *console) setWinsize() {
	if c.pty == nil {
		return
	}
	// error ignored: a pty whose child is gone cannot be resized, and the
	// exit is reported by the reader
	_ = unix.IoctlSetWinsize(int(c.pty.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Row: uint16(c.rows), Col: uint16(c.cols)})
}

// resize follows the pane: the emulator and pty get the new size; the
// screen asks the guest to match the cell grid's pixel area (a no-op unless
// the guest can change mode).
func (c *console) resize(cols, rows int) {
	c.cols, c.rows = max(cols, 20), max(rows, 5)
	if c.vt != nil {
		c.vtMu.Lock()
		c.vt.Resize(c.cols, c.rows)
		c.vtMu.Unlock()
		c.setWinsize()
	}
	if c.rfb != nil {
		// a cell is about 1:2, so cols x 2*rows is a square-pixel grid;
		// ask for a multiple of 8 in each direction
		c.rfb.requestSize(c.cols/8*8, c.rows*2/8*8)
	}
	c.seq.Add(1)
}

func (c *console) close() {
	if c.rfb != nil {
		c.rfb.Close()
	}
	if c.cmd != nil && c.cmd.Process != nil {
		// error ignored: the child may already have exited
		_ = c.cmd.Process.Kill()
	}
	if c.pty != nil {
		c.pty.Close()
	}
}

// status is the line under the console.
func (c *console) status() string {
	if c.menu {
		return stKey.Render("ctrl+]") + stDim.Render("  d detach · 1 screen · 2 serial · 3 ssh · x ctrl+alt+del · r redraw · ] send ctrl+] · any other key back")
	}
	what := c.kind.String()
	if c.kind == conScreen {
		what = fmt.Sprintf("screen %dx%d", c.fbW, c.fbH)
	}
	if c.kind == conSSH {
		what = "ssh root@" + c.addr
	}
	ended := ""
	if p := c.exit.Load(); p != nil {
		ended = stWarn.Render("  " + (*p).Error() + " — ctrl+] d to leave")
	}
	return stKey.Render(c.vm) + stDim.Render("  "+what+"  ·  keys go to the machine  ·  ") + stKey.Render("ctrl+]") + stDim.Render(" menu") + ended
}

// view renders the console body at w x h cells, from cache when nothing
// changed since the last call.
func (c *console) view(w, h int) string {
	seq := c.seq.Load()
	if c.rfb != nil {
		// the screen's frames arrive on the wire client's counter, not
		// ours: without this the first frame was the only one ever drawn
		seq += c.rfb.frames.Load() << 32
	}
	if c.cache.s != "" && c.cache.seq == seq && c.cache.w == w && c.cache.h == h {
		return c.cache.s
	}
	var s string
	if c.rfb != nil {
		s = c.renderScreen(w, h)
	} else {
		s = c.renderTerm(w, h)
	}
	c.cache.seq, c.cache.w, c.cache.h, c.cache.s = seq, w, h, s
	return s
}

// renderScreen draws the published framebuffer into w x h cells as upper
// half-blocks: the cell's foreground is the upper pixel, its background the
// lower one, each a box average of the source pixels it covers.
func (c *console) renderScreen(w, h int) string {
	var out strings.Builder
	c.rfb.withFrame(func(img *image.RGBA) {
		fw, fh := img.Bounds().Dx(), img.Bounds().Dy()
		c.fbW, c.fbH = fw, fh
		if fw == 0 || fh == 0 || w < 2 || h < 1 {
			return
		}
		gw, gh := w, h*2 // the pixel grid the cells can show
		scale := min(float64(gw)/float64(fw), float64(gh)/float64(fh))
		ow, oh := max(int(float64(fw)*scale), 1), max(int(float64(fh)*scale), 2)
		oh -= oh % 2
		c.scale = scale
		c.offX, c.offY = (w-ow)/2, (h-oh/2)/2
		// sample: out pixel (x,y) averages the source box it covers
		px := make([][3]uint8, ow*oh)
		for y := 0; y < oh; y++ {
			sy0, sy1 := int(float64(y)/scale), int(float64(y+1)/scale)
			sy1 = min(max(sy1, sy0+1), fh)
			for x := 0; x < ow; x++ {
				sx0, sx1 := int(float64(x)/scale), int(float64(x+1)/scale)
				sx1 = min(max(sx1, sx0+1), fw)
				var r, g, b, n uint32
				for sy := sy0; sy < sy1; sy++ {
					off := img.PixOffset(sx0, sy)
					for sx := sx0; sx < sx1; sx++ {
						r += uint32(img.Pix[off])
						g += uint32(img.Pix[off+1])
						b += uint32(img.Pix[off+2])
						off += 4
						n++
					}
				}
				if n > 0 {
					px[y*ow+x] = [3]uint8{uint8(r / n), uint8(g / n), uint8(b / n)}
				}
			}
		}
		pad := strings.Repeat(" ", c.offX)
		for row := 0; row < h; row++ {
			if row < c.offY || row >= c.offY+oh/2 {
				out.WriteString("\n")
				continue
			}
			y := (row - c.offY) * 2
			out.WriteString(pad)
			var lastFg, lastBg [3]uint8
			first := true
			for x := 0; x < ow; x++ {
				fg, bg := px[y*ow+x], px[(y+1)*ow+x]
				if first || fg != lastFg {
					fmt.Fprintf(&out, "\x1b[38;2;%d;%d;%dm", fg[0], fg[1], fg[2])
				}
				if first || bg != lastBg {
					fmt.Fprintf(&out, "\x1b[48;2;%d;%d;%dm", bg[0], bg[1], bg[2])
				}
				out.WriteString("▀")
				lastFg, lastBg, first = fg, bg, false
			}
			out.WriteString("\x1b[0m\n")
		}
	})
	if out.Len() == 0 {
		return stDim.Render("waiting for the first frame …")
	}
	return strings.TrimRight(out.String(), "\n")
}

// renderTerm draws the emulator's screen cell by cell, styles emitted as
// diffs, the cursor as a reversed cell.
func (c *console) renderTerm(w, h int) string {
	c.vtMu.Lock()
	defer c.vtMu.Unlock()
	cur := c.vt.CursorPosition()
	var out strings.Builder
	for y := 0; y < min(h, c.vt.Height()); y++ {
		prev := uv.Style{}
		for x := 0; x < min(w, c.vt.Width()); x++ {
			cell := c.vt.CellAt(x, y)
			st, content := uv.Style{}, " "
			if cell != nil {
				st = cell.Style
				if cell.Width == 0 && cell.Content == "" {
					continue // the tail of a wide character
				}
				if cell.Content != "" {
					content = cell.Content
				}
			}
			if x == cur.X && y == cur.Y {
				st.Fg, st.Bg = st.Bg, st.Fg
				if st.Fg == nil && st.Bg == nil {
					st.Fg, st.Bg = color.Black, color.White
				}
			}
			out.WriteString(st.Diff(&prev))
			out.WriteString(content)
			prev = st
		}
		out.WriteString("\x1b[0m\n")
	}
	return strings.TrimRight(out.String(), "\n")
}

// special keys: the keysym for the screen and the byte sequence for a pty.
var specialKeys = map[tea.KeyType]struct {
	sym uint32
	seq string
}{
	tea.KeyUp: {ksUp, "\x1b[A"}, tea.KeyDown: {ksDown, "\x1b[B"},
	tea.KeyRight: {ksRight, "\x1b[C"}, tea.KeyLeft: {ksLeft, "\x1b[D"},
	tea.KeyHome: {ksHome, "\x1b[H"}, tea.KeyEnd: {ksEnd, "\x1b[F"},
	tea.KeyPgUp: {ksPageUp, "\x1b[5~"}, tea.KeyPgDown: {ksPageDown, "\x1b[6~"},
	tea.KeyInsert: {ksInsert, "\x1b[2~"}, tea.KeyDelete: {ksDelete, "\x1b[3~"},
	tea.KeyF1: {ksF1, "\x1bOP"}, tea.KeyF2: {ksF1 + 1, "\x1bOQ"}, tea.KeyF3: {ksF1 + 2, "\x1bOR"},
	tea.KeyF4: {ksF1 + 3, "\x1bOS"}, tea.KeyF5: {ksF1 + 4, "\x1b[15~"}, tea.KeyF6: {ksF1 + 5, "\x1b[17~"},
	tea.KeyF7: {ksF1 + 6, "\x1b[18~"}, tea.KeyF8: {ksF1 + 7, "\x1b[19~"}, tea.KeyF9: {ksF1 + 8, "\x1b[20~"},
	tea.KeyF10: {ksF1 + 9, "\x1b[21~"}, tea.KeyF11: {ksF1 + 10, "\x1b[23~"}, tea.KeyF12: {ksF1 + 11, "\x1b[24~"},
	tea.KeyShiftTab: {ksTab, "\x1b[Z"},
}

// key forwards one key press to the machine.
func (c *console) key(msg tea.KeyMsg) {
	if c.rfb != nil {
		c.keyScreen(msg)
		return
	}
	if c.pty == nil {
		return
	}
	var b []byte
	switch {
	case msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace:
		b = []byte(string(msg.Runes))
		if msg.Type == tea.KeySpace {
			b = []byte{' '}
		}
	case msg.Type >= 0 && msg.Type < 32, msg.Type == tea.KeyBackspace:
		// control characters and DEL are their own byte
		b = []byte{byte(msg.Type)}
	default:
		if sk, ok := specialKeys[msg.Type]; ok {
			b = []byte(sk.seq)
		}
	}
	if len(b) == 0 {
		return
	}
	if msg.Alt {
		b = append([]byte{0x1b}, b...)
	}
	// error ignored here on purpose: a dead child is reported by the
	// reader goroutine, and a key into a closed pty has nowhere to go
	_, _ = c.pty.Write(b)
}

func (c *console) keyScreen(msg tea.KeyMsg) {
	r := c.rfb
	hold := func(sym uint32, f func()) { r.key(sym, true); f(); r.key(sym, false) }
	send := func() {
		switch {
		case msg.Type == tea.KeySpace:
			r.tap(' ')
		case msg.Type == tea.KeyRunes:
			for _, ch := range msg.Runes {
				r.tap(runeKeysym(ch))
			}
		case msg.Type == tea.KeyShiftTab:
			hold(ksShiftL, func() { r.tap(ksTab) })
		case msg.Type == tea.KeyEnter:
			r.tap(ksReturn)
		case msg.Type == tea.KeyTab:
			r.tap(ksTab)
		case msg.Type == tea.KeyEsc:
			r.tap(ksEscape)
		case msg.Type == tea.KeyBackspace:
			r.tap(ksBackSpace)
		case msg.Type >= 0 && msg.Type < 32:
			// a control character: Control held around the letter it is
			ch := uint32(msg.Type) + 'a' - 1
			switch msg.Type {
			case 0:
				ch = ' '
			case 28:
				ch = '\\'
			case 29:
				ch = ']'
			case 30:
				ch = '^'
			case 31:
				ch = '_'
			}
			hold(ksControlL, func() { r.tap(ch) })
		default:
			if sk, ok := specialKeys[msg.Type]; ok {
				r.tap(sk.sym)
			}
		}
	}
	if msg.Alt {
		hold(ksAltL, send)
		return
	}
	send()
}

// mouse maps a cell event onto the framebuffer and forwards it (screen only).
func (c *console) mouse(msg tea.MouseMsg, bodyTop int) {
	if c.rfb == nil || c.scale == 0 {
		return
	}
	cx, cy := msg.X-c.offX, msg.Y-bodyTop-c.offY
	fx := int(float64(cx) / c.scale)
	fy := int(float64(cy*2) / c.scale)
	fx = min(max(fx, 0), max(c.fbW-1, 0))
	fy = min(max(fy, 0), max(c.fbH-1, 0))
	var bit uint8
	switch msg.Button {
	case tea.MouseButtonLeft:
		bit = 1
	case tea.MouseButtonMiddle:
		bit = 2
	case tea.MouseButtonRight:
		bit = 4
	case tea.MouseButtonWheelUp:
		bit = 8
	case tea.MouseButtonWheelDown:
		bit = 16
	}
	switch msg.Action {
	case tea.MouseActionPress:
		if bit >= 8 { // a wheel notch is a press and a release
			c.rfb.pointer(c.mask|bit, fx, fy)
			c.rfb.pointer(c.mask, fx, fy)
			return
		}
		c.mask |= bit
	case tea.MouseActionRelease:
		c.mask &^= bit
	}
	c.rfb.pointer(c.mask, fx, fy)
}

// ctrlAltDel is the menu's x: the three-finger salute over RFB, or the
// SysRq-free equivalent a serial line has, a plain typed "reboot".
func (c *console) ctrlAltDel() {
	if c.rfb != nil {
		c.rfb.key(ksControlL, true)
		c.rfb.key(ksAltL, true)
		c.rfb.tap(ksDelete)
		c.rfb.key(ksAltL, false)
		c.rfb.key(ksControlL, false)
	}
}
