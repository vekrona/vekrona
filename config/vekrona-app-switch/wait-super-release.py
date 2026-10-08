#!/usr/bin/env python3
"""Exit once no Super key is held down on any input device.

Neither Sway nor Qt sees Super go up reliably, so ask the kernel for the key
state (EVIOCGKEY) of every device, xremap's virtual keyboard included, and
re-check whenever any device reports an event.
"""
import fcntl
import glob
import os
import select
import sys

EVIOCGKEY = 0x80000000 | (96 << 16) | (ord("E") << 8) | 0x18
KEY_LEFTMETA, KEY_RIGHTMETA = 125, 126
GIVE_UP_SEC = 60


def has_super_key(event):
    """Whether /sys says the device can send Super (its EV_KEY capability mask)."""
    with open(f"/sys/class/input/{event}/device/capabilities/key") as f:
        words = [int(w, 16) for w in f.read().split()]  # most significant word first
    mask = sum(w << (64 * i) for i, w in enumerate(reversed(words)))
    return any(mask >> k & 1 for k in (KEY_LEFTMETA, KEY_RIGHTMETA))


def open_devices():
    """Open only devices that can send Super: closing an evdev fd costs the
    kernel ~10 ms each, so holding all of them delayed the exit by ~250 ms."""
    fds = []
    for path in glob.glob("/dev/input/event*"):
        if not has_super_key(os.path.basename(path)):
            continue
        try:
            fds.append(os.open(path, os.O_RDONLY | os.O_NONBLOCK))
        except PermissionError:
            continue
    if not fds:
        sys.exit("cannot read any /dev/input/event* device: is the user in the input group?")
    return fds


def super_down(fds):
    for fd in fds:
        keys = bytearray(96)
        fcntl.ioctl(fd, EVIOCGKEY, keys)
        if any(keys[k // 8] >> (k % 8) & 1 for k in (KEY_LEFTMETA, KEY_RIGHTMETA)):
            return True
    return False


def main():
    fds = open_devices()
    while super_down(fds):
        readable, _, _ = select.select(fds, [], [], GIVE_UP_SEC)
        if not readable:
            sys.exit(f"Super still down after {GIVE_UP_SEC} s")
        for fd in readable:
            try:
                os.read(fd, 4096)
            except BlockingIOError:
                pass


main()
