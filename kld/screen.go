// screen.go — `kld screen <vm>`: the machine's display full-screen in the
// terminal, pixel-exact in sixels where the terminal draws them (foot,
// xterm, mlterm, wezterm) and as half-block cells everywhere else (tmux,
// tty1, anything that answers DA1 without ";4").
//
// What it does, in order:
//  1. connects to the VM's VNC display (vnc.go);
//  2. puts the terminal in raw mode, alternate screen, SGR mouse reporting,
//     asks it what it is (DA1) and how big a cell is (CSI 16 t);
//  3. loops: a new frame is scaled to the terminal's pixel area and drawn
//     (sixel bands or half-block rows) at most 15 times a second; every
//     byte typed is decoded into a keysym for the guest, every mouse report
//     into a pointer event, ctrl+] into the same menu the in-TUI console has.
//
// Why a separate command and not the TUI's pane: bubbletea owns the screen
// while the TUI runs and diffs it line by line, which sixel data (one band
// per six pixel rows, positioned by the cursor) does not survive. Owning the
// terminal directly is cheaper than teaching a line renderer about images,
// and it gives `kld screen` a life of its own over ssh.
//
// Notes: colours are quantised to a fixed 6x7x6 palette (252 registers)
// per frame; that is what a console needs, not a photo viewer. The cell
// size query is answered by foot, xterm and kitty; a terminal that stays
// silent gets 9x19, foot's default, which only affects how much of the
// screen the image covers. A DA1 that stays silent for 300 ms means blocks.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"image"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/x/term"
)

// runScreen is `kld screen <vm> [--blocks|--sixel]`.
func runScreen(args []string) error {
	var vm string
	blocks, sixel := false, false
	for _, a := range args {
		switch {
		case a == "--blocks":
			blocks = true
		case a == "--sixel":
			sixel = true
		case strings.HasPrefix(a, "-"):
			return fmt.Errorf("unknown option %s", a)
		case vm == "":
			vm = a
		default:
			return errors.New("one VM at a time")
		}
	}
	if vm == "" {
		return errors.New("which VM? kld screen <vm>")
	}
	if !nameOK(vm) {
		return errors.New("not a VM name: " + vm)
	}
	port, err := vncPort(vm)
	if err != nil {
		return err
	}
	r, err := dialRFB("127.0.0.1:" + strconv.Itoa(port))
	if err != nil {
		return fmt.Errorf("vnc :%d: %w", port, err)
	}
	defer r.Close()
	fd := os.Stdin.Fd()
	if !term.IsTerminal(fd) {
		return errors.New("kld screen needs a terminal")
	}
	st, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	// alternate screen, no cursor, SGR mouse (buttons + motion while held)
	out.WriteString("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h")
	out.Flush()
	defer func() {
		out.WriteString("\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l")
		out.Flush()
		// error ignored: restoring a terminal that went away has no recovery
		_ = term.Restore(fd, st)
	}()
	in := make(chan []byte, 64)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				b := make([]byte, n)
				copy(b, buf[:n])
				in <- b
			}
			if err != nil {
				close(in)
				return
			}
		}
	}()
	s := &screenView{r: r, vm: vm, out: out, cellW: 9, cellH: 19}
	// inside tmux the answer to DA1 is tmux's, and tmux 3.7c said it drew
	// sixels and then its server died on the first frame (onyx,
	// 2026-09-26, taking every session on the socket with it). So under
	// tmux the default is blocks; --sixel is the operator saying "I know".
	underTmux := os.Getenv("TMUX") != ""
	switch {
	case blocks:
		s.sixel = false
	case sixel:
		s.sixel = true
		s.probeTerminal(in) // still learn the cell size
	default:
		s.sixel = s.probeTerminal(in) && !underTmux
	}
	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)
	s.fit(fd)
	tick := time.NewTicker(66 * time.Millisecond)
	defer tick.Stop()
	var drawn uint64
	for {
		select {
		case <-r.done:
			if err := r.Err(); err != nil {
				return err
			}
			return nil
		case <-winch:
			s.fit(fd)
			drawn = 0
		case <-tick.C:
			if seq := r.frames.Load(); seq != drawn || s.dirty {
				s.draw()
				drawn, s.dirty = seq, false
			}
		case b, ok := <-in:
			if !ok {
				return nil
			}
			if s.input(b) {
				return nil
			}
		}
	}
}

