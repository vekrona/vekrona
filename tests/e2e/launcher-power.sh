#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

power_mode_opened() { launcher_is '.open and .mode == "power" and .query == ""'; }
logout_row_selected() { launcher_is '.mode == "power" and .query == "log" and .selectedId == "power:logout"'; }
armed_state() { launcher_is '.armed and .open'; }
armed_shown() { armed_state && vekrona-dev see text 'Press Enter again to log out' && vekrona-dev see text 'Cancel'; }
armed_gone() { launcher_is '.open and (.armed | not)'; }
export -f power_mode_opened logout_row_selected armed_state armed_shown armed_gone


vekrona-dev session
vekrona-dev move 600 500
clear_notifications

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
click_launcher_tab power
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- power_mode_opened || { launcher_state; die "a click on the Power tab must open /power"; }
log "ok: the Power tab opens the power commands"

# Tab enters the strip on the lit Power tab. A held Enter acts when it is released, so its repeats never reach the
# search field, where they would run the selected row, Lock.
vekrona-dev key tab
vekrona-dev hold ret 1500
power_mode_opened || { launcher_state; die "a held Enter on a tab must not run the first power command"; }
log "ok: a held Enter on a tab does not repeat into the search field"

vekrona-dev type log
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- logout_row_selected

vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- armed_shown
log "ok: the first Enter on Log out only arms it and asks for a second"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- armed_gone
log "ok: Escape disarms the row and keeps the launcher open"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
vekrona-dev sh swaymsg -t get_version >/dev/null
log "ok: the session is still running"
