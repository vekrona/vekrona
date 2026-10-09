#!/usr/bin/env python3
"""Measure the gaps between the right-side bar widgets on a screenshot.

usage: bar-gaps.py SCREENSHOT.png BAR_HEIGHT GROUP_JOIN_PX MAX_GAP MAX_SPREAD ICON_S

The widgets are found without knowing how many there are: the right-side bar is the run of
ink clusters (glyphs more than 3 px apart) that ends at the right edge and is not broken by a
gap of SECTION_BREAK px or more. Clusters closer than GROUP_JOIN_PX belong to one widget: a pictogram
with its value, or the words of the clock. Unread badges (red dots and counters) overhang their glyph by
design: their pixels are not measured as glyph ink, but a badge widens the widget it touches.
Prints each widget's bounds, the gaps between neighbours and the vertical ink centers; exits 1
when fewer than two widgets are found, a gap exceeds MAX_GAP px, the smallest and largest gap
differ by more than MAX_SPREAD px, vertical ink centers differ by more than VERTICAL_TOLERANCE px,
or the first cluster of any widget but the rightmost (the clock) is not a pictogram, at most ICON_S
and at least ICON_S // 2 px tall.
"""
import sys

from png_rows import read_png_rows

INK_THRESHOLD = 20
CLUSTER_GAP = 3
BADGE_RED_DOMINANCE = 60
BADGE_JOIN_GAP = 6
VERTICAL_TOLERANCE = 2
SECTION_BREAK = 80


def main():
    path, bar_height, group_join, max_gap, max_spread, icon_size = sys.argv[1], *map(int, sys.argv[2:7])
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]
    counts = {}
    for line in rows:
        for x in range(width):
            px = bytes(line[x * channels:x * channels + 3])
            counts[px] = counts.get(px, 0) + 1
    background = max(counts, key=counts.get)

    def is_ink(line, x):
        return max(abs(line[x * channels + c] - background[c]) for c in range(3)) > INK_THRESHOLD

    def is_badge_red(line, x):
        r, g, b = line[x * channels:x * channels + 3]
        return r - g > BADGE_RED_DOMINANCE and b >= g

    badges = []
    for x in range(width):
        for y, line in enumerate(rows):
            if is_badge_red(line, x):
                if badges and x - badges[-1][1] <= BADGE_JOIN_GAP:
                    b = badges[-1]
                    badges[-1] = [b[0], x, min(b[2], y), max(b[3], y)]
                else:
                    badges.append([x, x, y, y])

    def in_badge(x, y):
        return any(x0 - 1 <= x <= x1 + 1 and y0 - 1 <= y <= y1 + 1 for x0, x1, y0, y1 in badges)

    ink = [[y for y, line in enumerate(rows) if is_ink(line, x) and not in_badge(x, y)] for x in range(width)]
    clusters, start, last = [], None, None
    for x in range(width):
        if not ink[x]:
            continue
        if start is None:
            start = x
        elif x - last > CLUSTER_GAP:
            clusters.append((start, last))
            start = x
        last = x
    if start is not None:
        clusters.append((start, last))

    def height(cluster):
        ys = [y for x in range(cluster[0], cluster[1] + 1) for y in ink[x]]
        return max(ys) - min(ys) + 1

    right_bar = clusters[-1:]
    for cluster in reversed(clusters[:-1]):
        if right_bar[0][0] - cluster[1] - 1 >= SECTION_BREAK:
            break
        right_bar.insert(0, cluster)
    groups = []
    for cluster in right_bar:
        if groups and cluster[0] - groups[-1][-1][1] - 1 < group_join:
            groups[-1].append(cluster)
        else:
            groups.append([cluster])
    print(f"ink clusters in the right bar: {[(c[0], c[1]) for c in right_bar]}")
    print(f"widgets (clusters closer than {group_join} px joined): {[[(c[0], c[1]) for c in g] for g in groups]}")
    if len(groups) < 2:
        print(f"found {len(groups)} widgets, need at least 2 to measure a gap")
        sys.exit(1)
    widgets = []
    for group in groups:
        x0, x1 = group[0][0], group[-1][1]
        ys = [y for x in range(x0, x1 + 1) for y in ink[x]]
        touching = [b for b in badges if b[0] <= x1 + BADGE_JOIN_GAP and x0 - BADGE_JOIN_GAP <= b[1]]
        widgets.append((min([x0] + [b[0] for b in touching]), max([x1] + [b[1] for b in touching]), (min(ys) + max(ys)) / 2))

    gaps = [b[0] - a[1] - 1 for a, b in zip(widgets, widgets[1:])]
    centers = [p[2] for p in widgets if not any(b[0] <= p[1] and p[0] <= b[1] for b in badges)]
    for i, (x0, x1, cy) in enumerate(widgets):
        print(f"widget {i}: x {x0}..{x1} (w {x1 - x0 + 1}), vertical ink center {cy}")
    print(f"gaps px: {gaps}")
    print(f"vertical centers px (badged widgets skipped, their badge masks part of the glyph): {centers}")
    failures = []
    for group in groups[:-1]:
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
