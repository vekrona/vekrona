#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# A tray icon is drawn once per screen pixel, so a fractional scale is where it breaks. Scale 1.5 needs a bigger mode for the
# right-side widgets to keep the tray in the right half of the screen.
SCALES=(1 1.5)
FIXTURES="$ROOT/tests/fixtures/tray"
BAR_HEIGHT_LOGICAL_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_LOGICAL_PX="$(vekrona_token_get size size-icon-s)"
INK="$(vekrona_token_get color ink dark)"
BAR="$(vekrona_token_get color surface-1 dark)"
INK_TRAY="$ROOT/tests/e2e/tray-ink.py"
GUEST_DIR=/tmp/bar-tray
GUEST_SNI="$GUEST_DIR/fake-sni.py"
GUEST_LOG=/tmp/bar-tray-fake-sni.log
TRAY_UNIT=tailscale-systray.service
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

check_icon() {
  local name="$1" kind="$2" shape="$3" scale="$4" bar_px="$5" icon_px="$6"
  vekrona-dev spawn "$GUEST_LOG" -- python3 "$GUEST_SNI" "$kind"
  registered() { vekrona-dev run grep -q registered "$GUEST_LOG"; }
  tray_ink_ok() { python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$bar_px" "$icon_px" "$INK" "$BAR" "$shape" >/dev/null 2>&1; }
  export -f registered tray_ink_ok
  export GUEST_LOG INK_TRAY without_icon bar_px icon_px INK BAR shape
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- registered
  if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tray_ink_ok; then
    log "the $name tray icon did not settle within ${STEP_TIMEOUT_SEC}s at scale $scale; measuring the final state"
  fi
  python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$bar_px" "$icon_px" "$INK" "$BAR" "$shape" || die "the $name tray icon is drawn wrongly at scale $scale, see the measurement above"
  stop_fake_icons
}

vekrona-dev session
clear_notifications
trap 'stop_fake_icons; reset_output' EXIT
# The fake icon must be the only one in the tray, or the measured box would depend on the order of the icons.
if vekrona-dev sh systemctl --user is-active --quiet "$TRAY_UNIT"; then
  trap 'stop_fake_icons; reset_output; start_tray_unit' EXIT
  vekrona-dev sh systemctl --user stop "$TRAY_UNIT"
fi
vekrona-dev run mkdir -p "$GUEST_DIR"
for file in "$ROOT/tests/e2e/fake-sni.py" "$ROOT/tests/e2e/png_rows.py" "$FIXTURES"/*.png; do
  vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_DIR/$(basename "$file")" <"$file"
done

for scale in "${SCALES[@]}"; do
  set_output "$scale"
  vekrona-dev move 600 500
  export -f bar_settled
  export SETTLED_MAX_DIFF
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_settled
  bar_px="$(scaled_px "$BAR_HEIGHT_LOGICAL_PX" "$scale")"
  icon_px="$(scaled_px "$ICON_S_LOGICAL_PX" "$scale")"
  without_icon="$(vekrona-dev shot)"
  check_icon "opaque" opaque dots "$scale" "$bar_px" "$icon_px"
  log "ok: at scale $scale an opaque tray icon shows its dots as ink on the bar, not a solid ink square"
  check_icon "alpha" alpha disc "$scale" "$bar_px" "$icon_px"
  log "ok: at scale $scale a tray icon with transparency keeps its shape as an ink silhouette"
  check_icon "1Password" "$GUEST_DIR/1password.png" disc "$scale" "$bar_px" "$icon_px"
  log "ok: at scale $scale the real 1Password tray icon is a whole ink disc"
  check_icon "Tailscale" "$GUEST_DIR/tailscale.png" dots "$scale" "$bar_px" "$icon_px"
  log "ok: at scale $scale the real Tailscale tray icon is ink dots on the bar"
done
