#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $(basename "$0") <domain> <timeout-seconds>" >&2; exit 2; }
domain="$1"
timeout="$2"

virsh_() { virsh --connect qemu:///system "$@"; }

bridge="$(virsh_ net-info default | awk -F': *' '/^Bridge/{print $2}')"
[[ -n "$bridge" ]] || { echo "could not determine bridge for network 'default'" >&2; exit 1; }
status_file="/var/lib/libvirt/dnsmasq/$bridge.status"

current_ip() {
  virsh_ domifaddr "$domain" --source lease 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1
}

wait_for_lease_activity() {
  local out rc
  if [[ -e "$status_file" && -r "$status_file" ]]; then
    out="$(inotifywait -q -t 5 -e modify,close_write "$status_file" 2>&1)" && rc=0 || rc=$?
  elif [[ -e "$status_file" ]]; then
    out="$(sudo inotifywait -q -t 5 -e modify,close_write "$status_file" 2>&1)" && rc=0 || rc=$?
  else
    out="$(inotifywait -q -t 5 -e create "$(dirname "$status_file")" 2>&1)" && rc=0 || rc=$?
  fi
  case "$rc" in
    0 | 2) return 0 ;;
    *)
      echo "inotifywait failed while watching for a DHCP lease on $status_file: $out" >&2
      return 1
      ;;
  esac
}

deadline=$((SECONDS + timeout))
ip="$(current_ip)"
while [[ -z "$ip" ]]; do
  (( SECONDS < deadline )) || { echo "VM '$domain' did not get an IPv4 address within ${timeout}s" >&2; exit 1; }
  wait_for_lease_activity
  ip="$(current_ip)"
done

echo "$ip"
