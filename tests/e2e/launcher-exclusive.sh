#!/usr/bin/env bash
# The launcher, the notification centre and the bar's popouts each grab the keyboard, so only one is up at a time: opening the
# launcher closes the other two, as opening either of them closes the launcher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
POSITION_FILE="$(mktemp)"
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

centre_shown() { vekrona-dev see text 'No notifications'; }
centre_hidden() { ! centre_shown; }
month_shown() { vekrona-dev see text "$MONTH"; }
month_hidden() { ! month_shown; }
clock_position() { vekrona-dev see find "$CLOCK_WEEKDAY" >"$POSITION_FILE"; }
export -f centre_shown centre_hidden month_shown month_hidden clock_position
export POSITION_FILE

cleanup() {
  close_launcher
  close_notification_centre
  rm -f "$POSITION_FILE"
}
trap cleanup EXIT

vekrona-dev session
MONTH="$(vekrona-dev run date '+%B %Y')"
CLOCK_WEEKDAY="$(vekrona-dev run date +%a)"
export MONTH CLOCK_WEEKDAY
vekrona-dev move 600 500
clear_notifications

open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- centre_shown
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- centre_hidden || die "opening the launcher must close the notification centre"
log "ok: opening the launcher closes the notification centre"
close_launcher

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_position
read -r x y <"$POSITION_FILE"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_shown
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_hidden || die "opening the launcher must close an open bar popout"
log "ok: opening the launcher closes the bar's popout"
