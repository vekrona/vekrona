#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
CRASHES=8

locker_pid() { vekrona-dev sh systemctl --user show vekrona-lock -p MainPID --value; }

# SIGKILL the locker, then wait for systemd to start the next one (a new MainPID).
crash_locker() {
  local before after
  before="$(locker_pid)"
  vekrona-dev sh systemctl --user kill --signal=KILL --kill-whom=main vekrona-lock
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bash -c "after=\$(vekrona-dev sh systemctl --user show vekrona-lock -p MainPID --value); [[ \$after != 0 && \$after != $before ]]"
}

lock_screen() {
  vekrona-dev sh vekrona-lock start
  lock_active || die "vekrona-lock returned before the locker confirmed the lock, so suspend would not wait for the screen to be locked"
}

unlock_with_password() {
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bash -c '[[ "$(vekrona-dev sh loginctl show-session auto -p LockedHint --value)" == yes ]]'
  vekrona-dev type --enter "$GUEST_PASSWORD"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
}

vekrona-dev session
lock_screen

for ((i = 0; i < CRASHES; i++)); do
  crash_locker || die "crash $((i + 1)) of $CRASHES: systemd did not restart the locker, so the screen is left locked with nobody to unlock it"
done
log "ok: a locker that crashes $CRASHES times in a row is restarted every time"

status=0
vekrona-dev sh timeout "$STEP_TIMEOUT_SEC" qs -c vekrona-lock >/dev/null 2>&1 || status=$?
# 124 is timeout's, a locker that sat idle; 255 is ssh's, a guest that could not be asked.
case "$status" in
  0) die "a second locker started while the session is locked exited 0, but must fail so that systemd restarts it" ;;
  124) die "a second locker started while the session is locked sat idle instead of exiting for a restart" ;;
  255) die "could not ask the guest to start a second locker" ;;
esac
log "ok: a locker the compositor refuses exits non-zero (status $status) instead of idling unlocked"

unlock_with_password
log "ok: after the crashes the password still unlocks"
