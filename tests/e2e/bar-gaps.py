#!/usr/bin/env python3
"""Measure the gaps between the right-side bar pictograms on a screenshot.

usage: bar-gaps.py SCREENSHOT.png BAR_HEIGHT MAX_GAP MAX_SPREAD

The pictograms are found without knowing how many there are: the right-side bar is the run of
ink clusters (glyphs more than 3 px apart) that ends at the right edge and is not broken by a
gap of SECTION_BREAK px or more. A percent label (a short, wide cluster such as "26%") belongs
to the icon right before it, so icon plus label is one pictogram. Unread badges (red dots and counters)
overhang their glyph by design, so they are not measured.
Prints each pictogram's bounds, the gaps between neighbours and the vertical ink centers; exits 1
when fewer than two pictograms are found, a gap exceeds MAX_GAP px, the smallest and largest gap
differ by more than MAX_SPREAD px, or vertical ink centers differ by more than VERTICAL_TOLERANCE px.
"""
import sys

from png_rows import read_png_rows

INK_THRESHOLD = 20
CLUSTER_GAP = 3
BADGE_RED_DOMINANCE = 60
BADGE_JOIN_GAP = 6
VERTICAL_TOLERANCE = 2
SECTION_BREAK = 80
LABEL_MAX_HEIGHT_BAR_FRACTION = 3  # a label is at most this fraction of the bar tall
LABEL_MIN_ASPECT = 1.5


def main():
    path, bar_height, max_gap, max_spread = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]
    label_max_height = bar_height // LABEL_MAX_HEIGHT_BAR_FRACTION
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

    def is_label(cluster):
        return height(cluster) <= label_max_height and cluster[1] - cluster[0] + 1 >= LABEL_MIN_ASPECT * height(cluster)

    right_bar = clusters[-1:]
    for cluster in reversed(clusters[:-1]):
        if right_bar[0][0] - cluster[1] - 1 >= SECTION_BREAK:
            break
        right_bar.insert(0, cluster)
    groups = []
    for cluster in right_bar:
        if groups and len(groups[-1]) == 1 and is_label(cluster):
            groups[-1].append(cluster)
        else:
            groups.append([cluster])
    print(f"ink clusters in the right bar: {[(c[0], c[1]) for c in right_bar]}")
    print(f"pictograms (icon + label merged): {[[(c[0], c[1]) for c in g] for g in groups]}")
    if len(groups) < 2:
        print(f"found {len(groups)} pictograms, need at least 2 to measure a gap")
        sys.exit(1)
    pictograms = []
    for group in groups:
        x0, x1 = group[0][0], group[-1][1]
        ys = [y for x in range(x0, x1 + 1) for y in ink[x]]
        pictograms.append((x0, x1, (min(ys) + max(ys)) / 2))

    gaps = [b[0] - a[1] - 1 for a, b in zip(pictograms, pictograms[1:])]
    centers = [p[2] for p in pictograms if not any(b[0] <= p[1] and p[0] <= b[1] for b in badges)]
    for i, (x0, x1, cy) in enumerate(pictograms):
        print(f"pictogram {i}: x {x0}..{x1} (w {x1 - x0 + 1}), vertical ink center {cy}")
    print(f"gaps px: {gaps}")
    print(f"vertical centers px (badged pictograms skipped, their badge masks part of the glyph): {centers}")
    failures = []
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
