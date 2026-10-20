#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
KEY_ID="${VEKRONA_E2E_KEY_ID:-1050:0407}"
KEY_ATTACHED=0

password_shown() { lock_text_shown 'password'; }
# pam_u2f asks for the PIN first (pinverification=1), and the lock screen tells how to answer it; the touch comes after.
key_prompt_shown() { lock_text_shown 'enter security key pin'; }
key_prompt_hidden() { lock_text_absent 'enter security key pin'; }
locked_hint() { vekrona-dev sh loginctl show-session auto -p LockedHint --value; }
export -f password_shown key_prompt_shown key_prompt_hidden

lock_screen() {
  vekrona-dev sh vekrona-lock start
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_shown
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_watcher_running
}

# With a key plugged in the field takes its PIN by default; Tab makes it a password field.
unlock_with_password() {
  if key_prompt_shown; then vekrona-dev key tab; fi
  vekrona-dev type --enter "$GUEST_PASSWORD"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
  [[ "$(locked_hint)" == no ]] || die "after the password unlock, logind LockedHint must be no, but it is $(locked_hint)"
}

detach_key() {
  if ((KEY_ATTACHED)); then
    vekrona-dev usb detach "$KEY_ID"
    KEY_ATTACHED=0
  fi
}
trap detach_key EXIT

command -v magick >/dev/null || die "the e2e scenario needs ImageMagick (magick) to crop screenshots"
vekrona-dev session
# The pointer rests on the status line after the login and garbles its OCR.
vekrona-dev move 10 10

lock_screen
key_prompt_hidden || die "with no security key plugged in, the lock screen must not ask for its PIN"
log "ok: without a key the lock screen asks for a password and not for a key PIN"
unlock_with_password
log "ok: the password unlocks it and LockedHint is no"

if ! vekrona-dev usb attach "$KEY_ID"; then
  skip "cannot hand $KEY_ID to the guest (stop pcscd on the host first); the key scenarios did not run"
fi
KEY_ATTACHED=1

lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_shown
log "ok: with a key plugged in the lock screen asks for its PIN, without a click"
unlock_with_password
log "ok: the password unlocks it while the key is armed"

vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
lock_screen
key_prompt_hidden || die "with the key unplugged, the lock screen must not ask for its PIN"
vekrona-dev usb attach "$KEY_ID"
KEY_ATTACHED=1
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_shown
log "ok: plugging the key in while locked shows the PIN prompt"
vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_hidden
log "ok: unplugging the key while locked removes the PIN prompt"
unlock_with_password
log "ok: the password unlocks it after the hotplug"
