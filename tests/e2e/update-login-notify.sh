#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

shown() { vekrona-dev see text "$1"; }
sway_gone() { ! vekrona-dev run pgrep -x sway >/dev/null; }
export -f shown sway_gone

cleanup() {
  updates_restore
  updates_forget
  clear_notifications
}

# The root check can finish before anybody has logged in, so the file is already there when the session starts.
vekrona-dev session
updates_stash
trap cleanup EXIT
vekrona-dev sh swaymsg exit
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sway_gone
log "ok: logged out"

updates_write "$(updates_pending_json 2.1.3)"
updates_forget

vekrona-dev session
vekrona-dev move 100 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'updates are ready'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Not tonight'
log "ok: updates found before the login are announced when the session starts"
