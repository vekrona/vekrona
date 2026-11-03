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

# Like firewall_list, but one entry per line: rich rules and forward ports are not single words.
firewall_lines() {
  local answer
  answer="$(root firewall-cmd "$@")" || die "firewall-cmd $* failed"
  sed '/^$/d' <<<"$answer"
}

# The running configuration is the permanent one again after this.
reload_firewalld() {
  log "reloading firewalld"
  root firewall-cmd --reload
}

# The zones some interface or source is in, one per line.
active_zones() {
  local active
  active="$(root firewall-cmd --get-active-zones)" || die "cannot read the active zones"
  awk '!/^[[:space:]]/ { print $1 }' <<<"$active" || die "awk failed on the active zones"
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

# Removes both, then reloads when the permanent configuration changed or a running zone still has the rule.
ensure_tailnet_ssh_firewall_gone() {
  local zones zone running reload=0
  running="$(zones_with_ssh_reject_rule)" || die "cannot list the running zones with the ssh reject rule"
  if [[ -n "$running" ]]; then reload=1; fi
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
  if [[ $reload -eq 1 ]]; then reload_firewalld; fi
}

# The unprivileged ports Fedora Workstation's own zone opens to every network.
HIGH_PORTS_FIRST=1025
HIGH_PORTS_LAST=65535

# True when one of the open TCP port ranges of ZONE (running configuration) covers HIGH_PORTS_FIRST-HIGH_PORTS_LAST.
zone_opens_high_tcp_ports() {
  local entries entry range
  entries="$(firewall_list --zone="$1" --list-ports)" || die "cannot list the open ports of the zone $1"
  while read -r entry; do
    [[ "$entry" == */tcp ]] || continue
    range="${entry%/tcp}"
    [[ "$range" == *-* ]] || range="$range-$range"
    if (( ${range%-*} <= HIGH_PORTS_FIRST && ${range#*-} >= HIGH_PORTS_LAST )); then return 0; fi
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

# What the default zone holds beyond the services given after the mode, as the firewall-cmd options that remove it, one per
# line: another service, a port, protocol, source port, forward port or rich rule, masquerading, and (permanent only, the
# running configuration has no target to read) a target other than "default". MODE is "permanent" or "running".
default_zone_extras() {
  local mode="$1" flags=() zone=(--zone="$DEFAULT_ZONE") wanted=("${@:2}") listed item kind target
  if [[ "$mode" == permanent ]]; then flags=(--permanent); fi
  listed="$(firewall_list "${flags[@]}" "${zone[@]}" --list-services)" || die "cannot list the services of the zone $DEFAULT_ZONE"
  while read -r item; do
    [[ -n "$item" ]] || continue
    case " ${wanted[*]} " in *" $item "*) ;; *) printf '%s\n' "--remove-service=$item" ;; esac
  done <<<"$listed"
  for kind in port protocol source-port; do
    listed="$(firewall_list "${flags[@]}" "${zone[@]}" "--list-${kind}s")" || die "cannot list the ${kind}s of the zone $DEFAULT_ZONE"
    while read -r item; do
      [[ -z "$item" ]] || printf '%s\n' "--remove-$kind=$item"
    done <<<"$listed"
  done
  for kind in forward-port rich-rule; do
    listed="$(firewall_lines "${flags[@]}" "${zone[@]}" "--list-${kind}s")" || die "cannot list the ${kind}s of the zone $DEFAULT_ZONE"
    while IFS= read -r item; do
      [[ -z "$item" ]] || printf '%s\n' "--remove-$kind=$item"
    done <<<"$listed"
  done
  if firewall_query "${flags[@]}" "${zone[@]}" --query-masquerade; then printf '%s\n' --remove-masquerade; fi
  if [[ "$mode" == permanent ]]; then
    target="$(root firewall-cmd --permanent "${zone[@]}" --get-target)" || die "cannot read the target of the zone $DEFAULT_ZONE"
    if [[ "$target" != default ]]; then printf '%s\n' --set-target=default; fi
  fi
}

# True when the default zone holds exactly the services after the mode and nothing else, in the configuration MODE names
# ("permanent" or "running").
default_zone_is_exact() {
  local mode="$1" flags=() extras service
  shift
  if [[ "$mode" == permanent ]]; then flags=(--permanent); fi
  extras="$(default_zone_extras "$mode" "$@")" || die "cannot list what the zone $DEFAULT_ZONE holds"
  [[ -z "$extras" ]] || return 1
  for service in "$@"; do
    firewall_query "${flags[@]}" --zone="$DEFAULT_ZONE" --query-service="$service" || return 1
  done
}

# Makes public the default zone, with exactly the services given as arguments and nothing else (default_zone_extras): whatever
# else the zone holds (stock ssh and mdns, ports opened by hand or by an older vekrona) is removed. Reloads when the permanent
# configuration changed or the running one differs from it.
ensure_default_zone() {
  local wanted=("$@") default service known extras option reload=0
  known="$(firewall_list --permanent --get-services)" || die "cannot list the firewalld services"
  for service in "${wanted[@]}"; do
    grep -qxF "$service" <<<"$known" || die "this firewalld has no service $service"
  done
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  if [[ "$default" != "$DEFAULT_ZONE" ]]; then
    log "making $DEFAULT_ZONE the default zone (it was $default)"
    root firewall-cmd --set-default-zone="$DEFAULT_ZONE" >/dev/null
  fi
  extras="$(default_zone_extras permanent "${wanted[@]}")" || die "cannot list what the zone $DEFAULT_ZONE holds"
  while IFS= read -r option; do
    [[ -n "$option" ]] || continue
    log "zone $DEFAULT_ZONE: $option"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" "$option" >/dev/null
    reload=1
  done <<<"$extras"
  for service in "${wanted[@]}"; do
    firewall_query --permanent --zone="$DEFAULT_ZONE" --query-service="$service" && continue
    log "opening the $service service in the zone $DEFAULT_ZONE"
    root firewall-cmd --permanent --zone="$DEFAULT_ZONE" --add-service="$service" >/dev/null
    reload=1
  done
  if [[ $reload -eq 1 ]] || ! default_zone_is_exact running "${wanted[@]}"; then reload_firewalld; fi
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  [[ "$default" == "$DEFAULT_ZONE" ]] || die "the default zone is $default after setting it to $DEFAULT_ZONE"
  default_zone_is_exact running "${wanted[@]}" || die "the zone $DEFAULT_ZONE still differs from the wanted services after the reload"
}

# The zones some interface or source is in that open every TCP port from the first unprivileged one: after ensure_default_zone these are the
# connections NetworkManager pins to a zone of their own. One per line.
zones_open_to_high_ports() {
  local zones zone
  zones="$(active_zones)" || die "cannot read the active zones"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    if zone_opens_high_tcp_ports "$zone"; then printf '%s\n' "$zone"; fi
  done <<<"$zones"
}

# True when ZONE (permanent configuration) rejects or drops what no other rule of it matched. libvirt's zone has the target
# ACCEPT and a rich rule of the lowest priority that rejects everything, so only its explicit rules let anything in.
zone_has_catch_all_rule() {
  local rules rule
  rules="$(firewall_lines --permanent --zone="$1" --list-rich-rules)" || die "cannot list the rich rules of the zone $1"
  while IFS= read -r rule; do
    if [[ "$rule" =~ ^rule(\ priority=\"[^\"]*\")?(\ family=\"[^\"]*\")?\ (reject|drop) ]]; then return 0; fi
  done <<<"$rules"
  return 1
}

# The zones some interface or source is in whose target accepts everything (trusted, or a hotspot's or Docker's zone) and
# that have no catch-all reject or drop rule behind it. One per line.
zones_accepting_everything() {
  local zones zone target
  zones="$(active_zones)" || die "cannot read the active zones"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    target="$(root firewall-cmd --permanent --zone="$zone" --get-target)" || die "cannot read the target of the zone $zone"
    if [[ "$target" == ACCEPT ]] && ! zone_has_catch_all_rule "$zone"; then printf '%s\n' "$zone"; fi
  done <<<"$zones"
}
