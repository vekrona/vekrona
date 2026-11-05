#!/usr/bin/env bash
# The turning Sync icon is a timer that wakes the shell four times a second, so it must not run while nobody can see it: the
# bar's Presence singleton (config/vekrona-shell/Presence.qml, the compositor's idle notification after 300 s without input, the
# time after which vekrona-idle.service locks the screen) gates it. The cheapest measure of "the icon's timer runs" is how often
# the shell's main thread is scheduled, read from /proc/PID/status over a fixed window (the one place where a duration is the
# measurement, not the order of events). A sync that outlasts the 300 s of idleness and two windows is made by throttling the
# receive rate. The other device is a second Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh):
#   - while input is recent and a folder syncs, the shell wakes at least 3 times a second more than when it is idle;
#   - after 300 s without input the screen is locked and, with the same sync still running, the shell wakes at least 3 times a
#     second less than before (the icon's timer and the load sampling are off);
#   - typing the password wakes it again: the sync goes on, and the shell wakes as often as before.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/sync-popout.sh
source "$ROOT/tests/e2e/lib/sync-popout.sh"

STEP_TIMEOUT_SEC=90
# swayidle locks after 300 s; the lock and the shell's idle notification both count from the last input.
IDLE_TIMEOUT_SEC=420
GUEST_PASSWORD=vekrona
FOLDER=e2e-sync-idle
# 30 MB at 50 KB/s take ten minutes, longer than the idle time and the three windows together.
SLOW_KBPS=50
BIG_BYTES=30000000
WINDOW_SEC=10
# The icon's timer fires 4 times a second, each wake is at least one switch.
MIN_SAVED_PER_SEC=3
PEER_ID=
export PEER_ID

shell_switches() {
  vekrona-dev run bash -c 'pid="$(systemctl --user show -p MainPID --value vekrona-shell.service)"
    [[ "$pid" -gt 0 ]] || { echo "vekrona-shell.service has no main process" >&2; exit 1; }
    awk "/ctxt_switches/ { n += \$2 } END { print n }" "/proc/$pid/status"'
}
# The scheduling switches of the shell during WINDOW_SEC.
shell_wakeups() {
  local before after
  before="$(shell_switches)"
  vekrona-dev run sleep "$WINDOW_SEC"
  after="$(shell_switches)"
  echo $((after - before))
}
throttle_receiving() { main_rest PATCH /rest/config/options "{\"maxRecvKbps\": $SLOW_KBPS, \"limitBandwidthInLan\": true}" >/dev/null; }
unthrottle_receiving() { main_rest PATCH /rest/config/options '{"maxRecvKbps": 0, "limitBandwidthInLan": false}' >/dev/null; }
remove_folder() { vekrona-dev run bash -c 'rm -rf "$HOME/Sync/$1"' _ "$FOLDER"; }
cleanup() { run_cleanups unthrottle_receiving peer_stop main_forget_peers remove_folder; }
export -f shell_switches

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | map(.id) == [$peer]'
vekrona-dev run vekrona-sync pair "$(state_json | jq -r '.nearby[0].id')"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has_pending_device
peer_accepts_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '(.state == "idle") and (.pendingDevices == []) and (.devices | any(.[]; .id == $peer and .connected))'

throttle_receiving
peer bash -c 'mkdir -p "$1" && head -c "$2" /dev/urandom >"$1/big.bin"' _ "$PEER_HOME/$FOLDER" "$BIG_BYTES"
peer_shares_folder "$FOLDER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.offers | any(.[]; .label == "'"$FOLDER"'")'
vekrona-dev run vekrona-sync join "peer-$FOLDER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "syncing"'

# Input now, so that the 300 s count from here, and the pointer rests away from the bar for the whole run.
vekrona-dev move 640 400
awake="$(shell_wakeups)"
log "the shell was scheduled $awake times in ${WINDOW_SEC}s while syncing with recent input"

vekrona-dev until --timeout "$IDLE_TIMEOUT_SEC" -- session_locked
state_is '.state == "syncing"' || die "the sync must still run when the screen is locked, or the comparison proves nothing"
idle="$(shell_wakeups)"
log "the shell was scheduled $idle times in ${WINDOW_SEC}s while syncing behind the lock screen"
((awake - idle >= MIN_SAVED_PER_SEC * WINDOW_SEC)) ||
  die "the shell must be scheduled at least $((MIN_SAVED_PER_SEC * WINDOW_SEC)) times less in ${WINDOW_SEC}s once the screen is locked and nobody is there ($awake awake, $idle idle)"
log "ok: with nobody there the shell is scheduled $((awake - idle)) times less in ${WINDOW_SEC}s, so the icon's timer and the sampling are off"

vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
state_is '.state == "syncing"' || die "the sync must still run after the unlock"
back="$(shell_wakeups)"
log "the shell was scheduled $back times in ${WINDOW_SEC}s after the unlock"
((back - idle >= MIN_SAVED_PER_SEC * WINDOW_SEC)) ||
  die "after the unlock the shell must be scheduled at least $((MIN_SAVED_PER_SEC * WINDOW_SEC)) times more in ${WINDOW_SEC}s than behind the lock screen ($back after, $idle before)"
log "ok: after the unlock the icon turns again ($back against $idle scheduled in ${WINDOW_SEC}s)"
