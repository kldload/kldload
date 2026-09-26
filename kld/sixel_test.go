package main

import (
	"bufio"
	"bytes"
	"strconv"
	"strings"
	"testing"
)

// TestSixelRoundTrip decodes what writeSixel emits with a small decoder of
// its own and expects every pixel back in its palette colour: a wrong run
// length, a band that forgot its carriage return or a palette index off
// by one all come back as a mismatch, not as a plausible picture.
func TestSixelRoundTrip(t *testing.T) {
	ow, oh := 37, 18 // odd width so runs end mid-image; 3 bands
	px := make([][3]uint8, ow*oh)
	for y := 0; y < oh; y++ {
		for x := 0; x < ow; x++ {
			px[y*ow+x] = [3]uint8{uint8(x * 7), uint8(y * 14), uint8((x * y) % 256)}
		}
	}
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)
	writeSixel(w, px, ow, oh)
	w.Flush()
	s := buf.String()
	if !strings.HasPrefix(s, "\x1bPq\"1;1;37;18") || !strings.HasSuffix(s, "\x1b\\") {
		t.Fatalf("framing: %q … %q", s[:20], s[len(s)-4:])
	}
	// decode: palette definitions, then per band #c<runs>$ … -
	got := make([]int, ow*oh)
	for i := range got {
		got[i] = -1
	}
	body := s[strings.Index(s, ";18")+3 : len(s)-2]
	band, x, colour := 0, 0, -1
	for i := 0; i < len(body); {
		c := body[i]
		switch {
		case c == '#':
			j := i + 1
			for j < len(body) && body[j] >= '0' && body[j] <= '9' {
				j++
			}
			n, _ := strconv.Atoi(body[i+1 : j])
			if j < len(body) && body[j] == ';' { // a palette definition
				for j < len(body) && body[j] != '#' && body[j] != '!' && body[j] != '$' && body[j] != '-' && (body[j] < '?' || body[j] > '~') {
					j++
				}
			} else {
				colour, x = n, 0
			}
			i = j
		case c == '!':
			j := i + 1
			for body[j] >= '0' && body[j] <= '9' {
				j++
			}
			run, _ := strconv.Atoi(body[i+1 : j])
			put(got, ow, band, &x, body[j], colour, run, t)
			i = j + 1
		case c == '$':
			x = 0
			i++
		case c == '-':
			band++
			x = 0
			i++
		case c >= '?' && c <= '~':
			put(got, ow, band, &x, c, colour, 1, t)
			i++
		default:
			t.Fatalf("unexpected byte %q at %d", c, i)
		}
	}
	bad := 0
	for i, c := range px {
		if got[i] != quantise(c) {
			bad++
		}
	}
	if bad > 0 {
		t.Fatalf("%d of %d pixels decoded to the wrong colour", bad, len(px))
	}
	t.Logf("%d pixels, %d bytes of sixel", len(px), len(s))
}

func put(got []int, ow, band int, x *int, ch byte, colour, run int, t *testing.T) {
	bits := int(ch) - 63
	for r := 0; r < run; r++ {
		if *x >= ow {
			t.Fatalf("run past the row at band %d", band)
		}
		for dy := 0; dy < 6; dy++ {
			if bits&(1<<dy) != 0 {
				got[(band*6+dy)*ow+*x] = colour
			}
		}
		*x++
	}
}
