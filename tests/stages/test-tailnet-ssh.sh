#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/firewall.sh"
source "$ROOT/lib/tailnet-ssh.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export FW="$scratch/fw" PEERS="$scratch/peers"
TAILNET_ZONE_FILE="$scratch/tailnet.xml"

source "$ROOT/tests/stages/firewalld-fakes.sh"
ssh_zones() { PATH="$stubs:$PATH" zones_allowing_ssh "$@" | tr '\n' ' '; }
ensure() { rc=0; (PATH="$stubs:$PATH" ensure_tailnet_ssh_only) >"$scratch/out" 2>&1 || rc=$?; }
tailnet_still_allows_ssh() { grep -qxF ssh "$FW/run/tailnet/services"; }

unset SSH_CONNECTION
LAN_PEERS='0 0 192.168.1.20:22 192.168.1.7:5555'
SSH_OPEN_EVERYWHERE="FedoraWorkstation internal public "

stock
[[ "$(ssh_zones)" == "$SSH_OPEN_EVERYWHERE" ]] || die "a stock firewalld lets ssh in through three zones, got: $(ssh_zones)"
log "ok: zones_allowing_ssh names every zone with the ssh service and skips the tailnet"

stock
ensure
[[ "$rc" == 0 && -z "$(ssh_zones)" && -z "$(ssh_zones --permanent)" ]] || die "with no ssh client off the tailnet, no zone may keep ssh: rc=$rc, zones '$(ssh_zones)': $(cat "$scratch/out")"
tailnet_still_allows_ssh || die "the tailnet zone lost ssh"
log "ok: ssh is closed in every zone but the tailnet's, public and internal included"

ensure_airplay() { (PATH="$stubs:$PATH" ensure_airplay_ports) >"$scratch/out" 2>&1; }
stock public
ensure_airplay
grep -qxF 6001-6010/udp "$FW/perm/public/ports" || die "AirPlay's UDP ports were not opened in the default zone"
grep -qxF 6001-6010/udp "$FW/run/public/ports" || die "AirPlay's UDP ports were not reloaded into the running zone"
stock
ensure_airplay
[[ "$(grep -c 6001 "$FW/perm/FedoraWorkstation/ports" || [[ $? -eq 1 ]])" == 0 ]] || die "AirPlay's ports were opened in a zone whose range already covers them"
log "ok: AirPlay's UDP ports are opened in the default zone unless a range covers them, apart from the ssh work"

for peers in '0 0 100.64.0.7:22 100.64.0.9:41000' '0 0 100.64.0.7:22 [fd7a:115c:a1e0::9]:41000' '0 0 127.0.0.1:22 127.0.0.1:41000' '0 0 [::ffff:100.100.1.1]:22 [::ffff:100.100.1.2]:41000'; do
  stock
  echo "$peers" >"$PEERS"
  ensure
  [[ "$rc" == 0 && -z "$(ssh_zones)" ]] || die "a client on the tailnet or on loopback ($peers) must not keep ssh open: rc=$rc, zones '$(ssh_zones)'"
done
log "ok: clients on the tailnet or on loopback do not keep ssh open"

stock
echo "$LAN_PEERS" >"$PEERS"
ensure
[[ "$rc" == 0 && "$(ssh_zones)" == "$SSH_OPEN_EVERYWHERE" ]] || die "an ssh client of the LAN must keep ssh open and the stage go on: rc=$rc, zones '$(ssh_zones)'"
grep -q 'FAIL:.*ssh stays open outside the tailnet.*192.168.1.7' "$scratch/out" || die "the deferred removal must be reported as a failure naming the client: $(cat "$scratch/out")"
log "ok: ssh in use from the LAN stays open, and the stage reports it as a failure"

stock
: >"$PEERS"
SSH_CONNECTION="192.168.1.7 5555 192.168.1.20 22" ensure
[[ "$rc" == 0 && "$(ssh_zones)" == "$SSH_OPEN_EVERYWHERE" ]] || die "this install's own ssh session from the LAN must keep ssh open: rc=$rc, zones '$(ssh_zones)'"
grep -q 'FAIL:.*stays open outside the tailnet' "$scratch/out" || die "the install's own LAN session must be reported too: $(cat "$scratch/out")"
log "ok: the install's own ssh session from the LAN counts"

