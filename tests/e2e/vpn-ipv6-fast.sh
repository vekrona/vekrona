#!/usr/bin/env bash
# A configuration without an IPv6 address must not leave IPv6 to time out: with the tunnel up, a connection to an IPv6 address on
# the internet is refused at once (the kill switch rejects it, and the connection has no IPv6 of its own, so no route sends it into
# a tunnel that would swallow it), where Proton's own app blackholed it and clients that try addresses in order stalled for minutes.
# Needs a Proton configuration without an IPv6 address on the host (tests/e2e/lib/vpn.sh); without it the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

require_vpn_conf
require_vpn_conf_without_ipv6

guest_has_ipv6_default() { [[ -n "$(vekrona-dev run ip -6 route show default)" ]]; }

vekrona-dev session
trap vpn_cleanup EXIT
vpn_cleanup
# Without a way out by IPv6 the guest would fail at once anyway, and the scenario would prove nothing.
guest_has_ipv6_default || skip "the guest has no IPv6 default route, so a failing IPv6 connection shows nothing"
vekrona-dev run curl -6 -sS --max-time 10 -o /dev/null "$VPN_PROBE_URL_V6" || skip "the guest cannot reach the internet by IPv6 without the VPN"

UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up

expect_fails_fast "an IPv6 address on the internet with the tunnel up" -6 "$VPN_PROBE_URL_V6"
route="$(vekrona-dev run ip -6 route get 2606:4700:4700::1111)" || die "ip cannot tell the IPv6 route to the probe address, though the guest has an IPv6 default route"
[[ "$route" != *vvpn0* ]] || die "no IPv6 route may lead into the tunnel when the configuration has no IPv6 address: $route"
log "ok: IPv6 is refused at once, and no route sends it into the tunnel"

[[ "$(vekrona-dev run curl -4 -sS --max-time 20 -o /dev/null -w '%{http_code}' "$VPN_PROBE_URL_V4")" =~ ^[0-9]+$ ]] || die "IPv4 must still work through the tunnel"
log "ok: IPv4 still works through the tunnel"
