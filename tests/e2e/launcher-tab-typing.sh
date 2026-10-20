#!/usr/bin/env bash
# A character typed while the mode tabs have the focus goes to the search field, and the focus goes back to it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev key tab
# Focus is on the tabs now: the search field has no say in the next characters.
vekrona-dev type 'ab'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .query == "ab"' || { launcher_state; die "characters typed on the mode tabs must land in the search field"; }
vekrona-dev type 'c'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.query == "abc"' || { launcher_state; die "after the first character the search field must hold the focus"; }
log "ok: typing while the mode tabs have the focus fills the search field"
close_launcher
