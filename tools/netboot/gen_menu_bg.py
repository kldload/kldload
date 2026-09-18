#!/usr/bin/env python3
"""Draw the netboot menu background: tools/netboot/gen_menu_bg.py OUT.png

The picture iPXE puts behind the armed-machine menu (kldload-netboot-server
_write_armed). iPXE cannot draw anything but 8x16 text, so the header, the
panel and the key hint live in this picture, and the menu text is confined to
the panel with `console --left/--right/--top/--bottom`. The geometry below and
NB_CONSOLE in kldload-netboot-server must agree: change one, change both.

Colours are the web UI's (free/css/app.css), so a machine booting over the
network looks like the same product as the page that armed it.

Needs Pillow and the Inter font (rsms-inter-fonts on Fedora). The PNG is
committed, so a build never runs this; it is here so the picture can be redrawn
rather than hand-edited:

    python3 tools/netboot/gen_menu_bg.py \
        live-build/config/includes.chroot/usr/share/kldload-netboot/menu.png
"""

import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1024, 768
# Text area handed to iPXE, in pixels from each edge. iPXE draws 9 x 19 px
# cells here (measured, 2026-09-18 -- not the 8 x 16 its font suggests), so
# 704 x 342 px = 78 x 18 cells: title on row 1, items from row 3, and
# LINES - 5 = 13 item rows (menu_ui.c MENU_ROWS) -- the install menu's seven
# profiles, live, local, shell and its gaps, plus one armed profile outside
# the seven.
LEFT, RIGHT, TOP, BOTTOM = 160, 160, 236, 190
BG = "#0c0e14"
CARD = "#161a24"
BORDER = "#283040"
ACCENT = "#326ce5"
BRIGHT = "#f0f4fa"
DIM = "#5a6a85"
FONT = "/usr/share/fonts/rsms-inter-fonts/Inter-SemiBold.ttf"
FONT_REG = "/usr/share/fonts/rsms-inter-fonts/Inter-Regular.ttf"


def main(out: str) -> None:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    word = ImageFont.truetype(FONT, 54)
    sub = ImageFont.truetype(FONT_REG, 20)
    hint = ImageFont.truetype(FONT_REG, 16)

    d.text((LEFT - 8, 84), "kldload", font=word, fill=BRIGHT)
    d.rectangle((LEFT - 8, 164, LEFT + 56, 167), fill=ACCENT)
    d.text((LEFT - 8, 178), "network boot", font=sub, fill=DIM)

    # The panel sits 16 px outside the text area on every side.
    d.rounded_rectangle(
        (LEFT - 16, TOP - 16, W - RIGHT + 16, H - BOTTOM + 16),
        radius=10, fill=CARD, outline=BORDER, width=1,
    )
    d.text(
        (LEFT - 8, H - BOTTOM + 40),
        "Up/Down  choose      Enter  select      Esc  back, then local disk",
        font=hint, fill=DIM,
    )
    img.save(out, optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: gen_menu_bg.py OUT.png\n")
        sys.exit(2)
    main(sys.argv[1])
