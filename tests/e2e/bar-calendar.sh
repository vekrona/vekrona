#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
EVENT_TITLE="Vekrona review"
# The clock is pinned to a morning, with the event at noon: an event at 23:59 of the real day is in the past for a run that starts
# in that minute, and the bar shows only an event that is still to come.
PINNED_NOW="2026-10-16 10:10:00"
EVENT_DAY=20261016
EVENT_START=120000
EVENT_END=130000
GUEST_CALENDAR_DIR='$HOME/.local/share/vekrona-calendars/e2e'

POSITION_FILE="$(mktemp)"
event_position() { vekrona-dev see find "Vekrona" >"$POSITION_FILE"; }
clock_position() { vekrona-dev see find "$CLOCK_WEEKDAY" >"$POSITION_FILE"; }
export -f event_position clock_position
export POSITION_FILE CLOCK_WEEKDAY

cleanup() {
  rm -f "$POSITION_FILE"
  run_cleanups clock_restore "vekrona-dev run bash -c 'rm -rf $GUEST_CALENDAR_DIR'" 'vekrona-dev sh vekrona-calendar render'
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
trap cleanup EXIT

clock_pin "$PINNED_NOW"
CLOCK_WEEKDAY="$(vekrona-dev run date -d "$PINNED_NOW" +%a)"
export CLOCK_WEEKDAY
vekrona-dev run bash -c "mkdir -p $GUEST_CALENDAR_DIR && cat >$GUEST_CALENDAR_DIR/review.ics" <<EOF2
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//vekrona//e2e//EN
BEGIN:VEVENT
UID:review@vekrona
DTSTAMP:${EVENT_DAY}T000000Z
DTSTART:${EVENT_DAY}T${EVENT_START}
DTEND:${EVENT_DAY}T${EVENT_END}
SUMMARY:$EVENT_TITLE
END:VEVENT
END:VCALENDAR
EOF2
vekrona-dev sh vekrona-calendar render

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- event_position
read -r event_x event_y <"$POSITION_FILE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_position
read -r clock_x clock_y <"$POSITION_FILE"
((event_x < clock_x)) || die "the next event at x=$event_x must sit left of the clock at x=$clock_x"
log "ok: the bar shows today's next event left of the clock"

month="$(vekrona-dev run date -d "$PINNED_NOW" '+%B %Y')"
month_shown() { text_shown "$MONTH"; }
month_hidden() { absent month_shown; }
export -f month_shown month_hidden
export MONTH="$month"

toggles_month_grid() {
  local name=$1 x=$2 y=$3
  vekrona-dev click "$x" "$y"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_shown
  log "ok: clicking the $name shows the month grid for $month"

  vekrona-dev click "$x" "$y"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_hidden
  log "ok: clicking the $name again closes the popout"
}

toggles_month_grid "date and time" "$clock_x" "$clock_y"
toggles_month_grid "next event" "$event_x" "$event_y"
