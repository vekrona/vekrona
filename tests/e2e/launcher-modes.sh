#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

window_count() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq '[.. | objects | select((.type? == \"con\" or .type? == \"floating_con\") and .pid? != null)] | length'"; }
# The footer says "Enter mode" only while the /calc suggestion is selected; the module title is on screen as the badge once the mode is entered.
suggestion_shown() { vekrona-dev see text 'Enter mode'; }
mode_entered() { vekrona-dev see text 'Calculator' && ! suggestion_shown; }
mode_left() { ! vekrona-dev see text 'Calculator'; }
actions_shown() { vekrona-dev see text 'Filter actions'; }
actions_hidden() { ! actions_shown; }
app_listed() { vekrona-dev see text 'Ghostty'; }
export -f suggestion_shown mode_entered mode_left actions_shown actions_hidden app_listed

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

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
log "ok: /calc and a space enter the calculator mode, shown as a badge"

vekrona-dev key ret
vekrona-dev key backspace
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_left
log "ok: Enter with nothing listed keeps the launcher open, and Backspace on an empty query leaves the mode"

vekrona-dev type ghostty
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_listed
vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_shown
log "ok: Ctrl+K opens the actions of the selected row"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_hidden
panel_shown || die "Escape on the actions panel must close only the panel, not the launcher"
log "ok: Escape closes the actions panel and keeps the launcher"

vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_shown
vekrona-dev key ctrl-k
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- actions_hidden
log "ok: Ctrl+K again closes the actions panel"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
[[ "$(window_count)" == "$windows_before" ]] || die "nothing in this scenario launches an application, but windows went from $windows_before to $(window_count)"
log "ok: no key in this scenario launched anything"
