#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

# The unread dot is found by its danger fill: a whole space-2 square.
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
DOT_PX="$(vekrona_token_get spacing space-2)"
BADGE_MIN_PIXELS=$((DOT_PX * DOT_PX))

# OCR reads the clock's leading zero as 9 or O, so any two characters stand for the hour.
CLOCK_HOURS='..'
# OCR also reads a zero in the minutes as 6, 9 or O (14:06 comes out as 14:66 and 14:20 as 14:29), and the same way on every screenshot of
# that minute: a run that starts in such a minute never matches within a timeout, but one that starts a few minutes later does.
OCR_ZERO='[0O69]'

clock_minute_pattern() { vekrona-dev run date +%M | sed "s/0/$OCR_ZERO/g"; }
clock_shown() { vekrona-dev see text "$CLOCK_HOURS:($CLOCK_BEFORE|$(clock_minute_pattern))"; }
danger_pixels() { python3 "$ROOT/tests/e2e/screen_colors.py" bar-count "$(vekrona-dev shot)" "$DANGER_HEX" "$BAR_HEIGHT_PX"; }
badge_hidden() { (($(danger_pixels) == 0)); }
badge_shown() { (($(danger_pixels) >= BADGE_MIN_PIXELS)); }
workspace_two_focused() {
  [[ "$(vekrona-dev sh swaymsg -t get_workspaces | jq -r '.[] | select(.focused) | .num')" == 2 ]]
}
export -f clock_minute_pattern clock_shown danger_pixels badge_hidden badge_shown workspace_two_focused

vekrona-dev session
clear_notifications

shell_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-shell.service; }
export -f shell_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_active
log "ok: the vekrona shell runs"

vekrona-dev move 100 400
CLOCK_BEFORE="$(clock_minute_pattern)"
export CLOCK_BEFORE CLOCK_HOURS OCR_ZERO
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_shown
log "ok: the bar shows the current time"

# The watcher rewrites the unread count whenever it records an error, e.g. the failed units it replays after a session restart.
# The scenario leaves the watcher running, the unread count real again, and the first desktop in front.
cleanup() {
  vekrona-dev sh systemctl --user start vekrona-errors.service
  vekrona-dev sh vekrona-error refresh-unread
  vekrona-dev sh swaymsg workspace number 1 >/dev/null
}
trap cleanup EXIT
vekrona-dev sh systemctl --user stop vekrona-errors.service
vekrona-dev sh bash -c 'mkdir -p ~/.local/state/vekrona/errors && echo 0 > ~/.local/state/vekrona/errors/unread'
export ROOT DANGER_HEX BAR_HEIGHT_PX BADGE_MIN_PIXELS
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badge_hidden
vekrona-dev sh bash -c 'echo 123 > ~/.local/state/vekrona/errors/unread'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badge_shown
log "ok: the agent badge appears when errors are unread"

read -r x y <<<"$(vekrona-dev see find '^2$')"
[[ -n "${x:-}" && -n "${y:-}" ]] || die "the bar must show desktop 2, but OCR found no such text to click"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- workspace_two_focused
log "ok: clicking a desktop's number focuses that desktop"
