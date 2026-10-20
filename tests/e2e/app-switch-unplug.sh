#!/usr/bin/env bash
# The app switcher's Super watcher survives a keyboard that is unplugged while Super is held, and ends once no Super is down.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30
# Longer than the steps below take, so the watcher ends because the keyboard went, not because Super was let go. QEMU queues every
# later key event behind the release of a held key, so a rerun within this time finds its own Super press waiting for it.
HOLD_MS=15000
GUEST_LOG=/tmp/app-switch-unplug.log
WATCHER='$HOME/.config/quickshell/vekrona-app-switch/wait-super-release.py'

watcher_running() { vekrona-dev run pgrep -f "[w]ait-super-release.py" >/dev/null; }
watcher_exited() { vekrona-dev run grep -q '^exit=' "$GUEST_LOG"; }
# xremap writes 1 here when it sees Super go down; a watcher started before that finds no Super down and ends at once.
super_recorded_down() { vekrona-dev run grep -qx 1 /run/xremap/super-L; }
export -f watcher_running watcher_exited super_recorded_down
export GUEST_LOG

remove_log() { vekrona-dev run rm -f "$GUEST_LOG"; }
trap 'run_cleanups rebind_keyboards "kill_guest -f \"[w]ait-super-release.py\"" remove_log' EXIT

vekrona-dev session
vekrona-dev move 600 500
vekrona-dev run rm -f "$GUEST_LOG"

vekrona-dev hold super "$HOLD_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- super_recorded_down || die "xremap must record Super as down while it is held"
vekrona-dev spawn "$GUEST_LOG" -- bash -c "python3 $WATCHER; echo exit=\$?"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_running || die "the Super watcher must keep running while Super is held"

unbind_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_exited || die "the Super watcher must end once the keyboard that held Super is unplugged"
vekrona-dev run grep -qx 'exit=0' "$GUEST_LOG" || die "an unplugged keyboard holds nothing, so the watcher must exit 0, but it logged: $(vekrona-dev run cat "$GUEST_LOG")"
log "ok: unplugging the keyboard that holds Super ends the watcher with status 0"
