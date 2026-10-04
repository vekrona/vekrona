#!/usr/bin/env python3
"""Check that the bar shows a visible vertical separator line in its left third.

usage: bar-separator.py SCREENSHOT.png BAR_HEIGHT MIN_LINE_HEIGHT MIN_CONTRAST

A separator column is one where at least MIN_LINE_HEIGHT rows differ by MIN_CONTRAST or more
(max over RGB channels) from the pixels 3 columns to its left and to its right. Prints the columns found and
exits 1 when there is none.
"""
import sys

from png_rows import read_png_rows

SIDE_OFFSET = 3


def main():
    path, bar_height, min_line_height, min_contrast = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]
    found = []
    def contrast(line, x, other):
        return max(abs(line[x * channels + c] - line[other * channels + c]) for c in range(3))

    for x in range(SIDE_OFFSET, width // 3):
        contrasts = [min(contrast(line, x, x - SIDE_OFFSET), contrast(line, x, x + SIDE_OFFSET)) for line in rows]
        tall = [d for d in contrasts if d >= min_contrast]
        if len(tall) >= min_line_height:
            found.append((x, len(tall), max(contrasts)))
    for x, height, contrast in found:
        print(f"separator column x {x}: {height} rows differ, peak contrast {contrast}")
    if not found:
        print(f"no column in the left third has {min_line_height} rows with contrast of {min_contrast} or more")
        sys.exit(1)


main()
