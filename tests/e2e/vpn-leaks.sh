#!/usr/bin/env bash
# The kill switch lets nothing of this machine out of the uplink but what its output chain accepts. It needs no provider and no
# secret: an `other` configuration with a throwaway key and a peer at 192.0.2.1 (TEST-NET, which never answers). One capture on the
# uplink (tcpdump -Q out, writing a pcap file, started before the probes and ready when its log says "listening on") runs through both phases, and the same
# probes and the same capture check run in each:
#   - the tunnel up: its handshake never completes, so the probes wait inside the tunnel and time out. The capture must show the
#     handshake (so it is not empty by accident) and nothing that the switch would not let out;
#   - the tunnel gone (its interface deleted, as a crash would): its default route goes, so each probe leaves by the uplink's address,
#     and the switch must reject it at once, with the error that a rejection gives (see probe).
# What the capture cannot mirror, so the scenario does not check it (the header of the filter lists it again, rule by rule):
#   - the ND hop limit of 255 (tcpdump shows it only with -v, and the kernel always sends 255);
#   - the mark of the handshake: only its destination (the endpoint) is in the capture;
#   - `ct direction reply`: a reply to an inbound connection leaves as an ordinary packet. The filter allows packets from the ports this
#     machine listens on at the start (`ss`), so an outbound packet from a listening port passes here even where the switch would reject it;
#   - tor's uid and tailscaled's marked packets: the switch lets both out by design, and neither is visible in a capture. Both services
#     are stopped for this scenario and started again afterwards if they were running, so their traffic is outside what it checks.
#   - tcpdump is not shipped by vekrona: it is installed in the guest when it is missing (vpn.sh, guest_tool).
# Without the kill switch the probes of the second phase would leave by the uplink, and the capture would show them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

CONF_NAME=NL-leaks
GUEST_CONF="$VPN_GUEST_DIR/$CONF_NAME.conf"
GUEST_DNS_PROBE="$VPN_GUEST_DIR/dns-probe.py"
# tcpdump writes its packets to CAPTURE (a pcap file, read back with tcpdump -nr); its own messages go to CAPTURE_LOG, which is read for
# the readiness line only.
CAPTURE="$VPN_GUEST_DIR/uplink-capture.pcap"
CAPTURE_LOG="$VPN_GUEST_DIR/uplink-capture.log"
TUNNEL_PEER=192.0.2.1
HANDSHAKE_PORT=51820
DNS_PORTS='53|853'  # plain DNS and DNS over TLS: the switch rejects them to every destination but the tunnel, tor and tailscaled
PROBES=(dns-peer dns-resolver ping-4 ping-6 curl-4 curl-6)
# What ping prints for the ICMP error that nft's `reject` sends back (v4, v6). A drop in the output chain gives EPERM too, but sends no
# ICMP error, so "Operation not permitted" alone is not a rejection.
PING_REJECTED='Packet filtered|Administratively prohibited'
REPLY_PORTS=""

