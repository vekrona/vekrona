#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The fixture's current temperature is 37.4. The bar shows it rounded, and OCR reads the glyph before it as a letter or a digit
# ("237°C") or drops the unit. A clock such as 03:37 and a volume or CPU load of 37 % must not match.
TEMPERATURE_REGEX='37 ?°|^[^0-9:%]?37$'
CLOCK_REGEX='^[0-9]{2}:[0-9]{2}$'
GUEST_FIXTURE=/tmp/bar-weather-open-meteo.json
GUEST_OVERRIDE='$HOME/.config/vekrona/weather.json'

POSITION_FILE="$(mktemp)"
temperature_position() { vekrona-dev see find "$TEMPERATURE_REGEX" >"$POSITION_FILE"; }
export -f temperature_position
export TEMPERATURE_REGEX POSITION_FILE

cleanup() {
  rm -f "$POSITION_FILE"
  vekrona-dev run bash -c "rm -f $GUEST_OVERRIDE"
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
trap cleanup EXIT

vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_FIXTURE" <"$ROOT/tests/fixtures/open-meteo.json"
vekrona-dev run bash -c "mkdir -p \$(dirname $GUEST_OVERRIDE) && echo '{\"latitude\": 52.5, \"longitude\": 13.4, \"name\": \"Berlin\"}' >$GUEST_OVERRIDE"
vekrona-dev sh env "VEKRONA_WEATHER_URL=file://$GUEST_FIXTURE" vekrona-weather

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
credit_shown() { vekrona-dev see text "Open-Meteo"; }
export -f credit_shown
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- credit_shown
log "ok: clicking the weather pill shows the Open-Meteo credit"

vekrona-dev click "$x" "$y"
credit_hidden() { ! credit_shown; }
export -f credit_hidden
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- credit_hidden
log "ok: clicking the weather pill again closes the popout"
