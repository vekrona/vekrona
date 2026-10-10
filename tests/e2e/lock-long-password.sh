#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
LONG_PASSWORD_CHARS=60
FRAME_WIDTH_TARGETS=12 # the field is twelve touch targets wide (config/vekrona-lock/shell.qml)
FIELD_INK="$ROOT/tests/e2e/lock-field-ink.py"
FRAME_HEX="$(vekrona_token_get color focus dark)" # the field always has focus, and the focus ring covers its border
INK_HEX="$(vekrona_token_get color ink dark)"
MIN_FRAME_WIDTH_PX=$((FRAME_WIDTH_TARGETS * $(vekrona_token_get size size-target)))
LAST_INSIDE_FILE="$(mktemp)"
trap 'rm -f "$LAST_INSIDE_FILE"' EXIT
export FIELD_INK FRAME_HEX INK_HEX MIN_FRAME_WIDTH_PX LAST_INSIDE_FILE

lock_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-lock; }
lock_inactive() { ! lock_active; }
# "inside outside" bullet pixel counts of a fresh screenshot; fails when the frame is not on the screen.
field_ink() { python3 "$FIELD_INK" "$(vekrona-dev shot)" "$FRAME_HEX" "$INK_HEX" "$MIN_FRAME_WIDTH_PX"; }
frame_shown() { field_ink >/dev/null; }
# The bullets are drawn once two screenshots in a row show the same, non-zero amount of them inside the frame.
bullets_settled() {
  local inside previous
  inside="$(field_ink | cut -d' ' -f1)"
  previous="$(cat "$LAST_INSIDE_FILE")"
  printf '%s' "$inside" >"$LAST_INSIDE_FILE"
  ((inside > 0)) && [[ "$inside" == "$previous" ]]
}
export -f lock_active lock_inactive field_ink frame_shown bullets_settled

command -v python3 >/dev/null || die "the e2e scenario needs python3 to read the screenshot"
vekrona-dev session
vekrona-dev sh vekrona-lock
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- frame_shown

vekrona-dev type "$(head -c "$LONG_PASSWORD_CHARS" /dev/zero | tr '\0' x)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bullets_settled
read -r inside outside < <(field_ink)
((outside == 0)) || die "a $LONG_PASSWORD_CHARS-character password drew $outside bullet pixels outside the field frame (and $inside inside it)"
log "ok: a $LONG_PASSWORD_CHARS-character password stays inside the field frame"

# The field still holds the long text, so this first submit fails and clears it; the second one unlocks.
vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
