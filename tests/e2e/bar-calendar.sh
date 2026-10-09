#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
EVENT_TITLE="Vekrona review"
GUEST_CALENDAR_DIR='$HOME/.local/share/vekrona/calendars/e2e'

POSITION_FILE="$(mktemp)"
event_position() { vekrona-dev see find "Vekrona" >"$POSITION_FILE"; }
clock_position() { vekrona-dev see find "$CLOCK_WEEKDAY" >"$POSITION_FILE"; }
export -f event_position clock_position
export POSITION_FILE CLOCK_WEEKDAY

cleanup() {
  rm -f "$POSITION_FILE"
  vekrona-dev run bash -c "rm -rf $GUEST_CALENDAR_DIR"
  vekrona-dev sh vekrona-calendar render
}

vekrona-dev session
vekrona-dev move 600 500
trap cleanup EXIT

CLOCK_WEEKDAY="$(vekrona-dev run date +%a)"
today="$(vekrona-dev run date +%Y%m%d)"
vekrona-dev run bash -c "mkdir -p $GUEST_CALENDAR_DIR && cat >$GUEST_CALENDAR_DIR/review.ics" <<EOF2
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//vekrona//e2e//EN
BEGIN:VEVENT
UID:review@vekrona
DTSTAMP:${today}T000000Z
DTSTART:${today}T235900
DTEND:${today}T235959
SUMMARY:$EVENT_TITLE
END:VEVENT
END:VCALENDAR
EOF2
vekrona-dev sh vekrona-calendar render

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- event_position
read -r x y <"$POSITION_FILE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_position
read -r clock_x _ <"$POSITION_FILE"
((x < clock_x)) || die "the next event at x=$x must sit left of the clock at x=$clock_x"
log "ok: the bar shows today's next event left of the clock"

month="$(vekrona-dev run date '+%B %Y')"
month_shown() { vekrona-dev see text "$MONTH"; }
month_hidden() { ! month_shown; }
export -f month_shown month_hidden
export MONTH="$month"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_shown
log "ok: clicking the calendar pill shows the month grid for $month"

vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- month_hidden
log "ok: clicking the calendar pill again closes the popout"
