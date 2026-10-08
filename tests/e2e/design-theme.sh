#!/usr/bin/env bash
# The Vekrona Design System reaches the screen: a bar of the size-bar token on a solid bg desktop, a mode switch that
# moves GTK, gsettings, the wallpaper and Sway together, and an app switcher panel in surface-1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
SWITCHER_TIMEOUT_SEC=6
SWITCHER_HOLD_MS=8000
# The panel is far larger than this many surface-1 pixels; the bar sits above the rows that are counted.
PANEL_MIN_PIXELS=5000
COLORS="$ROOT/tests/e2e/screen_colors.py"
GUEST_SWAY_DROP_IN='~/.config/sway/config.d/90-vekrona-design.conf'
BAR_PX="$(vekrona_token_get size size-bar)"
export COLORS BAR_PX PANEL_MIN_PIXELS

color() { vekrona_token_get color "$1" "$2"; }

desktop_is() { [[ "$(python3 "$COLORS" center "$(vekrona-dev shot)")" == "$1" ]]; }
bar_is_tall() { [[ "$(python3 "$COLORS" bar-height "$(vekrona-dev shot)" "$1")" == "$BAR_PX" ]]; }
panel_shown() { (($(python3 "$COLORS" count "$(vekrona-dev shot)" "$1" "$BAR_PX") >= PANEL_MIN_PIXELS)); }
focused_is() { [[ "$(vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '[recurse(.nodes[]?, .floating_nodes[]?) | select(.focused)][0].app_id'")" == "$1" ]]; }
export -f desktop_is bar_is_tall panel_shown focused_is

guest_gtk_window_bg() { vekrona-dev sh bash -c "sed -n 's/^@define-color window_bg_color \(#[0-9a-fA-F]*\);.*/\1/p' \"\$HOME/.config/gtk-4.0/gtk.css\""; }
guest_color_scheme() { vekrona-dev sh gsettings get org.gnome.desktop.interface color-scheme; }
guest_sway_focused_border() { vekrona-dev sh bash -c "sed -n 's/^client.focused \(#[0-9a-fA-F]*\) .*/\1/p' $GUEST_SWAY_DROP_IN"; }

assert_mode() {
  local mode="$1" scheme="$2" got
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- desktop_is "$(color bg "$mode")" \
    || die "$mode: the empty desktop must be the bg token $(color bg "$mode"), but its center pixel is $(python3 "$COLORS" center "$(vekrona-dev shot)")"
  got="$(guest_gtk_window_bg)"
  [[ "${got,,}" == "$(color surface-1 "$mode")" ]] || die "$mode: gtk-4.0/gtk.css window_bg_color must be surface-1 $(color surface-1 "$mode"), but it is '$got'"
  got="$(guest_color_scheme)"
  [[ "$got" == "'$scheme'" ]] || die "$mode: gsettings color-scheme must be $scheme, but it is $got"
  got="$(guest_sway_focused_border)"
  [[ "${got,,}" == "$(color accent "$mode")" ]] || die "$mode: the sway focused client color must be the accent $(color accent "$mode"), but it is '$got'"
  log "ok: $mode mode gives a bg desktop, a surface-1 GTK window, color-scheme $scheme and an accent focused border"
}

kill_guest() {
  local status=0
  vekrona-dev run pkill "$@" || status=$?
  ((status <= 1)) || warn "could not stop in the guest: pkill $* (exit $status)"
}
trap 'kill_guest -x foot' EXIT

vekrona-dev session
vekrona-dev move 600 500

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_is_tall "$(color bg dark)" \
  || die "the bar must be $BAR_PX px tall (token size-bar), but it measures $(python3 "$COLORS" bar-height "$(vekrona-dev shot)" "$(color bg dark)") px"
log "ok: the bar is $BAR_PX px tall"
assert_mode dark dark

vekrona-dev sh vekrona-theme light
assert_mode light light
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_is_tall "$(color bg light)" \
  || die "light: the bar must still be $BAR_PX px tall"

vekrona-dev sh vekrona-theme dark
assert_mode dark dark

for app in switch-first switch-second; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app"
done
vekrona-dev hold super-tab "$SWITCHER_HOLD_MS" &
holding=$!
vekrona-dev until --timeout "$SWITCHER_TIMEOUT_SEC" -- panel_shown "$(color surface-1 dark)" \
  || { wait "$holding"; die "holding Super+Tab with two windows must show a $(color surface-1 dark) (surface-1) panel, but fewer than $PANEL_MIN_PIXELS such pixels are below the bar"; }
wait "$holding"
log "ok: the app switcher shows a surface-1 panel"
