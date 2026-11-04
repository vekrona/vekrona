#!/usr/bin/env bash
# The Sync icon of the bar is the two round arrows of Material's "sync", and it shows the state of sync.json: the same arrows
# standing still while idle, turning in steps while a folder syncs (and standing still again when it is done, since a turning icon
# that nothing stops is a timer that wakes the laptop four times a second for nothing), a warning mark for a folder with a problem, and
# the arrows struck through while Syncthing does not run. Each is a pictogram to the bar scenarios, like its neighbours. The
# other device is a second Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh).
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
FOLDER=e2e-sync-icon
# A receive rate that makes a few megabytes take long enough to look at the icon turn.
SLOW_KBPS=100
STILL_LOOKS=6
PEER_ID=
export PEER_ID

declare -A SEEN_WHILE_SYNCING=()
# The icon's pixels, around the column where the icon was found while nothing happened.
look() { bar_widget look "$CENTRE"; }
# Every one of the next STILL_LOOKS looks, back to back (a turning icon changes within a quarter of a second, a screenshot takes longer), is $1 or, with no $1, the same.
holds_still() {
  local first="${1:-$(look)}" i
  for ((i = 0; i < STILL_LOOKS; i++)); do
    [[ "$(look)" == "$first" ]] || return 1
  done
}
sync_icon_is_a_pictogram() { [[ "$(bar_widget kinds | cut -c "$KINDS_SYNC_POSITION")" == P ]]; }
turned_often_enough() {
  SEEN_WHILE_SYNCING["$(look)"]=1
  ((${#SEEN_WHILE_SYNCING[@]} >= 3))
}
# Syncthing does not limit the rate of devices on a local network unless it is told to, and the veth pair is one.
throttle_receiving() { main_rest PATCH /rest/config/options "{\"maxRecvKbps\": $SLOW_KBPS, \"limitBandwidthInLan\": true}" >/dev/null; }
unthrottle_receiving() { main_rest PATCH /rest/config/options '{"maxRecvKbps": 0, "limitBandwidthInLan": false}' >/dev/null; }
start_syncthing() { vekrona-dev sh systemctl --user start syncthing.service; }
remove_folder() { vekrona-dev run bash -c 'rm -rf "$HOME/Sync/$1"' _ "$FOLDER"; }
cleanup() { run_cleanups start_syncthing unthrottle_receiving peer_stop main_forget_peers remove_folder; }

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
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '(.state == "idle") and (.pendingDevices == []) and (.offers == []) and (.devices | any(.[]; .id == $peer and .connected))'

# The pointer, which an earlier scenario may have left over the icon, would hide part of it.
vekrona-dev move 640 400
read -r CENTRE _ <<<"$(bar_widget center sync)"
# The sync icon is the fourth widget from the right of the bar (bar-widget.py's FROM_RIGHT), whatever number of widgets the bar has.
widgets="$(bar_widget kinds)"
KINDS_SYNC_POSITION=$((${#widgets} - 3))
export CENTRE KINDS_SYNC_POSITION
sync_icon_is_a_pictogram || die "the idle sync icon must be a pictogram to the bar scenarios, not a text"
IDLE="$(look)"
holds_still "$IDLE" || die "the idle sync icon must stand still"
snap icon-idle
log "ok: idle, the sync icon is a pictogram and stands still"

throttle_receiving
peer bash -c 'mkdir -p "$1" && head -c 5000000 /dev/urandom >"$1/big.bin"' _ "$PEER_HOME/$FOLDER"
peer_shares_folder "$FOLDER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.offers | any(.[]; .label == "'"$FOLDER"'")'
vekrona-dev run vekrona-sync join "peer-$FOLDER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "syncing"'
wait_until "$STEP_TIMEOUT_SEC" turned_often_enough || die "while syncing the icon showed only ${#SEEN_WHILE_SYNCING[@]} different looks, but it must turn through at least three"
sync_icon_is_a_pictogram || die "the icon must stay a pictogram while it turns"
snap icon-syncing
log "ok: while a folder syncs the icon turns (${#SEEN_WHILE_SYNCING[@]} different looks seen)"

unthrottle_receiving
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle"'
holds_still "$IDLE" || die "once the sync is done the icon must be the idle one and stand still again"
log "ok: when the sync is done the icon is the idle one again and stands still"

vekrona-dev run bash -c 'rm -rf "$HOME/Sync/$1"' _ "$FOLDER"
# The scan that notices the missing directory is refused with the very message that the icon then stands for.
scan_error="$(main_rest POST "/rest/db/scan?folder=peer-$FOLDER" 2>&1 || true)"
[[ "$scan_error" == *"folder path missing"* ]] || die "scanning a folder whose directory is gone must say so, but said: $scan_error"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "problem"'
PROBLEM="$(look)"
[[ "$PROBLEM" != "$IDLE" ]] || die "a folder with a problem must change the icon"
sync_icon_is_a_pictogram || die "the problem icon must be a pictogram"
holds_still "$PROBLEM" || die "the problem icon must stand still"
snap icon-problem
log "ok: a folder with a problem shows another icon, standing still"

vekrona-dev sh systemctl --user stop syncthing.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "offline"'
OFFLINE="$(look)"
[[ "$OFFLINE" != "$IDLE" && "$OFFLINE" != "$PROBLEM" ]] || die "an unreachable Syncthing must show an icon of its own"
sync_icon_is_a_pictogram || die "the offline icon must be a pictogram"
holds_still "$OFFLINE" || die "the offline icon must stand still"
snap icon-offline
log "ok: with Syncthing stopped the icon is struck through, standing still"
