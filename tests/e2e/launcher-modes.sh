#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

suggestion_shown() { launcher_is '.query == "/calc" and .mode == "" and .selectedId == "mode:calc"'; }
mode_entered() { launcher_is '.mode == "calc" and .query == "" and .rows == 0'; }
mode_left() { launcher_is '.open and .mode == "" and .query == ""'; }
actions_shown() { launcher_is '.actionsOpen'; }
actions_hidden() { launcher_is '.open and (.actionsOpen | not)'; }
leave_hint_shown() { vekrona-dev see text 'Leave mode'; }
app_listed() { vekrona-dev see text 'Foot'; }
percent_answered() { vekrona-dev see text '\b230\b'; }
refusal_shown() { vekrona-dev see text 'Couldn.t evaluate'; }
export -f percent_answered refusal_shown suggestion_shown mode_entered mode_left actions_shown actions_hidden leave_hint_shown app_listed


vekrona-dev session
vekrona-dev move 600 500
clear_notifications
windows_before="$(window_count)"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown

vekrona-dev type /calc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- suggestion_shown
log "ok: a leading slash suggests the modes"

vekrona-dev type ' '
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_entered
log "ok: /calc and a space enter the calculator mode"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- leave_hint_shown
log "ok: with nothing listed the footer says how to leave the mode"

vekrona-dev type '12.5% of 1840'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- percent_answered
log "ok: /calc answers \"12.5% of 1840\" with 230"

errors_before="$(shell_errors)"
vekrona-dev key ctrl-a
vekrona-dev key backspace
vekrona-dev type '5 apples + 3'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- refusal_shown
[[ "$(shell_errors)" == "$errors_before" ]] || die "an expression qalc cannot evaluate is the user's input and must not log a shell error"
log "ok: an expression qalc cannot evaluate is said so in the list and is not a shell error"

vekrona-dev key ctrl-a
vekrona-dev key backspace
vekrona-dev key ret
vekrona-dev key backspace
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_left
log "ok: Enter with nothing listed keeps the launcher open, and Backspace on an empty query leaves the mode"

vekrona-dev type foot
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_listed
vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_shown
log "ok: Ctrl+K opens the actions of the selected row"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_hidden
log "ok: Escape closes the actions panel and keeps the launcher"

vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_shown
vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_hidden
log "ok: Ctrl+K again closes the actions panel"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
[[ "$(window_count)" == "$windows_before" ]] || die "nothing in this scenario launches an application, but windows went from $windows_before to $(window_count)"
log "ok: no key in this scenario launched anything"
