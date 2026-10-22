#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-dot.sh"

STEP_TIMEOUT_SEC=60
# Where the pointer rests: over no widget.
PARK_X=600
PARK_Y=500
# How long a right click is given to open the launcher, which it must not. The launcher opens within a second. The click has no
# effect of its own to wait for instead: the robot does nothing with it, so only the absence of an opening shows it was ignored.
QUIET_SEC=10
# The watcher drops a repeat of a fingerprint within 10 minutes, and digits do not change a fingerprint, so each run needs fresh words.
# OCR reads the titles back, and it misreads random letters but not words.
mapfile -t words < <(printf '%s\n' amber basalt cedar dune ember fjord glacier harbor island jungle kelp lagoon meadow nectar orchid prairie quartz | shuf -n 10)
TITLE_KEYBOARD="Vekrona e2e ${words[0]} ${words[1]}"
TITLE_TYPED="Vekrona e2e ${words[2]} ${words[3]}"
TITLE_LATE="Vekrona e2e ${words[4]} ${words[5]}"
TITLE_SLASH="Vekrona e2e ${words[6]} ${words[7]}"
TITLE_OVER="Vekrona e2e ${words[8]} ${words[9]}"
SENTINEL="Vekrona e2e sentinel"
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_PX="$(vekrona_token_get size size-icon-s)"

error_listed() { vekrona-dev run bash -c "vekrona-error list | grep -qF '$1'"; }
# The watcher stores an error's context just before it would send a notification for it, if it did.
context_stored() { vekrona-dev run bash -c "test -f $ERRORS_DIR/$1/context.txt"; }
error_status_is() {
  local status
  status="$(vekrona-dev run bash -c "vekrona-error list --all | grep -F '$1' | awk '{print \$3}'")" || abort "cannot read the status of the error $1"
  [[ "$status" == "$2" ]]
}
unread_count() { vekrona-dev run bash -c "cat $ERRORS_DIR/unread"; }
unread_is() { [[ "$(unread_count)" == "$1" ]]; }
monitor_saw() { vekrona-dev run grep -qF -- "$1" "$NOTIFY_LOG"; }
# The id of the recorded error titled $1.
error_id() { vekrona-dev run bash -c "vekrona-error list --all | grep -F '$1' | awk '{print \$1}'"; }
# The 0-based row of the error titled $1 in the launcher, which lists the errors in the order `vekrona-error list` prints them.
error_row() { vekrona-dev run bash -c "vekrona-error list | tail -n +2 | grep -nF '$1' | cut -d: -f1" | awk '{print $1 - 1}'; }
agent_mode_shows() { launcher_is '.open and .mode == "agent"' && text_shown "$1"; }
selected_is() { launcher_is ".selectedId == \"$1\""; }
filtered_to() { launcher_is ".query == \"$1\" and .rows == 2"; }
# With no default agent set, vekrona-agent --pick --error ID keeps running on its picker. The bracket keeps pgrep from matching the shell that runs it.
agent_started_for() { vekrona-dev run pgrep -f -- "vekrona-agent --pic[k] --error $1" >/dev/null; }
agent_started_plain() { vekrona-dev run pgrep -f -- "vekrona-agent --pic[k]$" >/dev/null; }
picker_open() { vekrona-dev run pgrep -x rofi >/dev/null; }
picker_closed() { absent picker_open; }
export -f error_listed context_stored error_status_is unread_count unread_is monitor_saw agent_mode_shows selected_is filtered_to agent_started_for agent_started_plain picker_open picker_closed
export ROOT DANGER_HEX BAR_HEIGHT_PX
ERRORS_DIR='$HOME/.local/state/vekrona/errors'
MUTE_FILE='$HOME/.config/vekrona/errors-mute'
NOTIFY_LOG=/tmp/bar-agent-click-notify.log
export ERRORS_DIR NOTIFY_LOG

