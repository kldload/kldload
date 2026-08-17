#!/usr/bin/env python3
"""annotate-shot.py — put callouts on a product screenshot.

What it does, in order:
  1. Loads a screenshot and scales the annotation geometry to its width, so a
     1920px capture and a 2560px one get proportionate boxes, not boxes that
     look right on one and wrong on the other.
  2. Draws a rounded callout for each annotation, with a leader line from the
     box to the point it describes.
  3. Optionally dims everything outside a focus rectangle, which is how you
     say "look here" without cropping away the context that makes the shot
     worth showing.

WHY: the screenshots are the only evidence on the site that any of this
exists, and an unlabelled console is a wall of text to anyone who has not
used it. A callout turns "here is a dense UI" into "here is the estate, and
that is the zvol backing it".

Callouts are baked into the PNG deliberately. The site can overlay HTML
instead — crisper, themeable, editable — but an image that travels alone
into a README, a forum post or a PDF carries no CSS with it, and an
unlabelled screenshot in those places is worth very little.

Inputs:  a PNG, plus annotations as JSON (see --help for the shape).
Outputs: a new PNG. The source is never modified.

Notes:
  - Colours default to the console family's palette so an annotated shot
    still looks like the product rather than like a bug report.
  - Text is measured before the box is drawn, so a long label grows its box
    instead of overflowing it.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from PIL import Image, ImageDraw, ImageFont

# The console family's palette. Accent for the box, near-black for the ground,
# so a callout reads as part of the product.
ACCENT = (63, 142, 214, 255)      # OpenZFS blue — matches ztxplore/zxplore
GREEN = (76, 195, 138, 255)       # the pulse green
GOLD = (224, 168, 60, 255)
INK = (12, 15, 20, 240)           # box fill, slightly transparent
TEXT = (238, 244, 250, 255)

FONT_CANDIDATES = [
    "/usr/share/fonts/liberation-sans-fonts/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def _font(size: int) -> ImageFont.FreeTypeFont:
    """Load a bold sans face, falling back to PIL's bitmap font.

    The fallback is deliberately ugly: a missing font should be obvious in the
    output rather than silently producing a shot nobody can read at 4K.
    """
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _wrap(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont,
          max_w: int) -> list[str]:
    """Greedy wrap by measured width, not character count.

    Character counts lie for proportional faces — 'Illinois' and 'WWWWWWWW'
    are the same length and nowhere near the same width.
    """
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if draw.textlength(trial, font=font) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def annotate(src: str, dst: str, notes: list[dict[str, Any]],
             focus: list[int] | None = None, scale_ref: int = 1920) -> None:
    """Draw callouts onto a screenshot.

    Args:
        src:   input PNG path.
        dst:   output PNG path. Never the same as src.
        notes: each {"text", "at":[x,y], "box":[x,y], "colour":"accent|green|gold"}
               where `at` is the point being described and `box` is the
               callout's top-left. Coordinates are in the source image's pixels.
        focus: optional [x,y,w,h] to keep bright while the rest dims.
        scale_ref: width the geometry was authored against.

    Returns: None. Writes dst.
    """
    im = Image.open(src).convert("RGBA")
    W, H = im.size
    k = W / scale_ref  # geometry scales with the capture

    if focus:
        # Dim outside the focus rect rather than cropping: the surrounding
        # context is usually why the shot is interesting.
        shade = Image.new("RGBA", im.size, (0, 0, 0, 130))
        d = ImageDraw.Draw(shade)
        x, y, w, h = (int(v * k) for v in focus)
        d.rectangle([x, y, x + w, y + h], fill=(0, 0, 0, 0))
        im = Image.alpha_composite(im, shade)

    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = _font(max(13, int(19 * k)))
    pad = int(14 * k)
    maxw = int(330 * k)

    palette = {"accent": ACCENT, "green": GREEN, "gold": GOLD}

    for n in notes:
        colour = palette.get(n.get("colour", "accent"), ACCENT)
        bx, by = (int(v * k) for v in n["box"])
        lines = _wrap(draw, n["text"], font, maxw)
        lh = int(font.size * 1.42)
        tw = max(int(draw.textlength(ln, font=font)) for ln in lines)
        bw, bh = tw + pad * 2, lh * len(lines) + pad * 2

        # Leader first, so the box paints over its own tail.
        if "at" in n:
            ax, ay = (int(v * k) for v in n["at"])
            cx = bx + bw // 2
            cy = by + bh // 2
            draw.line([(cx, cy), (ax, ay)], fill=colour, width=max(2, int(3 * k)))
            r = max(4, int(7 * k))
            draw.ellipse([ax - r, ay - r, ax + r, ay + r], fill=colour)

        draw.rounded_rectangle([bx, by, bx + bw, by + bh],
                               radius=int(9 * k), fill=INK, outline=colour,
                               width=max(2, int(3 * k)))
        for i, ln in enumerate(lines):
            draw.text((bx + pad, by + pad + i * lh), ln, font=font, fill=TEXT)

    Image.alpha_composite(im, layer).convert("RGB").save(dst, quality=95)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Draw callouts on a screenshot.",
        epilog='notes JSON: [{"text":"...","at":[x,y],"box":[x,y],'
               '"colour":"accent|green|gold"}]')
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--notes", required=True, help="JSON list, or @file.json")
    ap.add_argument("--focus", help="x,y,w,h to keep bright")
    args = ap.parse_args()

    raw = args.notes
    if raw.startswith("@"):
        raw = open(raw[1:]).read()
    notes = json.loads(raw)
    focus = [int(v) for v in args.focus.split(",")] if args.focus else None

    annotate(args.src, args.dst, notes, focus)
    print(f"wrote {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
