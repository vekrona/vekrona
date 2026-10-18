#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# A tray icon is drawn once per screen pixel, so a fractional scale is where it breaks. A fractional scale needs a bigger mode for the
# right-side widgets to keep the tray in the right half of the screen.
SCALES=(1 1.25 1.5)
FIXTURES="$ROOT/tests/fixtures/tray"
BAR_HEIGHT_LOGICAL_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_LOGICAL_PX="$(vekrona_token_get size size-icon-s)"
INK="$(vekrona_token_get color ink dark)"
BAR="$(vekrona_token_get color surface-1 dark)"
INK_TRAY="$ROOT/tests/e2e/tray-ink.py"
LEFT_EDGE="$ROOT/tests/e2e/bar-left-edge.py"
GROUP_JOIN_LOGICAL_PX="$(vekrona_token_get spacing space-2)"
# A tray slot is as wide as an icon-only pill: the icon between two paddings. A hovered slot paints this behind its icon, on its second row
# (above the pointer, which the screenshot draws from the pointer's tip down).
SLOT_PX=$((ICON_S_LOGICAL_PX + 2 * $(vekrona_token_get spacing space-2)))
HOVER="$(vekrona_token_get color surface-2 dark)"
SLOT_ROW=$((($(vekrona_token_get size size-bar) - $(vekrona_token_get size size-target)) / 2 + 1))
PILL_WIDTH="$ROOT/tests/e2e/bar-pill-width.py"
PARK_X=600
PARK_Y=500
MENU_LABEL="Fake menu entry"
GUEST_DIR=/tmp/bar-tray
GUEST_SNI="$GUEST_DIR/fake-sni.py"
GUEST_LOG=/tmp/bar-tray-fake-sni.log
TRAY_UNIT=tailscale-systray.service
# How long a click is given to open a menu, which it must not (or to reopen one it closed). A menu opens within a second.
QUIET_SEC=10
DEFAULT_MODE=1280x800
SCALED_MODE=1920x1200
SETTLED_MAX_DIFF=0.2

scaled_px() { awk -v px="$1" -v scale="$2" 'BEGIN { printf "%d", px * scale + 0.5 }'; }
# pkill exits 1 when no fake icon is running, which is fine.
stop_fake_icons() { vekrona-dev run pkill -f "[b]ar-tray/fake-sni.py" || [[ $? -eq 1 ]]; }
start_tray_unit() { vekrona-dev sh systemctl --user start "$TRAY_UNIT"; }
reset_output() { vekrona-dev sh swaymsg output '*' mode "$DEFAULT_MODE" scale 1 >/dev/null; }
set_output() {
  local scale="$1" mode="$DEFAULT_MODE"
  [[ "$scale" == 1 ]] || mode="$SCALED_MODE"
  vekrona-dev sh swaymsg output '*' mode "$mode" scale "$scale" >/dev/null
}
# The bar lays out again after the output changes: wait until two screenshots agree.
bar_settled() { vekrona-dev see diff "$(vekrona-dev shot)" | awk -v max="$SETTLED_MAX_DIFF" '{ exit !($1 <= max) }'; }

