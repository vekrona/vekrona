#!/usr/bin/env bash
# Two devices on one network find each other and share folders, through the bar's Sync popout only. The other device is a second
# Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh), connected by a veth pair, so local discovery is what
# makes them known to each other; it acts as a phone would, and is never told the guest's device ID.
#   - it shows up under Nearby, Pair asks it to connect, it accepts, and it is under My devices, online, with the line that it
#     shares no folder with this computer until a folder lists it;
#   - "Share a folder…" opens the portal's folder chooser, the folder is offered to the other device, which joins it, and files
#     sync both ways;
#   - a folder that the other device shares is under "Offered to you", Join takes it, and files sync both ways;
#   - a restart of Syncthing restarts the watcher, and syncing and sync.json go on.
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
OWN_NAME=e2e-sync-own
PEER_NAME=e2e-sync-theirs
PEER_ID=
SHARED_ID=
export OWN_NAME PEER_NAME PEER_ID SHARED_ID

peer_has() { peer test -f "$PEER_HOME/$1"; }
main_has() { vekrona-dev run bash -c 'test -f "$HOME/$1"' _ "$1"; }
main_file_is() { main_has "$1" && [[ "$(vekrona-dev run bash -c 'cat "$HOME/$1"' _ "$1")" == "$2" ]]; }
peer_file_is() { peer_has "$1" && [[ "$(peer cat "$PEER_HOME/$1")" == "$2" ]]; }
export -f peer_has main_has main_file_is peer_file_is
folder_id_of() { main_rest GET /rest/config/folders | jq -r --arg label "$1" '.[] | select(.label == $label) | .id'; }
folder_exists_on_main() { [[ -n "$(folder_id_of "$1")" ]]; }
export -f folder_id_of folder_exists_on_main
remove_files() { vekrona-dev run bash -c 'rm -rf "$HOME/$1" "$HOME/Sync/$2"' _ "$OWN_NAME" "$PEER_NAME"; }
cleanup() { run_cleanups close_chooser close_popout close_notification_centre peer_stop main_forget_peers remove_files; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID
log "ok: the other device runs on its own network"

open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | map(.id) == [$peer]'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_row_shown
snap nearby
log "ok: the other device announces itself on the network and the popout lists it under Nearby"

click_word '^Pair$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has_pending_device
log "ok: Pair makes the other device see a request from the guest, which it learned from nothing but the connection"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '(.devices | any(.[]; .id == $peer and (.connected | not))) and (.nearby == [])'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent nearby_row_shown
snap paired-waiting
log "ok: the other device leaves Nearby for My devices, offline until it accepts"

peer_accepts_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer and .connected)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Online'
snap my-devices-online
log "ok: once the other device accepts, My devices lists it as Online"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Shares\s+no\s+folders'
state_is '.devices | any(.[]; .id == $peer and (.sharesWithUs | not))' || die "sync.json must say that the connected device shares nothing with this computer"
log "ok: a connected device that shares no folder with this computer says so under its name"

vekrona-dev run bash -c 'mkdir -p "$HOME/$1" && echo hello >"$HOME/$1/hello.txt"' _ "$OWN_NAME"
click_word --last '^Share$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- chooser_open 'Share a folder'
snap chooser
log "ok: Share a folder opens the portal's folder chooser"

choose_in_home "^$OWN_NAME\$" alt-s
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- folder_exists_on_main "$OWN_NAME"
SHARED_ID="$(folder_id_of "$OWN_NAME")"
export SHARED_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_folder_offered "$SHARED_ID"
log "ok: the folder chosen in the portal is shared and offered to the other device"

peer_joins_folder "$SHARED_ID" "$OWN_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_file_is "Sync/$OWN_NAME/hello.txt" hello
peer bash -c 'echo back >"$1/$2"' _ "$PEER_HOME/Sync/$OWN_NAME" from-peer.txt
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_file_is "$OWN_NAME/from-peer.txt" back
vekrona-dev run bash -c 'echo more >"$HOME/$1/from-guest.txt"' _ "$OWN_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_file_is "Sync/$OWN_NAME/from-guest.txt" more
log "ok: after the other device joins, files sync both ways"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle" and (.folders | any(.[]; .id == $folder and .state == "idle" and .progress == 100))'
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown "$OWN_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Up to date'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Shares\s+no\s+folders'
state_is '.devices | any(.[]; .id == $peer and .sharesWithUs)' || die "sync.json must say that the device shares a folder once one lists it"
snap folder-up-to-date
log "ok: the popout lists the folder as Up to date"

peer bash -c 'mkdir -p "$1" && echo theirs >"$1/theirs.txt"' _ "$PEER_HOME/$PEER_NAME"
peer_shares_folder "$PEER_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.offers | any(.[]; .label == "'"$PEER_NAME"'" and .device == $peer)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Offered to you'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown "$PEER_NAME"
snap offered-to-you
log "ok: a folder that the other device shares is under Offered to you, with the device it comes from"

click_word '^Join$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_file_is "Sync/$PEER_NAME/theirs.txt" theirs
peer bash -c 'echo second >"$1/second.txt"' _ "$PEER_HOME/$PEER_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_file_is "Sync/$PEER_NAME/second.txt" second
vekrona-dev run bash -c 'echo reply >"$HOME/Sync/$1/reply.txt"' _ "$PEER_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_file_is "$PEER_NAME/reply.txt" reply
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Offered to you'
log "ok: Join takes the offered folder to ~/Sync/<label>, and files sync both ways"

click_sync_pill
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
log "ok: a second click on the Sync pill closes the popout"

main_syncthing_restart
vekrona-dev run bash -c 'echo again >"$HOME/$1/after-restart.txt"' _ "$OWN_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_file_is "Sync/$OWN_NAME/after-restart.txt" again
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle" and (.devices | any(.[]; .id == $peer and .connected))'
log "ok: a restart of Syncthing restarts the watcher, and syncing and sync.json go on"
