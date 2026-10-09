#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
JSON="$VEKRONA_STATE_DIR/updates.json"
SKIP="$VEKRONA_STATE_DIR/update-skip"

skip() { run_as_root "$REPO/libexec/vekrona-update-skip" 2>"$work/err"; }

cat >"$JSON" <<'F'
{"checked": "2026-10-09T09:00:03+02:00", "pending": true, "night_armed": true,
 "groups": [{"name": "Agents", "items": [{"name": "pi", "from": "0.9.1", "to": "0.9.4"}]}]}
F
touch "$work/units/vekrona-update-night.timer.active"
skip
[[ "$(<"$SKIP")" == "$(date +%F)" ]] || die "today's date was not recorded: $(cat "$SKIP")"
[[ ! -e "$work/units/vekrona-update-night.timer.active" ]] || die "the night timer is still armed"
[[ "$(jq -c . "$JSON")" == '{"checked":"2026-10-09T09:00:03+02:00","pending":true,"night_armed":false,"groups":[{"name":"Agents","items":[{"name":"pi","from":"0.9.1","to":"0.9.4"}]}]}' ]] \
  || die "updates.json should only change night_armed: $(cat "$JSON")"
log "ok: skip records today, disarms the night timer and changes nothing else in updates.json"

rm "$JSON"
if skip; then die "skipped with no updates.json"; fi
grep -q 'nothing to skip' "$work/err" || die "no explanation: $(cat "$work/err")"
log "ok: with no updates.json there is nothing to skip"
