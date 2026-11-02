#!/usr/bin/env bash
# firewalld helpers shared by what opens or closes ports: stage 40-system installs them, 70-verify sources this too.
# firewalld is a vekrona package that stage 40 enables and starts before any of this runs, so none of it checks that it runs.

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

# Earlier installs gave sshd a firewalld zone of its own and closed ssh in every other zone with a reject rule. sshd is
# gone now, so both go: stage 40 removes them, 70-verify checks that none is left.
TAILNET_ZONE_FILE=/etc/firewalld/zones/tailnet.xml
SSH_REJECT_RULE='rule service name="ssh" reject'

# The zones that have the ssh reject rule, one per line. Arguments: firewall-cmd's mode, "--permanent" or none.
zones_with_ssh_reject_rule() {
  local zones zone
  zones="$(firewall_list "$@" --get-zones)" || die "cannot list the firewall zones"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    if firewall_query "$@" --zone="$zone" --query-rich-rule="$SSH_REJECT_RULE"; then printf '%s\n' "$zone"; fi
  done <<<"$zones"
}

ensure_tailnet_ssh_firewall_gone() {
  local zones zone reload=0
  zones="$(zones_with_ssh_reject_rule --permanent)" || die "cannot list the zones with the ssh reject rule"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    log "removing the ssh reject rule from the zone $zone"
    root firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$SSH_REJECT_RULE" >/dev/null
    reload=1
  done <<<"$zones"
  if ! path_absent "$TAILNET_ZONE_FILE"; then
    ensure_root_file_absent "$TAILNET_ZONE_FILE"
    reload=1
  fi
  if [[ $reload -eq 1 ]]; then root firewall-cmd --reload; fi
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

# vekrona's default zone is public, and it opens exactly what vekrona runs, firewalld services all of them:
#   dhcpv6-client        stock public's own
#   syncthing            the Syncthing daemon (stage 50): 22000/tcp+udp, 21027/udp local discovery
#   steam-streaming      Steam Remote Play (steam is installed by stage 30, configured by stage 60)
#   steam-lan-transfer   Steam local network game transfer
# plus ssh on a test guest that keeps sshd (keep_sshd). No port is open on its own. Syncthing's web GUI stays on 127.0.0.1 and
# has no opening. The Fedora Workstation zone's 1025-65535 and public's own mdns and ssh are not used.
DEFAULT_ZONE=public
DEFAULT_ZONE_SERVICES=(dhcpv6-client syncthing steam-streaming steam-lan-transfer)

# The services the default zone holds, one per line: the one list stage 40 sets and 70-verify compares the zone with.
default_zone_services() {
  printf '%s\n' "${DEFAULT_ZONE_SERVICES[@]}"
  if keep_sshd; then printf '%s\n' ssh; fi
}

# Makes public the default zone, with exactly the services given as arguments and no port: whatever else the zone holds
# (stock ssh and mdns, ports opened by hand or by an older vekrona) is removed. Reloads if the permanent configuration changed.
# Reports, without ending the install, an interface that a NetworkManager connection pins to a zone that opens the high ports.
ensure_default_zone() {
  local wanted=("$@") default service known current port reload=0
  known="$(firewall_list --permanent --get-services)" || die "cannot list the firewalld services"
  for service in "${wanted[@]}"; do
    grep -qxF "$service" <<<"$known" || die "this firewalld has no service $service"
  done
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  if [[ "$default" != "$DEFAULT_ZONE" ]]; then
    log "making $DEFAULT_ZONE the default zone (it was $default)"
    root firewall-cmd --set-default-zone="$DEFAULT_ZONE" >/dev/null
  fi
  current="$(firewall_list --permanent --zone="$DEFAULT_ZONE" --list-services)" || die "cannot list the services of the zone $DEFAULT_ZONE"
  while read -r service; do
    [[ -n "$service" ]] || continue
    case " ${wanted[*]} " in *" $service "*) continue ;; esac
    log "closing the $service service in the zone $DEFAULT_ZONE"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" --remove-service="$service" >/dev/null
    reload=1
  done <<<"$current"
  current="$(firewall_list --permanent --zone="$DEFAULT_ZONE" --list-ports)" || die "cannot list the ports of the zone $DEFAULT_ZONE"
  while read -r port; do
    [[ -n "$port" ]] || continue
    log "closing the port $port in the zone $DEFAULT_ZONE"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" --remove-port="$port" >/dev/null
    reload=1
  done <<<"$current"
  for service in "${wanted[@]}"; do
    firewall_query --permanent --zone="$DEFAULT_ZONE" --query-service="$service" && continue
    log "opening the $service service in the zone $DEFAULT_ZONE"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" --add-service="$service" >/dev/null
    reload=1
  done
  if [[ $reload -eq 1 ]]; then root firewall-cmd --reload; fi
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  [[ "$default" == "$DEFAULT_ZONE" ]] || die "the default zone is $default after setting it to $DEFAULT_ZONE"
}

# True when the default zone holds exactly the services after the first argument, and no port, in the configuration that
# argument names: "permanent" or "running".
default_zone_is_exact() {
  local mode=() have ports
  if [[ "$1" == permanent ]]; then mode=(--permanent); fi
  shift
  have="$(firewall_list "${mode[@]}" --zone="$DEFAULT_ZONE" --list-services | sort)" || die "cannot list the services of the zone $DEFAULT_ZONE"
  ports="$(firewall_list "${mode[@]}" --zone="$DEFAULT_ZONE" --list-ports)" || die "cannot list the ports of the zone $DEFAULT_ZONE"
  [[ "$have" == "$(printf '%s\n' "$@" | sort)" && -z "$ports" ]]
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
