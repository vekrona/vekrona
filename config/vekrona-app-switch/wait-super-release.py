#!/usr/bin/env python3
"""Exit once no Super key is held down.

Neither Sway nor Qt sees Super go up reliably, and the user may not read the keyboards, so xremap (which sees every key,
and runs as the only user that may read them) tells: its modmap runs vekrona-super-state on every Super press and
release, and that writes 1 or 0 to /run/xremap/super-L and /run/xremap/super-R. This waits for those files to change.
"""
import os
import select
import subprocess
import sys

STATE_DIR = os.environ.get("VEKRONA_SUPER_STATE_DIR", "/run/xremap")  # the variable is for the test
STATE_FILES = [f"{STATE_DIR}/super-L", f"{STATE_DIR}/super-R"]
GIVE_UP_SEC = 60


def super_down():
    for path in STATE_FILES:
        try:
            with open(path) as f:
                if f.read() == "1":
                    return True
        except FileNotFoundError:
            continue
    return False


def main():
    if not os.path.isdir(STATE_DIR):
        sys.exit(f"{STATE_DIR} does not exist: is xremap.service running?")
    # The watch starts before the first look, so a release between the two is not missed.
    watch = subprocess.Popen(
        ["inotifywait", "--monitor", "--quiet", "--event", "close_write", "--format", "x", STATE_DIR],
        stdout=subprocess.PIPE,
    )
    try:
        while super_down():
            readable, _, _ = select.select([watch.stdout], [], [], GIVE_UP_SEC)
            if not readable:
                sys.exit(f"Super still down after {GIVE_UP_SEC} s")
            if not watch.stdout.readline():
                sys.exit("inotifywait ended")
    finally:
        watch.kill()
        watch.wait()


main()
