#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

idle_active() { [[ "$(vekrona-dev sh systemctl --user is-active vekrona-idle.service)" == active ]]; }
locked() { [[ "$(vekrona-dev run loginctl show-session "$SESSION_ID" -p LockedHint --value)" == yes ]]; }
unlocked() { ! locked; }
export -f idle_active locked unlocked

vekrona-dev session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- idle_active
log "ok: swayidle runs as vekrona-idle.service"

SESSION_ID="$(vekrona-dev run loginctl show-user vekrona -p Display --value)"
[[ -n "$SESSION_ID" ]] || die "the sway session id is unknown"
export SESSION_ID

vekrona-dev run loginctl lock-session "$SESSION_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- locked
log "ok: a logind lock request reaches swayidle, which runs vekrona-lock"

vekrona-dev session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unlocked
