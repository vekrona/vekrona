"""Find the right-side bar widgets on a screenshot, without knowing how many there are.

The right-side bar is the run of ink clusters (glyphs more than CLUSTER_GAP px apart) that ends at the right edge and is
not broken by a gap of SECTION_BREAK px or more. A widget starts at each pictogram (a cluster at least
icon_size // 2 + 2 px tall, taller than any text) and takes the text clusters after it: its value, or the words of the
clock. A value is right-aligned in a slot as wide as the widest value, so the gap between a pictogram and its value
varies, and the widget's right edge is what stays put. Unread badges (red counters) overhang their glyph by design: their
pixels are not measured as glyph ink, but a badge widens the widget it touches."""
from png_rows import read_png_rows

INK_THRESHOLD = 20
CLUSTER_GAP = 3
BADGE_RED_DOMINANCE = 60
BADGE_JOIN_GAP = 6
SECTION_BREAK = 80


def find_widgets(path, bar_height, icon_size):
    """Return (right_bar, groups, widgets, ink, badges): the clusters of the right bar, the clusters grouped per widget,
    each widget's (x0, x1, vertical ink center), the ink rows per column and the badge boxes."""
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

    right_bar = clusters[-1:]
    for cluster in reversed(clusters[:-1]):
        if right_bar[0][0] - cluster[1] - 1 >= SECTION_BREAK:
            break
        right_bar.insert(0, cluster)
    def is_pictogram(cluster):
        ys = [y for x in range(cluster[0], cluster[1] + 1) for y in ink[x]]
        return max(ys) - min(ys) + 1 >= icon_size // 2 + 2

    groups = []
    for cluster in right_bar:
        if groups and not is_pictogram(cluster):
            groups[-1].append(cluster)
        else:
            groups.append([cluster])
    widgets = []
    for group in groups:
        x0, x1 = group[0][0], group[-1][1]
        ys = [y for x in range(x0, x1 + 1) for y in ink[x]]
        touching = [b for b in badges if b[0] <= x1 + BADGE_JOIN_GAP and x0 - BADGE_JOIN_GAP <= b[1]]
        widgets.append((min([x0] + [b[0] for b in touching]), max([x1] + [b[1] for b in touching]), (min(ys) + max(ys)) / 2))
    return right_bar, groups, widgets, ink, badges
