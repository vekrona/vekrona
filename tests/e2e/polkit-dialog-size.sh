#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
GUEST_CANCELLED_LOG=/tmp/vekrona-e2e-pkexec-cancelled.log
GUEST_GRANTED_LOG=/tmp/vekrona-e2e-pkexec-granted.log

dialog_open() { vekrona-dev see text 'Authentication required'; }
dialog_closed() { ! dialog_open; }
identity_shown() { vekrona-dev see text 'Password for vekrona'; }
failure_shown() { vekrona-dev see text 'fail|sorry|again|incorrect'; }
log_has() { vekrona-dev run grep -q "$2" "$1"; }
# The agent serves the user's Display session, which is the sway session or, when an ssh login came first, that ssh session; pkexec must run in the same one.
run_pkexec() {
  local display session_type
  display="$(vekrona-dev run loginctl show-user vekrona -p Display --value)"
  session_type="$(vekrona-dev run loginctl show-session "$display" -p Type --value)"
  if [[ "$session_type" == wayland ]]; then
    vekrona-dev sh swaymsg exec "'bash -c \"pkexec true && echo granted > $1 || echo refused > $1\"'" >/dev/null
  else
    vekrona-dev spawn "$1.out" -- bash -c "pkexec true && echo granted > $1 || echo refused > $1"
  fi
}
export -f dialog_open dialog_closed identity_shown failure_shown log_has

vekrona-dev session
clear_notifications
vekrona-dev run rm -f "$GUEST_CANCELLED_LOG" "$GUEST_GRANTED_LOG"

run_pkexec "$GUEST_CANCELLED_LOG"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_open
log "ok: a privileged command opens the Authentication required dialog"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- identity_shown
log "ok: the dialog names the account whose password it asks for"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_closed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_CANCELLED_LOG" refused
log "ok: Escape dismisses the dialog and the command is refused"

run_pkexec "$GUEST_GRANTED_LOG"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_open
vekrona-dev type --enter wrong-password
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- failure_shown
dialog_open || die "a wrong password must keep the dialog open for another try"
log "ok: a wrong password says so and keeps the dialog open"

vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_closed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_GRANTED_LOG" granted
log "ok: the right password after a wrong one authorises the command"