scale_sizes() {
  bar_px="$(scaled_px "$BAR_HEIGHT_LOGICAL_PX" "$1")"
  icon_px="$(scaled_px "$ICON_S_LOGICAL_PX" "$1")"
}
settle_output() {
  vekrona-dev move 600 500
  export -f bar_settled
  export SETTLED_MAX_DIFF
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_settled
}
# Sets BASELINE to a screenshot of the bar with a blank icon in the tray, which measure_icon compares an icon against. The slot an
# icon takes pushes the widgets left of the tray to the left, so a bar without any icon would show them as part of the icon.
blank_baseline() {
  local scale="$1" edge_without_slot bar_px icon_px join_px
  scale_sizes "$scale"
  join_px="$(scaled_px "$GROUP_JOIN_LOGICAL_PX" "$scale")"
  bar_edge() { python3 "$LEFT_EDGE" "$(vekrona-dev shot)" "$bar_px" "$icon_px" "$join_px"; }
  slot_taken() { [[ "$(bar_edge)" != "$edge_without_slot" ]]; }
  export -f bar_edge slot_taken
  export LEFT_EDGE bar_px icon_px join_px
  edge_without_slot="$(bar_edge)"
  export edge_without_slot
  start_icon blank
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- slot_taken || die "the blank icon took no slot in the tray at scale $scale: the left edge of the right side stayed at x=$edge_without_slot"
  settle_output
  BASELINE="$(vekrona-dev shot)"
  stop_fake_icons
}
start_icon() {
  vekrona-dev spawn "$GUEST_LOG" -- python3 "$GUEST_SNI" "$1"
  registered() { vekrona-dev run grep -q registered "$GUEST_LOG"; }
  export -f registered
  export GUEST_LOG
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- registered
}
# Measures the icon on screen against a screenshot of the same bar without it.
measure_icon() {
  local name="$1" shape="$2" scale="$3" without_icon="$4" bar_px icon_px
  scale_sizes "$scale"
  tray_ink_ok() { python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$bar_px" "$icon_px" "$INK" "$BAR" "$shape" >/dev/null 2>&1; }
  export -f tray_ink_ok
  export INK_TRAY without_icon bar_px icon_px INK BAR shape
  if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tray_ink_ok; then
    log "the $name tray icon did not settle within ${STEP_TIMEOUT_SEC}s at scale $scale; measuring the final state"
  fi
  python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$bar_px" "$icon_px" "$INK" "$BAR" "$shape" | tee "$MEASURE_FILE" || die "the $name tray icon is drawn wrongly at scale $scale, see the measurement above"
}
check_icon() {
  local name="$1" kind="$2" shape="$3" scale="$4" without_icon="$5"
  start_icon "$kind"
  measure_icon "$name" "$shape" "$scale" "$without_icon"
  stop_fake_icons
}
# An icon already on the bar must redraw when the output scale changes under it.
check_scale_change() {
  local from="$1" to="$2" without_from without_to
  set_output "$from"
  settle_output
  blank_baseline "$from"
  without_from="$BASELINE"
  set_output "$to"
  settle_output
  blank_baseline "$to"
  without_to="$BASELINE"
  set_output "$from"
  settle_output
  start_icon "$GUEST_DIR/tailscale.png"
  measure_icon "Tailscale" dots "$from" "$without_from"
  set_output "$to"
  settle_output
  measure_icon "Tailscale" dots "$to" "$without_to"
  stop_fake_icons
}

MEASURE_FILE="$(mktemp)"
menu_shown() { text_shown "$MENU_LABEL"; }
menu_gone() { absent menu_shown; }
menu_errors() { shell_log_count 'QApplication mode'; }
export -f menu_shown menu_gone
export MENU_LABEL

"$ROOT/tests/bake-shaders.sh" --check
vekrona-dev session
clear_notifications
trap 'stop_fake_icons; reset_output; rm -f "$MEASURE_FILE"' EXIT
# The fake icon must be the only one in the tray, or the measured box would depend on the order of the icons.
if vekrona-dev sh systemctl --user is-active --quiet "$TRAY_UNIT"; then
  trap 'stop_fake_icons; reset_output; rm -f "$MEASURE_FILE"; start_tray_unit' EXIT
  vekrona-dev sh systemctl --user stop "$TRAY_UNIT"
fi
vekrona-dev run mkdir -p "$GUEST_DIR"
for file in "$ROOT/tests/e2e/fake-sni.py" "$ROOT/tests/e2e/png_rows.py" "$FIXTURES"/*.png; do
  vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_DIR/$(basename "$file")" <"$file"
done

for scale in "${SCALES[@]}"; do
  set_output "$scale"
  settle_output
  blank_baseline "$scale"
  without_icon="$BASELINE"
  check_icon "opaque" opaque dots "$scale" "$without_icon"
  log "ok: at scale $scale an opaque tray icon shows its dots as ink on the bar, not a solid ink square"
  check_icon "alpha" alpha disc "$scale" "$without_icon"
  log "ok: at scale $scale a tray icon with transparency keeps its shape as an ink silhouette"
  check_icon "1Password" "$GUEST_DIR/1password.png" badged-disc "$scale" "$without_icon"
  log "ok: at scale $scale the real 1Password tray icon is an ink disc that keeps its opaque ring and keyhole as holes"
  check_icon "themed" "themed:$GUEST_DIR/themed-disc.png" disc "$scale" "$without_icon"
  log "ok: at scale $scale a tray icon that the icon theme supplies, as Steam's does, is a whole ink disc of the icon size"
  check_icon "Tailscale" "$GUEST_DIR/tailscale.png" dots "$scale" "$without_icon"
  log "ok: at scale $scale the real Tailscale tray icon is ink dots on the bar"
done

check_scale_change "${SCALES[0]}" "${SCALES[-1]}"
log "ok: a tray icon on the bar is redrawn whole when the output scale goes from ${SCALES[0]} to ${SCALES[-1]}"
check_scale_change "${SCALES[-1]}" "${SCALES[0]}"
log "ok: a tray icon on the bar is redrawn whole when the output scale goes from ${SCALES[-1]} to ${SCALES[0]}"

set_output 1
settle_output
blank_baseline 1
without_icon="$BASELINE"
start_icon "$GUEST_DIR/tailscale.png"
measure_icon "Tailscale" dots 1 "$without_icon"
read -r left right top bottom < <(sed -n 's/^icon box x \([0-9]*\)-\([0-9]*\) y \([0-9]*\)-\([0-9]*\):.*/\1 \2 \3 \4/p' "$MEASURE_FILE")
icon_x=$(((left + right) / 2))
icon_y=$(((top + bottom) / 2))
# The pointer enters from the empty desktop: a slot under a pointer that was on another widget a moment ago does not always light up.
hovered_slot_width() {
  vekrona-dev move "$PARK_X" "$PARK_Y"
  vekrona-dev move "$icon_x" "$icon_y"
  python3 "$PILL_WIDTH" "$(vekrona-dev shot)" "$SLOT_ROW" "$icon_x" "$HOVER"
}
export -f hovered_slot_width
export icon_x icon_y PARK_X PARK_Y PILL_WIDTH SLOT_ROW HOVER
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- hovered_slot_width >/dev/null || die "no tray slot lit up under the pointer at x=$icon_x"
slot_width="$(hovered_slot_width)"
[[ "$slot_width" == "$SLOT_PX" ]] || die "the tray slot is $slot_width px wide, not an icon-only pill's width ($SLOT_PX px)"
log "ok: a tray slot is as wide as an icon-only pill ($SLOT_PX px)"
menu_errors_before="$(menu_errors)"
vekrona-dev click "$icon_x" "$icon_y" --button right
stays_absent "$QUIET_SEC" menu_shown || die "right-clicking a tray icon must open nothing, but it opened its menu"
log "ok: right-clicking a tray icon opens nothing"
vekrona-dev click "$icon_x" "$icon_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- menu_shown || die "left-clicking a tray icon must open its menu"
[[ "$(menu_errors)" == "$menu_errors_before" ]] || die "left-clicking a tray icon made the shell complain that it is not in QApplication mode"
log "ok: left-clicking a tray icon opens its menu"
vekrona-dev click "$icon_x" "$icon_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- menu_gone || die "a second left click on the tray icon must close its menu"
stays_absent "$QUIET_SEC" menu_shown || die "a second left click on the tray icon closed its menu and then reopened it"
log "ok: a second left click on the tray icon closes its menu and leaves it closed"
stop_fake_icons
