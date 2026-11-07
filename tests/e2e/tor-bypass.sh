#!/usr/bin/env bash
# tor bypasses the VPN: with the VPN on (the scenario brings it up from a Proton configuration and takes it down again), the
# session's traffic leaves through the tunnel (vvpn0) while tor's own traffic (its user) takes the physical interface, by the
# ip rule that vekrona-tor-route.service holds while tor runs, and tor's established connections come from the physical
# interface's address. Tor Browser's sandbox, which never sees the tunnel, has only lo and reaches tor with the VPN on and off. Needs a
# Proton configuration on the host (tests/e2e/lib/vpn.sh); without one the scenario is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"
# shellcheck source=lib/tor-guest.sh
source "$ROOT/tests/e2e/lib/tor-guest.sh"
# shellcheck source=../../lib/tor.sh
source "$ROOT/lib/tor.sh"

VPN_INTERFACE=vvpn0
PROBE=1.1.1.1 # only asked about its route, never contacted

require_vpn_conf
require_tor_browser

# The interface a packet to $PROBE from user $1 leaves by.
route_device() { vekrona-dev run bash -c 'ip -j -4 route get "$1" uid "$2" | jq -r ".[0].dev"' _ "$PROBE" "$1"; }
# Whether a connection of the tor process is established from address $tor_address. ss shows processes of other users to root only.
tor_connected_from_tor_address() {
  local connections
  connections="$(vekrona-dev run sudo ss -tnpH state established)" || abort "ss failed in the guest"
  awk -v from="$tor_address" '/users:\(\("tor"/ { split($3, local, ":"); if (local[1] == from) found = 1 } END { exit !found }' <<<"$connections"
}
export -f tor_connected_from_tor_address

vekrona-dev session
trap 'run_cleanups stop_tor vpn_cleanup' EXIT
vpn_cleanup
stop_tor
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive

UUID="$(vpn_import_conf_uuid)"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
vekrona-dev run ip link show "$VPN_INTERFACE" >/dev/null 2>&1 || die "the VPN is up, but $VPN_INTERFACE does not exist"
user_device="$(route_device "$(vekrona-dev run id -u)")"
[[ "$user_device" == "$VPN_INTERFACE" ]] || die "with the VPN on, the session's traffic must leave by $VPN_INTERFACE, but it leaves by $user_device"
log "ok: the session's traffic leaves by $VPN_INTERFACE"

start_tor
tor_device="$(route_device "$(vekrona-dev run id -u "$VEKRONA_TOR_USER")")"
[[ -n "$tor_device" && "$tor_device" != "$VPN_INTERFACE" ]] || die "tor's traffic must leave by the physical interface, but it leaves by '$tor_device'"
log "ok: tor's traffic leaves by $tor_device"

tor_address="$(vekrona-dev run bash -c 'ip -j -4 addr show dev "$1" | jq -r ".[0].addr_info[0].local"' _ "$tor_device")"
[[ -n "$tor_address" ]] || die "$tor_device has no IPv4 address"
export tor_address
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- tor_connected_from_tor_address || die "tor must hold an established connection from $tor_address ($tor_device), not from the tunnel"
log "ok: tor's connections come from $tor_address"

interfaces="$(sandbox_interfaces)"
[[ "$interfaces" == lo ]] || die "with the VPN on, the Tor Browser sandbox must still have lo and nothing else, but it has: $(tr '\n' ' ' <<<"$interfaces")"
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- sandbox_reaches_tor || die "with the VPN on, the sandbox must still reach check.torproject.org through the tor socket; last attempt: $(sandbox_socks_check 2>&1 | tail -n 3 || true)"
log "ok: with the VPN on, the sandbox is still on tor and has only lo"
vpn_cleanup
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- sandbox_reaches_tor || die "with the VPN off again, the sandbox must reach check.torproject.org through the tor socket"
log "ok: with the VPN off again, the sandbox is still on tor"

stop_tor
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive
for family in -4 -6; do
  rules="$(vekrona-dev run ip "$family" -o rule show priority 100)"
  [[ -z "$rules" ]] || die "stopping tor must remove its ip rule ($family), but these are left: $rules"
done
log "ok: the bypass rules go away with tor"
