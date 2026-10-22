#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

vekrona-dev session
# Away from the launcher: the pointer would sit over the armed row's text and break OCR.
vekrona-dev move 100 700
clear_notifications

# Escape steps back one level per press (power mode, then the launcher), so press until it is gone.
escape_then_hidden() { vekrona-dev key esc; panel_hidden; }
export -f escape_then_hidden
close_launcher_by_escape() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- escape_then_hidden; }
cleanup() {
  run_cleanups close_launcher_by_escape updates_restore updates_forget clear_notifications
}
trap cleanup EXIT
updates_stash

open_power_view() {
  vekrona-dev key super-spc
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
  vekrona-dev type '/power '
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Log out'
}

# The launcher is open when the check result changes: the Power view must follow the file, not read it only when it opens.
updates_write '{"checked":"2026-10-09T09:00:03+02:00","pending":false,"night_armed":false,"groups":[]}'
open_power_view
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Update and shut down'
log "ok: nothing pending, no update items"

updates_write "$(updates_pending_json 2.1.3)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Update and shut down'
text_shown 'Update and restart' || die "the Power view must list Update and restart while updates are pending"
log "ok: updates that arrive while the Power view is open add Update and restart and Update and shut down"

vekrona-dev type 'update and shut'
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Press Enter again to update and shut down'
log "ok: the first Enter on Update and shut down only arms it"
