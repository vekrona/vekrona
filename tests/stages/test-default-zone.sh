#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/firewall.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export FW="$scratch/fw" PEERS="$scratch/peers"
TAILNET_ZONE_FILE="$scratch/tailnet.xml"
source "$ROOT/tests/stages/firewalld-fakes.sh"

ensure() { rc=0; (PATH="$stubs:$PATH" ensure_default_zone) >"$scratch/out" 2>&1 || rc=$?; }
high_port_zones() { PATH="$stubs:$PATH" zones_open_to_high_ports | tr '\n' ' '; }
opens() { grep -qxF "$3" "$FW/$1/$DEFAULT_ZONE/services"; }

stock
[[ "$(high_port_zones)" == "FedoraWorkstation " ]] || die "a stock Fedora Workstation binds eth0 to the zone that opens 1025-65535: '$(high_port_zones)'"
ensure
[[ "$rc" == 0 && "$(<"$FW/default")" == public ]] || die "public did not become the default zone: rc=$rc: $(cat "$scratch/out")"
for service in mdns dhcpv6-client syncthing steam-streaming steam-lan-transfer; do
  opens perm public "$service" && opens run public "$service" || die "the $service service is not open in public, permanent and running"
done
[[ -z "$(high_port_zones)" ]] || die "an interface is still in a zone that opens 1025-65535: '$(high_port_zones)'"
log "ok: public becomes the default zone, with the services vekrona uses open and no interface in the high-port zone"

before="$(cat "$FW"/perm/public/services "$FW"/perm/public/ports)"
ensure
[[ "$rc" == 0 && "$(cat "$FW"/perm/public/services "$FW"/perm/public/ports)" == "$before" ]] || die "a second run changed the zone: rc=$rc: $(cat "$scratch/out")"
! grep -q 'opening\|making' "$scratch/out" || die "a second run opened or changed something: $(cat "$scratch/out")"
log "ok: a second run changes nothing"

stock
FW_SERVICES="dhcpv6-client mdns ssh" ensure
[[ "$rc" != 0 ]] && grep -q 'no service syncthing' "$scratch/out" || die "a firewalld without a service vekrona needs must fail before anything changes: rc=$rc: $(cat "$scratch/out")"
[[ "$(<"$FW/default")" == FedoraWorkstation ]] || die "the default zone changed although the services are missing"
log "ok: a firewalld that lacks one of the services fails before it changes the default zone"

stock
FW_FAIL=--set-default-zone ensure
[[ "$rc" != 0 ]] || die "a failing --set-default-zone was ignored"
log "ok: a firewall-cmd that fails is an error"
