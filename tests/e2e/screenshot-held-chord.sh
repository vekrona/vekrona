#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

HOLD_MS=1500
VISIBLE_STEP=10
STEP_TIMEOUT_SEC=30
GUEST_BINDINGS=/tmp/vekrona-e2e-bindings.jsonl
GUEST_KEYS=/tmp/vekrona-e2e-keys.log

stop_watchers() {
  run_cleanups 'kill_guest_root -f "libinput-debug-events --show-keycodes"' 'kill_guest -f "sway-events.py binding"'
}
trap stop_watchers EXIT

# The mean luminance of the screen. awk compares an empty value with any ceiling as "dark enough", so a reading that is not a
# number ends the scenario instead of passing a brightness check.
current_luma() {
  local luma
  luma="$(vekrona-dev see luma)" || abort "cannot read the screen's luminance"
  [[ "$luma" =~ ^[0-9]+(\.[0-9]+)?$ ]] || abort "the screen's luminance is not a number: '$luma'"
  printf '%s\n' "$luma"
}
brighter_than() { awk -v now="$(current_luma)" -v floor="$1" 'BEGIN { exit !(now > floor) }'; }
no_brighter_than() { awk -v now="$(current_luma)" -v ceiling="$1" 'BEGIN { exit !(now <= ceiling) }'; }
watch_line() { vekrona-dev run grep -qE "$2" "$1"; }
export -f current_luma brighter_than no_brighter_than watch_line

vekrona-dev session
baseline="$(current_luma)"
log "baseline luminance: $baseline"

vekrona-dev events "$GUEST_BINDINGS" binding
vekrona-dev spawn --root "$GUEST_KEYS" -- libinput debug-events --show-keycodes
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_BINDINGS" '"subscribed"'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_KEYS" 'DEVICE_ADDED'

vekrona-dev hold super-shift-4 "$HOLD_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watch_line "$GUEST_KEYS" 'KEY_4 \(5\) released'

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- brighter_than "$(awk -v b="$baseline" -v s="$VISIBLE_STEP" 'BEGIN { print b + s }')"
dimmed="$(current_luma)"
log "luminance with the selection overlay: $dimmed"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_brighter_than "$(awk -v b="$baseline" -v s="$VISIBLE_STEP" 'BEGIN { print b + s / 2 }')" \
  || die "one Esc must restore the screen: the selection overlay is still dimming it"
absent vekrona-dev run pgrep -x slurp >/dev/null || die "one Esc must end the selection, but slurp is still running"

status=0
runs="$(vekrona-dev run grep -c 'vekrona-screenshot area' "$GUEST_BINDINGS")" || status=$?
((status <= 1)) || die "could not read the recorded sway bindings (grep exit $status)"
[[ "$runs" == 1 ]] || die "holding Cmd+Shift+4 must take one screenshot, but the binding ran $runs times"
log "ok: holding Cmd+Shift+4 opens one selection, and one Esc closes it"
