#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
LEFT_EDGE="$ROOT/tests/e2e/bar-left-edge.py"
# A CPU pinned at full load reads 100 % (or 9x % when a sample straddles the start). OCR reads the slashed zero as O.
# The sound pill reads 100 % at full volume, so the load shows as one more match than at idle.
LOADED_REGEX="(1[0O][0O]|9[0-9]) ?%"
GUEST_LOAD_OUT=/tmp/bar-perf-width-load.log

left_edge() { python3 "$LEFT_EDGE" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$ICON_S_PX"; }
# grep exits 1 when nothing matches, which is a count of 0.
loaded_count() { vekrona-dev see ocr | { grep -Eoi "$LOADED_REGEX" || (($? == 1)); } | wc -l; }
load_shown() { (($(loaded_count) > IDLE_LOADED_COUNT)); }
export -f loaded_count load_shown
export LOADED_REGEX

stop_load() {
  local status=0
  vekrona-dev run pkill -x yes || status=$?
  ((status <= 1)) || warn "could not stop the CPU load in the guest: pkill -x yes (exit $status)"
}
trap stop_load EXIT

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev see text "%"
IDLE_LOADED_COUNT="$(loaded_count)"
export IDLE_LOADED_COUNT
idle_edge="$(left_edge)"
log "ok: at idle the right side of the bar starts at x=$idle_edge"

vekrona-dev spawn "$GUEST_LOAD_OUT" -- bash -c 'for _ in $(seq "$(nproc)"); do yes >/dev/null & done; wait'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- load_shown || die "the bar never showed the CPU load rising to 90 % or more"
loaded_edge="$(left_edge)"
log "ok: under load the right side of the bar starts at x=$loaded_edge"

[[ "$idle_edge" == "$loaded_edge" ]] || die "the CPU and RAM values changed the width of their pills: the right side of the bar started at x=$idle_edge at idle and x=$loaded_edge under load"
log "ok: the Perf pills keep their width while their values change"
