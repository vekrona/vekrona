#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
NEXT_LAYOUT_CHORD=super-ctrl-alt-space

vekrona-dev session
clear_notifications
vekrona-dev move 600 500

# The VM boots with one layout, so the item is hidden until the keymap has two.
restore_layout() { set_layouts us; }
trap restore_layout EXIT
set_layouts us,ua

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown "EN"
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
