#!/usr/bin/env bash
# A pam_u2f attempt can hang after its touch cue and then ignores the touch until the key is replugged
# (host journal, 2026-10-16: 94 s with no result). The wedged attempt is simulated by a PAM stack whose only
# module prints the cue and then never returns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# pam_u2f gives up after about 29 s by itself; the lock screen's watchdog fires after 40 s.
WATCHDOG_TIMEOUT_SEC=90
GUEST_PASSWORD=vekrona
KEY_ID="${VEKRONA_E2E_KEY_ID:-1050:0407}"
KEY_ATTACHED=0
PAM_FILE=/etc/pam.d/vekrona-lock-u2f
PAM_ORIGINAL=/etc/pam.d/vekrona-lock-u2f.e2e-original
WEDGED_KEY=/usr/local/bin/vekrona-e2e-wedged-key

password_shown() { lock_text_shown 'password'; }
key_prompt_shown() { lock_text_shown 'touch your security key'; }
key_not_responding_shown() { lock_text_shown 'not responding'; }
# The restored stack is the real pam_u2f, which asks for the PIN first.
pin_expected() { lock_text_shown 'enter security key pin'; }
# The report of this run only: the guest keeps earlier runs' reports in the same boot's journal.
stall_report() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-lock --since "@$LOCK_STARTED_AT"; }
stall_report_complete() { local report; report="$(stall_report)" || return 1; grep -qx 'end of stall report' <<<"$report"; }
export -f stall_report stall_report_complete password_shown key_prompt_shown key_not_responding_shown pin_expected

wedge_pam_stack() {
  vekrona-dev run sudo bash -c "
set -euo pipefail
printf '#!/bin/sh\necho \"Please touch the FIDO authenticator.\"\nexec sleep 3601\n' >'$WEDGED_KEY'
chmod 755 '$WEDGED_KEY'
[[ -e '$PAM_ORIGINAL' ]] || cp -a '$PAM_FILE' '$PAM_ORIGINAL'
printf 'auth required pam_exec.so stdout $WEDGED_KEY\naccount required pam_permit.so\npassword required pam_deny.so\nsession required pam_permit.so\n' >'$PAM_FILE'
"
}

# The killed PAM child leaves its hung module command behind.
restore_pam_stack() {
  vekrona-dev run sudo bash -c "
if [[ -e '$PAM_ORIGINAL' ]]; then mv '$PAM_ORIGINAL' '$PAM_FILE'; fi
rm -f '$WEDGED_KEY'
pkill -f '^sleep 3601\$' || [[ \$? -eq 1 ]]
"
}

# A lock left running would keep the lock screen code of this run for the next one.
unlock_leftover_lock() {
  if lock_active; then
    vekrona-dev key tab # a no-op unless the key asks for its PIN, which a password must not answer
    vekrona-dev type --enter "$GUEST_PASSWORD"
    vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
  fi
}
detach_key() {
  if ((KEY_ATTACHED)); then vekrona-dev usb detach "$KEY_ID"; fi
}
# The PAM stack goes first: the wedged one, left behind, refuses the lock screen of every later scenario.
trap 'run_cleanups restore_pam_stack unlock_leftover_lock detach_key' EXIT

lock_screen() {
  vekrona-dev sh vekrona-lock start
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_shown
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_watcher_running
}

command -v magick >/dev/null || die "the e2e scenario needs ImageMagick (magick) to crop screenshots"
vekrona-dev session
# The pointer rests on the status line after the login and garbles its OCR.
vekrona-dev move 10 10

if ! vekrona-dev usb attach "$KEY_ID"; then
  skip "cannot hand $KEY_ID to the guest (stop pcscd on the host first); the wedged key scenario did not run"
fi
KEY_ATTACHED=1

wedge_pam_stack
LOCK_STARTED_AT="$(vekrona-dev sh date +%s)"
export LOCK_STARTED_AT
lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_shown
log "ok: a key whose attempt shows the cue gets the touch prompt"
vekrona-dev until --timeout "$WATCHDOG_TIMEOUT_SEC" -- key_not_responding_shown
log "ok: an attempt that hangs after the cue ends in 'not responding; replug it'"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stall_report_complete
report="$(stall_report)"
grep -qx 'security key stall report: no result after the touch cue' <<<"$report" \
  || die "the journal has no stall report header after the watchdog fired; vekrona-lock logged: $report"
grep -q '^thread [0-9]*: State:' <<<"$report" \
  || die "the stall report names no State of the hung PAM child's threads: $report"
log "ok: the watchdog logs a stall report with the hung PAM child's thread states before it aborts"

restore_pam_stack
vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
vekrona-dev usb attach "$KEY_ID"
KEY_ATTACHED=1
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pin_expected
log "ok: replugging the key starts a new attempt and asks for its PIN again"

# Tab makes the field a password field; typed as is, the password would be a wrong PIN for the real key.
vekrona-dev key tab
vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
log "ok: the password unlocks it"
