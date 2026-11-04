#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90

# The daemon's REST API listens on a unix socket with no login (stage 50); the API key in config.xml is what its REST calls carry.
syncthing_answers() {
  vekrona-dev run bash -c '
config="$(syncthing paths | awk "/^Configuration file:/ { getline; print \$1; exit }")"
key="$(sed -n "s|.*<apikey>\(.*\)</apikey>.*|\1|p" "$config")"
curl -fsS --unix-socket "/run/user/$(id -u)/syncthing/gui.sock" -H "X-API-Key: $key" http://localhost/rest/system/ping | grep -q pong'
}
export -f syncthing_answers

obsidian_stopped() { flatpak_stopped md.obsidian.Obsidian; }
export -f obsidian_stopped
# The window this scenario opens goes again, so the next scenario starts on an empty desktop.
close_windows() {
  obsidian_stopped || vekrona-dev run flatpak kill md.obsidian.Obsidian
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- obsidian_stopped
}

vekrona-dev session
trap close_windows EXIT

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- syncthing_answers
log "ok: the Syncthing daemon answers its REST API on its socket"

vekrona-dev sh swaymsg exec "flatpak run md.obsidian.Obsidian" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open md.obsidian.Obsidian
log "ok: Obsidian opens a window"
