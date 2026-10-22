#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The fixture's current temperature is 37.4. The bar shows it rounded, with its unit: the digits are followed by a mark.
# OCR reads the degree sign next to the load widget's bars as a degree sign, a dash or a lowercase c, so any mark counts,
# and a bare "37" does not. A clock such as 03:37 must not match.
TEMPERATURE_REGEX='^37 ?\S'
CLOCK_REGEX='^[0-9]{2}:[0-9]{2}$'
GUEST_FIXTURE=/tmp/bar-weather-open-meteo.json
GUEST_OVERRIDE='$HOME/.config/vekrona/weather.json'
# The weather unit's result: vekrona-weather below replaces it with the fixture's, so the guest's own is set aside and put back.
GUEST_STATE='$HOME/.local/state/vekrona/weather.json'
GUEST_STATE_ASIDE='$HOME/.local/state/vekrona/weather.json.e2e-aside'

POSITION_FILE="$(mktemp)"
temperature_position() { vekrona-dev see find "$TEMPERATURE_REGEX" >"$POSITION_FILE"; }
export -f temperature_position
export TEMPERATURE_REGEX POSITION_FILE

# An aside that is already there is a killed run's, which holds the guest's own result; a guest that had none gets none back.
set_state_aside() {
  vekrona-dev run bash -c "if [[ ! -e $GUEST_STATE_ASIDE ]]; then if [[ -e $GUEST_STATE ]]; then mv $GUEST_STATE $GUEST_STATE_ASIDE; else : >$GUEST_STATE_ASIDE.none; fi; fi"
}
put_state_back() {
  vekrona-dev run bash -c "if [[ -e $GUEST_STATE_ASIDE ]]; then mv $GUEST_STATE_ASIDE $GUEST_STATE; elif [[ -e $GUEST_STATE_ASIDE.none ]]; then rm -f $GUEST_STATE $GUEST_STATE_ASIDE.none; fi"
}
cleanup() {
  rm -f "$POSITION_FILE"
  run_cleanups "vekrona-dev run bash -c 'rm -f $GUEST_OVERRIDE'" put_state_back
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
trap cleanup EXIT
set_state_aside

vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_FIXTURE" <"$ROOT/tests/fixtures/open-meteo.json"
vekrona-dev run bash -c "mkdir -p \$(dirname $GUEST_OVERRIDE) && echo '{\"latitude\": 52.5, \"longitude\": 13.4, \"name\": \"Berlin\"}' >$GUEST_OVERRIDE"
vekrona-dev sh env "VEKRONA_WEATHER_URL=file://$GUEST_FIXTURE" vekrona-weather run

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
