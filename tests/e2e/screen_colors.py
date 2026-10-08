#!/usr/bin/env python3
"""Read colors and the bar height from a screenshot, so e2e scenarios compare against design tokens.

usage:
  screen_colors.py center SHOT.png                 print the center pixel as #rrggbb
  screen_colors.py bar-height SHOT.png BG_HEX      print the bar height: the contiguous run of pixels that are not
                                                   BG_HEX from the top edge, taken at the most common length over all columns
  screen_colors.py count SHOT.png HEX MIN_Y        print how many pixels at row MIN_Y or below equal HEX
  screen_colors.py contrast HEX HEX                print the largest per-channel difference between two colors
"""
import sys
from collections import Counter

from png_rows import read_png_rows


def hex_of(rows, channels, x, y):
    return "#" + bytes(rows[y][x * channels:x * channels + 3]).hex()


def center(path):
    width, rows, channels = read_png_rows(path)
    return hex_of(rows, channels, width // 2, len(rows) // 2)


def bar_height(path, background):
    width, rows, channels = read_png_rows(path)
    runs = Counter()
    for x in range(width):
        y = 0
        while y < len(rows) and hex_of(rows, channels, x, y) != background:
            y += 1
        runs[y] += 1
    height, columns = runs.most_common(1)[0]
    if height == 0:
        sys.exit(f"the top edge of the screen is {background} in {columns} of {width} columns: there is no bar")
    return height


def count(path, color, min_y):
    width, rows, channels = read_png_rows(path)
    return sum(1 for y in range(min_y, len(rows)) for x in range(width) if hex_of(rows, channels, x, y) == color)


def contrast(a, b):
    return max(abs(int(a[i:i + 2], 16) - int(b[i:i + 2], 16)) for i in (1, 3, 5))


COMMANDS = {
    "center": (1, lambda a: center(a[0])),
    "bar-height": (2, lambda a: bar_height(a[0], a[1])),
    "count": (3, lambda a: count(a[0], a[1], int(a[2]))),
    "contrast": (2, lambda a: contrast(a[0], a[1])),
}

if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS or len(sys.argv) - 2 != COMMANDS[sys.argv[1]][0]:
    sys.exit(__doc__)
print(COMMANDS[sys.argv[1]][1](sys.argv[2:]))
