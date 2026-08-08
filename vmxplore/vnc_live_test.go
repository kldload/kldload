//go:build gui

// vnc_live_test.go — RFB client smoke against a real qemu VNC server.
// Skips unless a running domain with a live VNC display exists, so plain
// `go test` on a dev box stays green; on a host with a running guest it
// proves the handshake, pixel-format negotiation and first framebuffer.
package main

import (
	"fmt"
	"testing"
	"time"
)

func TestRFBLiveFramebuffer(t *testing.T) {
	lv, err := ConnectSystem()
	if err != nil {
		t.Skipf("no libvirt: %v", err)
	}
	defer lv.Close()
	doms, err := lv.Estate()
	if err != nil {
		t.Skipf("estate: %v", err)
	}
	port := 0
	name := ""
	for _, d := range doms {
		if d.State != "running" {
			continue
		}
		if p, err := vncPort(lv, d.Name); err == nil {
			port, name = p, d.Name
			break
		}
	}
	if port == 0 {
		t.Skip("no running domain with a live VNC display")
	}

	conn, err := dialRFB(fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dial %s: %v", name, err)
	}
	defer conn.Close()
	if conn.fbW <= 0 || conn.fbH <= 0 {
		t.Fatalf("bad framebuffer size %dx%d", conn.fbW, conn.fbH)
	}

	frames := make(chan struct{}, 1)
	conn.onFrame = func() {
		select {
		case frames <- struct{}{}:
		default:
		}
	}
	select {
	case <-frames:
	case <-time.After(5 * time.Second):
		t.Fatal("no framebuffer update within 5s")
	}
	// a real frame has non-zero pixels somewhere (the guest paints
	// SOMETHING — even a boot console has text)
	conn.imgMu.Lock()
	nonZero := false
	for _, px := range conn.img.Pix {
		if px != 0 && px != 0xff { // skip bare alpha
			nonZero = true
			break
		}
	}
	conn.imgMu.Unlock()
	t.Logf("%s: %dx%d framebuffer, non-zero pixels: %v", name, conn.fbW, conn.fbH, nonZero)
}
