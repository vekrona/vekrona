#!/usr/bin/env bash
# The password field is dead until PAM asks for a response, and a security key check (pam_u2f) can run for
# about 30 s before it does (host, 2026-10-17: a polkit dialog sat 19 s with a silent, empty field).
# A slow module in front of the real stack models that check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
GUEST_CANCELLED_LOG=/tmp/vekrona-e2e-pkexec-cancelled.log
GUEST_GRANTED_LOG=/tmp/vekrona-e2e-pkexec-granted.log
GUEST_WAITED_LOG=/tmp/vekrona-e2e-pkexec-waited.log
GUEST_CUED_LOG=/tmp/vekrona-e2e-pkexec-cued.log
POLKIT_PAM_FILE=/etc/pam.d/polkit-1
POLKIT_PAM_ORIGINAL=/etc/pam.d/polkit-1.e2e-original
SLOW_CHECK_SEC=20
SLOW_CHECK=/usr/local/bin/vekrona-e2e-slow-check

dialog_open() { text_shown 'Authentication required'; }
dialog_closed() { text_absent 'Authentication required'; }
identity_shown() { text_shown 'Account: vekrona'; }
waiting_shown() { text_shown 'Waiting for the system'; }
cue_shown() { text_shown 'Please touch the device'; }
password_prompt_shown() { text_shown 'Password:'; }
failure_shown() { text_shown 'fail|sorry|again|incorrect'; }
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
export -f dialog_open dialog_closed identity_shown waiting_shown cue_shown password_prompt_shown failure_shown log_has

# The slow check runs before the system stack, as pam_u2f does; its own result never decides. pam_exec shows the
# script's output to the user only with the stdout option.
slow_check_stack() {
  vekrona-dev run sudo bash -c '
set -euo pipefail
# An /etc stack that is not this one is set aside once (Fedora ships polkit-1 under /usr/lib/pam.d, where a file of /etc/pam.d takes over).
if [[ -e "$4" && ! -e "$5" ]] && ! grep -q pam_exec.so "$4"; then cp -a "$4" "$5"; fi
printf "#!/bin/sh\necho Please touch the device.\nexec sleep %s\n" "$1" >"$2"
chmod 755 "$2"
printf "%s\n" "auth optional pam_exec.so $3 $2" "auth include system-auth" "account include system-auth" "password include system-auth" "session include system-auth" >"$4"
' _ "$SLOW_CHECK_SEC" "$SLOW_CHECK" "$1" "$POLKIT_PAM_FILE" "$POLKIT_PAM_ORIGINAL"
}
# An /etc stack that was set aside the first time the slow one replaced it comes back (an earlier run that was killed left it there);
# without one the stack under /usr/lib/pam.d is the one in force again.
restore_stack() {
  vekrona-dev run sudo bash -c 'if [[ -e "$2" ]]; then mv "$2" "$1"; else rm -f "$1"; fi; rm -f "$3"' _ "$POLKIT_PAM_FILE" "$POLKIT_PAM_ORIGINAL" "$SLOW_CHECK"
}
trap restore_stack EXIT

vekrona-dev session
clear_notifications
vekrona-dev run rm -f "$GUEST_CANCELLED_LOG" "$GUEST_GRANTED_LOG" "$GUEST_WAITED_LOG" "$GUEST_CUED_LOG"

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

slow_check_stack quiet
run_pkexec "$GUEST_WAITED_LOG"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- waiting_shown
log "ok: while PAM has not asked anything yet, the dialog says it is waiting"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_prompt_shown
log "ok: the dialog shows PAM's prompt once it arrives"
vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_closed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_WAITED_LOG" granted
log "ok: the password typed after a slow check authorises the command"

slow_check_stack stdout
run_pkexec "$GUEST_CUED_LOG"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- cue_shown
log "ok: a message from PAM, such as a key's touch cue, is shown while the dialog waits"
vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dialog_closed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_CUED_LOG" refused
log "ok: Escape dismisses a dialog that is still waiting"
