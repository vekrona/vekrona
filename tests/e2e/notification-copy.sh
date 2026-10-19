#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_ACTION_LOG=/tmp/vekrona-e2e-notify-copy-action.log
GUEST_TEXT_LOG=/tmp/vekrona-e2e-notify-copy-text.log
LONG_BODY="$(printf 'word%s ' {1..300})"
LONG_BODY="${LONG_BODY% }"

log_has() { vekrona-dev run grep -q "$2" "$1"; }
pasted() { [[ "$(vekrona-dev sh bash -c 'wl-paste --no-newline | base64 -w0')" == "$(printf %s "$EXPECTED" | base64 -w0)" ]]; }
export -f log_has pasted

notify() { vekrona-dev sh notify-send "$@"; }
# How many times a card has complained about reading a notification that no longer exists.
card_type_errors() { shell_log_count 'NotificationCard.qml.*TypeError'; }
expect_paste() {
  EXPECTED="$1"
  export EXPECTED
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pasted
}

vekrona-dev session
vekrona-dev move 100 500
close_notification_centre
clear_notifications
type_errors_before="$(card_type_errors)"

notify 'Copyable' 'line one body'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'line one'
click_card Copyable "$CENTRE_COPY_FROM_RIGHT_PX" "$CARD_BUTTONS_ABOVE_SUMMARY_PX"
expect_paste $'Copyable\nline one body'
log "ok: the copy button puts the summary and the body on the clipboard"
absent vekrona-dev sh pgrep -f 'wl-cop[y].*line one' >/dev/null || die "the copied text must not be in the command line of wl-copy"
log "ok: the copied text does not appear in any command line"

read -r x y <<<"$(vekrona-dev see find '^body$')"
[[ -n "${x:-}" ]] || die "the centre must show the body text, but OCR found none to select"
vekrona-dev click "$x" "$y" --double
vekrona-dev key ctrl-c
expect_paste body
log "ok: double-clicking a word in the centre selects it and Ctrl+C copies it"

close_notification_centre
clear_notifications
vekrona-dev spawn "$GUEST_ACTION_LOG" -- notify-send --wait -A default=Open 'Selectable' 'plain quiet text'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'plain quiet'
# Once its toast has expired, only the centre can show the card, and no toast can reappear when the centre closes.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'plain quiet'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'plain quiet'
vekrona-dev move 100 500
read -r x y <<<"$(vekrona-dev see find '^quiet$')"
[[ -n "${x:-}" ]] || die "the centre must show the body text, but OCR found none to select"
vekrona-dev click "$x" "$y" --double
vekrona-dev key ctrl-c
expect_paste quiet
! log_has "$GUEST_ACTION_LOG" default || die "selecting text must not invoke the notification's default action"
text_shown 'Selectable' || die "selecting text must leave the notification listed"
log "ok: selecting text neither invokes the default action nor removes the notification"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Selectable'
log "ok: Escape closes the centre while text is selected"

open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Clear all'
click_card Selectable "$CENTRE_CARD_PADDING_FROM_RIGHT_PX"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_ACTION_LOG" default
log "ok: clicking the padding of a card still invokes its default action"

clear_notifications
vekrona-dev spawn "$GUEST_TEXT_LOG" -- notify-send --wait -A default=Open 'Tappable' 'meadow'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'meadow'
read -r x y <<<"$(vekrona-dev see find '^meadow$')"
[[ -n "${x:-}" ]] || die "the centre must show the body text, but OCR found none to click"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- log_has "$GUEST_TEXT_LOG" default || die "a plain click on the text of a card must invoke its default action"
log "ok: a plain click on the text of a card invokes its default action"

clear_notifications
notify 'Longform' "$LONG_BODY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'word1'
click_card Longform "$CENTRE_COPY_FROM_RIGHT_PX" "$CARD_BUTTONS_ABOVE_SUMMARY_PX"
expect_paste "Longform"$'\n'"$LONG_BODY"
log "ok: the copy button copies a 300-word body in full"

read -r x y <<<"$(vekrona-dev see find '^word1$')"
[[ -n "${x:-}" ]] || die "the centre must show the start of the long body, but OCR found none to click"
vekrona-dev click "$x" "$y"
vekrona-dev key ctrl-a ctrl-c
expect_paste "$LONG_BODY"
log "ok: the centre holds a 300-word body in full, to the last word"

close_notification_centre
clear_notifications
notify 'Toasty' 'goes away'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'goes away'
click_card Toasty "$TOAST_DISMISS_FROM_RIGHT_PX" "$CARD_BUTTONS_ABOVE_SUMMARY_PX"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Toasty'
notify 'Centred' 'stays a while'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'stays a while'
click_card Centred "$CENTRE_DISMISS_FROM_RIGHT_PX" "$CARD_BUTTONS_ABOVE_SUMMARY_PX"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'Centred'
close_notification_centre
[[ "$(card_type_errors)" == "$type_errors_before" ]] || die "dismissing cards must not make them read a notification that is gone, but $(($(card_type_errors) - type_errors_before)) TypeErrors were logged"
log "ok: dismissing a toast and a centre card logs no TypeError"

clear_notifications
notify 'Lasting' 'outlives the shell'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'outlives'
click_card Lasting "$CENTRE_COPY_FROM_RIGHT_PX" "$CARD_BUTTONS_ABOVE_SUMMARY_PX"
expect_paste $'Lasting\noutlives the shell'
restart_shell
expect_paste $'Lasting\noutlives the shell'
log "ok: the copied text is still on the clipboard after the shell restarts"