# Escape cancels the picker the way a user does. Killing rofi instead would make vekrona-agent report a real error.
close_picker() {
  vekrona-dev key esc
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- picker_closed || die "the agent picker must close on Escape"
}
# Removes the errors this run recorded, and the mute that muting one of them added.
remove_errors() {
  local title id fingerprint
  for title in "$TITLE_KEYBOARD" "$TITLE_TYPED" "$TITLE_LATE" "$TITLE_SLASH" "$TITLE_OVER"; do
    id="$(error_id "$title")"
    [[ -z "$id" ]] && continue
    fingerprint="$(vekrona-dev run bash -c "vekrona-error show $id | sed -n 's/^fingerprint: //p'")"
    vekrona-dev run vekrona-error rm "$id"
    vekrona-dev run bash -c "[[ ! -e $MUTE_FILE ]] || sed -i '/$fingerprint/d' $MUTE_FILE"
  done
}
# vekrona installs no coding agent, and `vekrona-agent --pick` ends at once on a machine with none, so the picker these
# scenarios look for needs one on PATH. It does nothing.
FAKE_HARNESS='$HOME/.local/bin/claude'
install_fake_harness() {
  vekrona-dev run bash -c "[[ ! -e $FAKE_HARNESS ]]" || die "$FAKE_HARNESS exists: this scenario would overwrite a real agent harness"
  vekrona-dev run bash -c "printf '#!/bin/sh\nexit 0\n' >$FAKE_HARNESS && chmod +x $FAKE_HARNESS"
}
remove_fake_harness() { vekrona-dev run bash -c "rm -f $FAKE_HARNESS"; }
cleanup() {
  rm -f "$DOT_FILE" "$DOT_STATES"
  run_cleanups 'picker_closed || close_picker' 'kill_guest -x dbus-monitor' remove_errors unread_restore remove_fake_harness
}
# Records the error titled $1, and waits until $2 errors are unread.
report_unread() {
  vekrona-dev run vekrona-error report --title "$1" --summary 'raised by an e2e scenario'
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unread_is "$2" || die "recording '$1' must leave $2 unread, but the unread count is $(unread_count)"
}
open_error_list() {
  vekrona-dev click "$robot_x" "$robot_y"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .mode == "agent"' || { launcher_state; die "a left click on the robot must open the launcher on the error list"; }
}
# Types $1, which leaves the question for the agent and one more row, then selects the row $2. Their order follows their scores,
# which move with use, so it is not assumed.
filter_to_row() {
  vekrona-dev type "$1"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- filtered_to "$1" || { launcher_state; die "typing '$1' must leave the question for the agent and one more row"; }
  selected_is "$2" || vekrona-dev key down
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- selected_is "$2" || { launcher_state; die "the filtered list must select the row $2"; }
}
# Enter on the selected row must close the launcher and start the agent on the error $1, and not on the error $2.
activate_for() {
  vekrona-dev key ret
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "Enter on an error row must close the launcher"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- agent_started_for "$1" || die "Enter on the row must run vekrona-agent --pick --error $1"
  absent agent_started_for "$2" || die "the agent must not start on the error $2"
  close_picker
}

DOT_FILE="$(mktemp)"
export DOT_FILE
trap cleanup EXIT

vekrona-dev session
vekrona-dev move "$PARK_X" "$PARK_Y"
install_fake_harness
[[ -z "$(vekrona-dev run vekrona-agent get)" ]] || die "this scenario needs a VM without a default agent, so that the agent stops on its picker"
# The watcher is stopped meanwhile, so that the first count it writes is the one for the errors reported below. The shell counts
# the unseen errors of the store as it starts, which is none once they are acked.
unread_stash
vekrona-dev run vekrona-error ack --all
restart_shell
clear_notifications
vekrona-dev spawn "$NOTIFY_LOG" -- dbus-monitor --session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_saw NameLost
vekrona-dev sh systemctl --user start vekrona-errors.service
for title in "$TITLE_TYPED" "$TITLE_KEYBOARD"; do
  vekrona-dev run vekrona-error report --title "$title" --summary 'raised by an e2e scenario'
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- error_listed "$title"
done
ID_KEYBOARD="$(error_id "$TITLE_KEYBOARD")"
ID_TYPED="$(error_id "$TITLE_TYPED")"
for id in "$ID_KEYBOARD" "$ID_TYPED"; do
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- context_stored "$id"
done
# A notification sent for either error would be on the bus before this one.
vekrona-dev sh notify-send -- "$SENTINEL"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_saw "$SENTINEL"
for title in "$TITLE_KEYBOARD" "$TITLE_TYPED"; do
  absent monitor_saw "$title" || die "recording the error '$title' sent a desktop notification"
