#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
KEY_ID=1050:0407
KEY_ATTACHED=0

lock_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-lock; }
lock_inactive() { ! lock_active; }
key_watcher_running() { vekrona-dev sh pgrep -f fido-keys.sh >/dev/null; }
# OCR drops the small texts when the clock is in the picture, so only the lower part of the screen is read.
lock_text_shown() {
  local shot lower status=0
  shot="$(vekrona-dev shot)"
  lower="${shot%.png}-lower.png"
  magick "$shot" -gravity south -crop 100%x55%+0+0 +repage "$lower" || die "cannot crop the screenshot $shot"
  vekrona-dev see text "$1" "$lower" || status=$?
  rm -f "$shot" "$lower"
  return "$status"
}
password_shown() { lock_text_shown 'password'; }
key_prompt_shown() { lock_text_shown 'touch your security key'; }
key_prompt_hidden() { ! key_prompt_shown; }
locked_hint() { vekrona-dev sh loginctl show-session auto -p LockedHint --value; }
export -f lock_text_shown lock_active lock_inactive key_watcher_running password_shown key_prompt_shown key_prompt_hidden

lock_screen() {
  vekrona-dev sh vekrona-lock
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- password_shown
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_watcher_running
}

unlock_with_password() {
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

lock_screen
key_prompt_hidden || die "with no security key plugged in, the lock screen must not ask to touch one"
log "ok: without a key the lock screen asks for a password and not for a key touch"
unlock_with_password
log "ok: the password unlocks it and LockedHint is no"

if ! vekrona-dev usb attach "$KEY_ID"; then
  log "skip: cannot hand $KEY_ID to the guest (stop pcscd on the host first); the key scenarios did not run"
  exit 0
fi
KEY_ATTACHED=1

lock_screen
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_shown
log "ok: with a key plugged in the lock screen asks to touch it, without a click"
unlock_with_password
log "ok: the password unlocks it while the key is armed"

vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
lock_screen
key_prompt_hidden || die "with the key unplugged, the lock screen must not ask to touch it"
vekrona-dev usb attach "$KEY_ID"
KEY_ATTACHED=1
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_shown
log "ok: plugging the key in while locked shows the touch prompt"
vekrona-dev usb detach "$KEY_ID"
KEY_ATTACHED=0
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- key_prompt_hidden
log "ok: unplugging the key while locked removes the touch prompt"
unlock_with_password
log "ok: the password unlocks it after the hotplug"
