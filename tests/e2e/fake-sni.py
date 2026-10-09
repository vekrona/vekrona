#!/usr/bin/env python3
"""Serve one StatusNotifierItem on the session bus until killed, to put a known icon in the bar's tray.

usage: fake-sni.py opaque|alpha|ICON.png

  ICON.png  a real tray icon, saved as an 8-bit RGBA PNG, served at its own size (png_rows.py must sit next to this script)

  opaque  a light, fully opaque square with a 3x3 grid of dark dots, which tinting by alpha alone turns into a solid square
  alpha   a black disc on a transparent background
"""
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

SIZE = 32
MARGIN = 3
DOT = 4
DOT_PERIOD = 11
BACKGROUND = (0xE0, 0xE0, 0xE0)
DOT_COLOR = (0x20, 0x20, 0x20)

INTERFACE = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Id" type="s" access="read"/><property name="Title" type="s" access="read"/>
<property name="Category" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="IconName" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
</interface></node>"""


def pixel(kind, x, y):
    if kind == "alpha":
        inside = (x - SIZE / 2 + 0.5) ** 2 + (y - SIZE / 2 + 0.5) ** 2 <= (SIZE / 2) ** 2
        return (0xFF, 0, 0, 0) if inside else (0, 0, 0, 0)
    in_dot = all(0 <= c - MARGIN < 3 * DOT_PERIOD - 1 and (c - MARGIN) % DOT_PERIOD < DOT for c in (x, y))
    return (0xFF, *(DOT_COLOR if in_dot else BACKGROUND))


def pixmap(kind):
    data = bytes(channel for y in range(SIZE) for x in range(SIZE) for channel in pixel(kind, x, y))
    return GLib.Variant("a(iiay)", [(SIZE, SIZE, data)])


def png_pixmap(path):
    from png_rows import read_png_rows

    width, rows, channels = read_png_rows(path)
    assert channels == 4, f"{path} must be an RGBA PNG"
    data = bytes(
        channel
        for row in rows
        for x in range(width)
        for channel in (row[4 * x + 3], row[4 * x], row[4 * x + 1], row[4 * x + 2])
    )
    return GLib.Variant("a(iiay)", [(width, len(rows), data)])


def main(kind):
    name = os.path.splitext(os.path.basename(kind))[0]
    props = {
        "Id": GLib.Variant("s", "fake-sni-" + name),
        "Title": GLib.Variant("s", name),
        "Category": GLib.Variant("s", "ApplicationStatus"),
        "Status": GLib.Variant("s", "Active"),
        "IconName": GLib.Variant("s", ""),
        "IconPixmap": png_pixmap(kind) if kind.endswith(".png") else pixmap(kind),
        "ItemIsMenu": GLib.Variant("b", False),
        "Menu": GLib.Variant("o", "/NoMenu"),
    }

    def get_property(_connection, _sender, _path, _interface, name):
        return props[name]

    def call(_connection, _sender, _path, _interface, _method, _args, invocation):
        invocation.return_value(None)

    def acquired(connection, _name):
        connection.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(INTERFACE).interfaces[0], call, get_property, None)
        connection.call_sync(
            "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem", GLib.Variant("(s)", ("/StatusNotifierItem",)), None, Gio.DBusCallFlags.NONE, -1, None)
        print("registered", flush=True)

    Gio.bus_own_name(Gio.BusType.SESSION, f"org.kde.StatusNotifierItem-{name}-1", Gio.BusNameOwnerFlags.NONE, acquired, None, None)
    GLib.MainLoop().run()


if len(sys.argv) != 2 or not (sys.argv[1] in ("opaque", "alpha") or sys.argv[1].endswith(".png")):
    sys.exit(__doc__)
main(sys.argv[1])
