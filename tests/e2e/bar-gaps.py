#!/usr/bin/env python3
"""Measure the gaps between the right-side bar widgets on a screenshot.

usage: bar-gaps.py SCREENSHOT.png BAR_HEIGHT MAX_GAP MAX_SPREAD ICON_S

The widgets are found without knowing how many there are, see bar_widgets.py. A widget's right edge is
stable (values are right-aligned), so the gap from one widget's right edge to the next pictogram is the
pill spacing, whatever the width of the values.
Prints each widget's bounds, the gaps between neighbours and the vertical ink centers; exits 1
when fewer than two widgets are found, a gap exceeds MAX_GAP px, the smallest and largest gap
differ by more than MAX_SPREAD px, vertical ink centers differ by more than VERTICAL_TOLERANCE px,
or the first cluster of any widget is not a pictogram, at most ICON_S and at least ICON_S // 2 px tall.
"""
import sys

from bar_widgets import find_widgets

VERTICAL_TOLERANCE = 2


def main():
    path, bar_height, max_gap, max_spread, icon_size = sys.argv[1], *map(int, sys.argv[2:6])
    right_bar, groups, widgets, ink, badges = find_widgets(path, bar_height, icon_size)

    def height(cluster):
        ys = [y for x in range(cluster[0], cluster[1] + 1) for y in ink[x]]
        return max(ys) - min(ys) + 1

    print(f"ink clusters in the right bar: {[(c[0], c[1]) for c in right_bar]}")
    print(f"widgets (a pictogram with the text after it): {[[(c[0], c[1]) for c in g] for g in groups]}")
    if len(groups) < 2:
        print(f"found {len(groups)} widgets, need at least 2 to measure a gap")
        sys.exit(1)
    gaps = [b[0] - a[1] - 1 for a, b in zip(widgets, widgets[1:])]
    centers = [p[2] for p in widgets if not any(b[0] <= p[1] and p[0] <= b[1] for b in badges)]
    for i, (x0, x1, cy) in enumerate(widgets):
        print(f"widget {i}: x {x0}..{x1} (w {x1 - x0 + 1}), vertical ink center {cy}")
    print(f"gaps px: {gaps}")
    print(f"vertical centers px (badged widgets skipped, their badge masks part of the glyph): {centers}")
    failures = []
    for group in groups:
        icon_height = height(group[0])
        if not icon_size // 2 <= icon_height <= icon_size:
            failures.append(f"the pictogram at x {group[0][0]}..{group[0][1]} is {icon_height} px tall, not {icon_size // 2}..{icon_size} px")
    if max(gaps) > max_gap:
        failures.append(f"largest gap {max(gaps)} px exceeds {max_gap} px")
    if max(gaps) - min(gaps) > max_spread:
        failures.append(f"gaps differ by {max(gaps) - min(gaps)} px, more than {max_spread} px")
    if max(centers) - min(centers) > VERTICAL_TOLERANCE:
        failures.append(f"vertical centers differ by {max(centers) - min(centers)} px, more than {VERTICAL_TOLERANCE} px")
    for failure in failures:
        print(failure)
    sys.exit(1 if failures else 0)


main()
