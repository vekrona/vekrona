#!/usr/bin/env bash
# A device that is not nearby is paired by typing its ID into the field of the popout's "Pair another device…" section, with real
# key presses: what is no device ID is refused with Syncthing's reason in the popout, and the right ID (in whatever spelling a
# person pastes it: lower case, no dashes) adds the device, which then asks this computer back and is online once it accepts. The
# other device is a second Syncthing in a network namespace of the guest (tests/e2e/lib/sync-peer.sh).
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
PEER_ID=
export PEER_ID

only_this_computer() { [[ "$(main_rest GET /rest/config/devices | jq length)" == 1 ]]; }
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

open_popout
click_word '^another$'
click_word '^Paste$'
vekrona-dev type lizard
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'incorrect length'
snap paste-refused
only_this_computer || die "a word that is no device ID must add no device"
log "ok: a word that is no device ID is refused with Syncthing's reason in the popout, and adds nothing"

# The same ID with its last character changed: the right length, and the check digit gives it away.
SPOILT="${PEER_ID%?}$([[ "${PEER_ID: -1}" == A ]] && echo B || echo A)"
vekrona-dev key ctrl-a
vekrona-dev type "$SPOILT"
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'check digit incorrect'
only_this_computer || die "an ID with a wrong check digit must add no device"
log "ok: an ID with a wrong check digit is refused, and adds nothing"

vekrona-dev key ctrl-a
TYPED_ID="${PEER_ID//-/}"
vekrona-dev type "${TYPED_ID,,}"
vekrona-dev key tab
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- peer_has_pending_device
log "ok: the ID in lower case without dashes pairs the device (Tab to the Pair button and Enter), which then sees the request"

peer_accepts_pending_device
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer and .connected)'
log "ok: the device is online once it accepts"
