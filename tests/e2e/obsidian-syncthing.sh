#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90

# The GUI has a login (stage 50), so the request signs in with the stored password.
syncthing_gui_answers() { vekrona-dev run bash -c 'curl -fsS -u "vekrona:$(<"$HOME/.local/state/vekrona/syncthing-gui-password")" http://127.0.0.1:8384/ | grep -q Syncthing'; }
export -f syncthing_gui_answers

obsidian_stopped() { flatpak_stopped md.obsidian.Obsidian; }
export -f obsidian_stopped
# The windows this scenario opens go again, so the next scenario starts on an empty desktop.
close_windows() {
  if ! window_closed vekrona-syncthing; then vekrona-dev sh swaymsg '[app_id="vekrona-syncthing"] kill' >/dev/null; fi
  obsidian_stopped || vekrona-dev run flatpak kill md.obsidian.Obsidian
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_closed vekrona-syncthing
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- obsidian_stopped
}

vekrona-dev session
trap close_windows EXIT

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- syncthing_gui_answers
log "ok: the Syncthing daemon serves its GUI on 127.0.0.1:8384"

vekrona-dev sh swaymsg exec vekrona-webapp syncthing >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open vekrona-syncthing
log "ok: the Syncthing webapp opens its own window"

vekrona-dev sh swaymsg exec "flatpak run md.obsidian.Obsidian" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open md.obsidian.Obsidian
log "ok: Obsidian opens a window"
