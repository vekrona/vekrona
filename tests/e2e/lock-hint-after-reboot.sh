#!/usr/bin/env bash
# The lock screen marks sway's own login session locked, and unlocked again, also when a text or ssh login started before
# sway, as after a reboot: that login is then the user's Display session and logind's "auto" session for the lock's
# service. The scenario reboots, so vekrona-dev's ssh login comes first and stays the Display session.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

BOOT_TIMEOUT_SEC=240
STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona

display_session() { vekrona-dev run bash -c 'loginctl show-user "$(id -u)" -p Display --value'; }
locked_hint_of() { vekrona-dev run loginctl show-session "$1" -p LockedHint --value; }

previous_boot="$(boot_id)"
vekrona-dev reboot
booted_again "$previous_boot" || die "the guest did not boot again"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- greeter_up
vekrona-dev session

sway_session="$(sway_session_id)"
display="$(display_session)"
[[ -n "$sway_session" && -n "$display" && "$display" != "$sway_session" ]] \
  || die "the user's Display session ($display) must be another login than sway's ($sway_session), or the scenario proves nothing"
log "sway runs in session $sway_session, the user's Display session is $display"

vekrona-dev sh vekrona-lock start
lock_active || die "vekrona-lock returned before the locker confirmed the lock"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- session_locked \
  || die "the screen is locked, but sway's session $sway_session says LockedHint=$(session_locked_hint)"
[[ "$(locked_hint_of "$display")" == no ]] || die "the lock marked the Display session $display locked, which shows no lock screen"
log "ok: the lock screen marks sway's session $sway_session locked and leaves the Display session $display alone"

vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
# The locker quits only after it cleared the hint, so the hint is clear once the unit is gone.
[[ "$(session_locked_hint)" == no ]] || die "the screen is unlocked, but sway's session $sway_session still says LockedHint=$(session_locked_hint)"
log "ok: unlocking clears sway's session's locked hint"
