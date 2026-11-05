#!/usr/bin/env bash
# Nearby lists only devices that are there. Syncthing's discovery cache never forgets a device that announced itself (its REST
# answer carries no time, and no entry expires), so the list of sync.json keeps a device that has left, and the popout asks
# `vekrona-sync nearby`, which tries the TCP addresses the device announced, whenever it opens. The other device is a second
# Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh):
#   - while it runs, the popout lists it under Nearby;
#   - when its Syncthing stops (its address refuses the connection), Syncthing still lists it, and the popout does not;
#   - when it starts again, the popout lists it again, without a restart of anything on the guest;
#   - when its network is gone (nothing answers, the connect times out), the popout does not list it, and the command is
#     done within seconds.
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
# The command waits one second for a device that does not answer.
NEARBY_COMMAND_SEC=5
PEER_ID=
export PEER_ID NEARBY_COMMAND_SEC

nearby_ids() { vekrona-dev run timeout "$NEARBY_COMMAND_SEC" vekrona-sync nearby; }
nearby_is_the_peer() { [[ "$(nearby_ids)" == "$PEER_ID" ]]; }
nearby_is_empty() { [[ -z "$(nearby_ids)" ]]; }
syncthing_remembers_the_peer() { [[ "$(main_rest GET /rest/system/discovery | jq --arg id "$PEER_ID" 'has($id)')" == true ]]; }
export -f nearby_ids nearby_is_the_peer nearby_is_empty syncthing_remembers_the_peer
cleanup() { run_cleanups close_popout peer_stop main_forget_peers; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | map(.id) == [$peer]'
nearby_is_the_peer || die "the device that runs must be among the nearby devices that answer, but the command printed: $(nearby_ids)"
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_row_shown
snap nearby-there
log "ok: while the other device runs the popout lists it under Nearby"
close_popout

peer_kill syncthing
syncthing_remembers_the_peer || die "Syncthing must still remember the device that stopped, or this scenario proves nothing"
state_is '.nearby | map(.id) == [$peer]' || die "sync.json must still list the device that stopped, or this scenario proves nothing"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_is_empty
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Share a folder'
# Syncthing's list is in sync.json before the popout opens, so a popout that showed it unchecked would show the row in the very
# frame in which "Share a folder" is first readable.
absent nearby_row_shown || die "the popout must not list a device whose Syncthing has stopped"
snap nearby-stopped
log "ok: a device that stopped answering stays in Syncthing's cache and is not listed under Nearby"
close_popout

peer_syncthing_start
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_is_the_peer
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_row_shown
snap nearby-back
log "ok: when the other device is back the popout lists it again, with nothing restarted on the guest"
close_popout

peer_net_down
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nearby_is_empty
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Share a folder'
absent nearby_row_shown || die "the popout must not list a device whose network is gone"
log "ok: a device whose address does not answer at all is not listed either, and the command ends within $NEARBY_COMMAND_SEC s"
