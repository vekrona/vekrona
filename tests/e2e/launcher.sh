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
module_failures() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell | grep -c 'launcher: module .* failed' || [[ $? -eq 1 ]]; }
nothing_matches() { launcher_is '.query == "zzzzqqqq" and .rows == 0'; }
query_cleared() { launcher_is '.open and .query == ""'; }
# Whether the web module's bookmark and history lookup is not running: it has answered the query typed so far.
places_idle() { ! vekrona-dev sh pgrep -f '[v]ekrona-firefox places' >/dev/null; }
query_extended() { launcher_is '.query == "zzzzqqqqq"'; }
export -f terminal_open terminal_closed nothing_matches query_cleared places_idle query_extended
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

failures_before="$(module_failures)"
vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
log "ok: a query that matches no application lists no row"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- places_idle
vekrona-dev type q
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- query_extended
[[ "$(module_failures)" == "$failures_before" ]] || die "typing on after a module answered made a launcher module fail"
log "ok: a query typed after the modules answered the one before fails no module"
vekrona-dev key backspace

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- query_cleared
log "ok: Escape clears the query first and keeps the launcher open"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
log "ok: a second Escape closes the launcher"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- query_cleared
log "ok: reopening starts from an empty query"

vekrona-dev type GHOSTTY
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_open
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
log "ok: a case-insensitive query launches the application and closes the launcher"
[[ "$(window_count)" == "$((windows_before + 1))" ]] || die "only the searched application may open, but windows went from $windows_before to $(window_count)"
log "ok: only the searched application opened"

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
