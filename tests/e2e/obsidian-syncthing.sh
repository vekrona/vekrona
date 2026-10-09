#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90

window_open() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -e --arg c '$1' '[.. | objects | select((.app_id? == \$c) or (.window_properties?.class? == \$c))] | length > 0' >/dev/null"; }
syncthing_gui_answers() { vekrona-dev run curl -fsS http://127.0.0.1:8384/ | grep -q Syncthing; }
export -f window_open syncthing_gui_answers

vekrona-dev session

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- syncthing_gui_answers
log "ok: the Syncthing daemon serves its GUI on 127.0.0.1:8384"

vekrona-dev sh swaymsg exec vekrona-webapp syncthing >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open vekrona-syncthing
log "ok: the Syncthing webapp opens its own window"

vekrona-dev sh swaymsg exec "flatpak run md.obsidian.Obsidian" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open md.obsidian.Obsidian
log "ok: Obsidian opens a window"
