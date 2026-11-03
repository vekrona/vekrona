#!/usr/bin/env bash
# Opening the weather or the calendar popout starts the unit that refreshes its data, which an hourly timer otherwise keeps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
POSITION_FILE="$(mktemp)"

invocation() { vekrona-dev sh systemctl --user show -p InvocationID --value "$1"; }
started_again() { [[ "$(invocation "$1")" != "$2" ]]; }
weather_position() { vekrona-dev see find "$WEATHER_FIXTURE_REGEX" >"$POSITION_FILE"; }
clock_position() { vekrona-dev see find "$CLOCK_WEEKDAY" >"$POSITION_FILE"; }
export -f invocation started_again weather_position clock_position
export POSITION_FILE
forget_position() { rm -f "$POSITION_FILE"; }
trap 'run_cleanups forget_position weather_fixture_restore' EXIT

vekrona-dev session
# The shell starts a unit at most once in ten minutes and keeps that in memory, so a popout opened by an earlier scenario
# (bar-weather opens the weather popout) would leave nothing to start: a restarted shell has started nothing yet.
restart_shell
CLOCK_WEEKDAY="$(vekrona-dev run date +%a)"
export CLOCK_WEEKDAY
vekrona-dev move 600 500
clear_notifications
weather_fixture_apply "$WEATHER_FIXTURE_CELSIUS"

refresh_on_open() {
  local unit="$1" locate="$2" before
  before="$(invocation "$unit")"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$locate"
  read -r x y <"$POSITION_FILE"
  vekrona-dev click "$x" "$y"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- started_again "$unit" "$before" || die "opening the popout must start $unit"
  vekrona-dev click "$x" "$y"
}

refresh_on_open vekrona-weather.service weather_position
log "ok: opening the weather popout refreshes the forecast"
refresh_on_open vekrona-calendar.service clock_position
log "ok: opening the calendar popout syncs the calendars"
