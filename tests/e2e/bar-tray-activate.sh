#!/usr/bin/env bash
# A left click on a tray icon that has no menu asks the app to act (as for a window to open), and does not try to open a menu: the
# shell logs a critical error for that, which the error pipeline records.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
BAR_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_PX="$(vekrona_token_get size size-icon-s)"
INK="$(vekrona_token_get color ink dark)"
BAR="$(vekrona_token_get color surface-1 dark)"
INK_TRAY="$ROOT/tests/e2e/tray-ink.py"
LEFT_EDGE="$ROOT/tests/e2e/bar-left-edge.py"
JOIN_PX="$(vekrona_token_get spacing space-2)"
GUEST_DIR=/tmp/bar-tray-activate
GUEST_SNI="$GUEST_DIR/fake-sni.py"
GUEST_LOG=/tmp/bar-tray-activate-fake-sni.log
TRAY_UNIT=tailscale-systray.service
MEASURE_FILE="$(mktemp)"

stop_fake_icons() { vekrona-dev run pkill -f "[b]ar-tray-activate/fake-sni.py" || [[ $? -eq 1 ]]; }
start_icon() {
  vekrona-dev run rm -f "$GUEST_LOG"
  vekrona-dev spawn "$GUEST_LOG" -- python3 "$GUEST_SNI" "$1"
  registered() { vekrona-dev run grep -q registered "$GUEST_LOG"; }
  export -f registered
  export GUEST_LOG
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- registered
}
activated() { vekrona-dev run grep -q activated "$GUEST_LOG"; }
shell_criticals() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell | grep -c 'QApplication mode\|menu' || [[ $? -eq 1 ]]; }
export -f activated
export GUEST_LOG

restore() {
  stop_fake_icons
  rm -f "$MEASURE_FILE"
  [[ "${tray_was_active:-0}" == 1 ]] && vekrona-dev sh systemctl --user start "$TRAY_UNIT"
  return 0
}
trap restore EXIT

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
tray_was_active=0
if vekrona-dev sh systemctl --user is-active --quiet "$TRAY_UNIT"; then
  tray_was_active=1
  vekrona-dev sh systemctl --user stop "$TRAY_UNIT"
fi
vekrona-dev run mkdir -p "$GUEST_DIR"
for file in "$ROOT/tests/e2e/fake-sni.py" "$ROOT/tests/e2e/png_rows.py"; do
  vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_DIR/$(basename "$file")" <"$file"
done

# The same icon, as a blank one that draws nothing, gives the bar to compare it with.
edge_without="$(python3 "$LEFT_EDGE" "$(vekrona-dev shot)" "$BAR_PX" "$ICON_PX" "$JOIN_PX")"
slot_taken() { [[ "$(python3 "$LEFT_EDGE" "$(vekrona-dev shot)" "$BAR_PX" "$ICON_PX" "$JOIN_PX")" != "$edge_without" ]]; }
export -f slot_taken
export LEFT_EDGE BAR_PX ICON_PX JOIN_PX edge_without
start_icon blank
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- slot_taken
vekrona-dev move 600 500
BASELINE="$(vekrona-dev shot)"
stop_fake_icons

start_icon plain
tray_ink_ok() { python3 "$INK_TRAY" "$BASELINE" "$(vekrona-dev shot)" "$BAR_PX" "$ICON_PX" "$INK" "$BAR" dots >/dev/null 2>&1; }
export -f tray_ink_ok
export INK_TRAY BASELINE INK BAR
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tray_ink_ok || die "the plain tray icon never showed"
python3 "$INK_TRAY" "$BASELINE" "$(vekrona-dev shot)" "$BAR_PX" "$ICON_PX" "$INK" "$BAR" dots >"$MEASURE_FILE"
read -r left right top bottom < <(sed -n 's/^icon box x \([0-9]*\)-\([0-9]*\) y \([0-9]*\)-\([0-9]*\):.*/\1 \2 \3 \4/p' "$MEASURE_FILE")
icon_x=$(((left + right) / 2))
icon_y=$(((top + bottom) / 2))

errors_before="$(shell_criticals)"
vekrona-dev click "$icon_x" "$icon_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- activated || die "a left click on a tray icon without a menu must ask the app to act (Activate)"
[[ "$(shell_criticals)" == "$errors_before" ]] || die "a left click on a tray icon without a menu made the shell try to open a menu"
log "ok: a left click on a tray icon without a menu activates the app and logs no menu error"