done
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- robot_dotted || { cat "$DOT_FILE"; die "the robot must show its unread dot, and the bell none"; }
(($(unread_count) >= 2)) || die "two recorded errors must leave an unread count of at least 2"
log "ok: recording errors raises the robot's dot and sends no notification"
dot_left="$(sed -n '1s/^dot: x \([0-9]*\)\..*/\1/p' "$DOT_FILE")"
robot_x=$((dot_left - ICON_S_PX / 2))
robot_y=$((BAR_HEIGHT_PX / 2))

# Errors that are unread as the shell starts are not news: the dot shows at once and stays solid. Only an error that arrives
# once the shell is up pulses it.
unread_before="$(unread_count)"
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- errors_state_is ".loaded and .unread == $unread_before" || die "a restarted shell must count the $unread_before unseen errors: $(errors_state)"
errors_state_is '.pulsing | not' || die "a shell that starts with $unread_before unseen errors must not pulse the robot's dot: $(errors_state)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- robot_dotted || { cat "$DOT_FILE"; die "a shell that starts with unseen errors must show the robot's dot"; }
log "ok: a shell that starts with unseen errors shows the robot's dot at once and does not pulse it"

# The launcher's click catcher starts below the bar, so the second click reaches the robot, which closes the error list it opened.
open_error_list
for title in "$TITLE_KEYBOARD" "$TITLE_TYPED"; do
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- agent_mode_shows "$title" || { launcher_state; die "the error list must show the recorded error '$title'"; }
done
text_absent 'Fix latest error' || die "the error list replaces the Fix latest error row"
text_absent 'Open error list' || die "the error list replaces the Open error list row"
text_shown 'Fix with agent' || die "the footer must name the selected error's Enter action, Fix with agent"
log "ok: a left click on the robot opens the list of every recorded error, and the footer names Fix with agent"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unread_is 0 || die "opening the error list must mark every error seen, but the unread count is $(unread_count)"
error_status_is "$TITLE_KEYBOARD" seen || die "opening the error list must set the status of its errors to seen"
vekrona-dev click "$robot_x" "$robot_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a second left click on the robot must close the error list"
log "ok: a second left click on the robot closes the error list"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_dot || die "once the error list has been opened, the robot must show no dot"
log "ok: opening the error list marks every error seen and clears the robot's dot"

open_error_list
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.selectedId | startswith("agent:error:")' || { launcher_state; die "the first row of the error list must be selected"; }
rows_above="$(error_row "$TITLE_KEYBOARD")"
for ((row = 0; row < rows_above; row++)); do
  vekrona-dev key down
done
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- selected_is "agent:error:$ID_KEYBOARD" || { launcher_state; die "the arrow keys must reach the row of '$TITLE_KEYBOARD'"; }
activate_for "$ID_KEYBOARD" "$ID_TYPED"
log "ok: Enter on a row of the error list starts the agent on that error"

# Typing filters the rows.
open_error_list
filter_to_row "$TITLE_TYPED" "agent:error:$ID_TYPED"
activate_for "$ID_TYPED" "$ID_KEYBOARD"
log "ok: typing filters the error list"

