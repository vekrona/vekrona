#!/usr/bin/env python3
"""Check that every badge in the bar looks the same.

usage: bar-badges.py SCREENSHOT.png BAR_HEIGHT DANGER_HEX COUNT MIN_NUMBER_PIXELS

A badge is a run of columns holding DANGER_HEX pixels in the top BAR_HEIGHT rows. Prints each badge's bounds and
how many pixels inside it are not DANGER_HEX (the number's ink); exits 1 when the bar does not show exactly COUNT
badges, their widths, heights or top edges differ, or one holds fewer than MIN_NUMBER_PIXELS ink pixels, which is
a bare square without a number.
"""
import sys

from png_rows import read_png_rows


def main():
    path, bar_height, danger_hex, count, min_number_pixels = sys.argv[1], int(sys.argv[2]), sys.argv[3], *map(int, sys.argv[4:6])
    danger = bytes.fromhex(danger_hex.removeprefix("#"))
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]

    def is_danger(x, y):
        return bytes(rows[y][x * channels:x * channels + 3]) == danger

    badges = []
    for x in range(width):
        ys = [y for y in range(len(rows)) if is_danger(x, y)]
        if not ys:
            continue
        if badges and x - badges[-1][1] <= 1:
            b = badges[-1]
            badges[-1] = (b[0], x, min(b[2], ys[0]), max(b[3], ys[-1]))
        else:
            badges.append((x, x, ys[0], ys[-1]))
    failures = []
    inks = []
    for x0, x1, y0, y1 in badges:
        ink = sum(1 for y in range(y0, y1 + 1) for x in range(x0, x1 + 1) if not is_danger(x, y))
        inks.append(ink)
        print(f"badge: x {x0}..{x1} (w {x1 - x0 + 1}), y {y0}..{y1} (h {y1 - y0 + 1}), {ink} number pixels")
        if ink < min_number_pixels:
            failures.append(f"the badge at x {x0}..{x1} shows no number: {ink} ink pixels, need {min_number_pixels}")
    if len(badges) != count:
        failures.append(f"the bar shows {len(badges)} badges, expected {count}")
    for name, values in (("widths", [b[1] - b[0] + 1 for b in badges]), ("heights", [b[3] - b[2] + 1 for b in badges]), ("top edges", [b[2] for b in badges])):
        if len(set(values)) > 1:
            failures.append(f"the badges' {name} differ: {values}")
    for failure in failures:
        print(failure)
    sys.exit(1 if failures else 0)


main()
