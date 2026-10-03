#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
source "$ROOT/lib/luks-fido2.sh"
FIXTURES="$ROOT/tests/fixtures/crypttab"

UUID_PREFIX=0a1b2c3d-0000-4000-8000-00000000000
TOKEN_NAMES=("luks-${UUID_PREFIX}1" "luks-${UUID_PREFIX}3" "luks-${UUID_PREFIX}4")

installer="$(<"$FIXTURES/installer")"
expected="$(<"$FIXTURES/fido2-enabled")"

got="$(crypttab_with_fido2 "$installer" "${TOKEN_NAMES[@]}")"
[[ "$got" == "$expected" ]] || die "crypttab_with_fido2 on the installer's crypttab differs from tests/fixtures/crypttab/fido2-enabled:
$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") || true)"
log "ok: the installer's crypttab gains the fido2 options on token devices only"

again="$(crypttab_with_fido2 "$expected" "${TOKEN_NAMES[@]}")"
[[ "$again" == "$expected" ]] || die "crypttab_with_fido2 is not idempotent on an already prepared crypttab"
log "ok: an already prepared crypttab is left unchanged"

for name in "${TOKEN_NAMES[@]}"; do
  crypttab_line_has_fido2 "$expected" "$name" || die "$name should carry fido2-device in the prepared fixture"
done
! crypttab_line_has_fido2 "$expected" "luks-${UUID_PREFIX}2" || die "the tokenless device must not carry fido2-device"
log "ok: crypttab_line_has_fido2 agrees with the prepared fixture"

CRYPTTAB="$(mktemp -d)/crypttab"
absent="$(read_crypttab)" || die "a system without $CRYPTTAB must not fail the stage"
[[ -z "$absent" ]] || die "a system without $CRYPTTAB must read as empty, got: $absent"
[[ -z "$(crypttab_fido2_tokens "$absent")" ]] || die "no crypttab must mean no devices to unlock"
log "ok: a system without a crypttab has no LUKS devices"