write_conf() {
  vekrona-dev run bash -c 'umask 077 && mkdir -p "$(dirname "$1")" \
    && printf "[Interface]\nPrivateKey = %s\nAddress = 10.99.0.2/32\nDNS = 10.99.0.1\n\n[Peer]\nPublicKey = %s\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n" \
      "$(wg genkey)" "$(wg genkey | wg pubkey)" >"$1"' _ "$GUEST_CONF"
}
install_dns_probe() { vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_DNS_PROBE" <"$VPN_DNS_PROBE"; }
table_present() { vekrona-dev run sudo nft list table inet vekrona-vpn >/dev/null; }
gateway() {
  vekrona-dev run ip -4 route show table main default | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}
ipv6_default_route() { [[ -n "$(vekrona-dev run ip -6 route show default)" ]]; }
# The ports this machine listens on (TCP and UDP), joined for a regular expression: the replies to inbound connections.
listening_ports() {
  vekrona-dev run ss -H -tuln | awk '{ n = split($5, parts, ":"); print parts[n] }' | sort -un | paste -sd'|' -
}
# `vekrona-dev until -- CMD ARG...` runs CMD in the vekrona-dev process on the host, not in this shell: CMD sees only the functions
# exported with `export -f` (each one must be, and so must every function it calls) and the exported variables. So each callback below
# takes every value it needs as an argument, calls only exported functions, and is exported on the line after the definitions.
# The packet lines of a pcap file: tcpdump -nr prints nothing else on stdout (its file banner goes to stderr, and a failure is a failure).
capture_lines() { vekrona-dev run sudo tcpdump -nr "$1"; }
# capture_listening CAPTURE_LOG
capture_listening() { vekrona-dev run sudo grep -q 'listening on' "$1"; }
# capture_has_handshake CAPTURE PEER PORT
capture_has_handshake() { capture_lines "$1" | grep -F "> $2.$3: UDP" >/dev/null; }
# internet_reachable URL
internet_reachable() { vekrona-dev run curl -4 -sS --max-time 10 -o /dev/null "$1"; }
stop_capture() { vekrona-dev run sudo bash -c 'pkill -x tcpdump || true'; }
# tailscaled and tor run in the guest after vekrona's install, and the switch lets their own traffic out by design. This scenario is
# about everything else, so both are stopped for its length, and only those that were running are started again.
STOPPED_SERVICES=""
stop_outside_services() {
  local unit
  for unit in tailscaled tor; do
    if vekrona-dev run systemctl is-active --quiet "$unit"; then
      STOPPED_SERVICES="$STOPPED_SERVICES $unit"
      vekrona-dev run sudo systemctl stop "$unit"
    fi
  done
}
restart_outside_services() {
  local unit
  for unit in $STOPPED_SERVICES; do
    vekrona-dev run sudo systemctl start "$unit"
  done
}
# The EXIT cleanup runs on INT and TERM too: the scenario's own tunnel and recorded profiles are removed whatever ends it.
cleanup() { run_cleanups stop_capture vpn_cleanup restart_outside_services; }
export -f internet_reachable capture_listening capture_has_handshake capture_lines

# What the kill switch's output chain lets out of the uplink, one alternative per rule (lib/vekrona_vpn.py, output_rules), first match
# or not: `accept` in the chain, read rule by rule. Each alternative is a regular expression over one line of tcpdump's text.
allowed_out() {
  local alternatives=(
    # `udp` to the endpoint with the tunnel's mark: the mark is not in a capture, the destination is
    "> $TUNNEL_PEER\\.$HANDSHAKE_PORT: UDP"
    # `udp sport 68 dport 67`: DHCPv4 client to server
    "\\.68 > [0-9.]+\\.67: BOOTP/DHCP"
    # `udp sport 546 dport 547`: DHCPv6 client to server
    "\\.546 > [0-9a-f:.]+\\.547: dhcp6"
    # `ip6 hoplimit 255 icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert }`: the hop limit is not shown
    "ICMP6, (router solicitation|neighbor solicitation|neighbor advertisement)"
    # `icmpv6 type { mld-listener-report, mld2-listener-report } ip6 daddr ff02::/16`
    "> ff02::[0-9a-f:]*: (HBH )?ICMP6, multicast listener report"
    # `udp dport 21027` to the IPv4 broadcast address and to ff12::8384 (Syncthing's local discovery)
    "> (255\\.255\\.255\\.255|ff12::8384)\\.21027: UDP"
    # `ip daddr { 10/8, 172.16/12, 192.168/16, 169.254/16 }` and `ip6 daddr { fe80::/10, fc00::/7 }`, after the DNS reject (see DNS_PORTS)
    "> (10\\.[0-9.]+|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+|192\\.168\\.[0-9.]+|169\\.254\\.[0-9.]+): "
    "> (fe[89ab][0-9a-f]:[0-9a-f:]*|f[cd][0-9a-f]{2}:[0-9a-f:]*)\\.[0-9]+: "
    # not nftables' business at all: the link's own address resolution
    "ARP,"
  )
  # `ct direction reply accept`, approximated by the ports this machine listens on (see the header). Without any listening port the
  # rule is left out: an empty alternative would match every line.
  [[ -z "$REPLY_PORTS" ]] || alternatives+=("IP6? [0-9a-f:.]+\\.($REPLY_PORTS) > ")
  (IFS='|'; echo "${alternatives[*]}")
}
# Prints what the uplink carried that the switch would not let out: any DNS packet (the switch rejects DNS to every destination it does
# not route through the tunnel), and any line the accepts do not cover. Nothing when the uplink carried only what it may.
# Fails (status 1) when the capture cannot be read: that is not an empty capture.
capture_unexpected() {
  local allowed packets
  allowed="$(allowed_out)"
  packets="$(capture_lines "$CAPTURE")" || return 1
  { grep -E "\\.($DNS_PORTS): " <<<"$packets" ; grep -vE "$allowed" <<<"$packets" ; } || true
}
expect_only_allowed_out() {
  local unexpected
  unexpected="$(capture_unexpected)" || die "$1: the capture $CAPTURE cannot be read"
  [[ -z "$unexpected" ]] || die "$1: the uplink carried what the kill switch does not let out: $unexpected"
}

# Runs the command in the guest, timed there: "<exit status> <milliseconds>", then its output (both streams).
guest_probe() {
  vekrona-dev run bash -c 'start=$EPOCHREALTIME; out="$("$@" 2>&1)"; status=$?; end=$EPOCHREALTIME
    echo "$status $(( (${end/./} - ${start/./}) / 1000 ))"; printf "%s\n" "$out"' _ "$@"
}
# One probe, run in the guest and reduced to a verdict here: the one place that reads a probe's status. A verdict is what the probe's
# tool reported:
#   rejected  the switch refused it: the DNS probe exits 0 (within VPN_FAST_FAIL_MS); curl exits 7 or 56; ping prints "Administratively
#             prohibited" (v6) or "Packet filtered" (v4), whatever its exit status (1 or 2, by the guest's ping): the ICMP error is what
#             tells a reject from a drop. The DNS probe sees only an errno (EPERM for a reject and for a drop alike), so it cannot tell
#             them apart; the ping and curl probes carry that distinction
#   timeout   the tool waited for its own bound: the DNS probe exits 2, curl 28, ping 1
#   answered  something answered: the DNS probe exits 1, curl 0, ping 0
#   slow      the DNS probe's reject took more than a second (exit 3)
# A tool that is not installed (status 127) is an error, and so is any other status: a missing tool is never a pass. The IPv6 probes run
# only with an IPv6 default route in the guest; without one they are skipped, and that is said on stderr.
probe() {
  local name="$1" reply status ms output verdict
  case "$name" in
    *-6) if ! ipv6_default_route; then
           warn "probe $name skipped: the guest has no IPv6 default route, so there is no IPv6 to reject"
           printf '%s skipped 0\n' "$name"
           return 0
         fi ;;
  esac
  case "$name" in
    dns-peer) reply="$(guest_probe python3 "$GUEST_DNS_PROBE" 9.9.9.9)" ;;
    dns-resolver) reply="$(guest_probe python3 "$GUEST_DNS_PROBE" "$RESOLVER")" ;;
    ping-4) reply="$(guest_probe ping -c1 -W5 9.9.9.9)" ;;
    ping-6) reply="$(guest_probe ping -6 -c1 -W5 2620:fe::fe)" ;;
    curl-4) reply="$(guest_probe curl -4 -sS --max-time 5 -o /dev/null "$VPN_PROBE_URL_V4")" ;;
    curl-6) reply="$(guest_probe curl -6 -sS --max-time 5 -o /dev/null "$VPN_PROBE_URL_V6")" ;;
    *) die "no probe named $name" ;;
  esac
  read -r status ms <<<"$reply"
  output="$(tail -n +2 <<<"$reply")"
  [[ "$status" != 127 ]] || die "$name: the tool is not installed in the guest"
  case "$name" in
    dns-*) case "$status" in
             0) verdict=rejected ;; 1) verdict=answered ;; 2) verdict=timeout ;; 3) verdict=slow ;;
             *) die "$name: the DNS probe exited $status" ;;
           esac ;;
    ping-*) if [[ "$output" =~ $PING_REJECTED ]]; then
              verdict=rejected
            else
              case "$status" in
                0) verdict=answered ;; 1) verdict=timeout ;;
                *) die "$name: ping exited $status without a rejection: $output" ;;
              esac
            fi ;;
    curl-*) case "$status" in
              0) verdict=answered ;; 7|56) verdict=rejected ;; 28) verdict=timeout ;;
              *) die "$name: curl exited $status" ;;
            esac ;;
  esac
  # The raw output of every probe goes to the scenario log (stderr), labelled, so that a verdict can be checked against what the tool said.
  { printf '== probe %s: %s (exit status %s, %s ms)\n' "$name" "$verdict" "$status" "$ms"; [[ -z "$output" ]] || printf '%s\n' "$output"; } >&2
  printf '%s %s %s\n' "$name" "$verdict" "$ms"
}
# Every probe, once: "<name> <verdict> <milliseconds>" a line each.
probe_all() {
  local name
  for name in "${PROBES[@]}"; do
    probe "$name"
  done
}
# Fails unless every probe of the output of probe_all was rejected at once (or skipped, which is said by probe).
expect_all_rejected() {
  local name verdict ms
  while read -r name verdict ms; do
    case "$verdict" in
      rejected) ((ms < VPN_FAST_FAIL_MS)) || die "$name: rejected after $ms ms, which is not at once" ;;
      skipped) ;;
      *) die "$name: $verdict, but the kill switch must reject it" ;;
    esac
  done <<<"$1"
}

