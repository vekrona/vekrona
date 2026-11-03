#!/usr/bin/env bash
# With Super held, Right and Left move the app switcher's selection like Tab and Shift+Tab, instead of moving the focus under it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30
GUEST_BINDINGS=/tmp/vekrona-e2e-app-switch-arrows.jsonl
export GUEST_BINDINGS
# Sway binding events the scenario has caused so far. Each is one `qs ... ipc call` that sway starts and does not wait for.
bindings_expected=0

# One key event (down|up) for a QEMU key code, as JSON for `input-send-event`.
key_json() {
  local down=false
  [[ "$1" == down ]] && down=true
  printf '{"type":"key","data":{"down":%s,"key":{"type":"qcode","data":"%s"}}}' "$down" "$2"
}
# QMP's `send-key` with a hold time queues every later key behind the release, so Super is held by sending its press and its
# release as events of their own.
key_event() { vekrona-dev qmp input-send-event "{\"events\":[$(key_json "$1" "$2")]}" >/dev/null; }
# A tap sends press and release in one call: two calls could be further apart than sway's repeat_delay, and the held key would repeat.
key_tap() { vekrona-dev qmp input-send-event "{\"events\":[$(key_json down "$1"),$(key_json up "$1")]}" >/dev/null; }

binding_mode() { vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_binding_state | jq -r .name'; }
mode_is() { [[ "$(binding_mode)" == "$1" ]]; }
binding_runs() {
  local runs status=0
  runs="$(vekrona-dev run grep -c '"change":"run"' "$GUEST_BINDINGS")" || status=$?
  ((status <= 1)) || abort "cannot read the recorded sway bindings (grep exit $status)"
  printf '%s\n' "$runs"
}
bindings_reached() { (($(binding_runs) >= $1)); }
ipc_calls_running() { vekrona-dev run pgrep -f '[q]s -c vekrona-app-switch ipc call'; }
ipc_calls_done() { absent ipc_calls_running; }
export -f binding_mode mode_is binding_runs bindings_reached ipc_calls_running ipc_calls_done

# Presses and releases KEY, then waits until sway has run its binding and the overlay has handled the call. The calls are
# separate processes, so without the wait two quick presses could reach the overlay in either order.
tap() {
  key_tap "$1"
  bindings_expected=$((bindings_expected + 1))
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bindings_reached "$bindings_expected" || die "sway never ran a binding for $1"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- ipc_calls_done || die "the overlay never finished the call for $1"
}

# open_switcher: holds Super and taps Tab, and waits until the switcher has put sway in its mode.
open_switcher() {
  key_event down meta_l
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- super_recorded_down || die "xremap must record Super as down while it is held"
  tap tab
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is appswitch || die "the open switcher must put sway in the appswitch mode, but it is in '$(binding_mode)'"
}

# switch_to APP KEY...: opens the switcher, taps each KEY, releases Super and expects APP in focus.
switch_to() {
  local expected="$1" key
  shift
  open_switcher
  for key in "$@"; do
    tap "$key"
  done
  key_event up meta_l
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$expected" || die "after Tab $* the focus must be on $expected, but it is on $(focused_app_id)"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is default || die "a closed switcher must put sway back in the default mode"
}

cleanup() {
  run_cleanups 'key_event up meta_l' 'kill_guest -f "sway-events.py binding"' 'kill_guest -x foot'
}
trap cleanup EXIT

vekrona-dev session
kill_guest -x foot
# Moving the pointer re-arms swayidle's lock timer, and the session call after it unlocks a lock that fired before the move.
vekrona-dev move 600 500
vekrona-dev session

vekrona-dev events "$GUEST_BINDINGS" binding
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev run grep -q '"subscribed"' "$GUEST_BINDINGS"

# The apps are focused in this order, so the switcher lists them as arrows-c, arrows-b, arrows-a.
for app in arrows-a arrows-b arrows-c; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app" || die "$app never took focus; focused app: $(focused_app_id)"
done

# Tab selects arrows-b, Right moves on to arrows-a. Without the appswitch mode, Sway would run `focus right` and the overlay would never see Right.
switch_to arrows-a right
log "ok: Right moves the selection to the next app"

# The order is now arrows-a, arrows-c, arrows-b. Tab selects arrows-c, Right arrows-b, Left arrows-c, Left arrows-a, and Left once
# more wraps around to arrows-b.
switch_to arrows-b right left left left
log "ok: Left moves the selection back, and wraps around at the first app"

# The focus is on arrows-b and the first Tab selects arrows-a; Escape closes the switcher without committing that choice.
open_switcher
key_tap esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is default || die "Escape must close the switcher and put sway back in the default mode, but it is in '$(binding_mode)'"
key_event up meta_l
focused_is arrows-b || die "Escape must leave the focus alone, but it moved to $(focused_app_id)"
log "ok: Escape closes the switcher without moving the focus"
