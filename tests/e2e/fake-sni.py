#!/usr/bin/env python3
"""Serve one StatusNotifierItem on the session bus until killed, to put a known icon in the bar's tray.
Its menu, shown on a right click, has the single entry MENU_LABEL.

usage: fake-sni.py opaque|alpha|blank|plain|ICON.png|themed:ICON.png

  ICON.png  a real tray icon, saved as an 8-bit RGBA PNG, served at its own size (png_rows.py must sit next to this script)

  themed:ICON.png  like Steam's: no pixmap, only an icon name (ICON) and an icon theme path (ICON.png's directory), so the shell
                   asks the icon theme for the picture

  opaque  a light, fully opaque square with a 3x3 grid of dark dots, which tinting by alpha alone turns into a solid square
  alpha   a black disc on a transparent background
  plain   like opaque, with no menu at all, and it prints "activated" when the bar asks it to act (a left click)
  blank   a fully transparent square: it takes the tray slot and draws nothing, so a screenshot with it is the baseline of the
          same layout for the icons above
"""
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

SIZE = 32
# Hard-edged, so that only the shell's own resampling can anti-alias it; big enough to be shrunk to every tested icon size by at least 2x.
ALPHA_SIZE = 64
MARGIN = 3
DOT = 4
DOT_PERIOD = 11
BACKGROUND = (0xE0, 0xE0, 0xE0)
DOT_COLOR = (0x20, 0x20, 0x20)
MENU_LABEL = "Fake menu entry"
MENU_PATH = "/Menu"
THEMED_PREFIX = "themed:"

INTERFACE = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Id" type="s" access="read"/><property name="Title" type="s" access="read"/>
<property name="Category" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="IconName" type="s" access="read"/><property name="IconThemePath" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
</interface></node>"""

MENU_INTERFACE = """<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
<arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/>
<arg type="a(ia{sv})" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
</interface></node>"""

MENU_PROPS = {
    "Version": GLib.Variant("u", 3),
    "TextDirection": GLib.Variant("s", "ltr"),
    "Status": GLib.Variant("s", "normal"),
    "IconThemePath": GLib.Variant("as", []),
}
ENTRY = (1, {"label": GLib.Variant("s", MENU_LABEL)}, [])
ROOT = (0, {"children-display": GLib.Variant("s", "submenu")}, [GLib.Variant("(ia{sv}av)", ENTRY)])


def menu_call(_connection, _sender, _path, _interface, method, args, invocation):
    if method == "GetLayout":
        invocation.return_value(GLib.Variant("(u(ia{sv}av))", (1, ROOT)))
    elif method == "GetGroupProperties":
        invocation.return_value(GLib.Variant("(a(ia{sv}))", ([ENTRY[:2]],)))
    elif method == "AboutToShow":
        invocation.return_value(GLib.Variant("(b)", (False,)))
    else:
        invocation.return_value(None)


def pixel(kind, x, y):
    if kind == "blank":
        return (0, 0, 0, 0)
    if kind == "alpha":
        inside = (x - ALPHA_SIZE / 2 + 0.5) ** 2 + (y - ALPHA_SIZE / 2 + 0.5) ** 2 <= (ALPHA_SIZE / 2) ** 2
        return (0xFF, 0, 0, 0) if inside else (0, 0, 0, 0)
    in_dot = all(0 <= c - MARGIN < 3 * DOT_PERIOD - 1 and (c - MARGIN) % DOT_PERIOD < DOT for c in (x, y))
    return (0xFF, *(DOT_COLOR if in_dot else BACKGROUND))


def pixmap(kind):
    size = ALPHA_SIZE if kind == "alpha" else SIZE
    data = bytes(channel for y in range(size) for x in range(size) for channel in pixel(kind, x, y))
    return GLib.Variant("a(iiay)", [(size, size, data)])


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
    themed = kind.startswith(THEMED_PREFIX)
    kind = kind.removeprefix(THEMED_PREFIX)
    name = os.path.splitext(os.path.basename(kind))[0]
    props = {
        "Id": GLib.Variant("s", "fake-sni-" + name),
        "Title": GLib.Variant("s", name),
        "Category": GLib.Variant("s", "ApplicationStatus"),
        "Status": GLib.Variant("s", "Active"),
        "IconName": GLib.Variant("s", name if themed else ""),
        "IconThemePath": GLib.Variant("s", os.path.dirname(kind) if themed else ""),
        "IconPixmap": GLib.Variant("a(iiay)", []) if themed else png_pixmap(kind) if kind.endswith(".png") else pixmap(kind),
        "ItemIsMenu": GLib.Variant("b", False),
        "Menu": GLib.Variant("o", MENU_PATH),
    }

    if kind == "plain":
        del props["Menu"]

    def get_property(_connection, _sender, _path, _interface, name):
        return props[name]

    def call(_connection, _sender, _path, _interface, method, _args, invocation):
        if method == "Activate":
            print("activated", flush=True)
        invocation.return_value(None)

    def acquired(connection, _name):
        connection.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(INTERFACE).interfaces[0], call, get_property, None)
        connection.register_object(MENU_PATH, Gio.DBusNodeInfo.new_for_xml(MENU_INTERFACE).interfaces[0], menu_call, lambda _c, _s, _p, _i, name: MENU_PROPS[name], None)
        connection.call_sync(
            "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem", GLib.Variant("(s)", ("/StatusNotifierItem",)), None, Gio.DBusCallFlags.NONE, -1, None)
        print("registered", flush=True)

    Gio.bus_own_name(Gio.BusType.SESSION, f"org.kde.StatusNotifierItem-{name}-1", Gio.BusNameOwnerFlags.NONE, acquired, None, None)
    GLib.MainLoop().run()


if len(sys.argv) != 2 or not (sys.argv[1] in ("opaque", "alpha", "blank", "plain") or sys.argv[1].endswith(".png")):
    sys.exit(__doc__)
main(sys.argv[1])
