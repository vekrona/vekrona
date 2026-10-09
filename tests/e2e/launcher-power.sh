#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
WIDGET_STOP_TIMEOUT_SEC=10
WIDGET_STOPS=3

# A focused power widget labels its current button "Lock".
power_widget_labelled() { vekrona-dev see text '\bLock\b'; }
logout_row_listed() { vekrona-dev see text 'Log out'; }
armed_shown() { vekrona-dev see text 'Press Enter again to log out' && vekrona-dev see text 'Cancel'; }
armed_gone() { ! vekrona-dev see text 'Press Enter again'; }
export -f power_widget_labelled logout_row_listed armed_shown armed_gone

# Tab walks the widgets in turn and then returns to the search field, so the power widget is one of the first stops.
focus_power_widget() {
  local stop
  for ((stop = 0; stop < WIDGET_STOPS; stop++)); do
    vekrona-dev key tab
    if vekrona-dev until --timeout "$WIDGET_STOP_TIMEOUT_SEC" -- power_widget_labelled; then
      return 0
    fi
  done
  die "no Tab stop in the widget strip showed the power widget's Lock button"
}

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
focus_power_widget
log "ok: the power widget is in the launcher and Tab reaches it"

vekrona-dev key esc
vekrona-dev type '/power '
vekrona-dev type log
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- logout_row_listed

vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- armed_shown
log "ok: the first Enter on Log out only arms it and asks for a second"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- armed_gone
panel_shown || die "Escape on an armed row must only disarm it, not close the launcher"
log "ok: Escape disarms the row and keeps the launcher open"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
vekrona-dev sh swaymsg -t get_version >/dev/null
log "ok: the session is still running"
