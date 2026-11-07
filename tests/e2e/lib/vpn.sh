# shellcheck shell=bash
# Sourced by the VPN scenarios, after tests/lib.sh (so it lives in lib/, out of reach of a glob that runs every scenario).
#
# The credentials stay on the host, never in the repo and never printed, in $VPN_SECRETS_DIR (default ~/.cache/vekrona-vpn-secrets):
#   *.conf            a WireGuard configuration of Proton VPN (or any provider) whose Address has no IPv6 address, as Proton's
#                     downloads do; the first one by name is used. Its file name should start with the country ("NL-12.conf")
#   mullvad-account   the Mullvad account number
# A scenario that needs one that is not there is skipped with the reason. `vekrona-vpn` runs in the guest as a systemd user
# service (systemd-run --user), as the bar's popout runs it: polkit lets the units of vekrona-vpn start for the user manager and
# for a local session, and the ssh session of vekrona-dev is neither.
VPN_SECRETS_DIR="${VEKRONA_VPN_SECRETS_DIR:-$HOME/.cache/vekrona-vpn-secrets}"
VPN_GUEST_DIR=/tmp/vekrona-e2e-vpn
VPN_STEP_TIMEOUT_SEC=90
# A rejected connection answers in a few milliseconds; a dropped one takes the curl timeout.
VPN_FAST_FAIL_MS=1000
VPN_PROBE_URL_V4=https://1.1.1.1
VPN_PROBE_URL_V6='https://[2606:4700:4700::1111]'
VPN_EXIT_IP_URL=https://api.ipify.org
VPN_DNS_PROBE="$VEKRONA_ROOT/tests/e2e/lib/vpn-dns-probe.py"
VPN_TAILNET_NETNS=vktail
VPN_LAN_NETNS=vklan
export VPN_GUEST_DIR VPN_STEP_TIMEOUT_SEC VPN_DNS_PROBE VPN_FAST_FAIL_MS VPN_PROBE_URL_V4 VPN_PROBE_URL_V6 VPN_EXIT_IP_URL VPN_TAILNET_NETNS VPN_LAN_NETNS