type screenView struct {
	r            *rfbConn
	vm           string
	out          *bufio.Writer
	cols, rows   int
	cellW, cellH int
	sixel        bool
	menu         bool
	dirty        bool
	mask         uint8
	// the last drawn image's placement, for the mouse
	imgW, imgH int // in pixels (sixel) or cells (blocks)
	offX, offY int // in cells
	fbW, fbH   int
	pending    []byte // an incomplete escape sequence between reads
}

// probeTerminal asks DA1 and the cell size, waiting up to 300 ms. Sixel is
// attribute 4 in the DA1 reply; tmux answers for itself and never says 4.
func (s *screenView) probeTerminal(in chan []byte) bool {
	s.out.WriteString("\x1b[c\x1b[16t")
	s.out.Flush()
	var got []byte
	deadline := time.After(300 * time.Millisecond)
	for {
		select {
		case b := <-in:
			got = append(got, b...)
			if strings.Contains(string(got), "c") && (strings.Contains(string(got), "t") || len(got) > 64) {
				return s.parseProbe(got)
			}
		case <-deadline:
			return s.parseProbe(got)
		}
	}
}

func (s *screenView) parseProbe(b []byte) bool {
	str := string(b)
	sixel := false
	if i := strings.Index(str, "\x1b[?"); i >= 0 {
		rest := str[i+3:]
		if j := strings.IndexByte(rest, 'c'); j >= 0 {
			for _, p := range strings.Split(rest[:j], ";") {
				if p == "4" {
					sixel = true
				}
			}
		}
	}
	// CSI 6 ; height ; width t
	if i := strings.Index(str, "\x1b[6;"); i >= 0 {
		rest := str[i+4:]
		if j := strings.IndexByte(rest, 't'); j >= 0 {
			if hw := strings.Split(rest[:j], ";"); len(hw) == 2 {
				h, _ := strconv.Atoi(hw[0])
				w, _ := strconv.Atoi(hw[1])
				if h > 0 && w > 0 {
					s.cellH, s.cellW = h, w
				}
			}
		}
	}
	return sixel
}

// fit reads the terminal size and asks the guest to match the drawable
// pixel area (all rows but the status line), a no-op unless it can.
func (s *screenView) fit(fd uintptr) {
	w, h, err := term.GetSize(fd)
	if err != nil || w < 10 || h < 3 {
		w, h = 80, 24
	}
	s.cols, s.rows = w, h
	if s.sixel {
		s.r.requestSize((s.cols*s.cellW)/8*8, ((s.rows-1)*s.cellH)/8*8)
	} else {
		s.r.requestSize(s.cols/8*8, ((s.rows-1)*2)/8*8)
	}
	s.dirty = true
	s.out.WriteString("\x1b[2J")
}

func (s *screenView) status() string {
	if s.menu {
		return "ctrl+]  d detach · x ctrl+alt+del · r redraw · ] send ctrl+] · any other key back"
	}
	mode := "blocks"
	if s.sixel {
		mode = "sixel"
	}
	return fmt.Sprintf("%s  screen %dx%d · %s · keys and mouse go to the machine · ctrl+] menu", s.vm, s.fbW, s.fbH, mode)
}

// draw renders the published frame and the status line.
func (s *screenView) draw() {
	s.r.withFrame(func(img *image.RGBA) {
		s.fbW, s.fbH = img.Bounds().Dx(), img.Bounds().Dy()
		if s.sixel {
			s.drawSixel(img)
		} else {
			s.drawBlocks(img)
		}
	})
	fmt.Fprintf(s.out, "\x1b[%d;1H\x1b[0m\x1b[K%s", s.rows, truncate(s.status(), s.cols))
	s.out.Flush()
}

