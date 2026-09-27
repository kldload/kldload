package main

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
)

// keysOf feeds b to screenView.one over a pipe and returns what it consumed
// and the keysyms it pressed (release events are dropped).
func keysOf(t *testing.T, b []byte) (int, []uint32) {
	t.Helper()
	c, peer := net.Pipe()
	got := make(chan []uint32)
	go func() {
		var syms []uint32
		msg := make([]byte, 8)
		for {
			if _, err := io.ReadFull(peer, msg); err != nil {
				got <- syms
				return
			}
			if msg[0] == 4 && msg[1] == 1 { // KeyEvent, down
				syms = append(syms, binary.BigEndian.Uint32(msg[4:8]))
			}
		}
	}()
	s := &screenView{r: &rfbConn{c: c, done: make(chan struct{})}}
	n, _ := s.one(b)
	_ = c.Close() // ends the reader; the pipe has no other error to report
	return n, <-got
}

// The UTF-8 branch of one(): a whole character is one key, a split one
// waits, and a bad byte is consumed alone. Before 2026-09-27 a bad byte in
// the last three of a read looked "incomplete" and was never consumed, so the
// keyboard stalled on it; further from the end it swallowed two more bytes.
func TestOneUTF8(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		n    int
		syms []uint32
	}{
		{"latin-1", []byte("é rest"), 2, []uint32{0xe9}},
		{"beyond latin-1", []byte("€"), 3, []uint32{0x01000000 + 0x20ac}},
		{"split character waits", []byte("€")[:2], 0, nil},
		{"invalid byte alone", []byte{0xff, 'a', 'b'}, 1, []uint32{0x01000000 + 0xfffd}},
	}
	for _, tc := range cases {
		n, syms := keysOf(t, tc.in)
		if n != tc.n || len(syms) != len(tc.syms) {
			t.Errorf("%s: consumed %d keys %x, want %d keys %x", tc.name, n, syms, tc.n, tc.syms)
			continue
		}
		for i := range syms {
			if syms[i] != tc.syms[i] {
				t.Errorf("%s: key %d = %x, want %x", tc.name, i, syms[i], tc.syms[i])
			}
		}
	}
}