vekrona-dev session
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
vpn_cleanup
# The uplink and its resolver are read before the tunnel exists: once it is up, its default route is the tunnel's.
UPLINK="$(vpn_uplink_device)"
[[ -n "$UPLINK" ]] || die "the guest has no IPv4 default route outside the tunnel"
RESOLVER="$(gateway)"
[[ -n "$RESOLVER" ]] || die "the guest has no IPv4 default gateway to take as the resolver of the local network"
for tool in ping curl python3 ss; do
  vekrona-dev run bash -c 'command -v "$1" >/dev/null' _ "$tool" || die "the guest needs $tool for this scenario"
done
guest_tool tcpdump tcpdump || die "the guest has no tcpdump, and it cannot be installed there"
stop_outside_services

write_conf
install_dns_probe
vpn import --vendor other "$GUEST_CONF"
UUID="$(vpn_other_uuid "$CONF_NAME")"
vpn_record_made "$UUID"
[[ -n "$UUID" ]] || die "the imported configuration $CONF_NAME is not in vekrona-vpn list under other"
vpn connect "$UUID"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_up
table_present || die "connect must arm the kill switch: the table inet vekrona-vpn does not exist"
log "ok: connect arms the kill switch and brings the tunnel up"

vekrona-dev spawn --root "$CAPTURE_LOG" -- tcpdump -n -U -Z root -Q out -i "$UPLINK" -w "$CAPTURE"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- capture_listening "$CAPTURE_LOG"
REPLY_PORTS="$(listening_ports)"

probe_all >/dev/null
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- capture_has_handshake "$CAPTURE" "$TUNNEL_PEER" "$HANDSHAKE_PORT"
expect_only_allowed_out "the tunnel up"
log "ok: with the tunnel up, the handshake reached $TUNNEL_PEER and the uplink carried nothing the switch would not let out"

vekrona-dev run sudo ip link del vvpn0
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- vpn_down
vpn_status_is '.armed and .connection != null' || die "with the tunnel gone the kill switch must stay armed: $(vpn_status)"
results="$(probe_all)"
expect_all_rejected "$results"
expect_only_allowed_out "the tunnel gone"
log "ok: with the tunnel gone every probe is rejected at once, and the uplink carried nothing the switch would not let out"

vpn off
absent table_present || die "the kill switch table must be gone after off"
vekrona-dev until --timeout "$VPN_STEP_TIMEOUT_SEC" -- internet_reachable "$VPN_PROBE_URL_V4"
log "ok: off removes the kill switch, and the internet is reachable again"
