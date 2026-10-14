#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The Perf widget's CPU and RAM values stay below 100 in an idle VM, so only the sound pill matches. OCR reads the slashed zero as O or drops the space before the percent sign.
FULL_VOLUME_REGEX="1[0O][0O] ?%"
PLAYER_BUS_NAME=org.mpris.MediaPlayer2.vekronatest
# The windows are foot terminals: Ghostty's GL renderer crashes on the guest's llvmpipe while the popout covers it.
PLAYER_APP_ID=vekrona-media-player
OTHER_APP_ID=vekrona-media-other
TRACK_REGEX="Lighthouse ?Signal"
ARTIST_REGEX="Quiet ?Harbor"
IDENTITY_REGEX="Test ?Player"
ART_RGB=e6007e
ART_HEX="#$ART_RGB"
# The art is 72 px square (iconXl); a smaller run of its color is a partial or scaled-down picture.
MIN_ART_PIXELS=2000
SINK_NAME=VekronaTestSink
GUEST_DIR=/tmp/sound-media
GUEST_PLAYER="$GUEST_DIR/fake-mpris.py"
# An empty stretch of the bar: the pointer rests there so it covers no text OCR reads, and, unlike a spot over a
# window, it moves no focus (focus_follows_mouse).
PARK_X=400
PARK_Y=18
PLAYER_PROCESS_REGEX="^[^ ]*python3 [^ ]*fake-mpris\\.py"
export PLAYER_APP_ID OTHER_APP_ID TRACK_REGEX ARTIST_REGEX IDENTITY_REGEX ART_HEX MIN_ART_PIXELS SINK_NAME PLAYER_BUS_NAME

window_open() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -e '[recurse(.nodes[]?, .floating_nodes[]?) | select(.app_id? == \"$1\")] | length > 0' >/dev/null"; }
focused_app_id() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '[recurse(.nodes[]?, .floating_nodes[]?) | select(.focused)][0].app_id'"; }
focused_is() { [[ "$(focused_app_id)" == "$1" ]]; }
player_on_bus() { vekrona-dev sh busctl --user status "$PLAYER_BUS_NAME" >/dev/null 2>&1; }
player_off_bus() { ! player_on_bus; }
track_shown() { vekrona-dev see text "$TRACK_REGEX"; }
track_hidden() { ! track_shown; }
sink_listed() { vekrona-dev see text "$SINK_NAME"; }
sink_hidden() { ! sink_listed; }
art_shown() {
  local shot pixels
  shot="$(vekrona-dev shot)"
  pixels="$(python3 "$SCREEN_COLORS" count "$shot" "$ART_HEX" 0)"
  rm -f "$shot"
  ((pixels >= MIN_ART_PIXELS))
}
export -f window_open focused_app_id focused_is player_on_bus player_off_bus track_shown track_hidden sink_listed sink_hidden art_shown

await() {
  local failure="$1"
  shift
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$@" || die "$failure"
}

kill_guest() {
  local status=0
  vekrona-dev run pkill "$@" || status=$?
  ((status <= 1)) || warn "could not stop in the guest: pkill $* (exit $status)"
}

start_terminal() {
  vekrona-dev spawn "$GUEST_DIR/$1.log" -- foot --app-id="$1" "${@:2}"
}

vekrona-dev session
clear_notifications
vekrona-dev move "$PARK_X" "$PARK_Y"

# The VM has no sound card: the test brings its own output.
module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
cleanup() {
  kill_guest -f -- "--app-id=vekrona-media-"
  vekrona-dev run rm -rf "$GUEST_DIR" || warn "could not remove $GUEST_DIR in the guest"
  vekrona-dev sh pactl unload-module "$module" || warn "could not unload the null sink module $module"
}
trap cleanup EXIT
vekrona-dev sh pactl set-default-sink "$SINK_NAME"

vekrona-dev run mkdir -p "$GUEST_DIR"
vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_PLAYER" <"$ROOT/tests/e2e/fake-mpris.py"

vekrona-dev sh wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0
await "the bar never showed the sink volume of 100 %" vekrona-dev see text "$FULL_VOLUME_REGEX"
read -r pill_x pill_y <<<"$(vekrona-dev see find "$FULL_VOLUME_REGEX")"
[[ -n "${pill_x:-}" && -n "${pill_y:-}" ]] || die "the bar must show the volume, but OCR found no '100 %' to locate the sound pill"
log "ok: the sound pill is at $pill_x,$pill_y"

# The player runs in its own terminal, so the window that owns it is an ancestor of the process that owns the bus name.
start_terminal "$PLAYER_APP_ID" python3 "$GUEST_PLAYER" "$ART_RGB"
await "no window $PLAYER_APP_ID appeared" window_open "$PLAYER_APP_ID"
await "the fake player never took $PLAYER_BUS_NAME on the session bus" player_on_bus
start_terminal "$OTHER_APP_ID"
await "no window $OTHER_APP_ID appeared" window_open "$OTHER_APP_ID"
await "the second window never took focus" focused_is "$OTHER_APP_ID"
log "ok: the player runs in a window that is not focused"

vekrona-dev click "$pill_x" "$pill_y"
vekrona-dev move "$PARK_X" "$PARK_Y"
await "the popout never showed the track title" track_shown
await "the popout never showed the artist" vekrona-dev see text "$ARTIST_REGEX"
await "the popout never showed the player's name" vekrona-dev see text "$IDENTITY_REGEX"
log "ok: the popout shows the title, the artist and the player's name"

await "the track art color $ART_HEX never showed on screen" art_shown
log "ok: the popout shows the track art ($ART_HEX)"

read -r title_x title_y <<<"$(vekrona-dev see find "Lighthouse")"
[[ -n "${title_x:-}" && -n "${title_y:-}" ]] || die "OCR found the track title a moment ago but cannot locate it to click"
vekrona-dev click "$title_x" "$title_y"
await "clicking the track title did not close the popout" track_hidden
await "clicking the track title did not focus the window $PLAYER_APP_ID" focused_is "$PLAYER_APP_ID"
log "ok: clicking the track title closes the popout and focuses the player's window"

kill_guest -f "$PLAYER_PROCESS_REGEX"
await "$PLAYER_BUS_NAME is still on the session bus after the player was killed" player_off_bus
vekrona-dev click "$pill_x" "$pill_y"
vekrona-dev move "$PARK_X" "$PARK_Y"
await "the popout never listed the output $SINK_NAME" sink_listed
await "the popout still shows the track of a player that is gone" track_hidden
log "ok: without a player, the popout lists the outputs and no track"

vekrona-dev click "$pill_x" "$pill_y"
vekrona-dev move "$PARK_X" "$PARK_Y"
await "clicking the sound pill again did not close the popout" sink_hidden
log "ok: clicking the sound pill again closes the popout, so the next scenario starts without it"
