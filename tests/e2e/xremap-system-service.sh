#!/usr/bin/env bash
# xremap runs as the system user xremap, the session user is not in the input group, and the remaps still work:
# Caps Lock held is Hyper (a sway binding), and Cmd+C is Ctrl+C everywhere except in terminals, which the service
# learns from the compositor through the ACL it was given on the Wayland socket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30
RESULT_DIR=/tmp/vekrona-e2e-xremap

xremap_user() { vekrona-dev run ps -o user= -C xremap-wlroots; }
session_groups() { vekrona-dev run id -nG; }
windows_of() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '[recurse(.nodes[]?, .floating_nodes[]?) | select(.app_id == \"$1\")] | length'"; }
terminal_open() { [[ "$(windows_of com.mitchellh.ghostty)" -ge 1 ]]; }
result_is() { [[ "$(vekrona-dev run cat "$RESULT_DIR/$1" 2>/dev/null)" == "$2" ]]; }
export -f windows_of terminal_open result_is
export RESULT_DIR

close_terminal() { window_closed com.mitchellh.ghostty || vekrona-dev sh swaymsg '[app_id=com.mitchellh.ghostty] kill' >/dev/null; }
remove_results() { vekrona-dev run rm -rf "$RESULT_DIR"; }
trap 'run_cleanups close_terminal "kill_guest -x foot" remove_results' EXIT

vekrona-dev session
close_terminal
kill_guest -x foot
vekrona-dev run mkdir -p "$RESULT_DIR"

[[ "$(xremap_user)" == xremap ]] || die "xremap-wlroots must run as the user xremap, but runs as: $(xremap_user)"
[[ " $(session_groups) " != *" input "* ]] || die "the session user is in the input group: $(session_groups)"
log "ok: xremap runs as its own user and the session user is not in the input group"

# The Hyper binding is only reached through xremap's virtual keyboard: Caps Lock held, then Return opens the terminal.
vekrona-dev key caps_lock-ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_open
log "ok: Caps Lock held is Hyper, and the sway binding fires"
vekrona-dev sh swaymsg '[app_id=com.mitchellh.ghostty] kill' >/dev/null

# cat -v reads the keys; Ctrl+C kills it (exit status 130, the shell around it only handles the signal), Ctrl+D ends it (0).
# The window's app id decides the remap.
run_cat_in() {
  local app_id="$1" name="$2"
  vekrona-dev spawn "$RESULT_DIR/$name.log" -- foot --app-id="$app_id" sh -c "trap : INT; cat -v >/dev/null; echo \$? >$RESULT_DIR/$name"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app_id"
}

run_cat_in e2e-plain plain
vekrona-dev key super-c
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- result_is plain 130
log "ok: outside terminals Cmd+C is Ctrl+C"

run_cat_in foot terminal
vekrona-dev key super-c
vekrona-dev key ctrl-d
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- result_is terminal 0
log "ok: in a terminal Cmd+C is not Ctrl+C (it is Ctrl+Shift+C), so the program lives until Ctrl+D"
