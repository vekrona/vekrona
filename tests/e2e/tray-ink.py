#!/usr/bin/env python3
"""Measure how much of a tray icon is drawn in the ink color, from screenshots with and without the icon.

usage: tray-ink.py WITHOUT.png WITH.png BAR_HEIGHT ICON_PX INK_HEX BAR_HEX dots|disc

The icon is the leftmost group of changed pixels in the right half of the bar: the tray is the first
widget of the right-side group, and the widgets right of it do not move when an icon appears. Its box is
the bounding box of that group. A pixel is ink when it is closer to INK_HEX than to BAR_HEX.
dots: the icon is dark dots on an opaque light square, so the square must stay bar-colored.
disc: the icon is a disc on a transparent square, so the disc must be ink.
ICON_PX is the icon's size in screen pixels: its box must cover about all of it, or the icon is clipped or drawn at the wrong size.
Every ink pixel must be INK_HEX blended into BAR_HEX (the same share in each channel), and some must be pure INK_HEX,
or the icon is tinted wrongly.
Prints the box and the ink ratio; exits 1 when a check fails.
"""
import sys

from png_rows import read_png_rows

CHANGE_THRESHOLD = 20
GROUP_GAP = 8
DOTS_MAX_RATIO = 0.5
DISC_MIN_RATIO = 0.6
BOX_MIN_COVER = 0.75
BOX_FRINGE_PX = 2
BLEND_SHARE_SPREAD = 0.1
PURE_INK_SHARE = 0.95


def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))


def distance(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b))


def main():
    without_path, with_path, bar_height, icon_px, ink_hex, bar_hex, kind = sys.argv[1:8]
    if kind not in ("dots", "disc"):
        sys.exit(__doc__)
    bar_height, icon_px = int(bar_height), int(icon_px)
    ink, bar = rgb(ink_hex), rgb(bar_hex)
    width, without_rows, channels = read_png_rows(without_path, bar_height)
    with_width, with_rows, with_channels = read_png_rows(with_path, bar_height)
    if (width, channels) != (with_width, with_channels):
        sys.exit("the two screenshots differ in size or format")

    def pixel(rows, x, y):
        return tuple(rows[y][x * channels:x * channels + 3])

    changed = [
        (x, y)
        for y in range(bar_height)
        for x in range(width // 2, width)
        if max(abs(a - b) for a, b in zip(pixel(without_rows, x, y), pixel(with_rows, x, y))) > CHANGE_THRESHOLD
    ]
    if not changed:
        sys.exit("the tray icon did not change the right half of the bar")
    columns = sorted({x for x, _ in changed})
    group = [columns[0]]
    for x in columns[1:]:
        if x - group[-1] >= GROUP_GAP:
            break
        group.append(x)
    box_pixels = [(x, y) for x, y in changed if group[0] <= x <= group[-1]]
    left, right = group[0], group[-1]
    top, bottom = min(y for _, y in box_pixels), max(y for _, y in box_pixels)
    area = (right - left + 1) * (bottom - top + 1)
    ink_pixels = [
        pixel(with_rows, x, y)
        for y in range(top, bottom + 1)
        for x in range(left, right + 1)
        if distance(pixel(with_rows, x, y), ink) < distance(pixel(with_rows, x, y), bar)
    ]
    ratio = len(ink_pixels) / area
    print(f"icon box x {left}-{right} y {top}-{bottom}: {len(ink_pixels)} of {area} px are ink ({ratio:.2f})")
    width_px, height_px = right - left + 1, bottom - top + 1
    if not (BOX_MIN_COVER * icon_px <= min(width_px, height_px) and max(width_px, height_px) <= icon_px + BOX_FRINGE_PX):
        sys.exit(f"the icon box is {width_px}x{height_px} px, but the icon must cover about all of its {icon_px}x{icon_px} px")
    shares = [[(p - b) / (i - b) for p, i, b in zip(pix, ink, bar)] for pix in ink_pixels]
    off_blend = [pix for pix, share in zip(ink_pixels, shares) if max(share) - min(share) > BLEND_SHARE_SPREAD]
    if off_blend:
        sys.exit(f"{len(off_blend)} ink pixels are not {ink_hex} blended into {bar_hex}, such as {off_blend[0]}")
    if not shares or max(sum(share) / 3 for share in shares) < PURE_INK_SHARE:
        sys.exit(f"no pixel of the icon is pure {ink_hex}")
    if kind == "dots" and not 0 < ratio < DOTS_MAX_RATIO:
        sys.exit(f"the dots icon must be drawn as ink dots on a bar-colored square: its ink ratio must be in (0, {DOTS_MAX_RATIO})")
    if kind == "disc" and ratio < DISC_MIN_RATIO:
        sys.exit(f"the disc icon must be drawn as an ink disc: its ink ratio must be at least {DISC_MIN_RATIO}")


main()
