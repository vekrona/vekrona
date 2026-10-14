#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# systemd orders every .path, .timer and .socket unit Before= paths.target, timers.target or sockets.target, and
# those targets come after basic.target. A session target stops before basic.target does, so an After=<session target>
# on such a unit closes a cycle at logout ("basic.target: Found ordering cycle ... Job graphical-session.target/stop
# deleted"). PartOf= and WantedBy= already tie these units to the session.
session_targets='(sway|graphical)-session(-pre)?\.target'

shopt -s nullglob
units=("$ROOT"/config/systemd-user/*.path "$ROOT"/config/systemd-user/*.timer "$ROOT"/config/systemd-user/*.socket)
[[ ${#units[@]} -gt 0 ]] || die "no user .path, .timer or .socket unit found: the test looks in the wrong place"

for unit in "${units[@]}"; do
  if grep -En "^After=.*${session_targets}" "$unit"; then
    die "$(basename "$unit") is ordered After= a session target, which makes an ordering cycle at logout"
  fi
done
log "ok: no user .path, .timer or .socket unit is ordered after a session target"
