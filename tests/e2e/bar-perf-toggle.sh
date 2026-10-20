#!/usr/bin/env bash
# The performance pill opens btop in a window of its own, and the next click on it closes that window.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=60
APP_ID=vekrona.perf
POSITION_FILE="$(mktemp)"

perf_position() { bar_widget center load >"$POSITION_FILE"; }
btop_windows() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq '[.. | objects | select((.app_id? // \"\") == \"$APP_ID\")] | length'"; }
btop_open() { [[ "$(btop_windows)" -ge 1 ]]; }
btop_closed() { [[ "$(btop_windows)" -eq 0 ]]; }
export -f perf_position btop_windows btop_open btop_closed
export POSITION_FILE APP_ID

cleanup() {
  vekrona-dev sh systemctl --user stop vekrona-perf.service || true
  rm -f "$POSITION_FILE"
}
trap cleanup EXIT

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- perf_position
read -r x y <"$POSITION_FILE"

vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- btop_open || die "a click on the performance pill must open btop in a window with the app id $APP_ID"
[[ "$(btop_windows)" == 1 ]] || die "one click must open one btop window, not $(btop_windows)"
log "ok: a click on the performance pill opens one btop window"

vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- btop_closed || die "a second click on the performance pill must close the btop window"
log "ok: a second click on the performance pill closes it"
