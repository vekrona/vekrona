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
# A bright background makes the opaque switcher panel stand out in the probe's screen sample.
APP_BACKGROUND=ff00ff

probe_says() { vekrona-dev run grep -qE "$1" "$GUEST_PROBE_OUT"; }
export -f probe_says

# The probe timestamps the raw key events, which the session user may not read (xremap's user alone is in the input group):
# the scenario grants itself read access to the event devices for its run.
grant_input_read() { vekrona-dev run sudo bash -c 'setfacl -m "u:vekrona:r" /dev/input/event*'; }
revoke_input_read() { vekrona-dev run sudo bash -c 'setfacl -b /dev/input/event*'; }

cleanup() {
  revoke_input_read
  kill_guest -f app-switch-probe.py
  kill_guest -x foot
}
trap cleanup EXIT

explain_missing_focus() {
  warn "$1 never took focus; focused app: $(focused_app_id)"
  warn "session locked: $(vekrona-dev sh busctl get-property org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session LockedHint)"
  warn "windows: $(vekrona-dev sh bash -c "swaymsg -t get_tree | jq -c '[recurse(.nodes[]?, .floating_nodes[]?) | select(.pid != null) | {app_id, focused}]'")"
  warn "$1 log: $(vekrona-dev run cat "/tmp/vekrona-e2e-$1.log")"
  exit 1
}

vekrona-dev session
kill_guest -x foot
# Moving the pointer re-arms swayidle's lock timer, and the session call after it unlocks a lock that fired before the move.
vekrona-dev move 600 500
vekrona-dev session
for app in switch-first switch-second; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app" -o "colors.background=$APP_BACKGROUND"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app" || explain_missing_focus "$app"
done

grant_input_read
vekrona-dev spawn "$GUEST_PROBE_OUT" -- python3 -B "$GUEST_PROBE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- probe_says '"ready"'

vekrona-dev hold super-tab "$HOLD_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- probe_says 'overlay_ms|error'
result="$(vekrona-dev run grep -E "overlay_ms|error" "$GUEST_PROBE_OUT")"
log "probe: $result"

overlay_ms="$(jq -er '.overlay_ms' <<<"$result")" || die "the probe reported no timings: $result"
focus_ms="$(jq -er '.focus_ms' <<<"$result")"
poll_ms="$(jq -er '.poll_ms' <<<"$result")"
ipc_ms="$(jq -er '.ipc_ms' <<<"$result")"
# The limits are for an idle machine. The probe sees the overlay only at its next screen sample, and a sway round trip costs more
# when the host is busy, so each limit grows by what one sample or one round trip cost the probe just before the keys went down.
overlay_limit_ms=$((OVERLAY_MAX_MS + poll_ms))
focus_limit_ms=$((FOCUS_MAX_MS + ipc_ms))
((overlay_ms < overlay_limit_ms)) || die "the switcher took ${overlay_ms} ms to appear after Cmd+Tab, but must take under $overlay_limit_ms ms ($OVERLAY_MAX_MS ms and one ${poll_ms} ms screen sample)"
((focus_ms < focus_limit_ms)) || die "focus took ${focus_ms} ms to change after releasing Cmd, but must take under $focus_limit_ms ms ($FOCUS_MAX_MS ms and one ${ipc_ms} ms sway round trip)"
log "ok: the switcher appeared in $overlay_ms ms and focus moved in $focus_ms ms (limits $overlay_limit_ms and $focus_limit_ms ms)"

vekrona-dev sh swaymsg "[app_id=switch-second] focus" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is switch-second
vekrona-dev hold super-tab "$TAP_MS"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is switch-first
log "ok: a quick Cmd+Tab returns to the previous app"
