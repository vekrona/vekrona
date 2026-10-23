#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=60
# Every widget of the bar is one thing, a pictogram (P) or a text (T), never both. From the right edge the bar of the VM
# shows: the clock, the bell, the agent, the network and the sound icons, then the keyboard layout, the load icon (a
# CPU and a memory bar) and the weather. A widget that shows an icon next to its value adds a pictogram before its text.
EXPECTED_ENDING=TPTPPPPT
SINK_NAME=VekronaTestSink

kinds() { bar_widget kinds; }
bar_ends_as_expected() { [[ "$(kinds)" == *"$EXPECTED_ENDING" ]]; }
export -f kinds bar_ends_as_expected
export EXPECTED_ENDING

restore() {
  set_layouts us
  vekrona-dev sh pactl unload-module "$module"
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
# The VM has no sound card and one layout: the sound and keyboard widgets show up once the test brings them.
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
trap restore EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"
vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0
set_layouts us,ua
settled_bar_left_edge >/dev/null

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_ends_as_expected || die "the bar must end with $EXPECTED_ENDING (text, icon, text, icon, icon, icon, icon, text), but its widgets are $(kinds)"
log "ok: the weather, layout and clock show text only; the load, sound, network, agent and bell show an icon only"
