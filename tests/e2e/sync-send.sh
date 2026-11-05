#!/usr/bin/env bash
# A file sent to a device that is offline waits in their shared drop folder, and lands in that device's Downloads when it comes
# online: the first is chosen with "Send file…" of the Sync popout in the portal's file chooser, a second of the same name becomes
# "name (2)", and the drop folders are empty on both sides at the end, with no ignore line left in the sender's drop. The other device is a second Syncthing in a network
# namespace of the guest (tests/e2e/lib/sync-peer.sh), paired through discovery, with its own vekrona-sync watcher.
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
SEND_DIR=e2e-sync-send
POPOUT_FILE=e2e-sync-popout.txt
PEER_ID=
MAIN_HOME="$(vekrona-dev run printenv HOME)"
export SEND_DIR POPOUT_FILE PEER_ID MAIN_HOME

# The files under HOME $1 inside the inbox of device $2 of any drop folder: none, once everything has been delivered and the
# deletions have synced back.
inbox_empty() { vekrona-dev run bash -c 'shopt -s nullglob; files=("$1"/.local/share/vekrona-sync/drops/vekrona-drop-*/to/"$2"/*); ((${#files[@]} == 0))' _ "$1" "$2"; }
main_inbox_empty() { inbox_empty "$MAIN_HOME" "$PEER_ID"; }
peer_inbox_empty() { inbox_empty "$PEER_HOME" "$PEER_ID"; }
queued_on_main() { vekrona-dev run bash -c 'shopt -s nullglob; files=("$1"/.local/share/vekrona-sync/drops/vekrona-drop-*/to/"$2"/"$3"); ((${#files[@]} == 1))' _ "$MAIN_HOME" "$PEER_ID" "$1"; }
peer_downloaded() { [[ "$(peer cat "$PEER_HOME/Downloads/$1")" == "$2" ]]; }
peer_state_has_arrivals() { [[ "$(peer cat "$PEER_HOME/.local/state/vekrona/sync.json" | jq -r '[.arrivals[].name] | sort | join(",")')" == "$1" ]]; }
main_stignore_empty() { [[ -z "$(main_rest GET "/rest/db/ignores?folder=$DROP_ID" | jq -r '.ignore[]')" ]]; }
export -f main_stignore_empty inbox_empty main_inbox_empty peer_inbox_empty queued_on_main peer_downloaded peer_state_has_arrivals

write_file() { vekrona-dev run bash -c 'mkdir -p "$HOME/$1" && printf %s "$3" >"$HOME/$1/$2"' _ "$SEND_DIR" "$1" "$2"; }
remove_files() { vekrona-dev run bash -c 'rm -rf "$HOME/$1" "$HOME/$2"' _ "$SEND_DIR" "$POPOUT_FILE"; }
# The drop folder is made by the first send; the guest's copy of it goes when the other device is forgotten.
remove_drop() {
  [[ -n "${PEER_ID:-}" ]] || return 0
  vekrona-dev run bash -c 'rm -rf "$HOME"/.local/share/vekrona-sync/drops/vekrona-drop-*"$1"*' _ "$PEER_ID"
}
cleanup() { run_cleanups close_chooser close_popout close_notification_centre peer_stop main_forget_peers remove_drop remove_files; }

vekrona-dev session
trap cleanup EXIT
clear_notifications

# Pair as a user would from a terminal (the Nearby list is the popout's, and the other scenarios click it), then stop the other
# device's Syncthing.
main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | map(.id) == [$peer]'
vekrona-dev run vekrona-sync pair "$(state_json | jq -r '.nearby[0].id')"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has_pending_device
peer_accepts_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_connected_on_main "$PEER_ID"
peer_kill syncthing
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent device_connected_on_main "$PEER_ID"
log "ok: the other device is paired and now offline"

vekrona-dev run bash -c 'printf popped >"$HOME/$1"' _ "$POPOUT_FILE"
open_popout
click_word '^Send$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- chooser_open 'Send files'
snap send-chooser
choose_in_home "^e2e-sync-popo" alt-o
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- queued_on_main "$POPOUT_FILE"
log "ok: Send file… of the popout puts the chosen file in the drop folder while the device is offline"

write_file one.txt first
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" one.txt' _ "$SEND_DIR" "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- queued_on_main one.txt
log "ok: send puts a second file in the drop folder too"

peer_syncthing_start
peer_spawn watch vekrona-sync watch
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_downloaded "$POPOUT_FILE" popped
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_downloaded one.txt first
log "ok: when the device comes online its drop folder is taken without asking and both files land in Downloads"

write_file one.txt second
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" one.txt' _ "$SEND_DIR" "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_downloaded 'one (2).txt' second
[[ "$(peer cat "$PEER_HOME/Downloads/one.txt")" == first ]] || die "the second file must not overwrite the first"
log "ok: a second file of the same name lands as 'one (2).txt' and the first is untouched"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_inbox_empty
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_inbox_empty
log "ok: the drop folders are empty on both sides"

# A receiver that moves the files out gives the sender's watcher nothing to clean up that stays: whichever of the receiver's
# deletion and the watcher's ignore line came first, no line of an ignored file is left in the end.
DROP_ID="$(main_rest GET /rest/config/folders | jq -r '.[] | select(.id | startswith("vekrona-drop-")) | .id')"
export DROP_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_stignore_empty
log "ok: the .stignore of the drop holds no line once the receiver has moved every file out"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_state_has_arrivals "$POPOUT_FILE,one (2).txt,one.txt"
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'one.txt received'
log "ok: the receiving device lists both arrivals in sync.json and notified"
