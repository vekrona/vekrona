#!/usr/bin/env bash
# sshd takes keys only and answers only on the tailnet: stage 40-system installs it, 70-verify sources this too (after
# lib/firewall.sh, whose helpers it uses).
# The sshd drop-in closes password logins; the firewalld "tailnet" zone (bound to tailscale0 and the tailnet's address
# ranges, ssh the only service) is the only place ssh is open, so every other zone loses its ssh service.

SSHD_DROPIN=/etc/ssh/sshd_config.d/10-vekrona.conf
TAILNET_ZONE=tailnet
TAILNET_IFACE=tailscale0
# Tailscale's IPv4 CGNAT range and IPv6 ULA; keep in step with etc/firewalld/zones/tailnet.xml.
TAILNET_SOURCES=(100.64.0.0/10 fd7a:115c:a1e0::/48)
TAILNET_ZONE_FILE=/etc/firewalld/zones/tailnet.xml
# firewalld evaluates a reject rule before the open ports, services and target of a zone, so it closes ssh in a zone that
# cannot lose it by dropping a service (trusted, a hotspot's, Docker's: their target accepts everything).
SSH_REJECT_RULE='rule service name="ssh" reject'

has_sshd() { pkg_installed openssh-server; }

# The value of an effective sshd setting (sshd -T prints keywords in lower case).
sshd_setting() { root sshd -T | awk -v key="$1" '$1 == key { print $2; exit }'; }

# Installs the sshd drop-in. The drop-in alone is checked first (sshd -t -f), then the whole configuration, so a typo
# never reaches a running sshd; sshd re-reads its configuration only if it runs, on reload, and keeps its sessions.
ensure_sshd_keys_only() {
  local src="$VEKRONA_ROOT/etc/ssh/sshd_config.d/10-vekrona.conf" changed=1
  if ! has_sshd; then log "openssh-server not installed, nothing to restrict"; return 0; fi
  # sshd -t refuses a configuration without host keys, and a host whose sshd never started has none; sshd-keygen makes them the same way.
  root ssh-keygen -A >/dev/null || die "cannot generate the ssh host keys"
  root sshd -t -f "$src" || die "sshd rejects $src: not installed"
  if root_file_current "$src" "$SSHD_DROPIN" 0644; then changed=0; fi
  ensure_root_file "$src" "$SSHD_DROPIN"
  root sshd -t || die "sshd rejects its configuration after installing $SSHD_DROPIN: fix or remove it before the next reboot"
  if unit_is_active sshd.service; then
    [[ $changed -eq 0 ]] || root systemctl reload sshd.service
    [[ -s "$HOME/.ssh/authorized_keys" ]] || warn "sshd takes keys only and $HOME/.ssh/authorized_keys is empty or missing: nobody can log in over ssh"
  fi
}

# True for an address that stays reachable once the default zone drops ssh: a tailnet address (100.64.0.0/10 is
# 100.64-127.*, fd7a:115c:a1e0::/48) or loopback. An IPv4 peer of a dual-stack socket shows up as ::ffff:A.B.C.D.
is_tailnet_or_loopback() {
  case "${1#::ffff:}" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fd7a:115c:a1e0:*|127.*|::1) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints each address, outside the tailnet, that this install's ssh session (SSH_CONNECTION) or any established
# connection to port 22 comes from.
ssh_clients_off_tailnet() {
  local peers peer addr candidates=()
  peers="$(ss -Htn state established '( sport = :22 )' | awk '{ print $NF }')"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then candidates+=("${SSH_CONNECTION%% *}"); fi
  while IFS= read -r peer; do
    [[ -n "$peer" ]] || continue
    addr="${peer%:*}"; addr="${addr#[}"; addr="${addr%]}"
    candidates+=("$addr")
  done <<<"$peers"
  for addr in "${candidates[@]}"; do
    is_tailnet_or_loopback "$addr" || printf '%s\n' "$addr"
  done | sort -u
}

# The zones other than the tailnet that have the ssh service. Arguments: firewall-cmd's mode, "--permanent" or none
# (the running configuration).
zones_with_ssh_service() {
  local zones zone
  zones="$(firewall_list "$@" --get-zones)" || die "cannot list the firewall zones"
  while read -r zone; do
    [[ -n "$zone" && "$zone" != "$TAILNET_ZONE" ]] || continue
    if firewall_query "$@" --zone="$zone" --query-service=ssh; then printf '%s\n' "$zone"; fi
  done <<<"$zones"
}

zone_rejects_ssh() {
  local zone="$1"
  shift
  firewall_query "$@" --zone="$zone" --query-rich-rule="$SSH_REJECT_RULE"
}