# The Launch agent row starts the agent on no error.
open_error_list
# The whole title: a shorter query also fuzzy-matches the titles of unrelated errors the VM has recorded.
filter_to_row "launch agent" agent:launch
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "Enter on Launch agent must close the launcher"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- agent_started_plain || die "Enter on Launch agent must run vekrona-agent --pick"
close_picker
log "ok: the error list keeps the Launch agent row"

# Mute is the third action of the row, so it is in the Ctrl+K panel, which filters its actions by what is typed.
open_error_list
filter_to_row "$TITLE_TYPED" "agent:error:$ID_TYPED"
vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.actionsOpen' || { launcher_state; die "Ctrl+K must open the actions of the selected error"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Mute' || die "the actions of an error must list Mute"
vekrona-dev type mute
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- error_status_is "$TITLE_TYPED" muted || die "Mute on an error row must run vekrona-error mute for it"
# Typed, the title leaves only the question for the agent once its row is gone.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .rows == 1' || { launcher_state; die "a muted error must leave the list, and the launcher must stay open on it"; }
! error_status_is "$TITLE_KEYBOARD" muted || die "muting one error must not mute another"
vekrona-dev click "$robot_x" "$robot_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a left click on the robot must close the error list"
log "ok: Mute in the actions of an error row mutes it and drops the row from the list"

# The list was opened before, and it keeps its mode while closed: an error recorded now is still unread, and its dot
# pulses: it is sampled from before the report until the shell says the pulse is over.
dot_place "$robot_x" "$robot_y"
vekrona-dev move "$PARK_X" "$PARK_Y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_dot || die "the robot must show no dot before the late error is recorded"
vekrona-dev run vekrona-error report --title "$TITLE_LATE" --summary 'raised by an e2e scenario'
runs="$(dot_dim_runs 1)"
((runs >= 2)) || die "the robot's dot must pulse when an error is recorded, but it dimmed $runs times"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- robot_dotted || { cat "$DOT_FILE"; die "an error recorded while the error list is closed must raise the robot's dot"; }
log "ok: an error recorded while the error list is closed raises the dot again, and the dot pulses ($runs dim stretches) before it stays solid"

# Hyper+Shift+A toggles the same list as the robot. The list sees what it shows however it comes on screen.
vekrona-dev key super-ctrl-alt-shift-a
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .mode == "agent"' || { launcher_state; die "Hyper+Shift+A must open the launcher on the error list"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unread_is 0 || die "the error list opened by Hyper+Shift+A must mark its errors seen, but the unread count is $(unread_count)"
vekrona-dev key super-ctrl-alt-shift-a
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a second Hyper+Shift+A must close the error list"
log "ok: Hyper+Shift+A opens the error list and marks its errors seen, and pressing it again closes the list"

# Typing /agent in the open launcher brings the list on screen as well.
report_unread "$TITLE_SLASH" 1
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open || die "Super+Space must open the launcher"
vekrona-dev type '/agent '
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.mode == "agent"' || { launcher_state; die "typing /agent and a space must enter the error list"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unread_is 0 || die "the error list entered by typing /agent must mark its errors seen, but the unread count is $(unread_count)"
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "Super+Space must close the launcher"
log "ok: typing /agent in the open launcher shows the error list and marks its errors seen"

# So does the key binding while the launcher is open in another mode.
report_unread "$TITLE_OVER" 1
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .mode == ""' || die "Super+Space must open the launcher in its root search"
vekrona-dev key super-ctrl-alt-shift-a
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .mode == "agent"' || { launcher_state; die "Hyper+Shift+A must switch the open launcher to the error list"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unread_is 0 || die "the error list that Hyper+Shift+A switched to must mark its errors seen, but the unread count is $(unread_count)"
vekrona-dev key super-ctrl-alt-shift-a
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a second Hyper+Shift+A must close the error list"
log "ok: Hyper+Shift+A switches the open launcher to the error list and marks its errors seen"

vekrona-dev click "$robot_x" "$robot_y" --button right
stays_absent "$QUIET_SEC" launcher_open || die "a right click on the robot must do nothing, but it opened the launcher"
log "ok: a right click on the robot does nothing"
