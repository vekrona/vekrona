#!/usr/bin/env bash
# While the VPN is on, whatever does not leave through the tunnel is rejected at once, not dropped, whether the tunnel is up or has
# gone:
#   - with the tunnel up, a DNS query to the local network's resolver is rejected, not answered and not left to time out;
#   - the tunnel interface is deleted (as a crash of it would): status says armed with the tunnel down, an address on the internet
#     is refused within a second (curl's connect fails, it does not run into its timeout), and so is the DNS query;
#   - the local network stays open: a web server on a veth network of its own is reachable;
#   - Tailscale's interface reaches the tailnet and nothing else. The guest has no tailnet, so a veth pair named tailscale0 with a
#     tailnet address stands in: its server is reachable, and an address outside the tailnet that a route sends through it (an
#     exit node) is rejected;
#   - `off` takes the kill switch away: the internet is reachable again and no table is left.
# Needs a Proton configuration on the host (tests/e2e/lib/vpn.sh); without it the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

TAILNET_SERVER=100.64.0.2
LAN_SERVER=10.78.0.2
OUTSIDE_ADDRESS=203.0.113.50

require_vpn_conf

gateway() { vekrona-dev run bash -c "ip -4 route show table main default | awk '{ print \$3; exit }'"; }
dns_query_rejected() {
  local resolver
  resolver="$(gateway)"
  [[ -n "$resolver" ]] || die "the guest has no IPv4 default route to find the local resolver by"
  vekrona-dev run python3 - "$resolver" <"$VPN_DNS_PROBE"
}
serves() { vekrona-dev run curl -sS --max-time 5 -o /dev/null "http://$1:8080/"; }
internet_reachable() { vekrona-dev run curl -4 -sS --max-time 10 -o /dev/null "$VPN_PROBE_URL_V4"; }
export -f gateway dns_query_rejected serves internet_reachable

vekrona-dev session
trap vpn_cleanup EXIT
vpn_cleanup
UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up

dns_query_rejected || die "a DNS query to the local network's resolver must be rejected at once while the VPN is on"
log "ok: with the tunnel up, the local network's resolver is out of reach (DNS goes through the tunnel)"

vpn_stand_in_up "$VPN_LAN_NETNS" vklan0 10.78.0.1/24 "$LAN_SERVER/24"
vpn_stand_in_up "$VPN_TAILNET_NETNS" tailscale0 100.64.0.1/10 "$TAILNET_SERVER/10"
vekrona-dev run sudo ip route add "$OUTSIDE_ADDRESS/32" dev tailscale0
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- serves "$LAN_SERVER"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- serves "$TAILNET_SERVER"

vekrona-dev run sudo ip link del vvpn0
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_down
vpn_status_is '.armed and .connection != null' || die "with the tunnel gone the kill switch must stay armed and name the connection: $(vpn_status)"
expect_fails_fast "an IPv4 address on the internet with the tunnel gone" -4 "$VPN_PROBE_URL_V4"
expect_fails_fast "an IPv6 address on the internet with the tunnel gone" -6 "$VPN_PROBE_URL_V6"
dns_query_rejected || die "a DNS query to the local network's resolver must be rejected with the tunnel gone"
log "ok: with the tunnel gone the kill switch stays armed, and the internet and the local DNS are rejected at once"

serves "$LAN_SERVER" || die "the local network must stay reachable with the tunnel gone"
log "ok: the local network stays reachable"

serves "$TAILNET_SERVER" || die "the tailnet must stay reachable with the tunnel gone"
expect_fails_fast "an address outside the tailnet through tailscale0" -4 "http://$OUTSIDE_ADDRESS:8080/"
log "ok: tailscale0 reaches the tailnet and nothing else"

vpn off
absent vekrona-dev run sudo nft list table inet vekrona-vpn || die "the kill switch table must be gone after off"
vpn_status_is '(.armed | not) and .connection == null' || die "status must say that nothing is armed after off: $(vpn_status)"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- internet_reachable
log "ok: off removes the kill switch and the internet is reachable again"
