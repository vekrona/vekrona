#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
VOLUME_PERCENT=40
# OCR reads the slashed zero as O or drops the space before the percent sign.
VOLUME_REGEX="4[0O]? ?%"

volume_shown() { vekrona-dev see text "$VOLUME_REGEX"; }
export -f volume_shown
export VOLUME_REGEX

vekrona-dev session
vekrona-dev move 600 500

# The VM has no sound card: the test brings its own output.
SINK_NAME=VekronaTestSink
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
unload_sink() { vekrona-dev sh pactl unload-module "$module"; }
trap unload_sink EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ "0.$VOLUME_PERCENT"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_shown
log "ok: the bar shows the sink volume of $VOLUME_PERCENT %"

read -r x y <<<"$(vekrona-dev see find "$VOLUME_REGEX")"
[[ -n "${x:-}" && -n "${y:-}" ]] || die "the bar must show the volume, but OCR found no '$VOLUME_PERCENT %' to click"
vekrona-dev click "$x" "$y"
sink_listed() { vekrona-dev see text "$SINK_NAME"; }
export -f sink_listed
export SINK_NAME
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_listed
log "ok: clicking the sound pill lists the output $SINK_NAME"

vekrona-dev click "$x" "$y"
sink_hidden() { ! sink_listed; }
export -f sink_hidden
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_hidden
log "ok: clicking the sound pill again closes the popout"
