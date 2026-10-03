#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"

HOLD_MS=1500
VISIBLE_STEP=10
STEP_TIMEOUT_SEC=30
GUEST_BINDINGS=/tmp/vekrona-e2e-bindings.jsonl
GUEST_KEYS=/tmp/vekrona-e2e-keys.log

stop_watcher() {
  local status=0
  vekrona-dev run "$@" || status=$?
  ((status <= 1)) || warn "could not stop a guest watcher: $* (exit $status)"
}

stop_watchers() {
  stop_watcher sudo pkill -f "libinput debug-events --show-keycodes"
  stop_watcher pkill -f "swaymsg -r -m -t subscribe"
}
trap stop_watchers EXIT

brighter_than() { awk -v now="$(vekrona-dev see luma)" -v floor="$1" 'BEGIN { exit !(now > floor) }'; }
no_brighter_than() { awk -v now="$(vekrona-dev see luma)" -v ceiling="$1" 'BEGIN { exit !(now <= ceiling) }'; }
watch_line() { vekrona-dev run grep -qE "$2" "$1"; }
export -f brighter_than no_brighter_than watch_line

vekrona-dev session
baseline="$(vekrona-dev see luma)"
log "baseline luminance: $baseline"

vekrona-dev sh setsid -f bash -c "exec stdbuf -oL swaymsg -r -m -t subscribe '[\"binding\"]' > $GUEST_BINDINGS"
vekrona-dev run sudo setsid -f bash -c "exec stdbuf -oL libinput debug-events --show-keycodes > $GUEST_KEYS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_BINDINGS" '"success": ?true'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_KEYS" 'KEYBOARD_KEY'

vekrona-dev hold super-shift-4 "$HOLD_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_KEYS" 'KEY_4 \(5\) released'

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- brighter_than "$(awk -v b="$baseline" -v s="$VISIBLE_STEP" 'BEGIN { print b + s }')"
dimmed="$(vekrona-dev see luma)"
log "luminance with the selection overlay: $dimmed"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_brighter_than "$(awk -v b="$baseline" -v s="$VISIBLE_STEP" 'BEGIN { print b + s / 2 }')" \
  || die "one Esc must restore the screen: the selection overlay is still dimming it"
if vekrona-dev run pgrep -x slurp >/dev/null; then
  die "one Esc must end the selection, but slurp is still running"
fi

status=0
runs="$(vekrona-dev run grep -c 'vekrona-screenshot area' "$GUEST_BINDINGS")" || status=$?
((status <= 1)) || die "could not read the recorded sway bindings (grep exit $status)"
[[ "$runs" == 1 ]] || die "holding Cmd+Shift+4 must take one screenshot, but the binding ran $runs times"
log "ok: holding Cmd+Shift+4 opens one selection, and one Esc closes it"
