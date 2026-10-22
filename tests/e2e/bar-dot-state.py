#!/usr/bin/env python3
"""Say whether the unread dot at a place in the bar is solid, dimmed or absent.

usage: bar-dot-state.py SCREENSHOT DANGER_HEX X Y DOT_PX

X, Y is a pixel inside the dot when it is solid. Prints "solid" when that pixel is DANGER_HEX, "absent" when it is
what lies DOT_PX below it, where the pill shows no dot, and "dim" when it is any other colour, which is the dot
part way between the two.
"""
import sys

from png_rows import read_png_rows


def main():
    path, danger_hex, x, y, dot_px = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    _, rows, channels = read_png_rows(path, max_rows=y + dot_px + 1)

    def pixel(row):
        return bytes(rows[row][x * channels:x * channels + 3])

    if pixel(y) == bytes.fromhex(danger_hex.removeprefix("#")):
        print("solid")
    elif pixel(y) == pixel(y + dot_px):
        print("absent")
    else:
        print("dim")


main()
