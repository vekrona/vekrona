#!/usr/bin/env bash
# Cmd+Tab shows the app switcher at once, releasing Cmd focuses the picked app at once, and a quick tap goes back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

HOLD_MS=1500
TAP_MS=150
OVERLAY_MAX_MS=200
FOCUS_MAX_MS=75
STEP_TIMEOUT_SEC=30
GUEST_PROBE=/mnt/vekrona/tests/e2e/app-switch-probe.py
export GUEST_PROBE_OUT=/tmp/vekrona-e2e-app-switch.jsonl
# A bright background makes the dimming scrim stand out in the probe's screen sample.
APP_BACKGROUND=ff00ff

focused_app() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '[recurse(.nodes[]?, .floating_nodes[]?) | select(.focused)][0].app_id'"; }
focused_is() { [[ "$(focused_app)" == "$1" ]]; }
probe_says() { vekrona-dev run grep -qE "$1" "$GUEST_PROBE_OUT"; }
export -f focused_app focused_is probe_says

kill_guest() {
  local status=0
  vekrona-dev run pkill "$@" || status=$?
  ((status <= 1)) || warn "could not stop in the guest: pkill $* (exit $status)"
}
cleanup() {
  kill_guest -f app-switch-probe.py
  kill_guest -x foot
}
trap cleanup EXIT

vekrona-dev session
kill_guest -x foot
for app in switch-first switch-second; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app" -o "colors.background=$APP_BACKGROUND"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app"
done

vekrona-dev spawn "$GUEST_PROBE_OUT" -- python3 -B "$GUEST_PROBE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- probe_says '"ready"'

vekrona-dev hold super-tab "$HOLD_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- probe_says 'overlay_ms|error'
result="$(vekrona-dev run grep -E "overlay_ms|error" "$GUEST_PROBE_OUT")"
log "probe: $result"

overlay_ms="$(jq -er '.overlay_ms' <<<"$result")" || die "the probe reported no timings: $result"
focus_ms="$(jq -er '.focus_ms' <<<"$result")"
((overlay_ms < OVERLAY_MAX_MS)) || die "the switcher took ${overlay_ms} ms to appear after Cmd+Tab, but must take under $OVERLAY_MAX_MS ms"
((focus_ms < FOCUS_MAX_MS)) || die "focus took ${focus_ms} ms to change after releasing Cmd, but must take under $FOCUS_MAX_MS ms"
log "ok: the switcher appeared in $overlay_ms ms and focus moved in $focus_ms ms"

vekrona-dev sh swaymsg "[app_id=switch-second] focus" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is switch-second
vekrona-dev hold super-tab "$TAP_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is switch-first
log "ok: a quick Cmd+Tab returns to the previous app"
