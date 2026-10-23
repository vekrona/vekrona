#!/usr/bin/env python3
"""Check that every unread dot in the bar looks the same.

usage: bar-badges.py SCREENSHOT.png BAR_HEIGHT DANGER_HEX COUNT

A dot is a run of columns holding DANGER_HEX pixels in the top BAR_HEIGHT rows. Prints each dot's bounds; exits 1
when the bar does not show exactly COUNT dots, a dot is not a solid square, or their sizes or top edges differ.
"""
import sys

from png_rows import read_png_rows


def main():
    path, bar_height, danger_hex, count = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    danger = bytes.fromhex(danger_hex.removeprefix("#"))
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]

    def is_danger(x, y):
        return bytes(rows[y][x * channels:x * channels + 3]) == danger

    dots = []
    for x in range(width):
        ys = [y for y in range(len(rows)) if is_danger(x, y)]
        if not ys:
            continue
        if dots and x - dots[-1][1] <= 1:
            d = dots[-1]
            dots[-1] = (d[0], x, min(d[2], ys[0]), max(d[3], ys[-1]))
        else:
            dots.append((x, x, ys[0], ys[-1]))
    failures = []
    for x0, x1, y0, y1 in dots:
        w, h = x1 - x0 + 1, y1 - y0 + 1
        holes = sum(1 for y in range(y0, y1 + 1) for x in range(x0, x1 + 1) if not is_danger(x, y))
        print(f"dot: x {x0}..{x1} (w {w}), y {y0}..{y1} (h {h}), {holes} non-dot pixels")
        if w != h or holes:
            failures.append(f"the dot at x {x0}..{x1} is not a solid square: {w}x{h} with {holes} non-dot pixels")
    if len(dots) != count:
        failures.append(f"the bar shows {len(dots)} dots, expected {count}")
    for name, values in (("sizes", [d[1] - d[0] + 1 for d in dots]), ("top edges", [d[2] for d in dots])):
        if len(set(values)) > 1:
            failures.append(f"the dots' {name} differ: {values}")
    for failure in failures:
        print(failure)
    sys.exit(1 if failures else 0)


main()
