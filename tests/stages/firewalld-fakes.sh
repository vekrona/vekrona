#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
# A fake firewalld for the tests of lib/firewall.sh (source it after tests/lib.sh). The caller sets $scratch, $stubs (a
# directory first on PATH) and $FW (the firewalld state). `stock` resets the state to a stock Fedora Workstation.
write_fake "$stubs/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
# A firewalld of one permanent and one running configuration, a directory of files per zone and mode.
write_fake "$stubs/firewall-cmd" <<'F'
#!/usr/bin/env bash
set -euo pipefail
mode=run zone="" zone_given=0 action="" others=0
for arg in "$@"; do
  case "$arg" in
    --permanent) mode=perm; others=1 ;;
    --zone=*) zone="${arg#--zone=}"; zone_given=1; others=1 ;;
    *) [[ -z "$action" ]] || { echo "firewall-cmd stub: two actions in $*" >&2; exit 2; }; action="$arg" ;;
  esac
done
# firewall-cmd's own argument checks: a stand-alone option takes no other option, the target only --permanent.
usage="usage: 'firewall-cmd --help' for usage information or see firewall-cmd(1) man page"
case "$action" in
  --state|--reload|--complete-reload|--runtime-to-permanent|--reset-to-defaults|--check-config|--get-default-zone|--set-default-zone=*|--get-active-zones|--get-active-policies|--panic-on|--panic-off|--query-panic|--lockdown-on|--lockdown-off|--query-lockdown|--get-log-denied|--get-ipset-types)
    if [[ $others -eq 1 ]]; then printf "%s\nCan't use stand-alone options with other options.\n" "$usage" >&2; exit 2; fi ;;
  --get-target|--set-target=*)
    if [[ "$mode" != perm ]]; then printf '%s\nOption can be used only with --permanent.\n' "$usage" >&2; exit 2; fi ;;
esac
# FW_FAIL=--get-zones makes that option fail the way firewall-cmd does when firewalld stopped answering (status 252).
if [[ "${action%%=*}" == "${FW_FAIL:-none}" ]]; then echo "FirewallD is not running" >&2; exit 252; fi
# Like the real one: an empty --zone= is no zone, and no --zone at all means the default zone.
if [[ $zone_given -eq 1 && -z "$zone" ]]; then echo "Error: INVALID_ZONE: ''" >&2; exit 111; fi
[[ -n "$zone" ]] || zone="$(cat "$FW/default")"
dir="$FW/$mode"
has_line() { grep -qxF "$2" "$dir/$zone/$1"; }
# Removes the whole line from the zone's file; like firewall-cmd, removing what is not there is no error.
drop_line() { { grep -vxF -- "$2" "$dir/$zone/$1" || true; } >"$dir/$zone/$1.new" && mv "$dir/$zone/$1.new" "$dir/$zone/$1"; }
# --query-* print yes or no and exit 0 or 1.
query() { if has_line "$1" "$2"; then echo yes; else echo no; exit 1; fi; }
case "$action" in
  --reload) rm -rf "$FW/run" && cp -r "$FW/perm" "$FW/run" ;;
  --get-zones) ls "$dir" | tr '\n' ' ' ;;
  --get-default-zone) cat "$FW/default" ;;
  --set-default-zone=*)
    # Like firewalld: the interfaces of the old default zone move to the new one, in both configurations.
    new="${action#--set-default-zone=}"
    [[ -d "$FW/perm/$new" ]] || { echo "Error: INVALID_ZONE: $new" >&2; exit 101; }
    for m in perm run; do cat "$FW/$m/$(<"$FW/default")/interfaces" >>"$FW/$m/$new/interfaces"; : >"$FW/$m/$(<"$FW/default")/interfaces"; done
    echo "$new" >"$FW/default" ;;
  --get-services) echo "${FW_SERVICES:-dhcpv6-client mdns samba-client ssh steam-lan-transfer steam-streaming syncthing syncthing-gui}" ;;
  --get-active-zones)
    for z in $(ls "$dir"); do
      if [[ -s "$dir/$z/interfaces" || -s "$dir/$z/sources" ]]; then printf '%s\n  interfaces: %s\n' "$z" "$(tr '\n' ' ' <"$dir/$z/interfaces")"; fi
    done ;;
  --get-target) cat "$dir/$zone/target" ;;
  --set-target=*) echo "${action#--set-target=}" >"$dir/$zone/target" ;;
  --query-service=*) query services "${action#--query-service=}" ;;
  --query-rich-rule=*) query rich-rules "${action#--query-rich-rule=}" ;;
  --query-masquerade) if [[ -s "$dir/$zone/masquerade" ]]; then echo yes; else echo no; exit 1; fi ;;
  # Ports, protocols and source ports are listed on one line, forward ports and rich rules one per line.
  --list-services|--list-ports|--list-protocols|--list-source-ports) tr '\n' ' ' <"$dir/$zone/${action#--list-}" ;;
  --list-forward-ports|--list-rich-rules) cat "$dir/$zone/${action#--list-}" ;;
  # Changes apply to the configuration the mode names, the runtime one as well as the permanent one.
  --add-service=*) echo "${action#--add-service=}" >>"$dir/$zone/services" ;;
  --remove-masquerade) : >"$dir/$zone/masquerade" ;;
  --remove-service=*|--remove-port=*|--remove-protocol=*|--remove-source-port=*|--remove-forward-port=*|--remove-rich-rule=*)
    option="${action%%=*}"
    drop_line "${option#--remove-}s" "${action#*=}" ;;
  *) echo "firewall-cmd stub: unexpected $*" >&2; exit 99 ;;
esac
F

# zone NAME TARGET "SERVICES" "PORTS" "INTERFACES" "SOURCES": one zone, in both configurations, holding nothing else.
zone() {
  local mode kind name="$1"
  for mode in perm run; do
    mkdir -p "$FW/$mode/$name"
    printf '%s\n' "$2" >"$FW/$mode/$name/target"
    printf '%s\n' "$3" | tr ' ' '\n' | sed '/^$/d' >"$FW/$mode/$name/services"
    printf '%s\n' "$4" | tr ' ' '\n' | sed '/^$/d' >"$FW/$mode/$name/ports"
    printf '%s\n' "$5" | tr ' ' '\n' | sed '/^$/d' >"$FW/$mode/$name/interfaces"
    printf '%s\n' "$6" | tr ' ' '\n' | sed '/^$/d' >"$FW/$mode/$name/sources"
    for kind in protocols source-ports forward-ports rich-rules masquerade; do : >"$FW/$mode/$name/$kind"; done
  done
}
# hold MODE ZONE KIND VALUE: one more line in a file of the zone (services, ports, protocols, source-ports, forward-ports,
# rich-rules, masquerade). MODE is perm, run or both.
hold() {
  local mode
  for mode in ${1/both/perm run}; do printf '%s\n' "$4" >>"$FW/$mode/$2/$3"; done
}
# firewalld of a stock Fedora Workstation: ssh in every zone but trusted, and the workstation zone in use.
stock() {
  rm -rf "$FW"
  mkdir -p "$FW"
  echo "${1:-FedoraWorkstation}" >"$FW/default"
  zone FedoraWorkstation default "dhcpv6-client samba-client ssh" "1025-65535/tcp 1025-65535/udp" "eth0" ""
  zone public default "dhcpv6-client mdns ssh" "" "" ""
  zone internal default "dhcpv6-client ssh" "" "" ""
  zone trusted ACCEPT "" "" "" ""
}