REJECT='rule service name="ssh" reject'
rejects() { grep -qxF "$REJECT" "$FW/$1/$2/richrules"; }

stock
zone public default "dhcpv6-client" "22/tcp" "" ""
ensure
[[ "$rc" == 0 && -z "$(ssh_zones)" && -z "$(ssh_zones --permanent)" ]] && rejects perm public && rejects run public \
  || die "an open port 22 in public must be closed by a reject rule: rc=$rc, zones '$(ssh_zones)': $(cat "$scratch/out")"
! rejects perm internal || die "a zone that lost its ssh service and has no other way in needs no reject rule"
stock
zone internal default "dhcpv6-client" "1-1024/tcp" "" ""
ensure
[[ "$rc" == 0 && -z "$(ssh_zones)" ]] && rejects perm internal \
  || die "an open port range that covers 22 must be closed by a reject rule: rc=$rc, zones '$(ssh_zones)': $(cat "$scratch/out")"
log "ok: a port opened by hand that reaches sshd is closed by a reject rule"

stock
ensure
[[ "$rc" == 0 && -z "$(ssh_zones)" ]] && ! rejects perm trusted || die "an accepting zone nothing is bound to (trusted) is no way in and needs no rule: rc=$rc"
stock
zone trusted ACCEPT "" "" "docker0" ""
ensure
[[ "$rc" == 0 && -z "$(ssh_zones)" ]] && rejects perm trusted && rejects run trusted \
  || die "an accepting zone with an interface must be closed by a reject rule, not fail the stage: rc=$rc, zones '$(ssh_zones)': $(cat "$scratch/out")"
log "ok: an accepting zone gets a reject rule while something is bound to it, and none before"

stock
zone trusted ACCEPT "" "" "docker0" ""
echo "$LAN_PEERS" >"$PEERS"
ensure
[[ "$rc" == 0 && "$(ssh_zones)" == "FedoraWorkstation internal public trusted " ]] && ! rejects perm trusted \
  || die "while ssh is used from the LAN nothing is closed, a reject rule included: rc=$rc, zones '$(ssh_zones)'"
log "ok: a client from the LAN holds back the reject rules too"

stock
zone tailnet default "ssh" "tailscale0" "tailscale0" "100.64.0.0/10"
ensure
[[ "$rc" != 0 ]] && grep -q 'fd7a:115c:a1e0::/48 is not in the tailnet zone' "$scratch/out" || die "a tailnet zone without its IPv6 range must fail before ssh is closed anywhere: rc=$rc: $(cat "$scratch/out")"
[[ "$(ssh_zones)" == "$SSH_OPEN_EVERYWHERE" ]] || die "ssh must stay open while the tailnet zone is incomplete, got '$(ssh_zones)'"
log "ok: ssh is closed elsewhere only once the tailnet zone holds both address ranges"

# A firewall-cmd that fails is not an answer. Read as "no zone has ssh" it would pass the install and the verification
# for a machine whose ssh is open everywhere.
for failing in --get-zones --query-service --list-ports --get-active-zones; do
  stock
  FW_FAIL="$failing" ensure
  [[ "$rc" != 0 ]] || die "ensure_tailnet_ssh_only went on although firewall-cmd $failing failed"
  grep -q "firewall-cmd .*$failing.* failed\|cannot " "$scratch/out" || die "the failing $failing is not named: $(cat "$scratch/out")"
  [[ "$(ssh_zones)" == "$SSH_OPEN_EVERYWHERE" ]] || die "a failing $failing changed the zones: '$(ssh_zones)'"
done
for failing in --get-zones --query-service --list-ports --get-active-zones; do
  stock
  ssh_status=0
  out="$(FW_FAIL="$failing" PATH="$stubs:$PATH" zones_allowing_ssh --permanent 2>&1)" || ssh_status=$?
  [[ "$ssh_status" != 0 && "$out" == *"FirewallD is not running"* ]] || die "zones_allowing_ssh answered although firewall-cmd $failing failed (status $ssh_status): $out"
done
log "ok: a failing firewall-cmd ends the ssh work with an error and is never read as 'ssh is closed'"
