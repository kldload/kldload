#!/usr/bin/env python3
"""Write a fully transparent Xcursor theme: gen_blank_cursor.py THEME_DIR

The two kiosks (kldload-install-kiosk, part 1 of the show; kldload-firstboot-show
kiosk, part 2) run cage, and cage draws its own pointer until a client sets one.
A client only sets one when the pointer ENTERS it, which on a machine nobody
touches never happens, so the default arrow sat in the middle of the screen for
the whole recorded install (fiend, 2026-09-18). cage 0.3.1 has no option to hide
it. The kiosks point XCURSOR_PATH at this theme instead, and every name in it is
an empty 24x24 and 48x48 image.

Output: THEME_DIR/default/index.theme and THEME_DIR/default/cursors/<name>. The
theme is named "default" because that is the name libxcursor loads when the
compositor asks for no theme in particular. The files are committed; this
exists so they can be regenerated instead of hand-edited:

    python3 tools/cursor/gen_blank_cursor.py \\
        live-build/config/includes.chroot/usr/share/kldload/blank-cursor

Xcursor format: libXcursor's Xcursor.h (file header, table of contents, one
image chunk per size, ARGB32 pixels).
"""

import os
import struct
import sys

MAGIC = 0x72756358  # "Xcur"
FILE_VERSION = 0x10000
IMAGE_TYPE = 0xFFFD0002
IMAGE_VERSION = 1
SIZES = (24, 48)
# The names wlroots/cage and common toolkits ask for. Every one is the same
# empty image, so whatever cage requests, nothing is drawn.
NAMES = ("default", "left_ptr", "arrow", "top_left_arrow", "pointer", "text", "xterm")


def blank_cursor() -> bytes:
    header_len, toc_len, chunk_header = 16, 12, 36
    body = b""
    toc = b""
    pos = header_len + toc_len * len(SIZES)
    for size in SIZES:
        chunk = struct.pack("<9I", chunk_header, IMAGE_TYPE, size, IMAGE_VERSION,
                            size, size, 0, 0, 0)
        chunk += b"\x00\x00\x00\x00" * size * size
        toc += struct.pack("<3I", IMAGE_TYPE, size, pos)
        body += chunk
        pos += len(chunk)
    return struct.pack("<4I", MAGIC, header_len, FILE_VERSION, len(SIZES)) + toc + body


def main(theme_dir: str) -> None:
    cursors = os.path.join(theme_dir, "default", "cursors")
    os.makedirs(cursors, exist_ok=True)
    with open(os.path.join(theme_dir, "default", "index.theme"), "w") as f:
        f.write("[Icon Theme]\nName=kldload blank pointer\n"
                "Comment=Transparent pointer for the kldload kiosks\n")
    data = blank_cursor()
    for name in NAMES:
        with open(os.path.join(cursors, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: gen_blank_cursor.py THEME_DIR\n")
        sys.exit(2)
    main(sys.argv[1])
