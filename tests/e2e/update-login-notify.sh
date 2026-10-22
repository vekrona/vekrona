#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

cleanup() {
  run_cleanups updates_restore updates_forget close_notification_centre clear_notifications
}

# The root check can finish before anybody has logged in, so the file is already there when the session starts.
vekrona-dev session
trap cleanup EXIT
updates_stash
logout_sway
log "ok: logged out"

updates_write "$(updates_pending_json 2.1.3)"
updates_forget

vekrona-dev session
vekrona-dev move 100 500
# The toast may be gone by the time the session is unlocked and looked at; the centre still holds it.
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Updates available'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Not tonight'
log "ok: updates found before the login are announced when the session starts"
