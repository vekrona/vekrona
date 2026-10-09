#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
SINK_NAME=VekronaTestSink
ACCENT_HEX="$(vekrona_token_get color accent dark)"
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
OSD_MIN_PIXELS=$((ICON_S_PX * ICON_S_PX / 2))

volume() { vekrona-dev sh wpctl get-volume @DEFAULT_AUDIO_SINK@; }
volume_is() { [[ "$(volume)" == "Volume: $EXPECTED" ]]; }
volume_muted() { [[ "$(volume)" == *'[MUTED]'* ]]; }
volume_unmuted() { ! volume_muted; }
accent_pixels() { python3 "$SCREEN_COLORS" count "$(vekrona-dev shot)" "$ACCENT_HEX" "$BAR_HEIGHT_PX"; }
osd_shown() { (($(accent_pixels) >= OSD_MIN_PIXELS)); }
osd_hidden() { (($(accent_pixels) == 0)); }
shell_volume() { vekrona-dev sh qs -c vekrona-shell ipc call audio "$@" >/dev/null; }
export -f volume volume_is volume_muted volume_unmuted accent_pixels osd_shown osd_hidden
export EXPECTED ACCENT_HEX BAR_HEIGHT_PX OSD_MIN_PIXELS

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

# The VM has no sound card: the test brings its own output.
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
unload_sink() { vekrona-dev sh pactl unload-module "$module"; }
trap unload_sink EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.50
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- osd_hidden
shell_volume increment 5
EXPECTED=0.55
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_is
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- osd_shown
log "ok: the volume key raises the volume by 5 points and shows the OSD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- osd_hidden
log "ok: the OSD hides again"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.98
shell_volume increment 5
EXPECTED=1.00
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_is
log "ok: the volume stops at 1.0"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.02
shell_volume decrement 5
EXPECTED=0.00
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_is
log "ok: the volume stops at 0"

shell_volume mute
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_muted
shell_volume mute
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- volume_unmuted
log "ok: the mute key toggles mute"

vekrona-dev sh qs -c vekrona-shell ipc call mpris playPause >/dev/null
log "ok: media keys without a player do nothing and do not fail"
