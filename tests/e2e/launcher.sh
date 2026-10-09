#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
APP_ID_REGEX=ghostty

terminal_open() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -e '[.. | objects | select((.app_id? // \"\") | test(\"$APP_ID_REGEX\"))] | length > 0' >/dev/null"; }
terminal_closed() { ! terminal_open; }
terminal_pids() { vekrona-dev sh pgrep -x "$APP_ID_REGEX" | paste -sd,; }
shell_up() { vekrona-dev sh qs -c vekrona-shell ipc show >/dev/null; }
export -f shell_up
window_count() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq '[.. | objects | select((.type? == \"con\" or .type? == \"floating_con\") and .pid? != null)] | length'"; }
nothing_matches() { vekrona-dev see text 'No matches'; }
export -f terminal_open terminal_closed nothing_matches
export APP_ID_REGEX

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

close_terminals() { ! terminal_open || vekrona-dev sh pkill -x "$APP_ID_REGEX"; }

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
trap close_terminals EXIT
close_terminals
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_closed
windows_before="$(window_count)"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
log "ok: Super+Space opens the launcher"

vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
log "ok: a query that matches no application says so"

vekrona-dev key ret
vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
log "ok: Enter on no match and Escape close the launcher"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
! nothing_matches || die "reopening the launcher must clear the previous query"
log "ok: reopening starts from an empty query"

vekrona-dev type GHOSTTY
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
log "ok: a case-insensitive query launches the application and closes the launcher"
[[ "$(window_count)" == "$((windows_before + 1))" ]] || die "only the searched application may open, but windows went from $windows_before to $(window_count): Enter on an empty result list must launch nothing"
log "ok: Enter on no match launched nothing"

close_terminals
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_closed
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type btop
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_open
log "ok: an application that needs a terminal opens in one"

pids_before="$(terminal_pids)"
vekrona-dev sh systemctl --user restart vekrona-shell.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_up
[[ "$(terminal_pids)" == "$pids_before" ]] || die "an application launched from the shell must survive a shell restart: $pids_before before, $(terminal_pids) after"
log "ok: an application launched from the launcher outlives a restart of the shell"