require_vpn_conf() {
  local files=("$VPN_SECRETS_DIR"/*.conf)
  [[ -f "${files[0]}" ]] || skip "no WireGuard configuration: put a Proton *.conf in $VPN_SECRETS_DIR"
  VPN_CONF="${files[0]}"
  VPN_CONF_NAME="$(basename "$VPN_CONF" .conf)"
  export VPN_CONF VPN_CONF_NAME
}
require_vpn_account() {
  [[ -s "$VPN_SECRETS_DIR/mullvad-account" ]] || skip "no Mullvad account number: put it in $VPN_SECRETS_DIR/mullvad-account"
}
# The Proton configuration must have no IPv6 address for the scenarios that look at what IPv6 does then.
require_vpn_conf_without_ipv6() {
  if grep -iE '^[[:space:]]*Address[[:space:]]*=.*:' "$VPN_CONF" >/dev/null; then
    skip "$VPN_CONF has an IPv6 address; this scenario needs a configuration without one"
  fi
}

vpn() { vekrona-dev sh systemd-run --user --pipe --wait --collect --quiet -- vekrona-vpn "$@"; }
vpn_status() { vpn status; }
vpn_status_is() { vpn_status | jq -e "$1" >/dev/null; }
vpn_up() { vpn_status_is '.tunnel == "up"'; }
vpn_down() { vpn_status_is '.tunnel == "down"'; }
export -f vpn vpn_status vpn_status_is vpn_up vpn_down

# The configuration is copied into the guest for the import only, private, and removed by vpn_cleanup.
vpn_guest_write() { vekrona-dev run bash -c 'umask 077 && mkdir -p "$(dirname "$1")" && cat >"$1"' _ "$2" <"$1"; }
vpn_import_conf() {
  vpn_guest_write "$VPN_CONF" "$VPN_GUEST_DIR/$VPN_CONF_NAME.conf"
  vpn import --vendor proton "$VPN_GUEST_DIR/$VPN_CONF_NAME.conf"
}
vpn_conf_uuid() {
  vpn list | jq -r --arg name "$VPN_CONF_NAME" '[.vendors[] | select(.id == "proton") | .countries[].configs[] | select(.name == $name) | .uuid][0] // empty'
}
# Imports the configuration and prints its uuid; dies when vekrona-vpn list does not show the configuration under its country.
vpn_import_conf_uuid() {
  local uuid
  vpn_import_conf
  uuid="$(vpn_conf_uuid)"
  [[ -n "$uuid" ]] || die "the imported configuration $VPN_CONF_NAME is not in vekrona-vpn list"
  printf '%s\n' "$uuid"
}
vpn_mullvad_login() {
  local account
  account="$(<"$VPN_SECRETS_DIR/mullvad-account")"
  printf '%s\n' "$account" | vpn mullvad login
}
guest_exit_ip() { vekrona-dev run curl -4 -sS --max-time 20 "$VPN_EXIT_IP_URL"; }
export -f vpn_conf_uuid guest_exit_ip

# Runs curl in the guest with the arguments given and prints "<curl exit status> <milliseconds it took>", measured in the guest.
guest_curl_timed() {
  vekrona-dev run bash -c 'start=$EPOCHREALTIME; curl -sS --max-time 10 -o /dev/null "$@" >/dev/null 2>&1; status=$?; end=$EPOCHREALTIME
    echo "$status $(( (${end/./} - ${start/./}) / 1000 ))"' _ "$@"
}
# Fails unless curl failed, and failed at once: not by its timeout (status 28), and within VPN_FAST_FAIL_MS.
expect_fails_fast() {
  local what="$1" status ms
  shift
  read -r status ms < <(guest_curl_timed "$@")
  [[ "$status" =~ ^[0-9]+$ && "$ms" =~ ^[0-9]+$ ]] || die "$what: cannot read the result of curl: '$status $ms'"
  ((status != 0)) || die "$what: the connection succeeded, but it must be rejected"
  ((status != 28)) || die "$what: curl ran into its timeout, so the packets were dropped, not rejected"
  ((ms < VPN_FAST_FAIL_MS)) || die "$what: the failure took $ms ms, so it was not an immediate rejection"
}

# A network of its own on a veth pair, with a web server on the far end: $1 namespace, $2 the guest's interface name, $3 the
# guest's address with prefix, $4 the server's address with prefix. The server's address is what the scenario fetches.
vpn_stand_in_up() {
  vekrona-dev run sudo bash -c '
    set -euo pipefail
    ! ip link show "$2" >/dev/null 2>&1 || { echo "$2 exists already" >&2; exit 1; }
    ip netns add "$1"
    ip link add "$2" type veth peer name "$2-p"
    ip link set "$2-p" netns "$1"
    ip addr add "$3" dev "$2"
    ip link set "$2" up
    ip netns exec "$1" ip addr add "$4" dev "$2-p"
    ip netns exec "$1" ip link set "$2-p" up
    ip netns exec "$1" ip link set lo up' _ "$1" "$2" "$3" "$4"
  vekrona-dev spawn --root "/tmp/vekrona-e2e-vpn-$1.log" -- ip netns exec "$1" python3 -m http.server 8080 --bind "${4%/*}" --directory /tmp
}
vpn_stand_in_down() {
  vekrona-dev run sudo bash -c 'if [[ -e "/run/netns/$1" ]]; then ip netns pids "$1" | xargs --no-run-if-empty kill; ip netns del "$1"; fi; rm -f "/tmp/vekrona-e2e-vpn-$1.log"' _ "$1"
}
export -f vpn_stand_in_up vpn_stand_in_down

# Removes what a scenario made: the tunnel and the kill switch, every connection of vekrona-vpn (a Mullvad one first gives its
# device back to the account), the stand-in networks and the copied configuration.
vpn_guest_connections() { vekrona-dev run nmcli -t -f UUID,TYPE,NAME connection show | grep -E '^[0-9a-f-]{36}:wireguard:vekrona-vpn/' || true; }
vpn_revoke_mullvad_devices() {
  local line uuid pubkey token device
  while IFS= read -r line; do
    [[ "$line" == *':wireguard:vekrona-vpn/mullvad/'* ]] || continue
    uuid="${line%%:*}"
    pubkey="$(vekrona-dev run bash -c 'sudo nmcli -s -e no -g wireguard.private-key connection show uuid "$1" | wg pubkey' _ "$uuid")"
    token="$(curl -fsS -X POST https://api.mullvad.net/auth/v1/token -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg account "$(<"$VPN_SECRETS_DIR/mullvad-account")" '{account_number: $account}')" | jq -r .access_token)"
    device="$(curl -fsS https://api.mullvad.net/accounts/v1/devices -H "Authorization: Bearer $token" | jq -r --arg key "$pubkey" '.[] | select(.pubkey == $key) | .id')"
    [[ -n "$device" ]] || die "Mullvad does not list the device of $uuid; remove it at https://mullvad.net/account"
    curl -fsS -X DELETE "https://api.mullvad.net/accounts/v1/devices/$device" -H "Authorization: Bearer $token" >/dev/null
  done < <(vpn_guest_connections)
}
vpn_forget_all() {
  local line
  while IFS= read -r line; do
    vpn forget "${line%%:*}"
  done < <(vpn_guest_connections)
}
vpn_cleanup() {
  local steps=(vpn_off)
  if [[ -s "$VPN_SECRETS_DIR/mullvad-account" ]]; then steps+=(vpn_revoke_mullvad_devices); fi
  run_cleanups "${steps[@]}" vpn_forget_all "vpn_stand_in_down $VPN_TAILNET_NETNS" "vpn_stand_in_down $VPN_LAN_NETNS" \
    'vekrona-dev run rm -rf "$VPN_GUEST_DIR"'
}
vpn_off() { vpn off; }
export -f vpn_off
