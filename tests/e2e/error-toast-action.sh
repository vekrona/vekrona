#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The watcher drops a repeat of a fingerprint within 10 minutes, and digits do not change a fingerprint, so each run needs fresh letters.
ERROR_TITLE="Vekrona e2e $(printf '%s%s' "$RANDOM" "$RANDOM" | tr 0-9 g-p)"

shown() { vekrona-dev see text "$1"; }
error_status() { vekrona-dev run bash -c "vekrona-error list --all | grep -F '$ERROR_TITLE' | awk '{print \$3}'"; }
error_muted() { [[ "$(error_status)" == muted ]]; }
export -f shown error_status error_muted
export ERROR_TITLE

remove_error() {
  local id fingerprint
  id="$(vekrona-dev run bash -c "vekrona-error list --all | grep -F '$ERROR_TITLE' | awk '{print \$1}'")"
  [[ -n "$id" ]] || return 0
  fingerprint="$(vekrona-dev run bash -c "vekrona-error show $id | sed -n 's/^fingerprint: //p'")"
  vekrona-dev run vekrona-error rm "$id"
  vekrona-dev run bash -c "touch ~/.config/vekrona/errors-mute && sed -i '/$fingerprint/d' ~/.config/vekrona/errors-mute"
}

vekrona-dev session
vekrona-dev move 100 500
clear_notifications
remove_error
trap remove_error EXIT

vekrona-dev run vekrona-error report --title "$ERROR_TITLE" --summary 'raised by an e2e scenario'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Fix with agent'
log "ok: a recorded error pops up with its actions"

read -r x y <<<"$(vekrona-dev see find '^Mute$')"
[[ -n "${x:-}" ]] || die "the error toast must show a Mute action, but OCR found none to click"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- error_muted
log "ok: clicking an action reaches vekrona-error, which mutes the error"
