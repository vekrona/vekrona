#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
APP_ID_REGEX=ghostty

terminals_are() { [[ "$(window_rects "$APP_ID_REGEX" | wc -l)" == "$1" ]]; }
close_terminals() { vekrona-dev sh pkill -x "$APP_ID_REGEX" || [[ $? -eq 1 ]]; }
open_terminal() { vekrona-dev sh swaymsg exec ghostty >/dev/null; }
export -f terminals_are
export APP_ID_REGEX

# Opens one terminal, presses the key $1, launches a second terminal from the launcher, and prints "<x> <y>" of the first
# and then of the second.
launch_beside() {
  local key="$1" old_id
  close_terminals
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminals_are 0
  open_terminal
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminals_are 1
  read -r old_id _ < <(window_rects "$APP_ID_REGEX")
  vekrona-dev key "$key"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open
  vekrona-dev type GHOSTTY
  vekrona-dev key ret
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminals_are 2
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
  window_rects "$APP_ID_REGEX" | awk -v id="$old_id" '$1 == id { print $2, $3 }'
  window_rects "$APP_ID_REGEX" | awk -v id="$old_id" '$1 != id { print $2, $3 }'
}

vekrona-dev session
vekrona-dev move 600 500
trap close_terminals EXIT

rects="$(launch_beside super-backslash)"
read -r old_x old_y new_x new_y <<<"${rects//$'\n'/ }"
(( new_x > old_x && new_y == old_y )) || die "Super+\\ must open the app to the right: old at $old_x,$old_y, new at $new_x,$new_y"
log "ok: Super+\\ opens the launcher and the app lands to the right of the focused window"

rects="$(launch_beside super-minus)"
read -r old_x old_y new_x new_y <<<"${rects//$'\n'/ }"
(( new_y > old_y && new_x == old_x )) || die "Super+- must open the app below: old at $old_x,$old_y, new at $new_x,$new_y"
log "ok: Super+- opens the launcher and the app lands below the focused window"

close_terminals
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminals_are 0
open_terminal
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminals_are 1
vekrona-dev key super-backslash
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open
vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
terminals_are 1 || die "Escape after Super+\\ must open no window"
log "ok: Escape closes the launcher and opens nothing"
