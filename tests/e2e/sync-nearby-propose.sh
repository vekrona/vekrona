#!/usr/bin/env bash
# A Syncthing device that appears on the network is proposed to the user without opening the popout, once. The other device is a
# second Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh).
#   - the notification "A Syncthing device <code> is nearby" comes by itself, with Not now, Pair and Ignore, and the device has a
#     dot in sync.json (the bar's Sync dot counts it) until the popout is opened;
#   - Pair in the notification (clicked by OCR) sends the request, a notification says "Pair request sent to <code>", the other
#     device accepts, the popout lists it Online under My devices, and a notification says that it is now one of the devices;
#   - another device that appears and gets Not now is not proposed again when it is announced again (its Syncthing restarts,
#     which Syncthing reports as a new discovery), and stays under Nearby with its dot until the popout is opened;
#   - a third device that gets Ignore is never Nearby and never proposed again.
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
RETRY_WINDOW_SEC=30
PEER_ID=
export PEER_ID

proposed_in_centre() { text_shown 'is nearby'; }
export -f proposed_in_centre
cleanup() { run_cleanups close_popout close_notification_centre peer_stop main_forget_peers; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
main_forget_peers
main_syncthing_restart
# The ledger of what was proposed outlives the watcher: this scenario starts without it.
vekrona-dev run bash -c 'rm -f "$HOME/.local/state/vekrona/sync.json"'
vekrona-dev sh systemctl --user restart vekrona-sync.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
peer_start
PEER_ID="$(peer_id)"
export PEER_ID

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | any(.[]; .id == $peer and .unseen)'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proposed_in_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Pair with it'
snap proposed
log "ok: the device that appears is proposed in a notification without the popout open, and carries a dot"

click_word '^Pair$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Pair request sent'
snap pair-sent
log "ok: Pair in the notification asks the other device, and a notification says that the request is on its way"

peer_accepts_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer and .connected)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'is now one of your devices'
snap connected
close_notification_centre
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Online'
close_popout
log "ok: once the other device accepts, My devices lists it Online and a notification says that it is one of the devices"

# A second device. Not now, then it is announced again.
clear_notifications
peer_replace
PEER_ID="$(peer_id)"
export PEER_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | any(.[]; .id == $peer and .unseen)'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proposed_in_centre
click_word '^Not$'
close_notification_centre
clear_notifications
peer_kill syncthing
peer_syncthing_start
open_notification_centre
stays_absent "$RETRY_WINDOW_SEC" proposed_in_centre || die "a device that got Not now must not be proposed again when it is announced again"
close_notification_centre
state_is '.nearby | any(.[]; .id == $peer and .unseen)' || die "a device that got Not now must keep its dot until the popout is opened"
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Syncthing device'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | any(.[]; .id == $peer and (.unseen | not))'
close_popout
log "ok: Not now proposes it no more, it stays under Nearby with its dot, and opening the popout clears the dot"

# A third device. Ignore.
clear_notifications
peer_replace
PEER_ID="$(peer_id)"
export PEER_ID
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | any(.[]; .id == $peer)'
open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proposed_in_centre
click_word '^Ignore$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_ignored_on_main "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | map(.id) | index($peer) == null'
close_notification_centre
log "ok: Ignore puts the device on the ignored list, and it is no longer Nearby"
