#!/usr/bin/env bash
# A file sent to a device that is offline waits in their shared drop folder, and lands in that device's Downloads when it comes
# online: a second file of the same name becomes "name (2)", and the drop folders are empty on both sides at the end. The other
# device is a second Syncthing in the guest (tests/e2e/lib/sync-peer.sh), with its own vekrona-sync watcher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"

STEP_TIMEOUT_SEC=90
SEND_DIR=e2e-sync-send
MAIN_HOME="$(vekrona-dev run printenv HOME)"
export SEND_DIR MAIN_HOME

# The files under HOME $1 inside the inbox of device $2 of any drop folder: none, once everything has been delivered and the
# deletions have synced back.
inbox_empty() { vekrona-dev run bash -c 'shopt -s nullglob; files=("$1"/.local/share/vekrona-sync/drops/vekrona-drop-*/to/"$2"/*); ((${#files[@]} == 0))' _ "$1" "$2"; }
main_inbox_empty() { inbox_empty "$MAIN_HOME" "$PEER_ID"; }
peer_inbox_empty() { inbox_empty "$PEER_HOME" "$PEER_ID"; }
queued_on_main() { vekrona-dev run bash -c 'shopt -s nullglob; files=("$1"/.local/share/vekrona-sync/drops/vekrona-drop-*/to/"$2"/"$3"); ((${#files[@]} == 1))' _ "$MAIN_HOME" "$PEER_ID" "$1"; }
peer_downloaded() { [[ "$(peer cat "$PEER_HOME/Downloads/$1")" == "$2" ]]; }
peer_state_has_arrivals() { [[ "$(peer cat "$PEER_HOME/.local/state/vekrona/sync.json" | jq -r '[.arrivals[].name] | sort | join(",")')" == "$1" ]]; }
export -f inbox_empty main_inbox_empty peer_inbox_empty queued_on_main peer_downloaded peer_state_has_arrivals

write_file() { vekrona-dev run bash -c 'mkdir -p "$HOME/$1" && printf %s "$3" >"$HOME/$1/$2"' _ "$SEND_DIR" "$1" "$2"; }
remove_files() { vekrona-dev run bash -c 'rm -rf "$HOME/$1"' _ "$SEND_DIR"; }
# The drop folder is made by the first send; the guest's copy of it goes when the other device is forgotten.
remove_drop() {
  [[ -n "${PEER_ID:-}" ]] || return 0
  vekrona-dev run bash -c 'rm -rf "$HOME"/.local/share/vekrona-sync/drops/vekrona-drop-*"$1"*' _ "$PEER_ID"
}
cleanup() { run_cleanups close_notification_centre peer_stop main_forget_peer remove_drop remove_files; }

vekrona-dev session
trap cleanup EXIT
clear_notifications

# Pair, with the other device's watcher and Syncthing as they would run for a user, then stop it.
peer_start
peer_asks_main
vekrona-dev run vekrona-sync accept "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_known_on_main
main_dials_peer
peer_kill syncthing
log "ok: the other device is paired and now offline"

write_file one.txt first
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" one.txt' _ "$SEND_DIR" "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- queued_on_main one.txt
log "ok: send puts the file in the drop folder while the device is offline"

peer_syncthing_start
peer_spawn watch vekrona-sync watch
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_downloaded one.txt first
log "ok: when the device comes online its drop folder is taken without asking and the file lands in Downloads"

write_file one.txt second
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" one.txt' _ "$SEND_DIR" "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_downloaded 'one (2).txt' second
[[ "$(peer cat "$PEER_HOME/Downloads/one.txt")" == first ]] || die "the second file must not overwrite the first"
log "ok: a second file of the same name lands as 'one (2).txt' and the first is untouched"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_inbox_empty
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_inbox_empty
log "ok: the drop folders are empty on both sides"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_state_has_arrivals 'one (2).txt,one.txt'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'one.txt received'
log "ok: the receiving device lists both arrivals in sync.json and notified"
