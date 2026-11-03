#!/usr/bin/env python3
"""Check from a previous boot's journal that the session's units stopped before its scope did.

usage: session-teardown-order.py MARKER SESSION_ID UNIT...  < journalctl -o json output

The journal holds, in order, the entry whose MESSAGE is MARKER (written just before the reboot was requested), the user
manager's "Stopped" entries (USER_UNIT is the unit) and the system manager's "Stopping" entry of session-SESSION_ID.scope
(UNIT is the scope). The whole input is read, so that journalctl never meets a closed pipe. Every UNIT must have stopped after the marker and before the scope began to stop. Exits 1 and names
the first violation otherwise."""
import json
import sys


def main():
    marker, session_id, units = sys.argv[1], sys.argv[2], sys.argv[3:]
    scope = f"session-{session_id}.scope"
    marker_seen = scope_stopping = False
    stopped = set()
    for line in sys.stdin:
        entry = json.loads(line)
        message = entry.get("MESSAGE")
        if message == marker:
            marker_seen = True
        elif not marker_seen or scope_stopping or not isinstance(message, str):
            continue
        elif entry.get("USER_UNIT") in units and message.startswith("Stopped "):
            stopped.add(entry["USER_UNIT"])
        elif entry.get("UNIT") == scope and message.startswith("Stopping "):
            scope_stopping = True
    if not marker_seen:
        sys.exit("the journal does not hold the marker, so the reboot is not in it")
    if not scope_stopping:
        sys.exit(f"the journal never shows {scope} stopping after the marker")
    not_stopped = [unit for unit in units if unit not in stopped]
    if not_stopped:
        sys.exit(f"{scope} began to stop before these units had stopped: {' '.join(not_stopped)}")
    print(f"{' '.join(units)} stopped before {scope} began to stop")


main()
