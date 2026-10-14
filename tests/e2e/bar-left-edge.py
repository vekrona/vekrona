#!/usr/bin/env python3
"""Print the x of the left edge of the right-side bar on a screenshot.

usage: bar-left-edge.py SCREENSHOT.png BAR_HEIGHT ICON_S GROUP_JOIN_PX

The right side is right-aligned, so the left edge moves whenever any widget in it changes width.
Exits 1 when no widget is found."""
import sys

from bar_widgets import find_widgets


def main():
    path, bar_height, icon_size, group_join = sys.argv[1], *map(int, sys.argv[2:5])
    _, _, widgets, _, _ = find_widgets(path, bar_height, icon_size, group_join)
    if not widgets:
        print("found no widget in the right-side bar")
        sys.exit(1)
    print(widgets[0][0])


main()
