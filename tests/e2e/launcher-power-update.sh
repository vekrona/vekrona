#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

shown() { vekrona-dev see text "$1"; }
gone() { ! shown "$1"; }
export -f shown gone
export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
updates_stash

# Escape steps back one level per press (power mode, then the launcher), so press until it is gone.
escape_then_hidden() { vekrona-dev key esc; panel_hidden; }
export -f escape_then_hidden
close_launcher() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- escape_then_hidden; }
cleanup() {
  close_launcher
  updates_restore
  updates_forget
  clear_notifications
}
trap cleanup EXIT

open_power_view() {
  vekrona-dev key super-spc
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
  vekrona-dev type '/power '
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Log out'
}

updates_write "$(updates_pending_json 2.1.3)"
open_power_view
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Update and shut down'
shown 'Update and restart' || die "the Power view must list Update and restart while updates are pending"
log "ok: pending updates add Update and restart and Update and shut down to the Power view"

vekrona-dev type 'update and shut'
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Press Enter again to update and shut down'
log "ok: the first Enter on Update and shut down only arms it"
close_launcher

updates_write '{"checked":"2026-10-09T09:00:03+02:00","pending":false,"night_armed":false,"groups":[]}'
open_power_view
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'Update and shut down'
log "ok: nothing pending, no update items"
