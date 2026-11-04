#!/usr/bin/env python3
"""Measure the gaps between the right-side bar widgets on a screenshot.

usage: bar-gaps.py SCREENSHOT.png BAR_HEIGHT GROUP_JOIN_PX MAX_GAP MAX_SPREAD ICON_S TEXT_SLACK

The widgets are found without knowing how many there are, see bar_widgets.py: tray icons, icons and text alike. The gap
between two neighbours is the clear space between their inks, whatever they are. A text widget is centered in a slot
as wide as its widest value, so a narrower value leaves half its slack, at most TEXT_SLACK px, on each side.
Prints each widget's bounds, the gaps between neighbours and the vertical ink centers; exits 1
when fewer than two widgets are found, or a gap less the TEXT_SLACK of each text neighbour exceeds MAX_GAP px or the
smallest gap by more than MAX_SPREAD px, or vertical ink centers differ by more than VERTICAL_TOLERANCE px,
or a pictogram is taller than ICON_S.
"""
import sys

from bar_widgets import BADGE_JOIN_GAP, PICTOGRAM, TEXT, cluster_height, find_widgets

VERTICAL_TOLERANCE = 2


def main():
    path, bar_height, group_join, max_gap, max_spread, icon_size, text_slack = sys.argv[1], *map(int, sys.argv[2:8])
    right_bar, widgets, ink, badges = find_widgets(path, bar_height, icon_size, group_join)

    print(f"ink clusters in the right bar: {[(c[0], c[1]) for c in right_bar]}")
    if len(widgets) < 2:
        print(f"found {len(widgets)} widgets, need at least 2 to measure a gap")
        sys.exit(1)
    gaps = [b[0] - a[1] - 1 for a, b in zip(widgets, widgets[1:])]
    slot_gaps = [gap - text_slack * [a[3], b[3]].count(TEXT) for gap, a, b in zip(gaps, widgets, widgets[1:])]
    centers = [w[2] for w in widgets if not any(b[0] <= w[1] + BADGE_JOIN_GAP and w[0] - BADGE_JOIN_GAP <= b[1] for b in badges)]
    for i, (x0, x1, cy, kind) in enumerate(widgets):
        print(f"widget {i}: {kind} x {x0}..{x1} (w {x1 - x0 + 1}), vertical ink center {cy}")
    print(f"gaps px: {gaps}")
    print(f"gaps less the text slack px: {slot_gaps}")
    print(f"vertical centers px (badged widgets skipped, their dot masks part of the glyph): {centers}")
    failures = []
    for x0, x1, _, kind in widgets:
        height = cluster_height(ink, (x0, x1))
        if kind == PICTOGRAM and height > icon_size:
            failures.append(f"the pictogram at x {x0}..{x1} is {height} px tall, more than {icon_size} px")
    if max(slot_gaps) > max_gap:
        failures.append(f"largest gap less its text slack {max(slot_gaps)} px exceeds {max_gap} px")
    if max(slot_gaps) - min(gaps) > max_spread:
        failures.append(f"a gap less its text slack exceeds the smallest gap by {max(slot_gaps) - min(gaps)} px, more than {max_spread} px")
    if max(centers) - min(centers) > VERTICAL_TOLERANCE:
        failures.append(f"vertical centers differ by {max(centers) - min(centers)} px, more than {VERTICAL_TOLERANCE} px")
    for failure in failures:
        print(failure)
    sys.exit(1 if failures else 0)


main()
