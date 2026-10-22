#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
UNREAD_COUNT=123

# The unread dot is found by its danger fill: half of a space-2 square.
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
DOT_PX="$(vekrona_token_get spacing space-2)"
BADGE_MIN_PIXELS=$((DOT_PX * DOT_PX / 2))

danger_pixels() { python3 "$ROOT/tests/e2e/screen_colors.py" bar-count "$(vekrona-dev shot)" "$DANGER_HEX" "$BAR_HEIGHT_PX"; }
badge_hidden() { (($(danger_pixels) == 0)); }
badge_shown() { (($(danger_pixels) >= BADGE_MIN_PIXELS)); }
export -f danger_pixels badge_hidden badge_shown
export ROOT DANGER_HEX BAR_HEIGHT_PX BADGE_MIN_PIXELS

# A fresh account has no error store until the first error is recorded: set it aside, as that state, and put it back on exit.
STORE='~/.local/state/vekrona/errors'
ASIDE='~/.local/state/vekrona/errors.e2e-aside'
restore() {
  vekrona-dev sh bash -c "rm -rf $STORE && if [[ -e $ASIDE ]]; then mv $ASIDE $STORE; fi"
  vekrona-dev sh systemctl --user start vekrona-errors.service
  restart_shell
}
trap restore EXIT

vekrona-dev session
clear_notifications
vekrona-dev sh systemctl --user stop vekrona-errors.service
vekrona-dev sh bash -c "rm -rf $ASIDE && if [[ -e $STORE ]]; then mv $STORE $ASIDE; fi"
restart_shell

vekrona-dev sh bash -c "test -f $STORE/unread" || die "starting the shell must leave the error store's unread file behind, so the shell can watch it"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badge_hidden
log "ok: a shell started without an error store shows no agent dot, and the unread file exists"

vekrona-dev sh bash -c "echo $UNREAD_COUNT >$STORE/unread"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badge_shown || die "the agent dot must appear when errors are recorded after the shell started without a store"
log "ok: the agent dot appears once errors are recorded after the shell started"
