#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# shellcheck disable=SC2016 # $HOME expands in the guest
GUEST_SETTINGS='$HOME/.config/DankMaterialShell/settings.json'

# OCR cannot read the badge's dark text on its danger fill, so the badge is found by its fill: half of an icon-s square.
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
BADGE_MIN_PIXELS=$((ICON_S_PX * ICON_S_PX / 2))

# OCR reads the clock's leading zero as 9 or O, so any two characters stand for the hour.
CLOCK_HOURS='..'

clock_shown() {
  local after
  after="$(vekrona-dev run date +%M)"
  vekrona-dev see text "$CLOCK_HOURS:($CLOCK_BEFORE|$after)"
}
danger_pixels() { python3 "$ROOT/tests/e2e/screen_colors.py" bar-count "$(vekrona-dev shot)" "$DANGER_HEX" "$BAR_HEIGHT_PX"; }
badge_hidden() { (($(danger_pixels) == 0)); }
badge_shown() { (($(danger_pixels) >= BADGE_MIN_PIXELS)); }
workspace_two_focused() {
  [[ "$(vekrona-dev sh swaymsg -t get_workspaces | jq -r '.[] | select(.focused) | .num')" == 2 ]]
}
export -f clock_shown danger_pixels badge_hidden badge_shown workspace_two_focused

vekrona-dev session
vekrona-dev run bash -c "test -s $GUEST_SETTINGS" || die "DMS settings $GUEST_SETTINGS are missing: install did not seed them"

shell_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-shell.service; }
export -f shell_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_active
log "ok: the vekrona shell runs"

enabled="$(vekrona-dev sh bash -c "jq -c '[.barConfigs[] | select(.enabled != false) | .name]' $GUEST_SETTINGS")"
[[ "$enabled" == '[]' ]] || die "every DMS bar must be disabled so the shell's bar is the only one, but these are enabled: $enabled"
log "ok: the DMS bar is off"

vekrona-dev move 100 400
CLOCK_BEFORE="$(vekrona-dev run date +%M)"
export CLOCK_BEFORE CLOCK_HOURS
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_shown
log "ok: the bar shows the current time"

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
