#!/usr/bin/env python3
"""Guest-side stopwatch for tests/e2e/app-switch-latency.sh.

Run inside the sway session while the test presses and releases Super+Tab.
Prints one JSON line, "ready", once every watcher runs, then one more with
the milliseconds from the Tab binding until the screen centre changes (the
overlay is up) and from the Super release until sway reports a focus change.
That line also carries what one screen sample and one sway IPC round trip cost
on this machine right now (poll_ms, ipc_ms): the overlay is noticed no sooner
than the sample after it appears, and a focus change takes at least a round trip
when the machine is busy, so a scenario judges the timings relative to these.
"""
import atexit
import glob
import json
import os
import select
import struct
import subprocess
import sys
import threading
import time

KEY_LEFTMETA, KEY_RIGHTMETA, KEY_TAB = 125, 126, 15
EV_KEY = 1
EVENT = struct.Struct("llHHi")
SWAY_EVENTS = "/mnt/vekrona-dev/guest/sway-events.py"
DEADLINE_SEC = 20
POLL_PIXELS = "40x10"
CHANGED_BY = 40

SAMPLES = 5

stamps = {}
cost_ms = {}
ready = {name: threading.Event() for name in ("sway", "keys", "screen")}
done = threading.Event()


def stamp(name):
    stamps.setdefault(name, time.monotonic())


def watch_sway():
    proc = subprocess.Popen(["python3", "-B", SWAY_EVENTS, "window", "binding"],
                            stdout=subprocess.PIPE, text=True)
    atexit.register(proc.terminate)
    for line in proc.stdout:
        event = json.loads(line)
        if "subscribed" in event:
            ready["sway"].set()
        elif "binding" in event and event["binding"]["symbol"] == "Tab":
            stamp("tab")
        elif event.get("change") == "focus" and "release" in stamps:
            stamp("focus")
            done.set()
            return


def watch_keys():
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
                if kind == EV_KEY and value == 0 and code in (KEY_LEFTMETA, KEY_RIGHTMETA):
                    stamp("release")


def centre_pixels():
    out = json.loads(subprocess.check_output(["swaymsg", "-t", "get_outputs"]))
    rect = out[0]["rect"]
    w, h = (int(n) for n in POLL_PIXELS.split("x"))
    geometry = f"{rect['x'] + rect['width'] // 2 - w // 2},{rect['y'] + rect['height'] // 2 - h // 2} {POLL_PIXELS}"
    return lambda: subprocess.check_output(["grim", "-g", geometry, "-t", "ppm", "-"])


def median_cost_ms(operation):
    costs = []
    for _ in range(SAMPLES):
        started = time.monotonic()
        operation()
        costs.append((time.monotonic() - started) * 1000)
    return round(sorted(costs)[SAMPLES // 2])


def watch_screen():
    grab = centre_pixels()
    baseline = grab()
    cost_ms["poll_ms"] = median_cost_ms(grab)
    cost_ms["ipc_ms"] = median_cost_ms(lambda: subprocess.check_output(["swaymsg", "-t", "get_version"]))
    ready["screen"].set()
    while not done.is_set():
        now = grab()
        diff = sum(abs(a - b) for a, b in zip(now, baseline)) / len(baseline)
        if "tab" in stamps and diff > CHANGED_BY:
            stamp("overlay")
            return


def main():
    for target in (watch_sway, watch_keys, watch_screen):
        threading.Thread(target=target, daemon=True).start()
    for event in ready.values():
        event.wait()
    print(json.dumps({"ready": True}), flush=True)
    if not done.wait(DEADLINE_SEC):
        print(json.dumps({"error": "no focus change after the Super release", "seen": sorted(stamps)}), flush=True)
        return 1
    missing = [n for n in ("tab", "overlay", "release", "focus") if n not in stamps]
    if missing:
        print(json.dumps({"error": f"never saw {missing}", "seen": sorted(stamps)}), flush=True)
        return 1
    print(json.dumps({"overlay_ms": round((stamps["overlay"] - stamps["tab"]) * 1000),
                      "focus_ms": round((stamps["focus"] - stamps["release"]) * 1000),
                      **cost_ms}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
