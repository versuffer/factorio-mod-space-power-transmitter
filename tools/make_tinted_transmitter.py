#!/usr/bin/env python3
"""Bake the hull color and the glow overlay into a single transmitter texture.

The engine multiply-tint colors the whole sprite, glowing parts included.
This script bakes the coloring per-pixel instead:
  - bright (emissive) pixels keep their original color - they must not be
    painted blue;
  - hull pixels get the cool blue cast.
The bright-pixel mask is the luminance of the original sprite (the glow
image marks the same areas). The prototype keeps no tint on the base layer.

Usage: python3 tools/make_tinted_transmitter.py
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ENTITY = ROOT / "space-power-transmitter/graphics/entity"
SRC = ENTITY / "transmitter.png"
DST = ENTITY / "transmitter-tinted.png"

# the cool blue cast baked into the hull (the emissive parts keep their color)
TINT = (0.45, 0.62, 0.82)
# emissive pixels are dimmed by this factor before being kept
GLOW_DIM = 0.85
# luminance range over which a pixel fades from hull to emissive
MASK_LOW = 170
MASK_HIGH = 220


def smoothstep(v, low, high):
    if v <= low:
        return 0.0
    if v >= high:
        return 1.0
    t = (v - low) / (high - low)
    return t * t * (3 - 2 * t)


def main():
    hull = Image.open(SRC).convert("RGBA")
    r, g, b, a = hull.split()

    tinted = Image.merge(
        "RGBA",
        (
            r.point(lambda v: round(v * TINT[0])),
            g.point(lambda v: round(v * TINT[1])),
            b.point(lambda v: round(v * TINT[2])),
            a,
        ),
    )

    # emissive mask from the original's luminance (grayscale matrix convert)
    lum = hull.convert("L")
    mask = Image.eval(lum, lambda v: round(255 * smoothstep(v, MASK_LOW, MASK_HIGH)))

    # keep the emissive pixels, but dimmed: their original color scaled down
    dimmed = Image.merge(
        "RGBA",
        (
            r.point(lambda v: round(v * GLOW_DIM)),
            g.point(lambda v: round(v * GLOW_DIM)),
            b.point(lambda v: round(v * GLOW_DIM)),
            a,
        ),
    )
    result = Image.composite(dimmed, tinted, mask)
    result.save(DST)
    print(f"wrote {DST} ({result.size[0]}x{result.size[1]})")


if __name__ == "__main__":
    main()
