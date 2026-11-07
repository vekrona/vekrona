#!/usr/bin/env bash
# Importing a configuration while a tunnel is up leaves the tunnel alone. Every imported profile is born with autoconnect on and
# NetworkManager may bring it up at once; if it were born on the interface of the tunnel in use (vvpn0) it would replace that
# tunnel, and the kill switch would hold everything back with no tunnel behind it. The helper imports under a name of its own
# (vvpn-import) and only then gives the profile vvpn0, so:
#   - after the import of a second configuration the first connection is still the one in use, up and armed, and the exit address
#     is still not the guest's own;
#   - no profile named after the import is left in NetworkManager;
#   - the new configuration is listed and is not active.
# Needs a Proton configuration on the host (tests/e2e/lib/vpn.sh); without it the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

SECOND_NAME=SE-second
IMPORT_PROFILE=vvpn-import

import_profile_left() { vekrona-dev run bash -c 'nmcli -t -f NAME connection show | grep -qx "$1"' _ "$IMPORT_PROFILE"; }
second_uuid() {
  vpn list | jq -r --arg name "$SECOND_NAME" '[.vendors[] | select(.id == "proton") | .countries[].configs[] | select(.name == $name) | .uuid][0] // empty'
}

require_vpn_conf

vekrona-dev session
trap vpn_cleanup EXIT
vpn_cleanup
OWN_IP="$(guest_exit_ip)"
UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
[[ "$(guest_exit_ip)" != "$OWN_IP" ]] || die "the exit address is still the guest's own ($OWN_IP) with the tunnel up"

vpn_guest_write "$VPN_CONF" "$VPN_GUEST_DIR/$SECOND_NAME.conf"
vpn import --vendor proton "$VPN_GUEST_DIR/$SECOND_NAME.conf"

vpn_status_is ".tunnel == \"up\" and .armed and .connection.uuid == \"$UUID\"" \
  || die "importing a configuration must leave the tunnel in use alone: $(vpn_status)"
[[ "$(guest_exit_ip)" != "$OWN_IP" ]] || die "the exit address is the guest's own ($OWN_IP) after an import: the tunnel was replaced"
absent import_profile_left || die "a profile named $IMPORT_PROFILE is left in NetworkManager after the import"
SECOND="$(second_uuid)"
[[ -n "$SECOND" && "$SECOND" != "$UUID" ]] || die "the second configuration is not listed under its own uuid: '$SECOND'"
log "ok: importing $SECOND_NAME while $UUID is up leaves the tunnel up, and no import profile is left"
