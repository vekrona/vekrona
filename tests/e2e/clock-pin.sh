#!/usr/bin/env bash
# A test that moves the guest clock must not let the error watcher toast the record of lima's ssh noise again: without lima's guest agent
# sshd logs "connect to /run/lima-guestagent.sock" for every connection of the host, the jump makes that record long unseen, and the
# watcher toasts it at an arbitrary moment, over whatever the test clicks next (bar-caffeine lost a click to it, the agent picker opened).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

PINNED_NOW="2026-10-16 10:10:00"
WATCHER=vekrona-errors.service

watcher_state() { vekrona-dev sh systemctl --user is-active "$WATCHER" || [[ $? -eq 3 ]]; }
watcher_active() { [[ "$(watcher_state)" == active ]]; }
export -f watcher_state watcher_active
export WATCHER

vekrona-dev session
within() { vekrona-dev until --timeout 60 -- "$@"; }
within watcher_active
trap clock_restore EXIT

clock_pin "$PINNED_NOW"
[[ "$(watcher_state)" == inactive ]] || die "the error watcher must be stopped while the clock is pinned, but it is $(watcher_state)"
log "ok: the error watcher is stopped while the clock is pinned"

trap - EXIT
clock_restore
within watcher_active
log "ok: the error watcher runs again once the clock is real"
