#!/usr/bin/env bash
# A receiver that keeps what it is sent (Android, macOS: the other device here is a second Syncthing without vekrona-sync, which
# accepts the drop folder by hand like a phone user, and never moves a file out of it) must not leave the sent files in the
# sender's drop folder for good, and must never lose its own copy by it. The sender's watcher ignores the path of each file the
# receiver has in the drop's .stignore, deletes its own copy once Syncthing flagged the file as ignored, and drops the line when the
# receiver deletes its copy. The other device is a second Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh).
#   - sent files, also one whose name is full of characters of the pattern language, arrive on the other device, and the guest's
#     copies are gone while the other device's stay and stay live in its index, and exactly those files have a line in the .stignore;
#   - a file whose name looks like the pattern of such a line is still sent;
#   - a file of the same name sent again is not ignored but arrives under another name;
#   - when the other device deletes a file, the line of it goes, and the other device's other files are not touched;
#   - a restart of the guest's watcher changes none of that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"

STEP_TIMEOUT_SEC=90
SEND_DIR=e2e-sync-keeps
ODD_NAME='odd [1] {a,b} *?.txt'
# The line of ODD_NAME: every character of the pattern language escaped.
ODD_LINE='odd \[1\] \{a,b\} \*\?.txt'
# A name that the line of ODD_NAME would match if it were not escaped (a set, an alternative, a star and a question mark).
DECOY_NAME='odd 1 a xy.txt'
PEER_ID=
DROP_ID=
MAIN_HOME="$(vekrona-dev run printenv HOME)"
export SEND_DIR ODD_NAME ODD_LINE DECOY_NAME PEER_ID DROP_ID MAIN_HOME

peer_drop_dir() { echo "$PEER_HOME/Sync/vekrona drop/to/$PEER_ID"; }
main_drop_dir() { echo "$MAIN_HOME/.local/share/vekrona-sync/drops/$DROP_ID/to/$PEER_ID"; }
peer_has() { [[ "$(peer cat "$(peer_drop_dir)/$1" 2>/dev/null)" == "$2" ]]; }
main_names() { vekrona-dev run bash -c 'shopt -s nullglob dotglob; for f in "$1"/*; do basename "$f"; done | sort' _ "$(main_drop_dir)"; }
main_is_empty() { [[ -z "$(main_names)" ]]; }
main_ignore_lines() { main_rest GET "/rest/db/ignores?folder=$DROP_ID" | jq -r '.ignore[]'; }
main_has_line() { main_ignore_lines | grep -qxF -- "/to/$PEER_ID/$1"; }
main_has_no_line() { absent main_has_line "$1"; }
peer_entry_is_live() { [[ "$(peer_rest GET "/rest/db/file?folder=$DROP_ID&file=to/$PEER_ID/$1" | jq '(.local.deleted == false) and (.global.deleted == false)')" == true ]]; }
export -f peer_drop_dir main_drop_dir peer_has main_names main_is_empty main_ignore_lines main_has_line main_has_no_line peer_entry_is_live

write_files() { vekrona-dev run bash -c 'mkdir -p "$HOME/$1" && printf %s "$3" >"$HOME/$1/$2"' _ "$SEND_DIR" "$1" "$2"; }
remove_files() { vekrona-dev run bash -c 'rm -rf "$HOME/$1"' _ "$SEND_DIR"; }
remove_drop() {
  [[ -n "${PEER_ID:-}" ]] || return 0
  vekrona-dev run bash -c 'rm -rf "$HOME"/.local/share/vekrona-sync/drops/vekrona-drop-*"$1"*' _ "$PEER_ID"
}
cleanup() { run_cleanups peer_stop main_forget_peers remove_drop remove_files; }

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

write_files keep.txt first
write_files "$ODD_NAME" odd
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" keep.txt "$3"' _ "$SEND_DIR" "$PEER_ID" "$ODD_NAME"
DROP_ID="$(main_rest GET /rest/config/folders | jq -r '.[] | select(.id | startswith("vekrona-drop-")) | .id')"
[[ "$DROP_ID" == vekrona-drop-* ]] || die "the send must have made a drop folder, got: $DROP_ID"
export DROP_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_folder_offered "$DROP_ID"
# What a phone user does when the drop is offered: accept it, at a path of their choice (nothing but Syncthing runs there).
peer_joins_folder "$DROP_ID" "vekrona drop"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has keep.txt first
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has "$ODD_NAME" odd
log "ok: the files arrive on the device that keeps them, the odd name too"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_is_empty
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_has_line keep.txt
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_has_line "$ODD_LINE"
peer_has keep.txt first || die "the other device lost keep.txt when the guest cleaned up its copy"
peer_has "$ODD_NAME" odd || die "the other device lost the odd file when the guest cleaned up its copy"
peer_entry_is_live keep.txt || die "keep.txt must be live in the index of the other device"
log "ok: the guest's copies are gone, the other device keeps its own, live, and the .stignore of the drop names the sent files"

write_files "$DECOY_NAME" decoy
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" "$3"' _ "$SEND_DIR" "$PEER_ID" "$DECOY_NAME"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has "$DECOY_NAME" decoy
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_is_empty
log "ok: a file whose name the pattern of a line would match if it were not escaped is sent and cleaned up like any other"

write_files keep.txt second
vekrona-dev run bash -c 'cd "$HOME/$1" && vekrona-sync send "$2" keep.txt' _ "$SEND_DIR" "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has 'keep (2).txt' second
peer_has keep.txt first || die "the second keep.txt must not replace the first on the other device"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_is_empty
log "ok: a file of the same name sent again is not ignored but arrives as 'keep (2).txt'"

peer rm "$(peer_drop_dir)/keep.txt"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- main_has_no_line keep.txt
main_has_line 'keep (2).txt' || die "the line of keep (2).txt must stay while the other device has it"
peer_has 'keep (2).txt' second || die "the other device lost keep (2).txt when the line of keep.txt went"
log "ok: when the other device deletes a file the line of it goes, and its other files stay"

vekrona-dev sh systemctl --user restart vekrona-sync.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.state == "idle"'
peer_has 'keep (2).txt' second || die "a restart of the guest's watcher deleted a file of the other device"
peer_has "$ODD_NAME" odd || die "a restart of the guest's watcher deleted the odd file of the other device"
main_has_line 'keep (2).txt' || die "a restart of the watcher must keep the lines of files the other device still has"
main_is_empty || die "a restart of the watcher must not bring files back to the drop folder"
log "ok: a restart of the watcher changes nothing"
