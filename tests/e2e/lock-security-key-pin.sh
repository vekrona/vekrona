#!/usr/bin/env bash
# The lock screen asks for the security key's PIN (pinverification=1) and then for a touch. With a key plugged in the field takes
# the PIN by default and says so; Tab turns it into a password field (a password taken for a PIN counts against the key's few PIN
# attempts); with no key it takes the password. The key's PAM stack is replaced by a module that reads the PIN through the PAM conversation like
# pam_u2f does, records it, accepts 1234 and shows the touch cue.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
PIN=1234
KEY_ID="${VEKRONA_E2E_KEY_ID:-1050:0407}"
KEY_ATTACHED=0
PAM_FILE=/etc/pam.d/vekrona-lock-u2f
PAM_ORIGINAL=/etc/pam.d/vekrona-lock-u2f.e2e-original
PIN_KEY=/usr/local/bin/vekrona-e2e-pin-key
PIN_LOG=/tmp/vekrona-e2e-pin-key.log

pin_expected() { lock_text_shown 'enter security key pin'; }
password_expected() { lock_text_shown 'enter password'; }
touch_prompt_shown() { lock_text_shown 'touch your security key'; }
export -f pin_expected password_expected touch_prompt_shown

install_pin_stack() {
  vekrona-dev run sudo bash -c "
set -euo pipefail
rm -f '$PIN_LOG'
printf '#!/bin/sh\nread -r pin\necho \"\$pin\" >>$PIN_LOG\n[ \"\$pin\" = $PIN ] || exit 1\necho \"Please touch the FIDO authenticator.\"\n' >'$PIN_KEY'
chmod 755 '$PIN_KEY'
cp -a '$PAM_FILE' '$PAM_ORIGINAL'
printf 'auth required pam_exec.so expose_authtok stdout $PIN_KEY\naccount required pam_permit.so\npassword required pam_deny.so\nsession required pam_permit.so\n' >'$PAM_FILE'
"
}
restore_pam_stack() {
  vekrona-dev run sudo bash -c "
if [[ -e '$PAM_ORIGINAL' ]]; then mv '$PAM_ORIGINAL' '$PAM_FILE'; fi
rm -f '$PIN_KEY' '$PIN_LOG'
"
}
# What the fake key received, one PIN per line; nothing when it was never asked.
pin_log() { vekrona-dev run sudo bash -c '[[ ! -e "$1" ]] || cat "$1"' _ "$PIN_LOG"; }

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
# The PAM stack goes first: the fake one, left behind, refuses the lock screen of every later scenario.
trap 'run_cleanups restore_pam_stack unlock_leftover_lock detach_key' EXIT

lock_screen() {
  vekrona-dev sh vekrona-lock start
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_watcher_running
}

command -v magick >/dev/null || die "the e2e scenario needs ImageMagick (magick) to crop screenshots"
vekrona-dev session
vekrona-dev move 10 10

if ! vekrona-dev usb attach "$KEY_ID"; then
  skip "cannot hand $KEY_ID to the guest (stop pcscd on the host first); the PIN scenario did not run"
fi
KEY_ATTACHED=1

install_pin_stack
lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pin_expected
log "ok: with a key plugged in and its PIN asked for, the field says it expects the PIN"

vekrona-dev key tab
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_expected
vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
if pin_log | grep -qx "$GUEST_PASSWORD"; then die "the password reached the security key as a PIN: $(pin_log)"; fi
log "ok: Tab turns the field into a password field; the password unlocks and never reaches the key"

lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pin_expected
vekrona-dev type --enter "$PIN"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
pin_log | grep -qx "$PIN" || die "the PIN did not reach the key's PAM stack: $(pin_log)"
log "ok: the PIN typed once the prompt is up answers the key's prompt, and unlocks"

vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_expected
log "ok: with no key plugged in the field expects the password"
