#!/usr/bin/env bash
# An open app switcher closes and commits when the keyboard that holds Super is unplugged: the Super state it waits for ends.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30

cleanup() {
  run_cleanups rebind_keyboards 'key_event up meta_l' 'kill_guest -x foot'
}
trap cleanup EXIT

vekrona-dev session
kill_guest -x foot
vekrona-dev move 600 500
vekrona-dev session

# The focus ends on unplug-b, so the switcher's first Tab selects unplug-a.
for app in unplug-a unplug-b; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app" || die "$app never took focus; focused app: $(focused_app_id)"
done

key_event down meta_l
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- super_recorded_down || die "xremap must record Super as down while it is held"
key_tap tab
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is appswitch || die "the open switcher must put sway in the appswitch mode, but it is in '$(binding_mode)'"

unbind_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is default || die "the switcher must close once the keyboard that held Super is unplugged, but sway is in '$(binding_mode)'"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is unplug-a || die "an unplugged keyboard holds nothing, so the switcher must commit its choice unplug-a, but the focus is on $(focused_app_id)"
log "ok: unplugging the keyboard that holds Super closes the switcher on its choice"
