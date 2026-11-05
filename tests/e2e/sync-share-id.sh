#!/usr/bin/env bash
# "Share a folder…" closes the popout, opens the portal's folder chooser, and brings the popout back with a row to confirm the
# folder's ID, which vekrona-sync suggests from the folder's name (the name in lowercase with dashes) and which the user can edit
# with the keyboard: Enter shares, Esc cancels. The other device is a second Syncthing in a network namespace of the guest
# (tests/e2e/lib/sync-peer.sh), paired from a terminal.
#   - Enter shares the folder under the suggestion, "notes-e2e-share-id" for the directory "Notes e2e-share-id";
#   - an ID that is no ID shows its reason under the field and shares nothing; a typed ID is shared, and the other device is
#     offered the folder under exactly that ID;
#   - an ID that this computer has already is refused in words (Share is clicked this time), and Esc ends the confirmation with
#     nothing shared.
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
FIRST_DIR='Notes e2e-share-id'
EDIT_DIR='Edit e2e-share-edit'
SECOND_DIR='Other e2e-share-cancel'
TYPED_ID=my-id-e2e
PEER_ID=
export FIRST_DIR EDIT_DIR SECOND_DIR TYPED_ID PEER_ID

folder_ids_on_main() { main_rest GET /rest/config/folders | jq -r '.[].id' | sort | paste -sd,; }
folder_on_main() { main_rest GET /rest/config/folders | jq -e --arg id "$1" 'any(.[]; .id == $id)' >/dev/null; }
export -f folder_ids_on_main folder_on_main
remove_dirs() { vekrona-dev run bash -c 'rm -rf "$HOME/$1" "$HOME/$2" "$HOME/$3"' _ "$FIRST_DIR" "$EDIT_DIR" "$SECOND_DIR"; }
cleanup() { run_cleanups close_chooser close_popout peer_stop main_forget_peers remove_dirs; }

# Opens the chooser from the popout (its "Share a folder…" is the last "Share" on screen: the hint under a device that shares nothing and
# the confirmation's button have the word too), picks the directory whose name has the word regex $1, and waits for the confirmation row.
choose_to_share() {
  open_popout
  click_word --last '^Share$'
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- chooser_open 'Share a folder'
  choose_in_home "$1" alt-s
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_open
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Folder ID'
}

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
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_connected_on_main "$PEER_ID"
vekrona-dev run bash -c 'mkdir -p "$HOME/$1" "$HOME/$2" "$HOME/$3"' _ "$FIRST_DIR" "$EDIT_DIR" "$SECOND_DIR"

# The field's text is not OCR's to read (a dark input in a frame), so what the field held is what Enter shared.
choose_to_share '^e2e-share-id$'
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- folder_on_main notes-e2e-share-id
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_folder_offered notes-e2e-share-id
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent text_shown 'Folder ID'
first_shared="$(folder_ids_on_main)"
log "ok: the popout comes back after the chooser with the ID suggested from the folder's name, and Enter shares it under that ID"

choose_to_share '^e2e-share-edit$'
snap suggestion
vekrona-dev key ctrl-a
vekrona-dev type 'Bad ID'
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'may\s+have\s+only'
[[ "$(folder_ids_on_main)" == "$first_shared" ]] || die "an ID that is no ID must share nothing: $(folder_ids_on_main)"
snap invalid
log "ok: an ID that is no ID shows its reason under the field and shares nothing"

vekrona-dev key ctrl-a
vekrona-dev type "$TYPED_ID"
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- folder_on_main "$TYPED_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_folder_offered "$TYPED_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent text_shown 'Folder ID'
shared="$(folder_ids_on_main)"
log "ok: Enter shares the folder under the typed ID, and the other device is offered it under that ID"

choose_to_share '^e2e-share-cancel$'
vekrona-dev key ctrl-a
vekrona-dev type "$TYPED_ID"
click_word '^Share$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'already\s+has\s+a\s+folder\s+with\s+ID'
log "ok: an ID that this computer has already is refused in words"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent text_shown 'Folder ID'
[[ "$(folder_ids_on_main)" == "$shared" ]] || die "an ID that is refused and an Esc must share nothing more: $(folder_ids_on_main)"
log "ok: Esc ends the confirmation and shares nothing"
