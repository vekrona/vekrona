#!/usr/bin/env python3
"""Count the password bullets of the lock screen inside and outside the password field's frame.

usage: lock-field-ink.py SCREENSHOT.png FRAME_HEX INK_HEX MIN_FRAME_WIDTH [TOLERANCE]

The frame is found by its border: the longest horizontal run of FRAME_HEX pixels (at least MIN_FRAME_WIDTH long)
is the top border, and the left border column going down from it gives the height. Bullets are the pixels
within TOLERANCE (max over RGB channels, default 24) of INK_HEX. Prints "INSIDE OUTSIDE", where OUTSIDE counts
those pixels in the frame's rows, left and right of the frame. Exits 1 when no frame is found.
"""
import sys

from png_rows import read_png_rows


def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))


def main():
    path, frame_hex, ink_hex, min_width = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    tolerance = int(sys.argv[5]) if len(sys.argv) > 5 else 24
    width, rows, channels = read_png_rows(path)
    frame, ink = rgb(frame_hex), rgb(ink_hex)

    def pixel(x, y):
        return tuple(rows[y][x * channels:x * channels + 3])

    def is_ink(x, y):
        return max(abs(a - b) for a, b in zip(pixel(x, y), ink)) <= tolerance

    best = (0, 0, 0)  # run length, left x, y
    for y in range(len(rows)):
        run_start = None
        for x in range(width + 1):
            if x < width and pixel(x, y) == frame:
                run_start = x if run_start is None else run_start
            elif run_start is not None:
                best = (x - run_start, run_start, y) if x - run_start > best[0] else best
                run_start = None
    length, left, top = best
    if length < min_width:
        print(f"no frame: the longest row of {frame_hex} pixels is {length} px, expected at least {min_width}")
        sys.exit(1)
    right = left + length - 1
    bottom = top
    while bottom + 1 < len(rows) and pixel(left, bottom + 1) == frame:
        bottom += 1

    inside = sum(is_ink(x, y) for y in range(top + 1, bottom) for x in range(left + 1, right))
    outside = sum(is_ink(x, y) for y in range(top, bottom + 1) for x in [*range(left), *range(right + 1, width)])
    print(f"{inside} {outside}")


main()
