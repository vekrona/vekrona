#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"

STEP_TIMEOUT_SEC=60
# shellcheck disable=SC2016 # $HOME expands in the guest
GUEST_SETTINGS='$HOME/.config/DankMaterialShell/settings.json'
ID_OF='def id: if type == "string" then . else .id end;'

bars_failing() { vekrona-dev sh bash -c "jq -c '$ID_OF .barConfigs[] | $1' $GUEST_SETTINGS"; }

clock_shown() {
  local after
  after="$(vekrona-dev run date +%H:%M)"
  vekrona-dev see text "($CLOCK_BEFORE|$after)"
}
dash_open() { vekrona-dev see text 'wallpapers'; }
export -f clock_shown dash_open

vekrona-dev session
vekrona-dev run bash -c "test -s $GUEST_SETTINGS" || die "DMS settings $GUEST_SETTINGS are missing: install did not seed them"

found="$(bars_failing 'select((.leftWidgets | map(id)) as $w | ($w | index("vekronaSwayWorkspaces")) as $i | $i == null or $w[$i + 1] != "separator") | {name, leftWidgets}')"
[[ -z "$found" ]] || die "every bar must have a separator right after vekronaSwayWorkspaces in leftWidgets, but these do not: $found"
log "ok: every bar separates the sway workspaces from the next widget"

found="$(bars_failing 'select((.centerWidgets | map(id)) as $w | ($w | index("vekronaClock")) == null or ($w | index("vekronaWeather")) == null or ($w | index("clock")) != null or ($w | index("weather")) != null) | {name, centerWidgets}')"
[[ -z "$found" ]] || die "every bar must center vekronaClock and vekronaWeather and no stock clock or weather, but these do not: $found"
log "ok: every bar centers the vekrona clock and weather instead of the stock ones"

found="$(bars_failing '[.rightWidgets[] | select(id == "controlCenterButton")] as $c | select(($c | length) != 2 or ([$c[] | select(type == "object" and .showAudioIcon == false)] | length) != 1 or ([$c[] | select(type == "object" and .showAudioIcon == true and .showNetworkIcon == false)] | length) != 1) | {name, controlCenterButtons: $c}')"
[[ -z "$found" ]] || die "every bar must have two controlCenterButton entries, one without the audio icon and one with the audio icon but no network icon, but these do not: $found"
log "ok: every bar splits the control center into a network button and an audio button"

gap="$(vekrona_design_get gap)"
spacing="$(vekrona-dev sh bash -c "jq -r .trayIconSpacing $GUEST_SETTINGS")"
[[ "$spacing" == "$gap" ]] || die "trayIconSpacing must equal the design gap $gap, but it is $spacing"
log "ok: tray icons are spaced by the design gap"

vekrona-dev move 100 400
CLOCK_BEFORE="$(vekrona-dev run date +%H:%M)"
export CLOCK_BEFORE
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- clock_shown
read -r x y <<<"$(vekrona-dev see find "($CLOCK_BEFORE|$(vekrona-dev run date +%H:%M))")"
[[ -n "${x:-}" && -n "${y:-}" ]] || die "the bar must show the guest time $CLOCK_BEFORE, but OCR found no such text to click"
log "ok: DMS renders the vekrona clock with the current time"

vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dash_open
vekrona-dev key esc
log "ok: clicking the clock opens the dash overview"
