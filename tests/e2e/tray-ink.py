#!/usr/bin/env python3
"""Measure how much of a tray icon is drawn in the ink color, from screenshots with and without the icon.

usage: tray-ink.py WITHOUT.png WITH.png BAR_HEIGHT ICON_PX INK_HEX BAR_HEX dots|disc|badged-disc

The icon is the leftmost group of changed pixels in the right half of the bar: the tray is the first
widget of the right-side group, and the widgets right of it do not move when an icon appears. Its box is
the bounding box of that group. A pixel is ink when it is closer to INK_HEX than to BAR_HEX.
dots: the icon is dark dots on an opaque light square, so the square must stay bar-colored.
disc: the icon is a disc on a transparent square, so the disc must be ink.
badged-disc: like disc, but opaque details inside the disc (tests/fixtures/tray/1password.png: a blue ring and a keyhole in a
white disc) must stay visible as holes in the ink: regions of coverage below half, enclosed by the disc, not reaching the box
border.
ICON_PX is the icon's size in screen pixels: its box must cover about all of it, or the icon is clipped or drawn at the wrong size.
Every ink pixel must be INK_HEX blended into BAR_HEX (the same share in each channel), and some must be pure INK_HEX,
or the icon is tinted wrongly.
The coverage of a pixel is its share of INK_HEX in BAR_HEX, averaged over the channels and clamped to [0, 1].
disc: the edge must be anti-aliased: a smooth disc of ICON_PX leaves a ring of about pi * ICON_PX pixels of partial coverage,
a nearest-neighbour shrink leaves few. The disc must also be symmetric: rows (and columns) mirrored about the center of the box
differ by at most one pixel in the count of pixels covered at least half. badged-disc is not checked for symmetry: the real icon's
rim sits on a half of a pixel at scale 1.25, so the count of covered pixels flips between mirrored rows of the source itself.
Prints the box, the ink ratio, the partial pixels and the covered pixels per row and column; exits 1 when a check fails.
"""
import math
import sys

from png_rows import read_png_rows

CHANGE_THRESHOLD = 20
GROUP_GAP = 8
DOTS_MAX_RATIO = 0.5
DISC_MIN_RATIO = 0.6
# 1password.png keeps 0.49 of its disc's bounding box as ink once the ring and the keyhole are holes; 0.4 fails an icon that lost most of it.
BADGED_DISC_MIN_RATIO = 0.4
BOX_MIN_COVER = 0.75
BOX_FRINGE_PX = 2
BLEND_SHARE_SPREAD = 0.1
PURE_INK_SHARE = 0.95
PARTIAL_MIN_COVERAGE = 0.1
PARTIAL_MAX_COVERAGE = 0.9
DISC_MIN_PARTIAL_PER_CIRCUMFERENCE = 0.4
COVERED_MIN_COVERAGE = 0.5
MIRROR_MAX_DIFF = 1
# 1password.png is 256 px wide; its keyhole is 2045 px, 0.031 of the icon area, and its ring 12141 px. Half the keyhole must survive the shrink.
BADGED_DISC_HOLE_MIN_AREA_SHARE = 0.015
BADGED_DISC_MIN_HOLES = 2


def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))


def distance(a, b):
    return sum((p - q) ** 2 for p, q in zip(a, b))


def coverage(pix, ink, bar):
    return min(1, max(0, sum((p - b) / (i - b) for p, i, b in zip(pix, ink, bar)) / 3))


def neighbors(x, y, width, height):
    return [(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)) if 0 <= x + dx < width and 0 <= y + dy < height]


def low_regions(coverages):
    """The 4-connected regions of pixels covered less than half, as (pixels, touches the border of the box)."""
    height, width = len(coverages), len(coverages[0])
    seen, regions = set(), []
    for y in range(height):
        for x in range(width):
            if (x, y) in seen or coverages[y][x] >= COVERED_MIN_COVERAGE:
                continue
            seen.add((x, y))
            pixels, todo = [], [(x, y)]
            while todo:
                px, py = todo.pop()
                pixels.append((px, py))
                for n in neighbors(px, py, width, height):
                    if n not in seen and coverages[n[1]][n[0]] < COVERED_MIN_COVERAGE:
                        seen.add(n)
                        todo.append(n)
            regions.append((pixels, any(px in (0, width - 1) or py in (0, height - 1) for px, py in pixels)))
    return regions


