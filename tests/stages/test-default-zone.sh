#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/firewall.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export FW="$scratch/fw"
# The marker is a scratch file: the test passes the same where the real marker exists (the vekrona-dev VM) and where it does not.
VEKRONA_KEEP_SSHD_MARKER="$scratch/keep-sshd"
source "$ROOT/tests/stages/firewalld-fakes.sh"

FOUR="dhcpv6-client steam-lan-transfer steam-streaming syncthing "
WITH_SSH="dhcpv6-client ssh steam-lan-transfer steam-streaming syncthing "
ensure() {
  local wanted
  mapfile -t wanted < <(default_zone_services)
  rc=0
  (PATH="$stubs:$PATH" ensure_default_zone "${wanted[@]}") >"$scratch/out" 2>&1 || rc=$?
}
high_port_zones() { PATH="$stubs:$PATH" zones_open_to_high_ports | tr '\n' ' '; }
services_of() { sort "$FW/$1/public/services" | tr '\n' ' '; }
ports_of() { tr '\n' ' ' <"$FW/$1/public/ports"; }

rm -f "$VEKRONA_KEEP_SSHD_MARKER"
stock
[[ "$(high_port_zones)" == "FedoraWorkstation " ]] || die "a stock Fedora Workstation binds eth0 to the zone that opens 1025-65535: '$(high_port_zones)'"
ensure
[[ "$rc" == 0 && "$(<"$FW/default")" == public ]] || die "public did not become the default zone: rc=$rc: $(cat "$scratch/out")"
for mode in perm run; do
  [[ "$(services_of $mode)" == "$FOUR" && -z "$(ports_of $mode)" ]] \
    || die "a stock public zone must end with exactly the four services and no port, $mode: '$(services_of $mode)' '$(ports_of $mode)'"
done
[[ -z "$(high_port_zones)" ]] || die "an interface is still in a zone that opens 1025-65535: '$(high_port_zones)'"
log "ok: a stock public zone ends with exactly the four services and no port, and no interface stays in the high-port zone"

stock public
zone public default "dhcpv6-client syncthing steam-streaming steam-lan-transfer" "6001-6010/udp 8080/tcp" "" ""
ensure
[[ "$rc" == 0 && -z "$(ports_of perm)" && -z "$(ports_of run)" ]] || die "ports left over from earlier (AirPlay's 6001-6010) must be closed: rc=$rc, '$(ports_of perm)' '$(ports_of run)': $(cat "$scratch/out")"
log "ok: ports left over from earlier are closed"

before="$(cat "$FW"/perm/public/services "$FW"/perm/public/ports)"
ensure
[[ "$rc" == 0 && "$(cat "$FW"/perm/public/services "$FW"/perm/public/ports)" == "$before" ]] || die "a second run changed the zone: rc=$rc: $(cat "$scratch/out")"
! grep -q 'opening\|closing\|making' "$scratch/out" || die "a second run opened, closed or changed something: $(cat "$scratch/out")"
log "ok: a second run changes nothing"

stock
touch "$VEKRONA_KEEP_SSHD_MARKER"
ensure
[[ "$rc" == 0 && "$(services_of perm)" == "$WITH_SSH" && "$(services_of run)" == "$(services_of perm)" ]] || die "with the keep-sshd marker ssh must stay in the zone: rc=$rc, '$(services_of perm)': $(cat "$scratch/out")"
rm -f "$VEKRONA_KEEP_SSHD_MARKER"
ensure
[[ "$rc" == 0 && "$(services_of perm)" == "$FOUR" ]] || die "without the marker ssh must be closed again: rc=$rc, '$(services_of perm)'"
log "ok: ssh stays in the zone with the keep-sshd marker and goes without it"

stock
FW_SERVICES="dhcpv6-client mdns ssh" ensure
[[ "$rc" != 0 ]] && grep -q 'no service syncthing' "$scratch/out" || die "a firewalld without a service vekrona needs must fail before anything changes: rc=$rc: $(cat "$scratch/out")"
[[ "$(<"$FW/default")" == FedoraWorkstation ]] || die "the default zone changed although the services are missing"
log "ok: a firewalld that lacks one of the services fails before it changes the default zone"

stock
FW_FAIL=--set-default-zone ensure
[[ "$rc" != 0 ]] || die "a failing --set-default-zone was ignored"
for failing in --list-services --list-ports; do
  stock public
  FW_FAIL="$failing" ensure
  [[ "$rc" != 0 ]] || die "ensure_default_zone went on although firewall-cmd $failing failed"
done
log "ok: a firewall-cmd that fails is an error"
