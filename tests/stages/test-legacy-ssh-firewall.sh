#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=../../lib/firewall.sh
source "$ROOT/lib/firewall.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export FW="$scratch/fw"
TAILNET_ZONE_FILE="$scratch/tailnet.xml"
# shellcheck source=firewalld-fakes.sh
source "$ROOT/tests/stages/firewalld-fakes.sh"

ensure() { rc=0; (PATH="$stubs:$PATH" ensure_tailnet_ssh_firewall_gone) >"$scratch/out" 2>&1 || rc=$?; }
rejecting() { PATH="$stubs:$PATH" zones_with_ssh_reject_rule "$@" | tr '\n' ' '; }

stock
for name in public trusted; do hold both "$name" rich-rules "$SSH_REJECT_RULE"; done
echo "<zone/>" >"$TAILNET_ZONE_FILE"
[[ "$(rejecting)" == "public trusted " ]] || die "the zones with the ssh reject rule are not found: '$(rejecting)'"
ensure
[[ "$rc" == 0 && -z "$(rejecting)" && -z "$(rejecting --permanent)" ]] || die "an earlier install's ssh reject rules must go, permanent and running: rc=$rc, '$(rejecting)': $(cat "$scratch/out")"
[[ ! -e "$TAILNET_ZONE_FILE" ]] || die "the tailnet zone file of an earlier install must go"
log "ok: the ssh reject rules and the tailnet zone of an earlier install are removed"

before="$(cat "$FW"/perm/*/rich-rules "$FW"/perm/*/services)"
ensure
[[ "$rc" == 0 && "$(cat "$FW"/perm/*/rich-rules "$FW"/perm/*/services)" == "$before" ]] || die "a system without them must be left alone: rc=$rc: $(cat "$scratch/out")"
! grep -q 'removing\|reloading' "$scratch/out" || die "a second run removed or reloaded something: $(cat "$scratch/out")"
log "ok: a second run changes nothing"

stock
hold run internal rich-rules "$SSH_REJECT_RULE"
ensure
[[ "$rc" == 0 && -z "$(rejecting)" ]] || die "a rule that only the running configuration has must be removed by a reload: rc=$rc, '$(rejecting)': $(cat "$scratch/out")"
log "ok: a running zone that still has the rule is reloaded"

stock
FW_FAIL=--get-zones ensure
[[ "$rc" != 0 ]] || die "a failing firewall-cmd must not read as 'no zone has the rule'"
log "ok: a firewall-cmd that fails is an error"
