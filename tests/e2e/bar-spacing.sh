#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=90
# Two widgets sit two BarPill paddings (2 * space-2) apart, plus the padding of the 24-unit pictogram grid on both facing sides:
# 4 of 24 units each (the bell is the narrowest glyph), at size-icon-s px.
GLYPH_BEARING_PX=$(((ICON_S_PX * 4 + 23) / 24))
# A text widget is centered in a slot as wide as its widest value ("-88°C"), so a narrower value adds half of the difference,
# one digit at most, to the gap on each side.
TEXT_SLACK_PX=4
MAX_GAP_PX=$((2 * GROUP_JOIN_PX + 2 * GLYPH_BEARING_PX + TEXT_SLACK_PX))
MAX_GAP_SPREAD_PX=6
GAPS="$ROOT/tests/e2e/bar-gaps.py"
SEPARATOR="$ROOT/tests/e2e/bar-separator.py"
SEPARATOR_MIN_HEIGHT_PX=$((BAR_HEIGHT_PX / 2))
# The separator is drawn in the line token on the surface-1 bar.
# Antialiasing and fractional scale blend the line with the surface at the edges, so require half the token difference.
SEPARATOR_TOKEN_CONTRAST="$(python3 "$ROOT/tests/e2e/screen_colors.py" contrast "$(vekrona_token_get color line dark)" "$(vekrona_token_get color surface-1 dark)")"
SEPARATOR_MIN_CONTRAST=$((SEPARATOR_TOKEN_CONTRAST / 2))

bar_spacing_ok() {
  python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$GROUP_JOIN_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$ICON_S_PX" >/dev/null
}
export -f bar_spacing_ok
export ROOT BAR_HEIGHT_PX GROUP_JOIN_PX MAX_GAP_PX MAX_GAP_SPREAD_PX ICON_S_PX GAPS

# The clock pill is as wide as its widest date, so the gap before it depends on the date. On a Wednesday in August its
# words are the widest and the tallest ("Aug" has a descender), which is the worst case for the gap and for telling
# the clock's text from a pictogram.
WORST_CASE_DATE="2026-08-26 22:22:00"
WORST_CASE_MONTH=Aug
# Both dots show, so the check covers the pills that carry one: a dot hangs over its pill's padding and widens no gap.
UNREAD_COUNT=1
# The bar the user sees: two tray icons (Tailscale's own unit and a fake 1Password), the weather, the load (a pictogram of two bars),
# a second keyboard layout, the sound and network icons, the agent and the bell with their dots, the clock. A battery shows on laptops only.
EXPECTED_KINDS=PPTPTPPPPT
SINK_NAME=VekronaTestSink
GUEST_DIR=/tmp/bar-spacing
GUEST_LOG=/tmp/bar-spacing-fake-sni.log
registered() { vekrona-dev run grep -q registered "$GUEST_LOG"; }
export -f registered
export GUEST_LOG
# The clock goes first: a pinned clock is what every later scenario would meet.
unload_sink() { vekrona-dev sh pactl unload-module "$sink_module"; }
restore() {
  run_cleanups clock_restore unread_restore 'kill_guest -f "[b]ar-spacing/fake-sni.py"' "set_layouts us" unload_sink
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
sink_module="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$SINK_NAME" "sink_properties=device.description=$SINK_NAME")"
trap restore EXIT
vekrona-dev sh swaymsg 'input type:keyboard xkb_layout "us,ua"' >/dev/null
unread_stash
clock_pin "$WORST_CASE_DATE"
unread_set "$UNREAD_COUNT"
# The shell forgets the tray icons it was started without, so the fake one starts after the clock pin restarted it.
vekrona-dev run mkdir -p "$GUEST_DIR"
for file in "$ROOT/tests/e2e/fake-sni.py" "$ROOT/tests/e2e/png_rows.py" "$ROOT/tests/fixtures/tray/1password.png"; do
  vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_DIR/$(basename "$file")" <"$file"
done
vekrona-dev spawn "$GUEST_LOG" -- python3 "$GUEST_DIR/fake-sni.py" "$GUEST_DIR/1password.png"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- registered
settled_bar_left_edge >/dev/null
vekrona-dev sh notify-send "Spacing test"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev see find "$WORST_CASE_MONTH" || die "the bar never showed the pinned date $WORST_CASE_DATE"
# Widgets load at their own pace: wait for the spacing to settle.
if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_spacing_ok; then
  log "the bar spacing did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
fi

kinds="$(bar_widget kinds)"
[[ "$kinds" == *"$EXPECTED_KINDS" ]] || die "the bar must end with the widgets $EXPECTED_KINDS (P icon, T text), but they are $kinds"
python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$GROUP_JOIN_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$ICON_S_PX" || die "the right-side bar widgets must be evenly spaced at most $MAX_GAP_PX px apart, see the measurement above"
log "ok: every right-side bar widget, the tray icons and the text ones included, is separated by a similar, tight gap"

python3 "$SEPARATOR" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$SEPARATOR_MIN_HEIGHT_PX" "$SEPARATOR_MIN_CONTRAST" || die "the bar must show a visible separator line after the workspaces, see the measurement above"
log "ok: the separator after the workspaces is clearly visible"
