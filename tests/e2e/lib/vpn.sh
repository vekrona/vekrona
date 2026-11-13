# shellcheck shell=bash
# Sourced by the VPN scenarios, after tests/lib.sh (so it lives in lib/, out of reach of a glob that runs every scenario).
#
# The credentials stay on the host, never in the repo, never printed and never in a file of the host:
#   the WireGuard configuration of Proton VPN (or any provider) whose Address has no IPv6 address, as Proton's downloads do, is an item
#                     of the host's keyring (gnome-keyring): application vekrona-vpn, kind e2e-conf, id VEKRONA_VPN_E2E_CONF, which names
#                     the configuration as it imports ("NL-12"). Store it with
#                       secret-tool store --label="vekrona-vpn e2e conf" application vekrona-vpn kind e2e-conf id NL-12 <NL-12.conf
#   the Mullvad account number is an item of the same keyring: application vekrona-vpn, kind e2e-mullvad-account, id
#                     VEKRONA_VPN_E2E_ACCOUNT (the name you choose). Store it with
#                       printf '%s' 1234567890123456 | secret-tool store --label="vekrona-vpn e2e account" application vekrona-vpn kind e2e-mullvad-account id NAME
# A scenario that needs one that is not there is skipped with the reason. `vekrona-vpn` runs in the guest as a systemd user
# service (systemd-run --user), as the bar's popout runs it: polkit lets the units of vekrona-vpn start for the user manager and
# for a local session, and the ssh session of vekrona-dev is neither.
VPN_GUEST_DIR=/tmp/vekrona-e2e-vpn
VPN_STEP_TIMEOUT_SEC=90
# A rejected connection answers in a few milliseconds; a dropped one takes its tool's timeout (at least 5 s, so the two never overlap).
# The bound is 2.5 s, not 1 s, because the kernel rate-limits the ICMP errors that a reject sends (net.ipv4.icmp_ratelimit and
# net.ipv6.icmp.ratelimit, 1000 ms): back-to-back rejections of one family wait about a second for the next error.
VPN_FAST_FAIL_MS=2500
VPN_PROBE_URL_V4=https://1.1.1.1
VPN_PROBE_URL_V6='https://[2606:4700:4700::1111]'
VPN_EXIT_IP_URL=https://api.ipify.org
VPN_DNS_PROBE="$VEKRONA_ROOT/tests/e2e/lib/vpn-dns-probe.py"
VPN_TAILNET_NETNS=vktail
VPN_LAN_NETNS=vklan
export VPN_GUEST_DIR VPN_STEP_TIMEOUT_SEC VPN_DNS_PROBE VPN_FAST_FAIL_MS VPN_PROBE_URL_V4 VPN_PROBE_URL_V6 VPN_EXIT_IP_URL VPN_TAILNET_NETNS VPN_LAN_NETNS

# The configuration as the keyring holds it, on stdout: the text is a key, so it goes to a pipe and never to a file or a log.
vpn_conf_text() { secret-tool lookup application vekrona-vpn kind e2e-conf id "$VEKRONA_VPN_E2E_CONF"; }
require_vpn_conf() {
  [[ -n "${VEKRONA_VPN_E2E_CONF:-}" ]] || skip "no WireGuard configuration: store one in the keyring (see tests/e2e/lib/vpn.sh) and set VEKRONA_VPN_E2E_CONF to its id"
  vpn_conf_text >/dev/null || skip "no WireGuard configuration $VEKRONA_VPN_E2E_CONF in the keyring"
  VPN_CONF_NAME="$VEKRONA_VPN_E2E_CONF"
  export VPN_CONF_NAME
}
# The account number goes to the guest on a pipe, from the keyring of the host; it is never a file.
vpn_mullvad_account_text() { secret-tool lookup application vekrona-vpn kind e2e-mullvad-account id "$VEKRONA_VPN_E2E_ACCOUNT"; }
require_vpn_account() {
  [[ -n "${VEKRONA_VPN_E2E_ACCOUNT:-}" ]] || skip "no Mullvad account number: store one in the keyring (see tests/e2e/lib/vpn.sh) and set VEKRONA_VPN_E2E_ACCOUNT to its id"
  vpn_mullvad_account_text >/dev/null || skip "no Mullvad account number $VEKRONA_VPN_E2E_ACCOUNT in the keyring"
}
# The Proton configuration must have no IPv6 address for the scenarios that look at what IPv6 does then, and must have one for the
# scenarios that send IPv6 through the tunnel.
require_vpn_conf_without_ipv6() {
  if vpn_conf_text | grep -iE '^[[:space:]]*Address[[:space:]]*=.*:' >/dev/null; then
    skip "$VPN_CONF_NAME has an IPv6 address; this scenario needs a configuration without one"
  fi
}
require_vpn_conf_with_ipv6() {
  if ! vpn_conf_text | grep -iE '^[[:space:]]*Address[[:space:]]*=.*:' >/dev/null; then
    skip "$VPN_CONF_NAME has no IPv6 address; this scenario needs a configuration with one"
  fi
}

