#!/usr/bin/env bash
# The watcher is a long-running process that keeps the code it started with, while the shell reads the checkout's QML at once, so
# after an update the shell can meet a sync.json of an older layout (that is what an empty Nearby list was on a host). The shell
# then says in words that the sync service is out of date and how to restart it, shows the problem icon rather than the offline
# one, and logs it (which the error pipeline records); restarting the service makes the popout normal again. The other side of the
# same contract: a stage 50 run restarts the watcher, so no install leaves old code running. No other device is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/sync-popout.sh
source "$ROOT/tests/e2e/lib/sync-popout.sh"

STEP_TIMEOUT_SEC=90
# The layout from before sync.json had a schema and a nearby list.
OLD_LAYOUT='{"state": "idle", "problem": null, "folders": [], "offers": [], "pendingDevices": [], "devices": [], "arrivals": []}'
export OLD_LAYOUT

old_layout_written() { vekrona-dev run bash -c 'printf %s "$1" >"$HOME/.local/state/vekrona/sync.json"' _ "$OLD_LAYOUT"; }
schema_errors() { shell_log_count 'sync.json has schema'; }
watcher_stopped() { absent watcher_active; }
export -f schema_errors watcher_stopped
cleanup() { run_cleanups close_popout 'vekrona-dev sh systemctl --user start vekrona-sync.service'; }

vekrona-dev session
trap cleanup EXIT
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
before="$(schema_errors)"
vekrona-dev sh systemctl --user stop vekrona-sync.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_stopped
old_layout_written

open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'out of date'
text_shown 'restart vekrona-sync' || die "the message must say how to restart the service"
text_absent 'not reachable' || die "an old layout is no offline Syncthing, and must not say so"
snap out-of-date
(("$(schema_errors)" > before)) || die "the shell must log the mismatch, which is how the error pipeline records it"
state_is '.schema == null' || die "the scenario's own old-layout file must still be in place, or it proves nothing"
log "ok: a sync.json of another layout shows that the sync service is out of date, in words, and is logged"
close_popout

vekrona-dev sh systemctl --user start vekrona-sync.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.schema | type == "number"'
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'out of date'
log "ok: with the service restarted the file has the schema and the popout is normal again"