// drawBlocks is the half-block renderer at cell resolution, the same idea
// as the TUI pane's, written to the terminal directly.
func (s *screenView) drawBlocks(img *image.RGBA) {
	fw, fh := img.Bounds().Dx(), img.Bounds().Dy()
	w, h := s.cols, s.rows-1
	if fw == 0 || fh == 0 || w < 2 || h < 1 {
		return
	}
	scale := min(float64(w)/float64(fw), float64(h*2)/float64(fh))
	ow, oh := max(int(float64(fw)*scale), 1), max(int(float64(fh)*scale), 2)
	oh -= oh % 2
	px := sample(img, ow, oh)
	s.imgW, s.imgH = ow, oh/2
	s.offX, s.offY = (w-ow)/2, (h-oh/2)/2
	for row := 0; row < oh/2; row++ {
		fmt.Fprintf(s.out, "\x1b[%d;%dH", s.offY+row+1, s.offX+1)
		y := row * 2
		var lastFg, lastBg [3]uint8
		first := true
		for x := 0; x < ow; x++ {
			fg, bg := px[y*ow+x], px[(y+1)*ow+x]
			if first || fg != lastFg {
				fmt.Fprintf(s.out, "\x1b[38;2;%d;%d;%dm", fg[0], fg[1], fg[2])
			}
			if first || bg != lastBg {
				fmt.Fprintf(s.out, "\x1b[48;2;%d;%d;%dm", bg[0], bg[1], bg[2])
			}
			s.out.WriteString("▀")
			lastFg, lastBg, first = fg, bg, false
		}
		s.out.WriteString("\x1b[0m")
	}
}

