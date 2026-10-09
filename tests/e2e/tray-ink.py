#!/usr/bin/env python3
"""Measure how much of a tray icon is drawn in the ink color, from screenshots with and without the icon.

usage: tray-ink.py WITHOUT.png WITH.png BAR_HEIGHT INK_HEX BAR_HEX dots|disc

The icon is the leftmost group of changed pixels in the right half of the bar: the tray is the first
widget of the right-side group, and the widgets right of it do not move when an icon appears. Its box is
the bounding box of that group. A pixel is ink when it is closer to INK_HEX than to BAR_HEX.
dots: the icon is dark dots on an opaque light square, so the square must stay bar-colored.
disc: the icon is a disc on a transparent square, so the disc must be ink.
Prints the box and the ink ratio; exits 1 when the ratio is out of range for the kind.
"""
import sys

from png_rows import read_png_rows

CHANGE_THRESHOLD = 20
GROUP_GAP = 8
DOTS_MAX_RATIO = 0.5
DISC_MIN_RATIO = 0.6


def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))


def distance(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b))


def main():
    without_path, with_path, bar_height, ink_hex, bar_hex, kind = sys.argv[1:7]
    if kind not in ("dots", "disc"):
        sys.exit(__doc__)
    bar_height = int(bar_height)
    ink, bar = rgb(ink_hex), rgb(bar_hex)
    width, without_rows, channels = read_png_rows(without_path)
    with_width, with_rows, with_channels = read_png_rows(with_path)
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
    inked = sum(
        1
        for y in range(top, bottom + 1)
        for x in range(left, right + 1)
        if distance(pixel(with_rows, x, y), ink) < distance(pixel(with_rows, x, y), bar)
    )
    ratio = inked / area
    print(f"icon box x {left}-{right} y {top}-{bottom}: {inked} of {area} px are ink ({ratio:.2f})")
    if kind == "dots" and not 0 < ratio < DOTS_MAX_RATIO:
        sys.exit(f"the dots icon must be drawn as ink dots on a bar-colored square: its ink ratio must be in (0, {DOTS_MAX_RATIO})")
    if kind == "disc" and ratio < DISC_MIN_RATIO:
        sys.exit(f"the disc icon must be drawn as an ink disc: its ink ratio must be at least {DISC_MIN_RATIO}")


main()
