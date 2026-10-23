#!/usr/bin/env python3
"""Generate a flicker spritesheet from the static transmitter glow sprite.

Reads graphics/entity/transmitter-glow.png (500x364) and produces
transmitter-glow-flicker-{1..4}.png, 4 files of 6 frames each (24 frames,
3000x364 per file). Each frame applies a whole-sprite brightness pulse
(two sine harmonics) so the emissive parts of the structure appear to
flicker. The loop is seamless: every sine completes an integer number of
cycles across the 24 frames.

Usage: python3 tools/make_glow_flicker.py
"""

import math
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "space-power-transmitter/graphics/entity/transmitter-glow.png"

FRAMES_PER_FILE = 6
FILE_COUNT = 4
FRAME_COUNT = FRAMES_PER_FILE * FILE_COUNT

# brightness pulse: base level + two harmonics (slow breath + fast shimmer)
BASE_LEVEL = 0.74
HARMONICS = ((1, 0.18, 0.0), (2, 0.08, 1.3))  # (cycles over loop, amplitude, phase)


def brightness(frame):
    m = BASE_LEVEL
    for cycles, amplitude, phase in HARMONICS:
        m += amplitude * math.sin(2 * math.pi * cycles * frame / FRAME_COUNT + phase)
    return max(0.0, min(1.0, m))


def main():
    base = Image.open(SRC).convert("RGBA")
    width, height = base.size
    r, g, b, a = base.split()

    for file_index in range(FILE_COUNT):
        sheet = Image.new("RGBA", (width * FRAMES_PER_FILE, height), (0, 0, 0, 0))
        for column in range(FRAMES_PER_FILE):
            frame = file_index * FRAMES_PER_FILE + column
            level = round(255 * brightness(frame))
            flat = Image.new("L", (width, height), level)
            frame_img = Image.merge(
                "RGBA",
                (
                    ImageChops.multiply(r, flat),
                    ImageChops.multiply(g, flat),
                    ImageChops.multiply(b, flat),
                    a,
                ),
            )
            sheet.paste(frame_img, (column * width, 0))
        dst = ROOT / "space-power-transmitter/graphics/entity" / f"transmitter-glow-flicker-{file_index + 1}.png"
        sheet.save(dst)
        print(f"wrote {dst} ({sheet.size[0]}x{sheet.size[1]}, {FRAMES_PER_FILE} frames)")


if __name__ == "__main__":
    main()