// sample scales img to ow x oh by box averaging.
func sample(img *image.RGBA, ow, oh int) [][3]uint8 {
	fw, fh := img.Bounds().Dx(), img.Bounds().Dy()
	px := make([][3]uint8, ow*oh)
	for y := 0; y < oh; y++ {
		sy0, sy1 := y*fh/oh, (y+1)*fh/oh
		sy1 = min(max(sy1, sy0+1), fh)
		for x := 0; x < ow; x++ {
			sx0, sx1 := x*fw/ow, (x+1)*fw/ow
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
	return px
}

// palette: 6 levels of red, 7 of green, 6 of blue = 252 registers.
const palR, palG, palB = 6, 7, 6

func quantise(c [3]uint8) int {
	r := int(c[0]) * (palR - 1) / 255
	g := int(c[1]) * (palG - 1) / 255
	b := int(c[2]) * (palB - 1) / 255
	return (r*palG+g)*palB + b
}

// drawSixel scales the frame to the drawable pixel area and emits it as one
// sixel image at the top-left. Each six-row band is written colour by
// colour, only the colours the band uses, run-length encoded.
func (s *screenView) drawSixel(img *image.RGBA) {
	fw, fh := img.Bounds().Dx(), img.Bounds().Dy()
	areaW, areaH := s.cols*s.cellW, (s.rows-1)*s.cellH
	if fw == 0 || fh == 0 || areaW < 6 || areaH < 6 {
		return
	}
	scale := min(float64(areaW)/float64(fw), float64(areaH)/float64(fh))
	ow, oh := max(int(float64(fw)*scale), 1), max(int(float64(fh)*scale), 1)
	oh -= oh % 6
	if oh == 0 {
		return
	}
	px := sample(img, ow, oh)
	s.imgW, s.imgH = ow, oh
	s.offX, s.offY = 0, 0
	s.out.WriteString("\x1b[1;1H")
	writeSixel(s.out, px, ow, oh)
}

// writeSixel encodes px (ow x oh, oh a multiple of 6) as a sixel image with
// the fixed palette. Split out so a test can decode what it wrote.
func writeSixel(out *bufio.Writer, px [][3]uint8, ow, oh int) {
	// DCS q, raster 1:1, size, then the palette in percent
	fmt.Fprintf(out, "\x1bPq\"1;1;%d;%d", ow, oh)
	for r := 0; r < palR; r++ {
		for g := 0; g < palG; g++ {
			for b := 0; b < palB; b++ {
				fmt.Fprintf(out, "#%d;2;%d;%d;%d", (r*palG+g)*palB+b, r*100/(palR-1), g*100/(palG-1), b*100/(palB-1))
			}
		}
	}
	idx := make([]int, ow*oh)
	for i, c := range px {
		idx[i] = quantise(c)
	}
	var used [palR * palG * palB]bool
	col := make([]byte, ow)
	for band := 0; band < oh; band += 6 {
		for i := range used {
			used[i] = false
		}
		for y := band; y < band+6; y++ {
			for x := 0; x < ow; x++ {
				used[idx[y*ow+x]] = true
			}
		}
		for c := range used {
			if !used[c] {
				continue
			}
			// the six-bit column for this colour
			for x := 0; x < ow; x++ {
				var bits byte
				for dy := 0; dy < 6; dy++ {
					if idx[(band+dy)*ow+x] == c {
						bits |= 1 << dy
					}
				}
				col[x] = bits + 63
			}
			fmt.Fprintf(out, "#%d", c)
			for x := 0; x < ow; {
				run := 1
				for x+run < ow && col[x+run] == col[x] {
					run++
				}
				if run > 3 {
					fmt.Fprintf(out, "!%d", run)
					out.WriteByte(col[x])
				} else {
					for i := 0; i < run; i++ {
						out.WriteByte(col[x])
					}
				}
				x += run
			}
			out.WriteByte('$') // carriage return: next colour, same band
		}
		out.WriteByte('-') // next band
	}
	out.WriteString("\x1b\\")
}

// input decodes what the terminal sent: keys become keysyms, SGR mouse
// reports become pointer events, ctrl+] opens the menu. Returns true when
// the operator detached.
func (s *screenView) input(b []byte) bool {
	b = append(s.pending, b...)
	s.pending = nil
	for len(b) > 0 {
		n, quit := s.one(b)
		if n == 0 { // an incomplete sequence: wait for the rest
			s.pending = append([]byte{}, b...)
			return false
		}
		if quit {
			return true
		}
		b = b[n:]
	}
	return false
}

// one consumes one key or report from the front of b; 0 means incomplete.
func (s *screenView) one(b []byte) (int, bool) {
	r := s.r
	if s.menu {
		s.menu, s.dirty = false, true
		switch b[0] {
		case 'd', 'q':
			return len(b), true
		case 'x':
			r.key(ksControlL, true)
			r.key(ksAltL, true)
			r.tap(ksDelete)
			r.key(ksAltL, false)
			r.key(ksControlL, false)
		case 'r':
			s.out.WriteString("\x1b[2J")
			r.requestUpdate(false)
		case 0x1d:
			r.key(ksControlL, true)
			r.tap(']')
			r.key(ksControlL, false)
		}
		return 1, false
	}
	switch {
	case b[0] == 0x1d: // ctrl+]
		s.menu, s.dirty = true, true
		return 1, false
	case b[0] == 0x1b:
		if len(b) == 1 {
			// a lone escape: give the rest 0 bytes to arrive is not
			// possible here, so treat it as the Escape key
			r.tap(ksEscape)
			return 1, false
		}
		if b[1] == '[' || b[1] == 'O' {
			n, ok := s.csi(b)
			return n, ok
		}
		// alt + key
		n, _ := s.one(b[1:])
		if n == 0 {
			return 0, false
		}
		return 1 + n, false
	case b[0] == '\r':
		r.tap(ksReturn)
	case b[0] == '\t':
		r.tap(ksTab)
	case b[0] == 0x7f || b[0] == 0x08:
		r.tap(ksBackSpace)
	case b[0] < 0x20:
		ch := uint32(b[0]) + 'a' - 1
		switch b[0] {
		case 0:
			ch = ' '
		case 28:
			ch = '\\'
		case 30:
			ch = '^'
		case 31:
			ch = '_'
		}
		r.key(ksControlL, true)
		r.tap(ch)
		r.key(ksControlL, false)
	default:
		// a UTF-8 character
		str := string(b)
		for i, ch := range str {
			if ch == 0xfffd && i+4 > len(b) {
				return 0, false // incomplete multibyte character
			}
			r.tap(runeKeysym(ch))
			return len(string(ch)), false
		}
	}
	return 1, false
}

// csi decodes CSI sequences: cursor keys, editing keys, F keys and SGR
// mouse reports (CSI < b ; x ; y M|m).
func (s *screenView) csi(b []byte) (int, bool) {
	end := -1
	for i := 2; i < len(b); i++ {
		if b[i] >= 0x40 && b[i] <= 0x7e {
			end = i
			break
		}
	}
	if end < 0 {
		return 0, false
	}
	body, final := string(b[2:end]), b[end]
	r := s.r
	if b[1] == 'O' { // SS3: F1-F4, and cursor keys in application mode
		switch final {
		case 'P', 'Q', 'R', 'S':
			r.tap(ksF1 + uint32(final-'P'))
		case 'A', 'B', 'C', 'D':
			r.tap(map[byte]uint32{'A': ksUp, 'B': ksDown, 'C': ksRight, 'D': ksLeft}[final])
		case 'H':
			r.tap(ksHome)
		case 'F':
			r.tap(ksEnd)
		}
		return end + 1, false
	}
	if strings.HasPrefix(body, "<") {
		parts := strings.Split(body[1:], ";")
		if len(parts) == 3 {
			btn, _ := strconv.Atoi(parts[0])
			x, _ := strconv.Atoi(parts[1])
			y, _ := strconv.Atoi(parts[2])
			s.mouse(btn, x-1, y-1, final == 'M')
		}
		return end + 1, false
	}
	// modifiers (CSI 1;5A style) are dropped: the guest gets the plain key
	num := body
	if i := strings.IndexByte(body, ';'); i >= 0 {
		num = body[:i]
	}
	switch final {
	case 'A':
		r.tap(ksUp)
	case 'B':
		r.tap(ksDown)
	case 'C':
		r.tap(ksRight)
	case 'D':
		r.tap(ksLeft)
	case 'H':
		r.tap(ksHome)
	case 'F':
		r.tap(ksEnd)
	case 'Z':
		r.key(ksShiftL, true)
		r.tap(ksTab)
		r.key(ksShiftL, false)
	case '~':
		switch num {
		case "1", "7":
			r.tap(ksHome)
		case "2":
			r.tap(ksInsert)
		case "3":
			r.tap(ksDelete)
		case "4", "8":
			r.tap(ksEnd)
		case "5":
			r.tap(ksPageUp)
		case "6":
			r.tap(ksPageDown)
		case "15", "17", "18", "19", "20", "21", "23", "24":
			f := map[string]uint32{"15": 4, "17": 5, "18": 6, "19": 7, "20": 8, "21": 9, "23": 10, "24": 11}[num]
			r.tap(ksF1 + f)
		}
	case 'c', 't':
		// a late DA1 / cell-size reply: not a key
	}
	return end + 1, false
}

// mouse maps an SGR report onto the framebuffer. In sixel mode the image
// sits at the top-left at cellW x cellH per cell; in block mode each cell
// is one pixel wide and two tall.
func (s *screenView) mouse(btn, cx, cy int, press bool) {
	if s.imgW == 0 || s.fbW == 0 {
		return
	}
	var fx, fy int
	if s.sixel {
		fx = (cx * s.cellW) * s.fbW / s.imgW
		fy = (cy * s.cellH) * s.fbH / s.imgH
	} else {
		fx = (cx - s.offX) * s.fbW / s.imgW
		fy = (cy - s.offY) * 2 * s.fbH / (s.imgH * 2)
	}
	fx = min(max(fx, 0), s.fbW-1)
	fy = min(max(fy, 0), s.fbH-1)
	low := btn & 3
	motion := btn&32 != 0
	var bit uint8
	switch {
	case btn&64 != 0: // wheel: 64 up, 65 down
		if low == 0 {
			bit = 8
		} else {
			bit = 16
		}
		s.r.pointer(s.mask|bit, fx, fy)
		s.r.pointer(s.mask, fx, fy)
		return
	case low == 0:
		bit = 1
	case low == 1:
		bit = 2
	case low == 2:
		bit = 4
	}
	if !motion {
		if press {
			s.mask |= bit
		} else {
			s.mask &^= bit
		}
	}
	s.r.pointer(s.mask, fx, fy)
}
