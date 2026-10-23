"""Find the right-side bar widgets on a screenshot, without knowing how many there are.

The right-side bar is the run of ink clusters (glyphs more than CLUSTER_GAP px apart) that ends at the right edge and is
not broken by a gap of SECTION_BREAK px or more. Each cluster is a pictogram or text. A pictogram is a near-square mark
at least icon_size * 2 // 3 px tall (no wider than 1.5 times its height); the tallest text, a word with an ascender and a
descender such as "Aug", is 12 px tall but at least 24 px wide. Every widget is one thing: a pictogram, or a run of text.
Text clusters closer than word_join px are one run of text (a value, or the words of the clock); a pictogram is a run
of its own. Text is right-aligned in a slot as wide as the widest value, so a text widget's right edge is what stays put,
and its left edge moves with its value. Unread dots hang over the right padding of their pill by design: their pixels
are not measured as ink, so they neither make a widget nor widen one."""

from png_rows import read_png_rows

INK_THRESHOLD = 20
CLUSTER_GAP = 3
BADGE_RED_DOMINANCE = 60
BADGE_JOIN_GAP = 6
PICTOGRAM = "pictogram"
TEXT = "text"
SECTION_BREAK = 80


def cluster_height(ink, cluster):
    ys = [y for x in range(cluster[0], cluster[1] + 1) for y in ink[x]]
    return max(ys) - min(ys) + 1


def is_pictogram(width, height, icon_size):
    return height >= icon_size * 2 // 3 and 2 * width <= 3 * height


def bar_fill(ink, columns, top, bottom):
    """Return the percent a half of the gauge is filled: the rows, counted from the bottom, that the interior columns hold
    ink in all of, out of the interior rows. The frame's rows top and bottom are not interior."""
    filled = 0
    for y in range(bottom - 1, top, -1):
        if not all(y in ink[x] for x in columns):
            break
        filled += 1
    return round(100 * filled / (bottom - top - 1))


def gauge_fills(ink, x0, x1):
    """Return (cpu, memory), the fill of the left and the right half of the load widget at columns x0..x1, when the cluster
    is one frame split by a single line, else None. The frame is a rectangle as tall as the cluster: its first and last
    columns are full-height lines, and the cluster's top and bottom rows are ink across all of its columns, so no gap of
    background splits it. Its middle column is the one separator, a full-height line. Beside that line a half holds a
    full-height column only where its fill reaches the top, in which case all of its columns are full-height, so a second
    line in a half, such as the inner edge of a second frame, is rejected."""
    if (x1 - x0) % 2 != 0 or x1 - x0 < 4:
        return None
    ys = [y for x in range(x0, x1 + 1) for y in ink[x]]
    top, bottom = min(ys), max(ys)
    middle = (x0 + x1) // 2
    if any(len(ink[x]) != bottom - top + 1 for x in (x0, middle, x1)):
        return None
    if any(y not in ink[x] for y in (top, bottom) for x in range(x0, x1 + 1)):
        return None
    fills = []
    for columns in (range(x0 + 1, middle), range(middle + 1, x1)):
        fill = bar_fill(ink, columns, top, bottom)
        full = [x for x in columns if len(ink[x]) == bottom - top + 1]
        if full != (list(columns) if fill == 100 else []):
            return None
        fills.append(fill)
    return tuple(fills)


def read_bar(path, bar_height):
    """Return (width, rows, channels, background): the top bar_height rows of the screenshot and the bar's most common color."""
    width, rows, channels = read_png_rows(path)
    rows = rows[:bar_height]
    counts = {}
    for line in rows:
        for x in range(width):
            px = bytes(line[x * channels:x * channels + 3])
            counts[px] = counts.get(px, 0) + 1
    return width, rows, channels, max(counts, key=counts.get)


def ink_mass(path, bar_height, x0, x1):
    """How much the columns x0..x1 of the bar differ from its background, summed over every pixel and channel."""
    _, rows, channels, background = read_bar(path, bar_height)
    return sum(abs(line[x * channels + c] - background[c]) for line in rows for x in range(x0, x1 + 1) for c in range(3))


def find_widgets(path, bar_height, icon_size, word_join):
    """Return (right_bar, widgets, ink, badges): the clusters of the right bar, each widget's (x0, x1, vertical ink
    center, kind), the ink rows per column and the badge boxes."""
    width, rows, channels, background = read_bar(path, bar_height)

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
    def is_picto(cluster):
        return is_pictogram(cluster[1] - cluster[0] + 1, cluster_height(ink, cluster), icon_size)

    runs = []
    for cluster in right_bar:
        if runs and not is_picto(cluster) and not is_picto(runs[-1][-1]) and cluster[0] - runs[-1][-1][1] - 1 < word_join:
            runs[-1].append(cluster)
        else:
            runs.append([cluster])
    widgets = []
    for run in runs:
        x0, x1 = run[0][0], run[-1][1]
        ys = [y for x in range(x0, x1 + 1) for y in ink[x]]
        widgets.append((x0, x1, (min(ys) + max(ys)) / 2, PICTOGRAM if is_picto(run[0]) else TEXT))
    return right_bar, widgets, ink, badges
