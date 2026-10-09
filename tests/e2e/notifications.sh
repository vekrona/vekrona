#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_ACTION_LOG=/tmp/vekrona-e2e-notify-action.log
GUEST_FIVE_LOG=/tmp/vekrona-e2e-notify-five.log
LONG_BODY="$(printf 'overflow%.0s ' {1..300})"

shown() { vekrona-dev see text "$1"; }
gone() { ! shown "$1"; }
log_has() { vekrona-dev run grep -q "$2" "$1"; }
export -f shown gone log_has

notify() { vekrona-dev sh notify-send "$@"; }

vekrona-dev session
vekrona-dev move 100 500
clear_notifications

[[ "$(vekrona-dev sh busctl --user status org.freedesktop.Notifications | sed -n 's/^UserUnit=//p')" == vekrona-shell.service ]] \
  || die "org.freedesktop.Notifications must belong to vekrona-shell.service"
log "ok: the shell owns the notification bus name"

vekrona-dev spawn "$GUEST_ACTION_LOG" -- notify-send --wait -A default=Open -A fix=Fix 'Vekrona e2e' 'body text'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Vekrona e2e'
log "ok: a notification pops up"

read -r x y <<<"$(vekrona-dev see find '^body$')"
[[ -n "${x:-}" ]] || die "the toast must show its body text, but OCR found none to click"
vekrona-dev click "$x" "$y"
vekrona-dev move 100 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_ACTION_LOG" default
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'Vekrona e2e'
log "ok: clicking the body invokes the default action and dismisses the toast"

vekrona-dev spawn "$GUEST_FIVE_LOG" -- notify-send --wait -A first=Alpha -A second=Beta -A third=Gamma -A fourth=Delta -A fifth=Epsilon 'Five actions' 'many buttons'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Epsilon'
log "ok: five actions all fit"

clear_notifications
notify 'Plain one' 'no actions here'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'no actions here'
log "ok: a notification without actions shows"

clear_notifications
notify 'Markup' '<b>bold</b> & <i>italic</i>'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown '<b>bold'
log "ok: markup in a body is shown literally"

clear_notifications
notify 'Long body' "$LONG_BODY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'overflow'
shown 'Long body' || die "a very long body must not push the summary off screen"
log "ok: a very long body is clipped, not overflowing"

clear_notifications
notify -u critical -t 1000 'Critical one' 'must stay'
notify -t 1000 'Brief one' 'goes away'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Brief one'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'Brief one'
shown 'Critical one' || die "a critical notification must never expire"
log "ok: a normal notification expires and a critical one stays"

clear_notifications
replaced_id="$(notify -p -t 1000 'Replaced' 'first text')"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'first text'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'first text'
notify -r "$replaced_id" 'Replaced' 'second text'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'second text'
log "ok: a replaced notification shows its new text as a fresh toast after the old one expired"

clear_notifications
notify 'Kept' 'in the centre'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'in the centre'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'in the centre'
vekrona-dev key super-ctrl-alt-n
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Kept'
log "ok: the notification chord opens the centre, which lists an expired toast"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gone 'Kept'
log "ok: Escape closes the centre"
