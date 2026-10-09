#!/usr/bin/env python3
"""Guest-side stopwatch for tests/e2e/notification-dismiss.sh.

Run inside the sway session on an empty screen, then show a toast and click its X.
Prints one JSON line, "ready", once the watchers run, then one more with the
milliseconds from the mouse button release until the toast's screen area looks
as it did when the probe started (the toast is gone).
"""
import glob
import json
import os
import select
import struct
import subprocess
import sys
import threading
import time

BTN_LEFT = 0x110
EV_KEY = 1
EVENT = struct.Struct("llHHi")
DEADLINE_SEC = 30
CHANGED_BY = 3

stamps = {}
ready = {name: threading.Event() for name in ("keys", "screen")}
done = threading.Event()


def watch_clicks():
    fds = [os.open(path, os.O_RDONLY | os.O_NONBLOCK) for path in glob.glob("/dev/input/event*")]
    ready["keys"].set()
    while not done.is_set():
        readable, _, _ = select.select(fds, [], [], 0.05)
        for fd in readable:
            try:
                data = os.read(fd, EVENT.size * 64)
            except BlockingIOError:
                continue
            for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, kind, code, value = EVENT.unpack_from(data, off)
                if kind == EV_KEY and code == BTN_LEFT and value == 0:
                    stamps.setdefault("click", time.monotonic())


def watch_screen(region):
    def grab():
        return subprocess.check_output(["grim", "-g", region, "-t", "ppm", "-"])

    before_click = grab()
    ready["screen"].set()
    while not done.is_set():
        now = grab()
        stamp = time.monotonic()
        if "click" not in stamps:
            before_click = now
            continue
        diff = sum(abs(a - b) for a, b in zip(now, before_click)) / len(before_click)
        if diff > CHANGED_BY:
            stamps["changed"] = stamp
            done.set()


def main():
    x, y, w, h = sys.argv[1:5]
    region = f"{x},{y} {w}x{h}"
    for target in (watch_clicks, lambda: watch_screen(region)):
        threading.Thread(target=target, daemon=True).start()
    for event in ready.values():
        event.wait()
    print(json.dumps({"ready": True}), flush=True)
    if not done.wait(DEADLINE_SEC):
        print(json.dumps({"error": "the watched area never changed after the click", "seen": sorted(stamps)}), flush=True)
        return 1
    print(json.dumps({"changed_ms": round((stamps["changed"] - stamps["click"]) * 1000)}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
