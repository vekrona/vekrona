#!/usr/bin/env bash
# A shell that stops while the app switcher is open must not leave Sway in the appswitch mode: that mode has no binding that
# leaves it, so only the unit's ExecStopPost can put Sway back in the default mode before the shell comes up again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30

cleanup() {
  run_cleanups 'key_event up meta_l' restart_shell 'kill_guest -x foot'
}
trap cleanup EXIT

vekrona-dev session
kill_guest -x foot
vekrona-dev move 600 500
vekrona-dev session

# The switcher opens only when it has two apps to switch between.
for app in stop-a stop-b; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app" || die "$app never took focus; focused app: $(focused_app_id)"
done

key_event down meta_l
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- super_recorded_down || die "xremap must record Super as down while it is held"
key_tap tab
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is appswitch || die "the open switcher must put sway in the appswitch mode, but it is in '$(binding_mode)'"

# A stopped shell stays down, so no restart's Component.onCompleted can be what resets the mode.
vekrona-dev sh systemctl --user stop vekrona-shell.service
mode_is default || die "a shell stopped while the switcher is open must leave sway in the default mode, but it is in '$(binding_mode)'"
log "ok: stopping the shell with the switcher open puts sway back in the default mode"
