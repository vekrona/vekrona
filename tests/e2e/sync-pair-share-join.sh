#!/usr/bin/env bash
# Another device asks to connect and is accepted from the notification, a shared folder reaches it, and vekrona-sync follows a
# restart of Syncthing. The other device is a second Syncthing in the guest (tests/e2e/lib/sync-peer.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"

STEP_TIMEOUT_SEC=90
SHARE_NAME=e2e-sync-share
SHARED_ID=
export SHARE_NAME

state_json() { vekrona-dev run bash -c 'cat "$HOME/.local/state/vekrona/sync.json"'; }
# Whether sync.json satisfies a jq test; a state file that is not there yet is a no.
state_is() { state_json 2>/dev/null | jq -e --arg id "$SHARED_ID" --arg peer "$PEER_ID" "$1" >/dev/null; }
watcher_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-sync.service; }
accept_button() { vekrona-dev see find '^Accept$'; }
folder_offered_to_peer() { [[ "$(peer_rest GET /rest/cluster/pending/folders | jq --arg id "$SHARED_ID" 'has($id)')" == true ]]; }
peer_has() { peer test -f "$PEER_HOME/Sync/$SHARE_NAME/$1"; }
invocation() { vekrona-dev sh systemctl --user show -p InvocationID --value vekrona-sync.service; }
started_again() { [[ "$(invocation)" != "$1" ]]; }
export -f state_json state_is watcher_active accept_button folder_offered_to_peer peer_has invocation started_again

remove_share() { vekrona-dev run bash -c 'rm -rf "$HOME/$1"' _ "$SHARE_NAME"; }
cleanup() { run_cleanups close_notification_centre peer_stop main_forget_peer remove_share; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
log "ok: vekrona-sync.service runs with the session"

peer_start
peer_asks_main
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.pendingDevices | any(.[]; .id == $peer)'
log "ok: a device that asks to connect is in sync.json's pendingDevices"

open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'wants to connect'
read -r x y <<<"$(accept_button)"
[[ -n "${x:-}" ]] || die "the pairing notification must show an Accept button, but OCR found none"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_known_on_main
close_notification_centre
log "ok: the Accept action of the notification adds the device"

main_dials_peer
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer and .connected)'
log "ok: the accepted device is online in sync.json's devices"

vekrona-dev run bash -c 'mkdir -p "$HOME/$1" && echo hello >"$HOME/$1/hello.txt"' _ "$SHARE_NAME"
SHARED_ID="$(vekrona-dev run bash -c 'vekrona-sync share "$HOME/$1"' _ "$SHARE_NAME")"
[[ -n "$SHARED_ID" ]] || die "vekrona-sync share printed no folder ID"
export SHARED_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- folder_offered_to_peer
log "ok: a shared folder is offered to the accepted device"

peer vekrona-sync join "$SHARED_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has hello.txt
log "ok: after Join the folder's file arrives at ~/Sync/<label>"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle" and (.folders | any(.[]; .id == $id and .state == "idle" and .progress == 100))'
log "ok: sync.json shows the folder up to date"

before="$(invocation)"
vekrona-dev sh systemctl --user restart syncthing.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- started_again "$before"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
vekrona-dev run bash -c 'echo again >"$HOME/$1/after-restart.txt"' _ "$SHARE_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has after-restart.txt
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle" and (.devices | any(.[]; .id == $peer and .connected))'
log "ok: a restart of Syncthing restarts the watcher, and syncing and sync.json go on"
