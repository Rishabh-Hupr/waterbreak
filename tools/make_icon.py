#!/usr/bin/env python3
"""Draws WaterBreak's app icon as pixel art and writes the PNGs for `iconutil`.

Procedural, matching how the break scene itself is drawn: no binary assets in the
repo, and the design is editable as code. Zero dependencies — PNG encoding is a
few lines of `zlib` and `struct`, so this needs no Python packages.

The colours are lifted from `Palette` in `Sources/WaterBreak/PixelCanvas.swift` on
purpose, so the icon and the overlay it opens look like the same product. If that
palette changes, change it here too.

Authored on a small grid and upscaled nearest-neighbour, so pixels stay hard-edged
at every size. Two drawings: below 32 px the highlight and the ripples turn to
mud, so the small icon is a plainer droplet.
"""
import math
import os
import struct
import sys
import zlib

# --- palette (mirrors Palette in PixelCanvas.swift) -------------------------
TRANSPARENT = None
NIGHT = (20, 38, 74)          # outline
WATER = (48, 138, 200)        # droplet body
WATER_LIGHT = (96, 194, 232)  # lit left face
FOAM = (198, 240, 252)        # specular highlight
GLASS_SHINE = (226, 248, 255) # ripple lines


def blank(size):
    return [[TRANSPARENT for _ in range(size)] for _ in range(size)]


def put(px, x, y, colour):
    if 0 <= y < len(px) and 0 <= x < len(px):
        px[y][x] = colour


def droplet_mask(size, cx, cy, radius, tip_y):
    """Which pixels are inside a teardrop: a circle plus a cone up to the tip.

    Built as a set rather than drawn directly so the outline can be derived from
    it afterwards — an outline is just "inside, with an outside neighbour", which
    is far more reliable than trying to draw a teardrop border by hand.
    """
    inside = set()
    for y in range(size):
        for x in range(size):
            # Sample at pixel centres, or the shape sits half a pixel off.
            fx, fy = x + 0.5, y + 0.5
            if math.hypot(fx - cx, fy - cy) <= radius:
                inside.add((x, y))
                continue
            # The taper: above the circle's centre the half-width shrinks
            # linearly to nothing at the tip, giving the classic droplet point.
            if tip_y <= fy <= cy:
                progress = (fy - tip_y) / (cy - tip_y)
                # Exponent **below** 1 so the width climbs steeply away from the
                # tip and the sides bow *outward*, which is what reads as liquid
                # under surface tension. Above 1 the sides cave inward and the
                # result is a needle on a ball — tried it, looked like a balloon.
                half_width = radius * (progress ** 0.62)
                if abs(fx - cx) <= half_width:
                    inside.add((x, y))
    return inside


def draw_large(size=32):
    """The detailed icon: a droplet with a highlight, over two ripple lines."""
    px = blank(size)
    cx, cy, radius = 15.5, 17.0, 8.2
    inside = droplet_mask(size, cx, cy, radius, tip_y=3.0)

    for (x, y) in inside:
        # Light from the upper left: the left third is the lit face.
        px[y][x] = WATER_LIGHT if (x + 0.5) < cx - radius * 0.28 else WATER

    # Outline: any inside pixel with at least one orthogonal neighbour outside.
    for (x, y) in sorted(inside):
        if any((x + dx, y + dy) not in inside
               for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            px[y][x] = NIGHT

    # Specular highlight. Sits on the *darker* right-of-lit boundary rather than
    # inside the pale left face, where it was nearly invisible — a highlight needs
    # something dark behind it to register as shine.
    for y in range(14, 19):
        put(px, 13, y, FOAM)
    put(px, 14, 13, FOAM)
    put(px, 14, 19, FOAM)

    # Ripples beneath, suggesting the droplet has landed. Tucked close under the
    # droplet: further down they read as two unrelated stray lines. Asymmetric
    # lengths so it looks like water rather than a logo underline.
    for x in range(6, 26):
        put(px, x, 27, GLASS_SHINE)
    for x in range(10, 22):
        put(px, x, 29, GLASS_SHINE)
    return px, size


def draw_small(size=16):
    """The 16 px icon. A separate drawing, not a shrunk one.

    At this size the highlight becomes a stray speck and two ripples become a
    smudge, so there is one ripple and no highlight. The droplet is proportionally
    larger, because the only thing that must survive is the silhouette.
    """
    px = blank(size)
    cx, cy, radius = 7.5, 8.5, 4.6
    inside = droplet_mask(size, cx, cy, radius, tip_y=1.5)
    for (x, y) in inside:
        px[y][x] = WATER_LIGHT if (x + 0.5) < cx - radius * 0.3 else WATER
    for (x, y) in sorted(inside):
        if any((x + dx, y + dy) not in inside
               for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            px[y][x] = NIGHT
    for x in range(3, 13):
        put(px, x, 15, GLASS_SHINE)
    return px, size


def write_png(path, pixels, size, scale):
    """Writes an RGBA PNG, upscaled nearest-neighbour so pixels stay hard-edged.

    Smoothing would defeat the look, hence scaling here rather than via `sips`.
    """
    raw = bytearray()
    for row in pixels:
        line = bytearray()
        for pixel in row:
            if pixel is TRANSPARENT:
                chunk_bytes = bytes((0, 0, 0, 0))
            else:
                chunk_bytes = bytes((pixel[0], pixel[1], pixel[2], 255))
            line += chunk_bytes * scale
        for _ in range(scale):
            raw += b"\x00" + line  # filter byte 0 per scanline

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    side = size * scale
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


ICON_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
              (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_icon.py <iconset-dir>")
    target = sys.argv[1]
    os.makedirs(target, exist_ok=True)

    big, big_size = draw_large()
    small, small_size = draw_small()

    for points, scale_factor in ICON_SIZES:
        wanted = points * scale_factor
        art, art_size = (small, small_size) if wanted <= 32 else (big, big_size)
        if wanted % art_size:
            raise SystemExit(f"{wanted}px is not a whole multiple of {art_size}")
        suffix = "" if scale_factor == 1 else "@2x"
        write_png(os.path.join(target, f"icon_{points}x{points}{suffix}.png"),
                  art, art_size, wanted // art_size)
    print(f"wrote {len(ICON_SIZES)} PNGs to {target}")


if __name__ == "__main__":
    main()
