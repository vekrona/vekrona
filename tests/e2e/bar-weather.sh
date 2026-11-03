#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
CLOCK_REGEX='^[0-9]{2}:[0-9]{2}$'

POSITION_FILE="$(mktemp)"
temperature_position() { vekrona-dev see find "$WEATHER_FIXTURE_REGEX" >"$POSITION_FILE"; }
export -f temperature_position
export POSITION_FILE

forget_position() { rm -f "$POSITION_FILE"; }
cleanup() { run_cleanups forget_position weather_fixture_restore; }

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
trap cleanup EXIT
weather_fixture_apply "$WEATHER_FIXTURE_CELSIUS"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- temperature_position
read -r x y <"$POSITION_FILE"
clock_position() { vekrona-dev see find "$CLOCK_REGEX" >"$POSITION_FILE"; }
export -f clock_position
export CLOCK_REGEX
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_position
read -r clock_x _ <"$POSITION_FILE"
((x < clock_x)) || die "the temperature at x=$x must sit left of the clock at x=$clock_x"
log "ok: the bar shows the fixture's rounded temperature left of the clock"

vekrona-dev click "$x" "$y"
credit_shown() { text_shown "Open-Meteo"; }
export -f credit_shown
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- credit_shown
log "ok: clicking the weather pill shows the Open-Meteo credit"

vekrona-dev click "$x" "$y"
credit_hidden() { absent credit_shown; }
export -f credit_hidden
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- credit_hidden
log "ok: clicking the weather pill again closes the popout"
