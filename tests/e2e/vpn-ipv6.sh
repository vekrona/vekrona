#!/usr/bin/env bash
# IPv6 goes through the tunnel, whatever the uplink does: with a configuration that has an IPv6 address (Proton's do; the keyring item
# of tests/e2e/lib/vpn.sh), connect, then a request to an IPv6 literal (a host with no IPv4 address to reach it by) answers 200 through
# vvpn0, and the server sees an address of the tunnel, not one of the uplink's.
# The uplink's global IPv6 addresses are removed for the scenario and put back afterwards: a VM on a Proton host gets the host's tunnel
# address 2a07:b944::2:2 from passt, which is also the address Proton gives the tunnel, so the two would collide (TODO.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

V6_TARGET=2606:4700:4700::1111
IPV6_TRACE_URL="$VPN_PROBE_URL_V6/cdn-cgi/trace"
UPLINK=""
FLUSHED=0

require_vpn_conf
require_vpn_conf_with_ipv6

# Whether the uplink has an IPv6 default route (the one NetworkManager gives it, in RA or DHCPv6).
uplink_v6_default() { [[ -n "$(vekrona-dev run ip -6 route show default dev "$1")" ]]; }
export -f uplink_v6_default
remove_uplink_v6() {
  vekrona-dev run sudo ip -6 addr flush dev "$UPLINK" scope global
  FLUSHED=1
}
# NetworkManager brings the flushed addresses and the route back on a reapply: that is the live test's result, and it is cheaper than
# the addresses kept by hand.
restore_uplink_v6() {
  [[ "$FLUSHED" == 1 ]] || return 0
  vekrona-dev run sudo nmcli device reapply "$UPLINK"
  FLUSHED=0
}
cleanup() { run_cleanups vpn_cleanup restore_uplink_v6; }

vekrona-dev session
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
vpn_cleanup
UPLINK="$(vpn_uplink_device)"
[[ -n "$UPLINK" ]] || die "the guest has no IPv4 default route outside the tunnel"
remove_uplink_v6

UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up

if ! body="$(vekrona-dev run curl -6 -sS --max-time 20 -w '\n%{http_code}' "$IPV6_TRACE_URL")"; then
  die "curl -6 to $V6_TARGET failed through the tunnel"
fi
status="${body##*$'\n'}"
[[ "$status" == 200 ]] || die "a request to $V6_TARGET over IPv6 must answer 200 through the tunnel, but it answered $status"
log "ok: curl -6 to an IPv6 literal answers 200 through the tunnel"

route_dev="$(vekrona-dev run ip -6 route get "$V6_TARGET" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
[[ "$route_dev" == vvpn0 ]] || die "IPv6 to $V6_TARGET must leave by vvpn0, but its route leaves by '$route_dev'"
log "ok: the route to $V6_TARGET is vvpn0"

vpn off
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_down
restore_uplink_v6
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- uplink_v6_default "$UPLINK" || die "the uplink has no IPv6 default route after the reapply"
log "ok: the uplink has its IPv6 default route again"
