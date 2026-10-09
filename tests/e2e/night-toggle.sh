#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
UNIT=vekrona-night.service

night_state() { vekrona-dev sh systemctl --user is-active "$UNIT" || true; }
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

! vekrona-dev sh vekrona-night bogus 2>/dev/null || die "an unknown vekrona-night command must fail"
log "ok: an unknown command is refused"
