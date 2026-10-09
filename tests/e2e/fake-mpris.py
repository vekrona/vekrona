#!/usr/bin/env python3
"""Serve one MPRIS media player on the session bus until killed, to put a known track in the Sound popout's media card.

usage: fake-mpris.py ART_RRGGBB

The player is org.mpris.MediaPlayer2.vekronatest: "Vekrona Test Player", playing "Lighthouse Signal" by "Quiet Harbor".
Its cover art is a solid 64x64 PNG of ART_RRGGBB (six hex digits), written to a temporary directory that is removed on exit.
It cannot be raised, and every transport method does nothing.

GDBus answers org.freedesktop.DBus.Properties Get and GetAll for the registered interfaces from the properties below.
"""
import pathlib
import shutil
import signal
import struct
import sys
import tempfile
import zlib

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS_NAME = "org.mpris.MediaPlayer2.vekronatest"
OBJECT_PATH = "/org/mpris/MediaPlayer2"
IDENTITY = "Vekrona Test Player"
TRACK_ID = "/org/vekrona/test/track/1"
TITLE = "Lighthouse Signal"
ARTIST = "Quiet Harbor"
ART_SIZE = 64

ROOT_INTERFACE = """<node><interface name="org.mpris.MediaPlayer2">
<property name="Identity" type="s" access="read"/><property name="DesktopEntry" type="s" access="read"/>
<property name="CanRaise" type="b" access="read"/><property name="CanQuit" type="b" access="read"/>
<property name="HasTrackList" type="b" access="read"/>
<method name="Raise"/><method name="Quit"/>
</interface></node>"""

PLAYER_INTERFACE = """<node><interface name="org.mpris.MediaPlayer2.Player">
<property name="PlaybackStatus" type="s" access="read"/><property name="Metadata" type="a{sv}" access="read"/>
<property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
<property name="CanPlay" type="b" access="read"/><property name="CanPause" type="b" access="read"/>
<property name="CanControl" type="b" access="read"/>
<method name="Next"/><method name="Previous"/><method name="PlayPause"/><method name="Play"/><method name="Pause"/><method name="Stop"/>
</interface></node>"""


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def write_solid_png(path, rgb):
    header = struct.pack(">IIBBBBB", ART_SIZE, ART_SIZE, 8, 2, 0, 0, 0)
    rows = (b"\x00" + bytes(rgb) * ART_SIZE) * ART_SIZE
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def properties(art_url):
    return {
        "org.mpris.MediaPlayer2": {
            "Identity": GLib.Variant("s", IDENTITY),
            "DesktopEntry": GLib.Variant("s", ""),
            "CanRaise": GLib.Variant("b", False),
            "CanQuit": GLib.Variant("b", False),
            "HasTrackList": GLib.Variant("b", False),
        },
        "org.mpris.MediaPlayer2.Player": {
            "PlaybackStatus": GLib.Variant("s", "Playing"),
            "Metadata": GLib.Variant("a{sv}", {
                "mpris:trackid": GLib.Variant("o", TRACK_ID),
                "xesam:title": GLib.Variant("s", TITLE),
                "xesam:artist": GLib.Variant("as", [ARTIST]),
                "mpris:artUrl": GLib.Variant("s", art_url),
            }),
            "CanGoNext": GLib.Variant("b", True),
            "CanGoPrevious": GLib.Variant("b", True),
            "CanPlay": GLib.Variant("b", True),
            "CanPause": GLib.Variant("b", True),
            "CanControl": GLib.Variant("b", True),
        },
    }


def serve(art_url):
    props = properties(art_url)
    loop = GLib.MainLoop()
    lost = []

    def get_property(_connection, _sender, _path, interface, name):
        return props[interface][name]

    def call(_connection, _sender, _path, _interface, _method, _args, invocation):
        invocation.return_value(None)

    def bus_acquired(connection, _name):
        for xml in (ROOT_INTERFACE, PLAYER_INTERFACE):
            connection.register_object(OBJECT_PATH, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], call, get_property, None)

    def name_acquired(_connection, _name):
        print("serving", flush=True)

    def name_lost(_connection, _name):
        lost.append(True)
        loop.quit()

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, loop.quit)
    owner = Gio.bus_own_name(Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE, bus_acquired, name_acquired, name_lost)
    loop.run()
    Gio.bus_unown_name(owner)
    if lost:
        sys.exit(f"could not own {BUS_NAME} on the session bus")


def main(art_hex):
    rgb = bytes.fromhex(art_hex)
    if len(rgb) != 3:
        sys.exit(__doc__)
    art_dir = pathlib.Path(tempfile.mkdtemp(prefix="fake-mpris-"))
    try:
        art = art_dir / "art.png"
        write_solid_png(art, rgb)
        serve(art.as_uri())
    finally:
        shutil.rmtree(art_dir)


if len(sys.argv) != 2:
    sys.exit(__doc__)
main(sys.argv[1])
