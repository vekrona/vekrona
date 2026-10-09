#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state" XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_CONFIG_HOME/vekrona"
override="$XDG_CONFIG_HOME/vekrona/weather.json"
output="$XDG_STATE_HOME/vekrona/weather.json"

write_override() { printf '{"latitude": %s, "longitude": 13.4, "name": "Berlin"}\n' "$1" >"$override"; }
output_field() { python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$output" "$1"; }

write_override 52.5
VEKRONA_WEATHER_URL="file://$ROOT/tests/fixtures/open-meteo.json" "$ROOT/bin/vekrona-weather"
[[ "$(output_field current)" == '{"temperature": 37.4, "weather_code": 3, "is_day": true}' ]] || die "current weather does not match the fixture: $(output_field current)"
[[ "$(output_field error)" == null ]] || die "a good fetch must leave error null: $(output_field error)"
[[ "$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["daily"]))' "$output")" == 7 ]] || die "expected seven forecast days"
[[ "$(output_field location)" == '{"name": "Berlin", "latitude": 52.5, "longitude": 13.4}' ]] || die "location does not match the override: $(output_field location)"
log "ok: the forecast fixture becomes the widget's data"

VEKRONA_WEATHER_URL="file://$scratch/missing.json" "$ROOT/bin/vekrona-weather" 2>/dev/null || die "an unreachable forecast must be surfaced in the output, not fail the unit"
[[ "$(output_field error)" != null ]] || die "an unreachable forecast must set error"
[[ "$(output_field current)" == '{"temperature": 37.4, "weather_code": 3, "is_day": true}' ]] || die "an unreachable forecast must keep the last good current weather"
log "ok: a fetch failure sets error and keeps the last good data"

printf 'not json' >"$scratch/garbage.json"
if VEKRONA_WEATHER_URL="file://$scratch/garbage.json" "$ROOT/bin/vekrona-weather" 2>/dev/null; then
  die "a forecast that is not JSON must fail the unit"
fi
log "ok: malformed API data fails the unit"

for bad in '"lizard"' null 91 -1e999; do
  write_override "$bad"
  if "$ROOT/bin/vekrona-weather" 2>/dev/null; then
    die "an override with latitude $bad must fail the unit"
  fi
done
printf '[]' >"$override"
if "$ROOT/bin/vekrona-weather" 2>/dev/null; then
  die "an override that is not an object must fail the unit"
fi
log "ok: a malformed location override fails the unit"
