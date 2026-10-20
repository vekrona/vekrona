#!/usr/bin/env bash
# firewalld helpers shared by what opens or closes ports: stage 40-system installs them, 70-verify sources this too.

# AirPlay (RAOP) timing and control run on these UDP ports; the public zone does not open them.
AIRPLAY_UDP_LO=6001
AIRPLAY_UDP_HI=6010

firewalld_active() { unit_is_active firewalld.service; }

# A yes/no question to firewall-cmd (a --query-* option): status 0 is yes and 1 is no. Any other status is an error
# (firewalld not running, an unknown zone) and ends the command; read as "no" it would open the question the other way
# round, e.g. as "ssh is closed here".
firewall_query() {
  local status=0
  root firewall-cmd "$@" >/dev/null || status=$?
  [[ $status -le 1 ]] || die "firewall-cmd $* failed with exit status $status"
  return "$status"
}

# What a list question to firewall-cmd (--get-zones, --list-ports) answers, one word per line. A failure ends the command.
# Callers assign the result before looping over it: a die inside a $(...) in the loop header would only end that subshell
# and leave the loop with nothing to check.
firewall_list() {
  local answer
  answer="$(root firewall-cmd "$@")" || die "firewall-cmd $* failed"
  tr -s '[:space:]' '\n' <<<"$answer" | sed '/^$/d'
}

# True when one of the open port ranges of ZONE covers PROTO ports LO-HI. Arguments after the ports: firewall-cmd's mode,
# "--permanent" or none (the running configuration).
zone_lists_port_range() {
  local zone="$1" proto="$2" lo="$3" hi="$4" entries entry range
  shift 4
  entries="$(firewall_list "$@" --zone="$zone" --list-ports)" || die "cannot list the open ports of the zone $zone"
  while read -r entry; do
    [[ "$entry" == */"$proto" ]] || continue
    range="${entry%/"$proto"}"
    [[ "$range" == *-* ]] || range="$range-$range"
    if (( ${range%-*} <= lo && ${range#*-} >= hi )); then return 0; fi
  done <<<"$entries"
  return 1
}

# The target of ZONE. firewalld answers this one only for the permanent configuration, and a reload copies it to the
# running one.
zone_target() { root firewall-cmd --permanent --zone="$1" --get-target; }

# True when ZONE (permanent configuration) lets UDP LO-HI in: its target accepts everything, or one open port range covers it.
zone_allows_udp_range() {
  local zone="$1" lo="$2" hi="$3" target
  target="$(zone_target "$zone")" || die "cannot read the target of the zone $zone"
  [[ "$target" == ACCEPT ]] || zone_lists_port_range "$zone" udp "$lo" "$hi" --permanent
}

# Opens AirPlay's UDP ports in the default zone unless it has them already.
ensure_airplay_ports() {
  local default range="$AIRPLAY_UDP_LO-$AIRPLAY_UDP_HI"
  firewalld_active || return 0
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  zone_allows_udp_range "$default" "$AIRPLAY_UDP_LO" "$AIRPLAY_UDP_HI" && return 0
  log "opening UDP $range in the default zone $default for AirPlay"
  root firewall-cmd --permanent --zone="$default" --add-port="$range/udp" >/dev/null
  root firewall-cmd --reload
}

# vekrona's default zone is public, which opens nothing but mDNS and dhcpv6-client (ssh goes with tailnet-ssh.sh), not the
# FedoraWorkstation zone's 1025-65535. What vekrona runs gets exactly its own openings, firewalld services all of them:
#   mdns, dhcpv6-client  stock public; mDNS finds AirPlay speakers and answers the other machines' names
#   syncthing            the Syncthing daemon (stage 50): 22000/tcp+udp, 21027/udp local discovery
#   steam-streaming      Steam Remote Play (steam is installed by stage 30, configured by stage 60)
#   steam-lan-transfer   Steam local network game transfer
# AirPlay's UDP ports are opened by ensure_airplay_ports. Syncthing's web GUI stays on 127.0.0.1 and has no opening.
DEFAULT_ZONE=public
DEFAULT_ZONE_SERVICES=(mdns dhcpv6-client syncthing steam-streaming steam-lan-transfer)

# Makes public the default zone and gives it the services above, then reloads if the permanent configuration changed.
# Reports, without ending the install, an interface that a NetworkManager connection pins to a zone that opens the high ports.
ensure_default_zone() {
  local default service known reload=0
  firewalld_active || return 0
  known="$(firewall_list --permanent --get-services)" || die "cannot list the firewalld services"
  for service in "${DEFAULT_ZONE_SERVICES[@]}"; do
    grep -qxF "$service" <<<"$known" || die "this firewalld has no service $service"
  done
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  if [[ "$default" != "$DEFAULT_ZONE" ]]; then
    log "making $DEFAULT_ZONE the default zone (it was $default)"
    root firewall-cmd --set-default-zone="$DEFAULT_ZONE" >/dev/null
  fi
  for service in "${DEFAULT_ZONE_SERVICES[@]}"; do
    firewall_query --permanent --zone="$DEFAULT_ZONE" --query-service="$service" && continue
    log "opening the $service service in the zone $DEFAULT_ZONE"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" --add-service="$service" >/dev/null
    reload=1
  done
  if [[ $reload -eq 1 ]]; then root firewall-cmd --reload; fi
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  [[ "$default" == "$DEFAULT_ZONE" ]] || die "the default zone is $default after setting it to $DEFAULT_ZONE"
}

# The zones some interface or source is in that open every TCP port from 1025: after ensure_default_zone these are the
# connections NetworkManager pins to a zone of their own. One per line.
zones_open_to_high_ports() {
  local active zones zone
  active="$(root firewall-cmd --get-active-zones)" || die "cannot read the active zones"
  zones="$(awk '!/^[[:space:]]/ { print $1 }' <<<"$active")" || die "awk failed on the active zones"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    if zone_lists_port_range "$zone" tcp 1025 65535; then printf '%s\n' "$zone"; fi
  done <<<"$zones"
}
