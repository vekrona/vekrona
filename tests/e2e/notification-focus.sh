#!/usr/bin/env bash
# Clicking a notification, or one of its actions, brings the sender's window forward, from any desktop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# How long a focus change that must not happen is looked for, back to back.
FOCUS_SETTLE_SEC=3
ORIGIN=vekrona-e2e-origin
GUEST_ACTION_LOG=/tmp/vekrona-e2e-notify-focus.log

focused_desktop_is() { [[ "$(vekrona-dev sh bash -c "swaymsg -t get_workspaces | jq -r '.[] | select(.focused).num'")" == "$1" ]]; }
focus_left_desktop_2() { ! focused_desktop_is 2; }
log_has() { vekrona-dev run grep -q "$2" "$1"; }
export -f focused_desktop_is focus_left_desktop_2 log_has

kill_origin() {
  local status=0
  vekrona-dev run pkill -f "app-id=$ORIGIN" || status=$?
  ((status <= 1)) || warn "could not stop the origin window (pkill exit $status)"
  vekrona-dev sh swaymsg workspace number 1 >/dev/null
}
trap kill_origin EXIT

leave_origin_on_a_clean_screen() {
  vekrona-dev key super-2
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_desktop_is 2
  clear_notifications
}

click_text() {
  local x y
  read -r x y <<<"$(vekrona-dev see find "$1")"
  [[ -n "${x:-}" ]] || die "OCR found no '$1' to click"
  vekrona-dev click "$x" "$y"
  vekrona-dev move 100 500
}

expect_origin_focused() {
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$ORIGIN" \
    || die "$1 must focus the sender's window $ORIGIN on desktop 1, but focus is on $(focused_app_id)"
  focused_desktop_is 1 || die "$1 must switch to the sender's desktop 1"
}

vekrona-dev session
vekrona-dev move 100 500
clear_notifications
kill_origin
shell_errors_before="$(shell_errors)"

vekrona-dev key super-1
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_desktop_is 1
vekrona-dev spawn "/tmp/$ORIGIN.log" -- foot --app-id="$ORIGIN"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$ORIGIN"

leave_origin_on_a_clean_screen
vekrona-dev spawn "$GUEST_ACTION_LOG" -- notify-send --wait -h "string:desktop-entry:$ORIGIN" -A default=Open 'Focus by entry' 'entry body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'entry body'
click_text '^body$'
expect_origin_focused "clicking a notification whose desktop-entry names the sender"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_ACTION_LOG" default
log "ok: clicking a notification focuses its sender on another desktop and still runs the default action"

leave_origin_on_a_clean_screen
vekrona-dev sh notify-send -a "$ORIGIN" 'Focus by name' 'plain body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'plain body'
click_text '^plain$'
expect_origin_focused "clicking a notification without actions whose app name is the sender"
log "ok: a notification without actions focuses its sender by app name"

leave_origin_on_a_clean_screen
vekrona-dev spawn "$GUEST_ACTION_LOG" -- notify-send --wait -h "string:desktop-entry:$ORIGIN" -A reply=Reply 'Focus by action' 'action body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'action body'
click_text '^Reply$'
expect_origin_focused "clicking an action button"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_ACTION_LOG" reply
log "ok: an action button focuses the sender and runs its action"

leave_origin_on_a_clean_screen
vekrona-dev spawn "$GUEST_ACTION_LOG" -- notify-send --wait -a 'no such app' -A default=Open 'Nobody home' 'orphan body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'orphan body'
click_text '^orphan$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_ACTION_LOG" default
# The shell looks for the sender's window before it runs the action, so a focus change would have been sent by now; Sway gets
# a moment of looks to carry it out.
stays_absent "$FOCUS_SETTLE_SEC" focus_left_desktop_2 || die "a notification from an app without a window must leave focus on desktop 2, but it is on $(focused_app_id)"
((shell_errors_before == $(shell_errors))) || die "a notification from an app without a window must not log a failure"
log "ok: a notification whose sender has no window leaves focus alone"
