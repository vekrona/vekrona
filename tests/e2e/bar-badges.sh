#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# OCR cannot read the badge's dark text on its danger fill, so a badge is found by its fill and its number by the ink inside it.
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
BADGES="$ROOT/tests/e2e/bar-badges.py"
BADGE_COUNT=2
NOTIFICATIONS=3
MIN_NUMBER_PIXELS=8

badges_alike() { python3 "$BADGES" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" "$BADGE_COUNT" "$MIN_NUMBER_PIXELS" >/dev/null; }
export -f badges_alike
export BADGES BAR_HEIGHT_PX DANGER_HEX BADGE_COUNT MIN_NUMBER_PIXELS

# The watcher rewrites the unread count whenever it records an error, e.g. the failed units it replays after a session restart.
restart_error_watcher() { vekrona-dev sh systemctl --user start vekrona-errors.service; }
trap restart_error_watcher EXIT

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
vekrona-dev sh systemctl --user stop vekrona-errors.service
vekrona-dev sh bash -c "mkdir -p ~/.local/state/vekrona/errors && echo $NOTIFICATIONS > ~/.local/state/vekrona/errors/unread"
for i in $(seq "$NOTIFICATIONS"); do
  vekrona-dev sh notify-send "Badge test $i" "body $i"
done

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badges_alike || log "the badges did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
python3 "$BADGES" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" "$BADGE_COUNT" "$MIN_NUMBER_PIXELS" || die "the agent and the notification bell must show the same badge with a number, see the measurement above"
log "ok: the agent and the notification bell show the same badge: a red box with a number"
