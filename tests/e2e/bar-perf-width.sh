#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
# A CPU pinned at full load reads 100 %, the widest value, so the check covers a three-digit width. OCR reads the slashed zero as O.
# The sound pill reads 100 % at full volume, so the load shows as one more match than at idle.
LOADED_REGEX="1[0O][0O] ?%"
GUEST_LOAD_OUT=/tmp/bar-perf-width-load.log

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
idle_edge="$(settled_bar_left_edge)"
IDLE_LOADED_COUNT="$(loaded_count)"
export IDLE_LOADED_COUNT
log "ok: at idle the right side of the bar starts at x=$idle_edge"

vekrona-dev spawn "$GUEST_LOAD_OUT" -- bash -c 'for _ in $(seq "$(nproc)"); do yes >/dev/null & done; wait'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- load_shown || die "the bar never showed the CPU load rising to 100 %"
loaded_edge="$(bar_left_edge)"
log "ok: under load the right side of the bar starts at x=$loaded_edge"

[[ "$idle_edge" == "$loaded_edge" ]] || die "the CPU and RAM values changed the width of their pills: the right side of the bar started at x=$idle_edge at idle and x=$loaded_edge under load"
log "ok: the Perf pills keep their width while their values change"
