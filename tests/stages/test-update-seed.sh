#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
JSON="$VEKRONA_STATE_DIR/updates.json"

seed() { run_as_root "$REPO/libexec/vekrona-update-seed" 2>"$work/err"; }

rm -rf "$VEKRONA_STATE_DIR"
seed
[[ "$(jq -c . "$JSON")" == '{"checked":"","pending":false,"night_armed":false,"groups":[]}' ]] || die "a fresh machine did not get the empty state: $(cat "$JSON")"
[[ "$(stat -c %a "$JSON")" == 644 ]] || die "updates.json mode is $(stat -c %a "$JSON")"
log "ok: without a state directory, the seed writes the 'nothing checked yet' state"

echo '{"checked":"2026-10-09T09:00:03+02:00","pending":true,"night_armed":false,"groups":[]}' >"$JSON"
before="$(cat "$JSON")"
seed
[[ "$(cat "$JSON")" == "$before" ]] || die "the seed overwrote a real check result: $(cat "$JSON")"
log "ok: an existing updates.json is left alone"
