#!/usr/bin/env python3
"""Measure the pill under the pointer on a screenshot.

usage: bar-pill-width.py SCREENSHOT.png ROW X HOVER_HEX

The pointer rests on a pill, which paints HOVER_HEX behind its content. Prints the width of the run of HOVER_HEX
pixels that holds (X, ROW): the pill's width. Exits 1 when that pixel is not HOVER_HEX."""
import sys

from png_rows import read_png_rows


def main():
    path, row, x, hover_hex = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    hover = bytes.fromhex(hover_hex.removeprefix("#"))
    width, rows, channels = read_png_rows(path, row + 1)

    def hovered(i):
        return bytes(rows[row][i * channels:i * channels + 3]) == hover

    if not hovered(x):
        print(f"the pixel at x {x}, row {row} is not the hover color {hover_hex}: no pill is under the pointer")
        sys.exit(1)
    left = right = x
    while left > 0 and hovered(left - 1):
        left -= 1
    while right < width - 1 and hovered(right + 1):
        right += 1
    print(right - left + 1)


main()
