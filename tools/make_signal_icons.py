#!/usr/bin/env python3
"""Bake the circuit status signal icons for the transmitter link states.

Each icon is the dimmed grayscale transmitter silhouette with a colored
status badge in the bottom-right corner (the same traffic-light colors as
the beam/alert language of the mod):
  spt-link-up       green  badge, up arrow   - the link is healthy;
  spt-link-failing  yellow badge, exclamation - starving, the link will drop soon.
When neither signal is present the link is down.

Usage: python3 tools/make_signal_icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "space-power-transmitter/graphics/icons"
SRC = ICONS / "space-power-transmitter.png"

SIZE = 64
BADGE_CENTER = (44, 44)
BADGE_RADIUS = 15
OUTLINE = (28, 32, 38, 255)
BADGE_OUTLINE_WIDTH = 3

# badge fill colors (close to the vanilla signal palette)
GREEN = (87, 202, 87, 255)
YELLOW = (222, 189, 63, 255)
# glyph color on the badge
GLYPH = (24, 28, 33, 255)


def dimmed_silhouette():
    src = Image.open(SRC).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)
    px = src.load()
    for y in range(SIZE):
        for x in range(SIZE):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            lum = int(0.3 * r + 0.59 * g + 0.11 * b)
            px[x, y] = (lum, lum, lum, a)
    return src


def draw_up_arrow(draw, cx, cy, color):
    # shaft + head as one filled arrow
    w = 4  # shaft half-width
    head = 9  # head half-width
    draw.polygon(
        [(cx - head, cy - 3), (cx, cy - 12), (cx + head, cy - 3), (cx + w, cy - 3),
         (cx + w, cy + 10), (cx - w, cy + 10), (cx - w, cy - 3)],
        fill=color,
    )


def draw_exclamation(draw, cx, cy, color):
    draw.rectangle([cx - 3, cy - 12, cx + 3, cy + 3], fill=color)
    draw.ellipse([cx - 3, cy + 7, cx + 3, cy + 13], fill=color)


def make_icon(name, badge_color, glyph):
    image = dimmed_silhouette()
    # halo ring under the badge so it reads on any background
    halo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    cx, cy = BADGE_CENTER
    r = BADGE_RADIUS + BADGE_OUTLINE_WIDTH
    halo_draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=OUTLINE)
    image = Image.alpha_composite(halo, image)

    draw = ImageDraw.Draw(image)
    draw.ellipse(
        [cx - BADGE_RADIUS, cy - BADGE_RADIUS, cx + BADGE_RADIUS, cy + BADGE_RADIUS],
        fill=badge_color,
    )
    glyph(draw, cx, cy - 1, GLYPH)

    target = ICONS / f"{name}.png"
    image.save(target)
    print(f"wrote {target}")


def main():
    make_icon("spt-link-up", GREEN, draw_up_arrow)
    make_icon("spt-link-failing", YELLOW, draw_exclamation)


if __name__ == "__main__":
    main()
