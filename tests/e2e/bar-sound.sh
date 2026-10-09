#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The Perf widget's CPU and RAM values never reach 100, so only the sound pill matches. OCR reads the slashed zero as O or drops the space before the percent sign.
FULL_VOLUME_REGEX="1[0O][0O] ?%"
VOLUMES=(0.42 0.64)
# A changed value moves the pill's centre by a few characters, but the neighbouring Perf pills sit further away.
PILL_DRIFT_PX=40

volume_shown() {
  local center x
  center="$(vekrona-dev see find "$1")" || return 1
  x="${center%% *}"
  ((x > PILL_X - PILL_DRIFT_PX && x < PILL_X + PILL_DRIFT_PX))
}
export -f volume_shown
export PILL_DRIFT_PX

vekrona-dev session
clear_notifications
vekrona-dev move 600 500

# The VM has no sound card: the test brings its own output.
SINK_NAME=VekronaTestSink
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
unload_sink() { vekrona-dev sh pactl unload-module "$module"; }
trap unload_sink EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev see text "$FULL_VOLUME_REGEX"
read -r PILL_X y <<<"$(vekrona-dev see find "$FULL_VOLUME_REGEX")"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the volume, but OCR found no '100 %' to locate the sound pill"
export PILL_X
log "ok: the bar shows the initial sink volume of 100 % at x=$PILL_X"

for volume in "${VOLUMES[@]}"; do
  percent="$(awk -v v="$volume" 'BEGIN { printf "%d", v * 100 }')"
  vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ "$volume"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_shown "$percent ?%"
  log "ok: the bar follows the sink volume to $percent %"
done

vekrona-dev click "$PILL_X" "$y"
sink_listed() { vekrona-dev see text "$SINK_NAME"; }
export -f sink_listed
export SINK_NAME
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_listed
log "ok: clicking the sound pill lists the output $SINK_NAME"

vekrona-dev click "$PILL_X" "$y"
sink_hidden() { ! sink_listed; }
export -f sink_hidden
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_hidden
log "ok: clicking the sound pill again closes the popout"
