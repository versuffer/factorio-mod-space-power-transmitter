#!/usr/bin/env python3
"""Sharpen the transmitter shadow.

The source shadow has a soft falloff. This script crispens its edges:
an unsharp mask on the alpha channel plus a contrast curve that pushes
mid-tone alpha toward the solid core / clean cutoff. The original file
stays untouched as the source.

Usage: python3 tools/make_sharp_shadow.py
"""

from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ENTITY = ROOT / "space-power-transmitter/graphics/entity"
SRC = ENTITY / "transmitter-shadow.png"
DST = ENTITY / "transmitter-shadow-sharp.png"

CONTRAST = 1.6
MIDPOINT = 110


def main():
    shadow = Image.open(SRC).convert("RGBA")
    r, g, b, a = shadow.split()

    a = a.filter(ImageFilter.UnsharpMask(radius=2, percent=120, threshold=2))
    a = a.point(lambda v: max(0, min(255, round((v - MIDPOINT) * CONTRAST + MIDPOINT))))

    Image.merge("RGBA", (r, g, b, a)).save(DST)
    print(f"wrote {DST}")


if __name__ == "__main__":
    main()
