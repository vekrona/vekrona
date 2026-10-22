#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The searched application is a foot window: Ghostty's GL renderer crashes on the guest's llvmpipe. Entries that run in
# a terminal open in the shell's own terminal, which is Ghostty (Exec.qml), so the btop steps still need it.
SEARCHED_APP=foot
SHELL_TERMINAL=ghostty

# 0 when a window's app_id matches the regex $1, 1 when none does, anything else when the query failed.
app_open() { vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_tree | jq -e --arg re "$1" "[.. | objects | select((.app_id? // \"\") | test(\$re))] | length > 0" >/dev/null' _ "$1"; }
app_closed() { absent app_open "$1"; }
app_pids() { vekrona-dev sh pgrep -x "$1" | paste -sd,; }
shell_up() { vekrona-dev sh qs -c vekrona-shell ipc show >/dev/null; }
export -f shell_up
module_failures() { shell_log_count 'launcher: module .* failed'; }
nothing_matches() { launcher_is '.query == "zzzzqqqq" and .empty'; }
query_cleared() { launcher_is '.open and .query == ""'; }
# Whether the web module's bookmark and history lookup is not running: it has answered the query typed so far.
places_running() { vekrona-dev sh pgrep -f '[v]ekrona-firefox places' >/dev/null; }
places_idle() { absent places_running; }
query_extended() { launcher_is '.query == "zzzzqqqqq"'; }
export -f app_open app_closed nothing_matches query_cleared places_running places_idle query_extended

close_apps() { vekrona-dev sh pkill -x "$SEARCHED_APP|$SHELL_TERMINAL" || [[ $? -eq 1 ]]; }

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
trap close_apps EXIT
close_apps
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_closed "$SEARCHED_APP"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_closed "$SHELL_TERMINAL"
windows_before="$(window_count)"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
log "ok: Super+Space opens the launcher"

failures_before="$(module_failures)"
vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
log "ok: a query that matches no application says so"
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

# The launcher is only its panel, so a click outside it reaches the catcher window under the panel, which closes it.
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev click 100 700
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a click outside the panel must close the launcher"
vekrona-dev move 600 500
log "ok: a click outside the panel closes the launcher"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- query_cleared
log "ok: reopening starts from an empty query"

vekrona-dev type FOOT
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_open "$SEARCHED_APP"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
log "ok: a case-insensitive query launches the application and closes the launcher"
[[ "$(window_count)" == "$((windows_before + 1))" ]] || die "only the searched application may open, but windows went from $windows_before to $(window_count)"
log "ok: only the searched application opened"

close_apps
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_closed "$SEARCHED_APP"
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type btop
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- app_open "$SHELL_TERMINAL"
log "ok: an application that needs a terminal opens in one"

pids_before="$(app_pids "$SHELL_TERMINAL")"
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_up
[[ "$(app_pids "$SHELL_TERMINAL")" == "$pids_before" ]] || die "an application launched from the shell must survive a shell restart: $pids_before before, $(app_pids "$SHELL_TERMINAL") after"
log "ok: an application launched from the launcher outlives a restart of the shell"
