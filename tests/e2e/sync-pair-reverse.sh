#!/usr/bin/env bash
# The other device adds this computer first, with an ID that it got from the QR code on this computer's screen (no discovery on
# its side tells it anything it did not see there): this computer gets the request as a notification and under "New devices" in the
# Sync popout, Accept connects them, and a second device that is Rejected is ignored for good: it asks no more, is no longer
# Nearby, and can still be paired on purpose by typing its ID into the popout's field. The other device is a second Syncthing in a
# network namespace of the guest (tests/e2e/lib/sync-peer.sh).
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
SCREEN_GUEST_PNG=/tmp/vekrona-e2e-sync-screen.png
PEER_ID=
export PEER_ID

# The other device tries again, as a phone does when its user taps the device in its list: a new connection attempt at once.
peer_retries() {
  peer_rest DELETE "/rest/config/devices/$SCANNED" >/dev/null
  peer_adds_device "$SCANNED"
}
# What a phone's camera would read from the guest's screen: the QR codes in a screenshot, as the guest's zbarimg decodes them.
scanned_from_screen() {
  guest_write "$(vekrona-dev shot)" "$SCREEN_GUEST_PNG"
  vekrona-dev run zbarimg --quiet --raw "$SCREEN_GUEST_PNG"
}
cleanup() { run_cleanups close_popout close_notification_centre peer_stop main_forget_peers "vekrona-dev run rm -f $SCREEN_GUEST_PNG"; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
vekrona-dev run bash -c 'command -v zbarimg >/dev/null || sudo dnf -y install zbar >/dev/null'
main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID

open_popout
click_word '^another$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Copy ID'
scan_screen() { SCANNED="$(scanned_from_screen)" && [[ -n "$SCANNED" ]]; }
wait_until "$STEP_TIMEOUT_SEC" scan_screen || die "the popout's QR code was not readable from a screenshot"
snap qr-shown
[[ "$SCANNED" == "$(main_id)" ]] || die "the QR code on screen holds $SCANNED, not this computer's device ID $(main_id)"
log "ok: the QR code on the guest's screen reads as the guest's device ID"

peer_adds_device "$SCANNED"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.pendingDevices | any(.[]; .id == $peer)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'New devices'
log "ok: a device that adds this computer by its scanned ID is under New devices"

open_notification_centre
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'device code starts with'
close_notification_centre
log "ok: and in a notification with the code to compare"

clear_notifications
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'New devices'
snap new-device
click_word '^Accept$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_connected_on_main "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '(.pendingDevices == []) and (.devices | any(.[]; .id == $peer and .connected))'
snap accepted
log "ok: Accept connects the two, and the request is gone"

peer_replace
PEER_ID="$(peer_id)"
export PEER_ID
peer_adds_device "$SCANNED"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.pendingDevices | any(.[]; .id == $peer)'
main_rest DELETE "/rest/cluster/pending/devices?device=$PEER_ID" >/dev/null
peer_retries
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_pending_on_main "$PEER_ID"
log "ok: a device whose request was only cleared asks again at its next attempt (the control of the check below)"
clear_notifications
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'New devices'
click_word '^Reject$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_ignored_on_main "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.pendingDevices == []'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'New devices'
snap rejected
log "ok: Reject ignores the device for good, and the request leaves the popout"

[[ "$(main_rest GET /rest/system/discovery | jq --arg id "$PEER_ID" 'has($id)')" == true ]] || die "the rejected device must still announce itself, or the check that it is not Nearby proves nothing"
state_is '.nearby | map(.id) | index($peer) == null' || die "a rejected device must not be listed under Nearby"
peer_retries
stays_absent "$RETRY_WINDOW_SEC" device_pending_on_main "$PEER_ID" || die "a rejected device that asks again must not be asked about again"
state_is '(.pendingDevices == []) and (.nearby | map(.id) | index($peer) == null)' || die "a rejected device that asks again must not come back in the popout"
log "ok: a rejected device that retries is not asked about again, and is not Nearby"

absent_ignored() { absent device_ignored_on_main "$PEER_ID"; }
export -f absent_ignored
click_word '^another$'
click_word '^Paste$'
TYPED_ID="${PEER_ID//-/}"
vekrona-dev type "${TYPED_ID,,}"
snap typed-id
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent_ignored
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- device_connected_on_main "$PEER_ID"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent text_shown 'Paste a device ID'
log "ok: a rejected device is paired on purpose by typing its ID in lower case without dashes, which takes it off the ignored list"
