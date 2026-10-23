#!/usr/bin/env python3
"""Generate an animated beam spritesheet from the static beam sprite.

Reads graphics/entity/transmitter-beam.png (500x1455) and produces
transmitter-beam-anim-{1..4}.png, 4 files of 6 frames each (24 frames,
3000xH per file). The column region (above the emitter ring art) is
stretched so the beam reaches BEAM_HEIGHT_FACTOR times as high; the ring
stays 1:1 so the beam base stays attached to the structure. Each frame
modulates brightness with sine ripples that travel upward, so the beam
appears to carry energy toward the sky. The loop is seamless: every sine
completes an integer number of cycles across the 24 frames.

Prints the sprite parameters (height, shift) the prototype must use.

Usage: python3 tools/make_beam_animation.py
"""

import math
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "space-power-transmitter/graphics/entity/transmitter-beam.png"

FRAMES_PER_FILE = 6
FILE_COUNT = 4
FRAME_COUNT = FRAMES_PER_FILE * FILE_COUNT

# the beam reaches this many times as high (the sheet top is the reference)
BEAM_HEIGHT_FACTOR = 3.0
# the emitter ring art spans these rows in the 500x1455 source (measured)
SOURCE_RING_TOP = 1161
SOURCE_RING_BOTTOM = 1444
# world y (px, entity-relative, scale included) of the ring art center in the
# current prototype: shift -293 + (1302.5 - 727.5) * 0.5
RING_CENTER_WORLD = -5.5

# ripple 1: slow, wide bands
WAVE1_LENGTH = 210
WAVE1_AMPLITUDE = 0.14
WAVE1_CYCLES = 1
# ripple 2: fast, narrow bands
WAVE2_LENGTH = 85
WAVE2_AMPLITUDE = 0.07
WAVE2_CYCLES = 2


def brightness_map(height, width, frame):
    """Vertical brightness multiplier map for one frame, values in [1-a..1]."""
    rows = []
    for y in range(height):
        phase1 = 2 * math.pi * (y / WAVE1_LENGTH + WAVE1_CYCLES * frame / FRAME_COUNT)
        phase2 = 2 * math.pi * (y / WAVE2_LENGTH + WAVE2_CYCLES * frame / FRAME_COUNT + 0.35)
        m = 1.0 - WAVE1_AMPLITUDE * (0.5 + 0.5 * math.sin(phase1))
        m -= WAVE2_AMPLITUDE * (0.5 + 0.5 * math.sin(phase2))
        rows.append(max(0, min(255, round(255 * m))))
    strip = Image.new("L", (1, height))
    strip.putdata(rows)
    return strip.resize((width, height))


def main():
    base = Image.open(SRC).convert("RGBA")
    width, height = base.size

    # split the source into column and ring; stretch the column so the sheet
    # top lands at BEAM_HEIGHT_FACTOR times the current height
    ring = base.crop((0, SOURCE_RING_TOP, width, height))
    column = base.crop((0, 0, width, SOURCE_RING_TOP))
    source_ring_center = (SOURCE_RING_TOP + SOURCE_RING_BOTTOM) / 2
    source_top_world = RING_CENTER_WORLD + (0 - source_ring_center) * 0.5
    target_top_world = source_top_world * BEAM_HEIGHT_FACTOR

    # new sheet: the ring pasted 1:1 at the bottom (column_length rows above it);
    # pin the ring at its world spot and put the top at the target:
    #   shift + (ring_center_sheet - H/2) * 0.5 = RING_CENTER_WORLD
    #   shift - H/4 = target_top_world
    ring_center_in_ring = (ring.size[1] - 1) / 2
    ring_center_sheet = (RING_CENTER_WORLD - target_top_world) * 2
    column_length = round(ring_center_sheet - ring_center_in_ring)
    frame_height = column_length + ring.size[1]
    shift_y = target_top_world + frame_height / 4

    frame = Image.new("RGBA", (width, frame_height), (0, 0, 0, 0))
    frame.paste(column.resize((width, column_length)), (0, 0))
    frame.paste(ring, (0, column_length))
    fr, fg, fb, fa = frame.split()

    for file_index in range(FILE_COUNT):
        sheet = Image.new("RGBA", (width * FRAMES_PER_FILE, frame_height), (0, 0, 0, 0))
        for column_index in range(FRAMES_PER_FILE):
            frame_no = file_index * FRAMES_PER_FILE + column_index
            f = brightness_map(frame_height, width, frame_no)
            frame_img = Image.merge(
                "RGBA",
                (
                    ImageChops.multiply(fr, f),
                    ImageChops.multiply(fg, f),
                    ImageChops.multiply(fb, f),
                    fa,
                ),
            )
            sheet.paste(frame_img, (column_index * width, 0))
        dst = ROOT / "space-power-transmitter/graphics/entity" / f"transmitter-beam-anim-{file_index + 1}.png"
        sheet.save(dst)
        print(f"wrote {dst} ({sheet.size[0]}x{sheet.size[1]}, {FRAMES_PER_FILE} frames)")

    print(f"prototype: height = {frame_height}, shift = util.by_pixel(42, {round(shift_y)})")


if __name__ == "__main__":
    main()