vpn() { vekrona-dev sh systemd-run --user --pipe --wait --collect --quiet -- vekrona-vpn "$@"; }
vpn_status() { vpn status; }
vpn_status_is() { vpn_status | jq -e "$1" >/dev/null; }
vpn_up() { vpn_status_is '.tunnel == "up"'; }
vpn_down() { vpn_status_is '.tunnel == "down"'; }
export -f vpn vpn_status vpn_status_is vpn_up vpn_down

# The configuration is copied into the guest for the import only, private (stdin to the file, so no host file holds it), and removed by
# vpn_cleanup.
vpn_guest_write() { vekrona-dev run bash -c 'umask 077 && mkdir -p "$(dirname "$1")" && cat >"$1"' _ "$1"; }
vpn_import_conf() {
  vpn_conf_text | vpn_guest_write "$VPN_GUEST_DIR/$VPN_CONF_NAME.conf"
  vpn import --vendor other "$VPN_GUEST_DIR/$VPN_CONF_NAME.conf"
}
# The uuid of the `other` configuration named NAME in `vekrona-vpn list`, or nothing.
vpn_other_uuid() {
  vpn list | jq -r --arg name "$1" '[.vendors[] | select(.id == "other") | .countries[].configs[] | select(.name == $name) | .uuid][0] // empty'
}
vpn_conf_uuid() { vpn_other_uuid "$VPN_CONF_NAME"; }
# Imports the configuration and prints its uuid. The uuid is recorded as soon as the list shows it, before anything that can fail, so
# that cleanup forgets the configuration even when the scenario dies after this.
vpn_import_conf_uuid() {
  local uuid
  vpn_import_conf
  uuid="$(vpn_conf_uuid)"
  vpn_record_made "$uuid"
  [[ -n "$uuid" ]] || die "the imported configuration $VPN_CONF_NAME is not in vekrona-vpn list"
  printf '%s\n' "$uuid"
}
vpn_mullvad_login() {
  { vpn_mullvad_account_text; printf '\n'; } | vpn mullvad login
}
guest_exit_ip() { vekrona-dev run curl -4 -sS --max-time 20 "$VPN_EXIT_IP_URL"; }
export -f vpn_conf_uuid guest_exit_ip

# Runs the command in the guest with its output dropped and prints "<exit status> <milliseconds it took>", measured in the guest.
guest_timed() {
  vekrona-dev run bash -c 'start=$EPOCHREALTIME; "$@" >/dev/null 2>&1; status=$?; end=$EPOCHREALTIME
    echo "$status $(( (${end/./} - ${start/./}) / 1000 ))"' _ "$@"
}
guest_curl_timed() { guest_timed curl -sS --max-time 10 -o /dev/null "$@"; }
# A tool the scenario needs, which vekrona does not ship: installed in the guest when it is missing (dnf runs in the guest only, never on
# the host). Fails when the tool is still missing after that.
guest_tool() {
  vekrona-dev run bash -c '
    if ! command -v "$1" >/dev/null; then sudo dnf -y install "$2" >/dev/null; fi
    command -v "$1" >/dev/null' _ "$1" "$2"
}
# The device of the IPv4 default route that is not the tunnel's: the uplink.
vpn_uplink_device() {
  vekrona-dev run ip -4 route show table main default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) != "vvpn0") { print $(i + 1); exit } }'
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
# Logs the device out of the Mullvad account: the guest's own keyring holds the account and the device, and `mullvad logout` removes
# the device at Mullvad and forgets the Mullvad connections.
vpn_mullvad_logout() { vpn mullvad logout; }
# The connections this scenario made, by uuid, in the guest: every scenario records the ones it creates (vpn_record_made), and cleanup
# forgets those and no other connection of the guest.
vpn_record_made() {
  [[ -n "$1" ]] || return 0
  vekrona-dev run bash -c 'mkdir -p "$1" && printf "%s\n" "$2" >>"$1/made-connections"' _ "$VPN_GUEST_DIR" "$1"
}
vpn_made_connections() { vekrona-dev run bash -c 'cat "$1/made-connections" 2>/dev/null || true' _ "$VPN_GUEST_DIR"; }
vpn_forget_all() {
  local uuid listed
  listed="$(vpn_guest_connections | cut -d: -f1)"
  while IFS= read -r uuid; do
    if grep -qxF -- "$uuid" <<<"$listed"; then vpn forget "$uuid"; fi
  done < <(vpn_made_connections)
}
vpn_cleanup() {
  local steps=(vpn_off)
  if [[ -n "${VEKRONA_VPN_E2E_ACCOUNT:-}" ]]; then steps+=(vpn_mullvad_logout); fi
  run_cleanups "${steps[@]}" vpn_forget_all "vpn_stand_in_down $VPN_TAILNET_NETNS" "vpn_stand_in_down $VPN_LAN_NETNS" \
    'vekrona-dev run rm -rf "$VPN_GUEST_DIR"'
}
vpn_off() { vpn off; }
export -f vpn_off
