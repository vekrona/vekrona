#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
UNIT=vekrona-night.service

# systemctl is-active prints the state and exits 3 for every state but active: only a guest that could not be asked is an error.
night_state() {
  local state status=0
  state="$(vekrona-dev sh systemctl --user is-active "$UNIT")" || status=$?
  ((status == 0 || status == 3)) || abort "cannot ask the guest for the state of $UNIT (exit $status)"
  printf '%s\n' "$state"
}
night_active() { [[ "$(night_state)" == active ]]; }
night_inactive() { [[ "$(night_state)" == inactive ]]; }
export -f night_state night_active night_inactive
export UNIT

vekrona-dev session
trap 'vekrona-dev sh systemctl --user stop "$UNIT"' EXIT

vekrona-dev sh vekrona-night toggle
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- night_active
log "ok: the first toggle turns the night light on"

vekrona-dev sh vekrona-night toggle
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- night_inactive
log "ok: the second toggle turns it off"

status=0
vekrona-dev sh vekrona-night bogus 2>/dev/null || status=$?
((status == 2)) || die "an unknown vekrona-night command must be refused with exit 2, got $status"
log "ok: an unknown command is refused"
