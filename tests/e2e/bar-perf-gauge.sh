#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=90
# The VM is idle once the session has settled, so the CPU bar sits far below half. Right after the session starts the guest
# is busy, and the shell's first CPU sample only primes its counters, so the bar is waited on, not read once. Pinned cores
# fill it to the top: 90 allows for the rounding of a bar 14 px tall and for a core that the load leaves a moment to the shell itself.
IDLE_FILL_BELOW=50
LOADED_FILL_FROM=90
GUEST_LOAD_OUT=/tmp/bar-perf-gauge-load.log

load_shown() { bar_widget center load >/dev/null; }
cpu_fill() {
  local gauge
  gauge="$(bar_widget gauge)"
  echo "${gauge% *}"
}
cpu_idle() { (($(cpu_fill) < IDLE_FILL_BELOW)); }
cpu_loaded() { (($(cpu_fill) >= LOADED_FILL_FROM)); }
export -f load_shown cpu_fill cpu_idle cpu_loaded
export IDLE_FILL_BELOW LOADED_FILL_FROM

stop_load() {
  local status=0
  vekrona-dev run pkill -x yes || status=$?
  ((status <= 1)) || warn "could not stop the CPU load in the guest: pkill -x yes (exit $status)"
}
trap stop_load EXIT

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- load_shown || die "the bar never showed the load widget (one frame split by a single line)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- cpu_idle || die "the CPU bar stayed at $(cpu_fill)% in an idle guest, so it cannot show the load rising"
idle_edge="$(settled_bar_left_edge)"
log "ok: at idle the CPU bar is below $IDLE_FILL_BELOW% (now $(cpu_fill)%) and the right side of the bar starts at x=$idle_edge"

vekrona-dev spawn "$GUEST_LOAD_OUT" -- bash -c 'for _ in $(seq "$(nproc)"); do yes >/dev/null & done; wait'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- cpu_loaded || die "the CPU bar never filled to $LOADED_FILL_FROM% under full load, it stayed at $(cpu_fill)%"
loaded_edge="$(bar_left_edge)"
log "ok: under full load the CPU bar is $(cpu_fill)% full and the right side of the bar starts at x=$loaded_edge"

[[ "$idle_edge" == "$loaded_edge" ]] || die "the load changed the width of its widget: the right side of the bar started at x=$idle_edge at idle and x=$loaded_edge under load"
log "ok: the load widget keeps its width while its bars fill"
