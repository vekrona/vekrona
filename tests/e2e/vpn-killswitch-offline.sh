#!/usr/bin/env bash
# The privileged helper of vekrona-vpn (vekrona-vpn-apply@.service) can run nft under SELinux, which Fedora enforces. With
# NoNewPrivileges=yes the exec of /usr/bin/nft (init_t to iptables_t) is denied (nnp_transition), so `connect` died with
# "nft: Permission denied" and armed nothing. A WireGuard configuration generated here, whose peer is a TEST-NET address that
# answers nothing, is enough to see the helper work, so the scenario needs no secrets and no network:
#   - `connect` succeeds and the kill switch table inet vekrona-vpn exists;
#   - `off` removes the table;
#   - the helper (comm vekrona-vpn-app) was denied nothing by SELinux while the scenario ran.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn.sh
source "$ROOT/tests/e2e/lib/vpn.sh"

CONF_NAME=NL-offline
GUEST_CONF="$VPN_GUEST_DIR/$CONF_NAME.conf"

other_conf_uuid() {
  vpn list | jq -r --arg name "$CONF_NAME" '[.vendors[] | select(.id == "other") | .countries[].configs[] | select(.name == $name) | .uuid][0] // empty'
}
write_conf() {
  vekrona-dev run bash -c 'umask 077 && mkdir -p "$(dirname "$1")" \
    && printf "[Interface]\nPrivateKey = %s\nAddress = 10.99.0.2/32\nDNS = 10.99.0.1\n\n[Peer]\nPublicKey = %s\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n" \
      "$(wg genkey)" "$(wg genkey | wg pubkey)" >"$1"' _ "$GUEST_CONF"
}
table_present() { vekrona-dev run sudo nft list table inet vekrona-vpn >/dev/null; }
# Whether the audit log holds an AVC of the helper since $1 ("date time", as `date +"%x %T"` prints it). ausearch says "<no matches>"
# when there is none, reads standard input unless it is given the log, and exits 1 for an unreadable time as well, so its output
# tells the cases apart.
avc_denied_since() {
  local out date time
  read -r date time <<<"$1"
  out="$(vekrona-dev run bash -c 'sudo ausearch -if /var/log/audit/audit.log -m AVC -c vekrona-vpn-app -ts "$1" "$2" 2>&1 || true' _ "$date" "$time")"
  if grep -q '^type=AVC' <<<"$out"; then
    printf '%s\n' "$out"
  elif [[ "$out" != '<no matches>' ]]; then
    abort "cannot tell whether the helper was denied, ausearch said: $out"
  else
    return 1
  fi
}

[[ "$(vekrona-dev run getenforce)" == Enforcing ]] || die "the guest must enforce SELinux for this scenario to mean anything"

vekrona-dev session
trap vpn_cleanup EXIT
vpn_cleanup
START="$(vekrona-dev run date '+%x %T')"

write_conf
vpn import --vendor other "$GUEST_CONF"
UUID="$(other_conf_uuid)"
[[ -n "$UUID" ]] || die "the imported configuration $CONF_NAME is not in vekrona-vpn list under other"

vpn connect "$UUID" || die "connect must succeed: the helper could not run nft"
table_present || die "connect must arm the kill switch: the table inet vekrona-vpn does not exist"
log "ok: connect arms the kill switch"

vpn off
absent table_present || die "the kill switch table must be gone after off"
log "ok: off removes the kill switch"

absent avc_denied_since "$START" || die "SELinux denied the helper (comm vekrona-vpn-app): $(avc_denied_since "$START")"
log "ok: SELinux denied the helper nothing"

vpn forget "$UUID"
[[ -z "$(other_conf_uuid)" ]] || die "forget must remove the configuration"
