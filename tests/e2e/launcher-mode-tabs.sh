#!/usr/bin/env bash
# The strip under the search field has one tab per mode: Apps, Calculator, Search, Clipboard, a gap, Settings, Power.
# The launcher's state says where each tab is and which one is lit, so nothing here knows the strip's layout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
CLIP_ENTRY=vekrona-tab-clip

export CLIP_ENTRY

# The launcher is open in the mode $1 with only the tab $2 lit (by default the mode's own tab).
in_mode() { launcher_is ".open and .mode == \"$1\"" && launcher_tab_lit "${2-$1}"; }
query_is() { launcher_is ".open and .query == \"$1\""; }
stored() { vekrona-dev sh bash -c 'cliphist list | grep -qF "$1"' _ "$CLIP_ENTRY"; }
clip_listed() { launcher_is '.mode == "clip" and (.selectedId | startswith("clip:"))'; }
settings_listed() { launcher_is '.mode == "settings" and .view == "" and .selectedId == "settings:theme"'; }
night_selected() { launcher_is '.mode == "settings" and .selectedId == "settings:night"'; }
audio_view() { launcher_is '.mode == "settings" and (.view | endswith("Audio output"))' && launcher_tab_lit settings; }
export -f in_mode query_is stored clip_listed settings_listed night_selected audio_view

# Waits for the mode $1 with only the tab $2 lit; $3 says what has just happened.
expect_mode() {
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- in_mode "$1" "$2" || { launcher_state; die "the launcher must be open in mode '$1' with only the tab '$2' lit: $3"; }
}
# Waits for the check $2... to hold; $1 says what it must show.
expect_that() {
  local what="$1"
  shift
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$@" || { launcher_state; die "$what"; }
}

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
vekrona-dev sh bash -c 'printf %s "$1" | wl-copy >/dev/null 2>&1' _ "$CLIP_ENTRY"
expect_that "the clipboard history must record $CLIP_ENTRY" stored

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
expect_mode "" "" "Super+Space opens the launcher on the Apps tab"
log "ok: the launcher opens on Apps, the root mode"

click_launcher_tab clip
expect_mode clip clip "a click on the Clipboard tab"
expect_that "the Clipboard tab must list the clipboard history" clip_listed
log "ok: a click on the Clipboard tab opens /clip, lists the history and lights the tab"

click_launcher_tab clip
expect_mode clip clip "a click on the lit tab"
log "ok: a click on the lit tab keeps the launcher open in its mode"

click_launcher_tab ""
expect_mode "" "" "a click on the Apps tab"
log "ok: a click on Apps returns to the root mode"

vekrona-dev key tab
vekrona-dev key right
vekrona-dev key right
vekrona-dev key ret
expect_mode search search "Tab, Right, Right, Enter from the Apps tab"
log "ok: Tab enters the strip on the lit tab, Right moves along it and Enter opens the focused tab"

vekrona-dev key tab
vekrona-dev key left
vekrona-dev key spc
expect_mode calc calc "Tab, Left, Space from the Search tab"
log "ok: Tab enters the strip on the lit tab, not on the first one, and Space opens the focused tab"

vekrona-dev key tab
vekrona-dev key esc
vekrona-dev type hello
expect_that "Escape in the strip must hand focus back to the search field, which then takes what is typed" query_is hello
vekrona-dev key ctrl-a
vekrona-dev key backspace
vekrona-dev key backspace
expect_mode "" "" "Backspace on an empty query leaves the mode"
log "ok: Escape in the strip returns to the search field and keeps the launcher open"

vekrona-dev key shift-tab
vekrona-dev key right
vekrona-dev key right
vekrona-dev key ret
expect_mode search search "Shift+Tab, Right, Right, Enter from the search field"
vekrona-dev key backspace
expect_mode "" "" "Backspace on an empty query leaves the mode"
log "ok: Shift+Tab from the search field enters the strip too"

vekrona-dev type '/calc '
expect_mode calc calc "typing /calc and a space"
vekrona-dev key backspace
expect_mode "" "" "Backspace on an empty query leaves the mode"
log "ok: typing /calc lights the Calculator tab"

vekrona-dev type '/apps '
expect_mode apps "" "typing /apps and a space"
vekrona-dev key backspace
expect_mode "" "" "Backspace on an empty query leaves the mode"
log "ok: /apps lights the Apps tab"

vekrona-dev type '/cal'
vekrona-dev key tab
expect_mode calc calc "Tab on the /calc mode suggestion"
vekrona-dev key backspace
expect_mode "" "" "Backspace on an empty query leaves the mode"
log "ok: Tab on a mode suggestion enters the mode instead of the strip"

click_launcher_tab settings
expect_mode settings settings "a click on the Settings tab"
expect_that "the Settings tab must list the settings, starting with the theme" settings_listed
vekrona-dev key down
expect_that "the settings list must have the night light right after the theme" night_selected
log "ok: the Settings tab lists the settings"

vekrona-dev sh qs -c vekrona-shell ipc call launcher settings audio
expect_that "ipc call launcher settings audio must push the Audio output view under the lit Settings tab" audio_view
click_launcher_tab settings
expect_that "a click on the lit Settings tab inside a sub-view must return to the settings list" settings_listed
log "ok: a click on the lit tab inside a sub-view returns to the mode's list"

click_launcher_tab power
expect_mode power power "a click on the Power tab"
log "ok: the Power tab opens /power"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
vekrona-dev key super-spc
expect_mode "" "" "opening the launcher again after it was closed in /power"
log "ok: the launcher opens on Apps again"
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
