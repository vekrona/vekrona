#!/usr/bin/env bash
# The first click after an unlock reaches the bar, also when the pointer did not move. Sway gives the pointer to the surface under it
# when a lock surface maps, but not when the lock ends, so until the next motion no surface had the pointer, and the press of a click
# that came first was lost: the pill showed its hover once the pointer was given back, and opened nothing. The lock screen gives the
# pointer back itself when it unlocks (config/vekrona-lock/shell.qml).
#   - the pointer rests on the Sync pill, the screen locks and is unlocked with the password, and a click on the pill without any
#     motion opens the popout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/sync-popout.sh
source "$ROOT/tests/e2e/lib/sync-popout.sh"

STEP_TIMEOUT_SEC=30
cleanup() { run_cleanups close_popout; }

vekrona-dev session
trap cleanup EXIT
read -r x y <<<"$(bar_widget center sync)"
[[ -n "${x:-}" ]] || die "the bar must show the sync icon"
close_popout
vekrona-dev move "$x" "$y"
vekrona-dev sh vekrona-lock start
# Types the password at the lock screen: key presses, no pointer motion.
vekrona-dev session
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_open || die "a click on the Sync pill right after the unlock, with the pointer resting on it, must open the popout"
log "ok: the first click after an unlock, with the pointer resting on the pill, opens the popout"
