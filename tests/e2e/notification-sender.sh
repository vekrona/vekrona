#!/usr/bin/env bash
# A notification card names its sender, and a click on its body runs only the action the app marked as default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
SENDER=Vekrona-e2e-sender
GUEST_LOG=/tmp/vekrona-e2e-notification-sender.log
GUEST_AFTER_LOG=/tmp/vekrona-e2e-notification-sender-after.log

shown() { vekrona-dev see text "$1"; }
log_has() { vekrona-dev run grep -q "$2" "$1"; }
export -f shown log_has

cleanup() {
  kill_guest -f "notify-send --wait"
  vekrona-dev run rm -f "$GUEST_LOG" "$GUEST_AFTER_LOG"
  close_notification_centre
}
trap cleanup EXIT

vekrona-dev session
vekrona-dev move 100 500
clear_notifications
vekrona-dev run rm -f "$GUEST_LOG" "$GUEST_AFTER_LOG"

vekrona-dev spawn "$GUEST_LOG" -- notify-send --wait -a "$SENDER" -A reply=Reply 'Sender check' 'sender body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'sender body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown "$SENDER" || die "a notification card must name the app that sent it, $SENDER"
log "ok: the card shows the sender's name"

open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'sender body'
# A click on the body of the card; the card has no default action, so it runs none. OCR reads words, not lines.
vekrona-dev click-text '^body$'
# The pointer rests on the card, where the next card would appear under it and garble its OCR.
vekrona-dev move 100 500
# A later notification is shown only after the click was handled, which makes the absence of an action observable.
vekrona-dev spawn "$GUEST_AFTER_LOG" -- notify-send --wait -h string:desktop-entry:none -A default=Open 'After click' 'after body'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'after body'
! log_has "$GUEST_LOG" reply || die "a click on the body of a notification without a default action ran its first action, Reply"
log "ok: a click on the body of a notification without a default action runs none of its actions"

vekrona-dev click-text '^Reply$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_LOG" reply || die "the Reply button must still run its action"
log "ok: the action's own button still runs it"
