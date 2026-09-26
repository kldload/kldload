package main

import (
	"image"
	"os"
	"testing"
	"time"
)

// TestRFBLive exercises the wire client against a real qemu display:
// KLD_VNC_LIVE=127.0.0.1:5900 names it. It taps Shift (harmless at any
// prompt, and it unblanks a Linux console) and then expects a frame with
// some non-black pixels within a few seconds. Skipped without the address.
func TestRFBLive(t *testing.T) {
	addr := os.Getenv("KLD_VNC_LIVE")
	if addr == "" {
		t.Skip("KLD_VNC_LIVE not set")
	}
	r, err := dialRFB(addr)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	r.tap(ksShiftL)
	deadline := time.Now().Add(8 * time.Second)
	var lit int
	var w, h int
	for time.Now().Before(deadline) {
		lit = 0
		r.withFrame(func(img *image.RGBA) {
			w, h = img.Bounds().Dx(), img.Bounds().Dy()
			for i := 0; i+3 < len(img.Pix); i += 4 {
				if img.Pix[i] > 16 || img.Pix[i+1] > 16 || img.Pix[i+2] > 16 {
					lit++
				}
			}
		})
		if lit > 0 {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Logf("%s: %dx%d, %d lit pixels, %d frames", addr, w, h, lit, r.frames.Load())
	if lit == 0 {
		t.Fatalf("no lit pixel in %dx%d after a Shift tap: the blit or the wake is wrong", w, h)
	}
	if err := r.Err(); err != nil {
		t.Fatal(err)
	}
}
