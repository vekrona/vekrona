#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/firewall.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export FW="$scratch/fw"
TAILNET_ZONE_FILE="$scratch/tailnet.xml"
source "$ROOT/tests/stages/firewalld-fakes.sh"

ensure() { rc=0; (PATH="$stubs:$PATH" ensure_tailnet_ssh_firewall_gone) >"$scratch/out" 2>&1 || rc=$?; }
rejecting() { PATH="$stubs:$PATH" zones_with_ssh_reject_rule "$@" | tr '\n' ' '; }

stock
for mode in perm run; do
  echo "$SSH_REJECT_RULE" >>"$FW/$mode/public/richrules"
  echo "$SSH_REJECT_RULE" >>"$FW/$mode/trusted/richrules"
done
echo "<zone/>" >"$TAILNET_ZONE_FILE"
[[ "$(rejecting)" == "public trusted " ]] || die "the zones with the ssh reject rule are not found: '$(rejecting)'"
ensure
[[ "$rc" == 0 && -z "$(rejecting)" && -z "$(rejecting --permanent)" ]] || die "an earlier install's ssh reject rules must go, permanent and running: rc=$rc, '$(rejecting)': $(cat "$scratch/out")"
[[ ! -e "$TAILNET_ZONE_FILE" ]] || die "the tailnet zone file of an earlier install must go"
log "ok: the ssh reject rules and the tailnet zone of an earlier install are removed"

before="$(cat "$FW"/perm/*/richrules "$FW"/perm/*/services)"
ensure
[[ "$rc" == 0 && "$(cat "$FW"/perm/*/richrules "$FW"/perm/*/services)" == "$before" ]] || die "a system without them must be left alone: rc=$rc: $(cat "$scratch/out")"
! grep -q 'removing' "$scratch/out" || die "a second run removed something: $(cat "$scratch/out")"
log "ok: a second run changes nothing"

stock
FW_FAIL=--get-zones ensure
[[ "$rc" != 0 ]] || die "a failing firewall-cmd must not read as 'no zone has the rule'"
log "ok: a firewall-cmd that fails is an error"