# The zones other than the tailnet through which a packet to port 22 gets in: the ssh service, an open tcp port range that
# covers 22, or an accepting target (trusted) on a zone in use, that is the default zone or one with an interface or a
# source. A zone with the reject rule for ssh lets nothing in. Arguments as for zones_with_ssh_service; the default
# zone, the active zones and the target are asked in one mode only.
zones_allowing_ssh() {
  local zones zone default active in_use target
  default="$(root firewall-cmd --get-default-zone)" || die "cannot read the default zone"
  active="$(root firewall-cmd --get-active-zones)" || die "cannot read the active zones"
  in_use="$(awk '!/^[[:space:]]/ { print $1 }' <<<"$active")" || die "awk failed on the active zones"
  zones="$(firewall_list "$@" --get-zones)" || die "cannot list the firewall zones"
  while read -r zone; do
    [[ -n "$zone" && "$zone" != "$TAILNET_ZONE" ]] || continue
    ! zone_rejects_ssh "$zone" "$@" || continue
    if firewall_query "$@" --zone="$zone" --query-service=ssh || zone_lists_port_range "$zone" tcp 22 22 "$@"; then
      printf '%s\n' "$zone"
    elif [[ "$zone" == "$default" ]] || grep -qxF "$zone" <<<"$in_use"; then
      target="$(zone_target "$zone")" || die "cannot read the target of the zone $zone"
      [[ "$target" != ACCEPT ]] || printf '%s\n' "$zone"
    fi
  done <<<"$zones"
}

# Leaves ssh open on the tailnet only: no other firewalld zone lets it in. Order matters: the tailnet zone comes first
# and has to hold the tailnet's source ranges before the other zones close ssh. The sources, not the tailscale0
# interface, are the gate: NetworkManager may put the interface in another zone, but it does not touch sources, and a
# source match wins over an interface. A zone loses its ssh service, and one that still lets ssh in (an open port, or a
# target that accepts everything) gets a reject rule for it. While any ssh client comes from outside the tailnet (a
# remote install over the LAN, or the vekrona-dev VM's host) nothing is closed and the failure is reported: closing
# would cut that session off. Established sessions survive a reload, but the next login would not. 70-verify fails
# until a run from the tailnet or a console closes it.
ensure_tailnet_ssh_only() {
  local src="$VEKRONA_ROOT/etc/firewalld/zones/tailnet.xml" zone reload=0 cidr clients open_zones ssh_service_zones reject_zones still_open
  if ! firewalld_active; then
    warn "firewalld is not running: if sshd runs, it answers on every interface, not only on the tailnet"
    return 0
  fi
  if ! root_file_current "$src" "$TAILNET_ZONE_FILE" 0644; then reload=1; fi
  ensure_root_file "$src" "$TAILNET_ZONE_FILE"
  if [[ $reload -eq 1 ]]; then root firewall-cmd --reload; reload=0; fi
  for cidr in "${TAILNET_SOURCES[@]}"; do
    [[ "$(root firewall-cmd --get-zone-of-source="$cidr")" == "$TAILNET_ZONE" ]] \
      || die "$cidr is not in the $TAILNET_ZONE zone: ssh stays open in the default zone"
  done
  firewall_query --zone="$TAILNET_ZONE" --query-service=ssh || die "the $TAILNET_ZONE zone does not allow ssh"
  [[ "$(root firewall-cmd --get-default-zone)" != "$TAILNET_ZONE" ]] || die "$TAILNET_ZONE is the default zone: every interface would reach sshd"
  open_zones="$(zones_allowing_ssh --permanent)" || die "cannot list the zones that let ssh in"
  clients="$(ssh_clients_off_tailnet)"
  if [[ -n "$clients" ]]; then
    [[ -z "$open_zones" ]] || report_failure "ssh stays open outside the tailnet, in the zones $(tr '\n' ' ' <<<"$open_zones")because it is in use from outside the tailnet ($(tr '\n' ' ' <<<"$clients")): run ./install.sh 40 from a console or over the tailnet to close it"
    return 0
  fi
  ssh_service_zones="$(zones_with_ssh_service --permanent)" || die "cannot list the zones with the ssh service"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    log "removing the ssh service from the zone $zone"
    root firewall-cmd --permanent --zone="$zone" --remove-service=ssh >/dev/null
    reload=1
  done <<<"$ssh_service_zones"
  reject_zones="$(zones_allowing_ssh --permanent)" || die "cannot list the zones that let ssh in"
  while read -r zone; do
    [[ -n "$zone" ]] || continue
    log "rejecting ssh in the zone $zone, which lets it in without the ssh service"
    root firewall-cmd --permanent --zone="$zone" --add-rich-rule="$SSH_REJECT_RULE" >/dev/null
    reload=1
  done <<<"$reject_zones"
  if [[ $reload -eq 1 ]]; then root firewall-cmd --reload; fi
  still_open="$(zones_allowing_ssh)" || die "cannot list the zones that let ssh in"
  [[ -z "$still_open" ]] || die "ssh still gets in through the zones $(tr '\n' ' ' <<<"$still_open")"
}
