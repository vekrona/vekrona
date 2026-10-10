#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

# A focused power widget labels its current button "Lock".
power_widget_labelled() { vekrona-dev see text '\bLock\b'; }
logout_row_selected() { launcher_is '.mode == "power" and .query == "log" and .selectedId == "power:logout"'; }
armed_state() { launcher_is '.armed and .open'; }
armed_shown() { armed_state && vekrona-dev see text 'Press Enter again to log out' && vekrona-dev see text 'Cancel'; }
armed_gone() { launcher_is '.open and (.armed | not)'; }
export -f power_widget_labelled logout_row_selected armed_state armed_shown armed_gone

# The widget strip is ordered by Modules.qml: the settings widget, then the power widget.
focus_power_widget() {
  vekrona-dev key tab
  vekrona-dev key tab
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- power_widget_labelled \
    || die "the second Tab stop of the widget strip did not show the power widget's Lock button"
}

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
focus_power_widget
log "ok: the power widget is in the launcher and the second Tab reaches it"

vekrona-dev key esc
vekrona-dev type '/power '
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
