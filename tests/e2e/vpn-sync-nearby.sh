#!/usr/bin/env bash
# With the VPN on, Syncthing's local discovery still finds a device on the local network: the kill switch lets its broadcast and the
# connections to the local network through, while everything else stays shut. The other device is a second Syncthing in a network
# namespace of the guest (tests/e2e/lib/sync-peer.sh), as in the Sync scenarios.
# Needs a Proton configuration on the host (tests/e2e/lib/vpn.sh); without it the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

STEP_TIMEOUT_SEC=90
PEER_ID=
export PEER_ID

require_vpn_conf

cleanup() { run_cleanups peer_stop main_forget_peers vpn_cleanup; }

vekrona-dev session
trap cleanup EXIT
vpn_cleanup
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
vpn_status_is '.armed' || die "the VPN must be armed for this scenario: $(vpn_status)"

main_forget_peers
main_syncthing_restart
peer_start
PEER_ID="$(peer_id)"
export PEER_ID

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.nearby | any(.[]; .id == $peer)'
log "ok: with the VPN on, the device on the local network is found by local discovery"

peer_adds_device "$(main_id)"
main_rest POST /rest/config/devices "$(jq -nc --arg id "$PEER_ID" '{deviceID: $id, name: "e2e-vpn-peer"}')" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- state_is '.devices | any(.[]; .id == $peer and .connected)'
log "ok: with the VPN on, the two devices connect over the local network"