def mirrored_mismatch(counts):
    return [(a, len(counts) - 1 - a) for a in range(len(counts) // 2) if abs(counts[a] - counts[len(counts) - 1 - a]) > MIRROR_MAX_DIFF]


def main():
    without_path, with_path, bar_height, icon_px, ink_hex, bar_hex, kind = sys.argv[1:8]
    if kind not in ("dots", "disc", "badged-disc"):
        sys.exit(__doc__)
    bar_height, icon_px = int(bar_height), int(icon_px)
    ink, bar = rgb(ink_hex), rgb(bar_hex)
    width, without_rows, channels = read_png_rows(without_path, bar_height)
    with_width, with_rows, with_channels = read_png_rows(with_path, bar_height)
    if (width, channels) != (with_width, with_channels):
        sys.exit("the two screenshots differ in size or format")

    def pixel(rows, x, y):
        return tuple(rows[y][x * channels:x * channels + 3])

    changed = [
        (x, y)
        for y in range(bar_height)
        for x in range(width // 2, width)
        if max(abs(a - b) for a, b in zip(pixel(without_rows, x, y), pixel(with_rows, x, y))) > CHANGE_THRESHOLD
    ]
    if not changed:
        sys.exit("the tray icon did not change the right half of the bar")
    columns = sorted({x for x, _ in changed})
    group = [columns[0]]
    for x in columns[1:]:
        if x - group[-1] >= GROUP_GAP:
            break
        group.append(x)
    box_pixels = [(x, y) for x, y in changed if group[0] <= x <= group[-1]]
    left, right = group[0], group[-1]
    top, bottom = min(y for _, y in box_pixels), max(y for _, y in box_pixels)
    area = (right - left + 1) * (bottom - top + 1)
    ink_pixels = [
        pixel(with_rows, x, y)
        for y in range(top, bottom + 1)
        for x in range(left, right + 1)
        if distance(pixel(with_rows, x, y), ink) < distance(pixel(with_rows, x, y), bar)
    ]
    ratio = len(ink_pixels) / area
    print(f"icon box x {left}-{right} y {top}-{bottom}: {len(ink_pixels)} of {area} px are ink ({ratio:.2f})")
    width_px, height_px = right - left + 1, bottom - top + 1
    if not (BOX_MIN_COVER * icon_px <= min(width_px, height_px) and max(width_px, height_px) <= icon_px + BOX_FRINGE_PX):
        sys.exit(f"the icon box is {width_px}x{height_px} px, but the icon must cover about all of its {icon_px}x{icon_px} px")
    shares = [[(p - b) / (i - b) for p, i, b in zip(pix, ink, bar)] for pix in ink_pixels]
    off_blend = [pix for pix, share in zip(ink_pixels, shares) if max(share) - min(share) > BLEND_SHARE_SPREAD]
    if off_blend:
        sys.exit(f"{len(off_blend)} ink pixels are not {ink_hex} blended into {bar_hex}, such as {off_blend[0]}")
    if not shares or max(sum(share) / 3 for share in shares) < PURE_INK_SHARE:
        sys.exit(f"no pixel of the icon is pure {ink_hex}")
    if kind == "dots" and not 0 < ratio < DOTS_MAX_RATIO:
        sys.exit(f"the dots icon must be drawn as ink dots on a bar-colored square: its ink ratio must be in (0, {DOTS_MAX_RATIO})")
    min_ratio = {"disc": DISC_MIN_RATIO, "badged-disc": BADGED_DISC_MIN_RATIO}.get(kind)
    if min_ratio and ratio < min_ratio:
        sys.exit(f"the {kind} icon must be drawn as an ink disc: its ink ratio must be at least {min_ratio}")
    if kind in ("disc", "badged-disc"):
        coverages = [[coverage(pixel(with_rows, x, y), ink, bar) for x in range(left, right + 1)] for y in range(top, bottom + 1)]
        partial = sum(PARTIAL_MIN_COVERAGE < c < PARTIAL_MAX_COVERAGE for row in coverages for c in row)
        holes = [pixels for pixels, outside in low_regions(coverages) if not outside]
        row_counts = [sum(c >= COVERED_MIN_COVERAGE for c in row) for row in coverages]
        column_counts = [sum(c >= COVERED_MIN_COVERAGE for c in column) for column in zip(*coverages)]
        hole_areas = sorted((len(pixels) for pixels in holes), reverse=True)
        print(f"{partial} partial px (anti-aliased edge); hole areas {hole_areas}; covered px per row {row_counts}, per column {column_counts}")
        min_hole_area = BADGED_DISC_HOLE_MIN_AREA_SHARE * icon_px**2
        big_holes = [area for area in hole_areas if area >= min_hole_area]
        if kind == "badged-disc" and len(big_holes) < BADGED_DISC_MIN_HOLES:
            sys.exit(f"the badged-disc icon must keep its opaque details as holes in the ink: at least {BADGED_DISC_MIN_HOLES} enclosed regions of at least {min_hole_area:.1f} px, but it has {big_holes}")
        min_partial = DISC_MIN_PARTIAL_PER_CIRCUMFERENCE * math.pi * icon_px
        if partial < min_partial:
            sys.exit(f"the disc icon must have a smooth anti-aliased edge: at least {min_partial:.0f} px of partial coverage, but it has {partial}")
    if kind == "disc":
        rows_off = mirrored_mismatch(row_counts)
        if rows_off:
            sys.exit(f"the disc icon must be symmetric: rows {[(top + a, top + b) for a, b in rows_off]} are mirrored about the center but differ in width by more than {MIRROR_MAX_DIFF} px, counts {row_counts}")
        columns_off = mirrored_mismatch(column_counts)
        if columns_off:
            sys.exit(f"the disc icon must be symmetric: columns {[(left + a, left + b) for a, b in columns_off]} are mirrored about the center but differ in height by more than {MIRROR_MAX_DIFF} px, counts {column_counts}")


main()
