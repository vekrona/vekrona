#!/usr/bin/env python3
"""Look at one named widget of the right-side bar on a screenshot.

usage: bar-widget.py SCREENSHOT.png BAR_HEIGHT ICON_S GROUP_JOIN_PX COMMAND [NAME]

  kinds       print the kind of every widget of the right bar from the left, one letter each: P pictogram, T text
  center NAME print the widget's center as "x y"
  ink NAME    print how much ink the widget's columns hold
  gauge       print the fill of the load widget's two halves as "CPU MEMORY", each 0 to 100

The widgets are named by their place from the right edge, on the bar of the VM, which has no battery: the clock, the
notification bell, the agent, the network and the sound icon. The load widget is found by its shape, one frame split by a single line,
because the caffeine and tray pictograms may sit left of it. Exits 1 when the bar has fewer widgets than the name needs."""
import sys

from bar_widgets import PICTOGRAM, find_widgets, gauge_fills, ink_mass

FROM_RIGHT = ["clock", "bell", "agent", "network", "sound"]
LOAD = "load"


def named_widget(widgets, ink, name):
    """Return the widget called name, or exit 1 when the bar does not show it."""
    if name == LOAD:
        gauges = [widget for widget in widgets if widget[3] == PICTOGRAM and gauge_fills(ink, widget[0], widget[1])]
        if not gauges:
            sys.exit("the bar shows no frame split by a single line, so there is no load")
        return gauges[0]
    place = FROM_RIGHT.index(name)
    if len(widgets) <= place:
        sys.exit(f"the bar shows {len(widgets)} widgets, so there is no {name}")
    return widgets[-1 - place]


def main():
    path, bar_height, icon_size, group_join, command = sys.argv[1], *map(int, sys.argv[2:5]), sys.argv[5]
    _, widgets, ink, _ = find_widgets(path, bar_height, icon_size, group_join)
    if command == "kinds":
        print("".join("P" if kind == PICTOGRAM else "T" for _, _, _, kind in widgets))
        return
    if command == "gauge":
        x0, x1, _, _ = named_widget(widgets, ink, LOAD)
        print(*gauge_fills(ink, x0, x1))
        return
    x0, x1, cy, _ = named_widget(widgets, ink, sys.argv[6])
    if command == "center":
        print(f"{(x0 + x1) // 2} {round(cy)}")
    elif command == "ink":
        print(ink_mass(path, bar_height, x0, x1))
    else:
        sys.exit(__doc__)


main()
