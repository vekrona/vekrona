#!/usr/bin/env bash
# A VPN comes up from a configuration the user imported and from a Mullvad account, through the commands the bar's VPN popout runs
# (the popout shows exactly what `vekrona-vpn list` says and runs `connect` and `off`), and goes away again:
#   - a configuration of another provider (Proton's download, say) imports under its country, is listed, and `connect` arms the kill switch and brings the tunnel up:
#     the exit address is not the guest's own, status says armed and up, and /run/vekrona-vpn/state.json (root-owned, readable)
#     says the same;
#   - Mullvad: logging in with the account number registers a device, `connect mullvad se` picks a relay of Sweden, Mullvad says
#     "You are connected to Mullvad", and the exit address changed again;
#   - `off` takes the tunnel down and removes the kill switch: the exit address is the guest's own again.
# Needs credentials on the host (tests/e2e/lib/vpn.sh); without them the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

require_vpn_conf
require_vpn_account

mullvad_says_connected() { vekrona-dev run curl -4 -sS --max-time 20 https://am.i.mullvad.net/connected | grep -q 'You are connected to Mullvad'; }
state_file_says() { vekrona-dev run jq -e "$1" /run/vekrona-vpn/state.json >/dev/null; }
export -f mullvad_says_connected state_file_says

vekrona-dev session
trap vpn_cleanup EXIT
vpn_cleanup
OWN_IP="$(guest_exit_ip)"
log "the guest's own exit address is $OWN_IP"

UUID="$(vpn_import_conf_uuid)"
COUNTRY="$(vpn list | jq -r --arg uuid "$UUID" '.vendors[] | select(.id == "other") | .countries[] | select(any(.configs[]; .uuid == $uuid)) | .code')"
log "the configuration is listed under other, country $COUNTRY"

vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
vpn_status_is ".armed and .connection.uuid == \"$UUID\" and .connection.vendor == \"other\"" || die "status must say armed and name the connection: $(vpn_status)"
[[ "$(vekrona-dev run stat -c '%U %a' /run/vekrona-vpn/state.json)" == "root 644" ]] || die "state.json must be root-owned and world-readable"
state_file_says ".armed == true and .uuid == \"$UUID\"" || die "state.json must say the same as status"
PROTON_IP="$(guest_exit_ip)"
[[ "$PROTON_IP" != "$OWN_IP" ]] || die "the exit address is still the guest's own ($OWN_IP) with the tunnel up"
log "ok: the configuration connects through $COUNTRY, the exit address is $PROTON_IP and the kill switch is armed"

vpn_mullvad_login
vpn list | jq -e '.vendors[] | select(.id == "mullvad") | .countries | any(.[]; .code == "SE")' >/dev/null || die "Mullvad's relay list must name Sweden"
vpn_status_is '.mullvad.logged_in' || die "status must say that Mullvad is logged in"
vpn connect mullvad se
vpn_record_made "$(vpn_status | jq -r '.connection.uuid // empty')"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
vpn_status_is '.connection.vendor == "mullvad" and .connection.country == "SE" and .armed' || die "status must name the Mullvad connection in SE: $(vpn_status)"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- mullvad_says_connected
MULLVAD_IP="$(guest_exit_ip)"
[[ "$MULLVAD_IP" != "$OWN_IP" && "$MULLVAD_IP" != "$PROTON_IP" ]] || die "the exit address must change again for Mullvad: $MULLVAD_IP"
log "ok: Mullvad connects through Sweden, Mullvad says so and the exit address is $MULLVAD_IP"

vpn off
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_down
vpn_status_is '.armed | not' || die "off must remove the kill switch: $(vpn_status)"
absent vekrona-dev run sudo nft list table inet vekrona-vpn || die "the kill switch table must be gone after off"
[[ "$(guest_exit_ip)" == "$OWN_IP" ]] || die "the exit address must be the guest's own again after off"
state_file_says '.armed == false and .uuid == null' || die "state.json must say disarmed after off"
log "ok: off takes the tunnel down and removes the kill switch"
