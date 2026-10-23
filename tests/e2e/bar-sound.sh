#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=60
# The sound icon is the speaker, filled from the bottom up to the volume. These volumes all show the same glyph, so the
# icon holds less ink the quieter it is.
VOLUMES=(1.0 0.7 0.4)
QUIET_OUTPUT_VOLUME=0.2

sound_ink() { bar_widget ink sound; }
# The icon follows a volume change a moment later, so a reading counts once two in a row agree.
settled_sound_ink() {
  local ink next attempt
  ink="$(sound_ink)"
  for attempt in $(seq 20); do
    next="$(sound_ink)"
    [[ "$next" == "$ink" ]] && { echo "$ink"; return; }
    ink="$next"
  done
  die "the sound icon kept changing: $ink ink after $attempt screenshots"
}
sound_ink_changed() { [[ "$(sound_ink)" != "$PREVIOUS_INK" ]]; }
export -f sound_ink sound_ink_changed

vekrona-dev session
clear_notifications
vekrona-dev move 600 500

# The VM has no sound card and PipeWire has no sink until a PulseAudio client connects, so the test brings its own output.
# The quiet volume gives the speaker icon that none of the volumes below show again.
SINK_NAME=VekronaTestSink
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
unload_sink() { vekrona-dev sh pactl unload-module "$module"; }
trap unload_sink EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"
vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ "$QUIET_OUTPUT_VOLUME"
PREVIOUS_INK="$(settled_sound_ink)"
export PREVIOUS_INK

for volume in "${VOLUMES[@]}"; do
  vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ "$volume"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sound_ink_changed || die "the sound icon never changed for volume $volume: it still holds $PREVIOUS_INK ink"
  ink="$(settled_sound_ink)"
  [[ "$volume" == "${VOLUMES[0]}" ]] || ((ink < PREVIOUS_INK)) || die "at volume $volume the sound icon holds $ink ink, not less than the $PREVIOUS_INK of the louder volume"
  log "ok: the sound icon at volume $volume holds $ink ink, the step before held $PREVIOUS_INK"
  PREVIOUS_INK="$ink"
  export PREVIOUS_INK
done
read -r PILL_X y <<<"$(bar_widget center sound)"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the sound icon"
vekrona-dev click "$PILL_X" "$y"
sink_listed() { text_shown "$SINK_NAME"; }
export -f sink_listed
export SINK_NAME
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_listed
log "ok: clicking the sound pill lists the output $SINK_NAME"

vekrona-dev click "$PILL_X" "$y"
sink_hidden() { absent sink_listed; }
export -f sink_hidden
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_hidden
log "ok: clicking the sound pill again closes the popout"

# An open launcher holds the keyboard exclusively, so the popout opens over it only once the launcher has closed.
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open || die "Super+Space must open the launcher"
vekrona-dev click "$PILL_X" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_listed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "opening the sound popout must close the launcher"
log "ok: opening a popout closes the open launcher"
vekrona-dev click "$PILL_X" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sink_hidden
