#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
NEXT_LAYOUT_CHORD=super-ctrl-alt-space
# A changed code keeps the pill in place (its width is fixed); other text containing EN or UA sits elsewhere on screen.
PILL_DRIFT_PX=20

code_shown() {
  local center x
  center="$(vekrona-dev see find "$1")" || return 1
  x="${center%% *}"
  ((x > PILL_X - PILL_DRIFT_PX && x < PILL_X + PILL_DRIFT_PX))
}
export -f code_shown
export PILL_DRIFT_PX

vekrona-dev session
clear_notifications
vekrona-dev move 600 500

# The VM boots with one layout, so the item is hidden until the keymap has two.
# Sway splits a command at commas, so the layout list is quoted inside the command.
set_layouts() { vekrona-dev sh swaymsg "input type:keyboard xkb_layout \"$1\""; }
restore_layout() { set_layouts us; }
trap restore_layout EXIT
set_layouts us,ua

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev see text "EN"
read -r PILL_X y <<<"$(vekrona-dev see find "EN")"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the layout code EN once the keymap has two layouts"
export PILL_X
log "ok: the bar shows EN for a us,ua keymap at x=$PILL_X"

vekrona-dev key "$NEXT_LAYOUT_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "UA"
log "ok: Hyper+Space switches to the next layout and the bar shows UA"

vekrona-dev key "$NEXT_LAYOUT_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "EN"
log "ok: Hyper+Space again wraps back to EN"
