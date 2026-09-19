#!/usr/bin/env python3
"""Render the intro to a video, frame by frame: tools/intro/render.py [options]

What it does, in order:
  1. serves free/intro/ on 127.0.0.1 and accepts POST /frame?i=N (a PNG) and
     POST /done?frames=N from the page;
  2. runs headless Chrome on the page with ?render&fps=..&aa=.. at the given
     size, on the GPU (ANGLE over EGL -- headless Chrome on onyx gets the RTX
     3080 this way; the default is SwiftShader, which is software);
  3. checks the frame count it was sent against what the page said it sent,
     and every frame index in between;
  4. encodes the PNGs with ffmpeg to H.264 High, yuv420p, in MP4.

Why: a screen capture drops frames and records the pointer; a render cannot.
The page draws frame i at exactly i/fps seconds, so the video is the same
however long any single frame takes to draw.

Exit: 0 video written and checked, 1 render or encode failed, 2 usage.
"""

import argparse
import http.server
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse

REPO = pathlib.Path(__file__).resolve().parents[2]
PAGE_DIR = REPO / "live-build/config/includes.chroot/usr/local/share/kldload-webui/free/intro"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="output .mp4")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--aa", type=int, default=2, help="N x N samples per pixel")
    ap.add_argument("--crf", type=int, default=14, help="x264 quality; lower is better")
    ap.add_argument("--keep-frames", action="store_true")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds for the whole render")
    a = ap.parse_args()

    for tool in ("google-chrome", "ffmpeg"):
        if not shutil.which(tool):
            print(f"render: {tool} is not on PATH", file=sys.stderr)
            return 1
    # Frames go under $HOME, not /tmp: on onyx /tmp is noexec and small.
    cache = os.path.expanduser("~/.cache")
    frames = pathlib.Path(tempfile.mkdtemp(prefix="intro-frames-", dir=cache))
    got: set[int] = set()
    sent = {"n": -1}
    done = threading.Event()

    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kw):  # type: ignore[no-untyped-def]
            super().__init__(*args, directory=str(PAGE_DIR), **kw)

        def log_message(self, *args):  # type: ignore[no-untyped-def]
            pass

        def do_POST(self) -> None:
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if u.path == "/frame":
                i = int(q["i"][0])
                (frames / f"f{i:06d}.png").write_bytes(body)
                got.add(i)
                if i % 60 == 0:
                    print(f"render: frame {i}", file=sys.stderr, flush=True)
            elif u.path == "/done":
                sent["n"] = int(q["frames"][0])
                done.set()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    if a.width % 2 or a.height % 2:
        print("render: width and height must be even (H.264 4:2:0)", file=sys.stderr)
        return 2
    url = f"http://127.0.0.1:{port}/index.html?render&fps={a.fps}&aa={a.aa}&w={a.width}&h={a.height}"
    profile = tempfile.mkdtemp(prefix="intro-chrome-", dir=os.path.expanduser("~/.cache"))
    chrome = subprocess.Popen(
        ["google-chrome", "--headless=new", "--use-angle=gl-egl", "--enable-gpu",
         "--ignore-gpu-blocklist", f"--user-data-dir={profile}",
         f"--window-size={a.width},{a.height}", "--hide-scrollbars", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not done.wait(a.timeout):
            print(f"render: timed out after {a.timeout}s with {len(got)} frames", file=sys.stderr)
            return 1
    finally:
        chrome.terminate()
        chrome.wait(10)
        srv.shutdown()
        shutil.rmtree(profile, ignore_errors=True)

    # A count is not a result: every index the page claims to have sent must be on disk.
    missing = [i for i in range(sent["n"]) if i not in got]
    if sent["n"] <= 0 or missing:
        print(f"render: page reported {sent['n']} frames, missing {len(missing)} "
              f"(first: {missing[:5]})", file=sys.stderr)
        return 1
    with open(frames / "f000000.png", "rb") as f:   # PNG IHDR: width, height at bytes 16..24
        head = f.read(24)
    fw, fh = int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    if (fw, fh) != (a.width, a.height):
        print(f"render: frames are {fw}x{fh}, asked for {a.width}x{a.height}", file=sys.stderr)
        return 1
    print(f"render: {sent['n']} frames at {a.width}x{a.height}, aa {a.aa}", file=sys.stderr)

    enc = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(a.fps),
         "-i", str(frames / "f%06d.png"), "-c:v", "libx264", "-profile:v", "high",
         "-preset", "slow", "-crf", str(a.crf), "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", a.out])
    if enc.returncode != 0:
        print(f"render: ffmpeg exited {enc.returncode}; frames kept in {frames}", file=sys.stderr)
        return 1
    if a.keep_frames:
        print(f"render: frames kept in {frames}", file=sys.stderr)
    else:
        shutil.rmtree(frames, ignore_errors=True)
    print(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
