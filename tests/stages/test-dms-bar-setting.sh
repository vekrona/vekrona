#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
source "$ROOT/lib/dms-settings.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# die() reports through $VEKRONA_ROOT/bin/vekrona-error when it exists; point it at an empty tree.
VEKRONA_ROOT="$scratch/no-root"

dms_settings_dir="$scratch/dms"
dms_settings="$dms_settings_dir/settings.json"
mkdir -p "$dms_settings_dir"

two_bars() { echo '{"keep":1,"barConfigs":[{"id":"a","spacing":4},{"id":"b"}]}' > "$dms_settings"; }
bar_values() { jq -c --arg k "$1" '[.barConfigs[][$k]]' "$dms_settings"; }
run() { ( "$@" ) >"$scratch/out" 2>&1; }

two_bars
run ensure_dms_bar_setting_enforced spacing 8 || die "enforce failed: $(cat "$scratch/out")"
[[ "$(bar_values spacing)" == '[8,8]' ]] || die "not every bar updated: $(bar_values spacing)"
[[ "$(jq -c '[.barConfigs[].id, .keep]' "$dms_settings")" == '["a","b",1]' ]] || die "enforcing clobbered other keys"
grep -q "enforcing DMS bar setting: spacing = 8" "$scratch/out" || die "first run did not log enforcing: $(cat "$scratch/out")"
log "ok: every bar gets the key, other keys survive"

run ensure_dms_bar_setting_enforced spacing 8 || die "second run failed: $(cat "$scratch/out")"
grep -q "already enforced" "$scratch/out" || die "second run did not log already enforced: $(cat "$scratch/out")"
log "ok: second run is a no-op"

run ensure_dms_bar_setting_enforced noBackground true || die "boolean enforce failed: $(cat "$scratch/out")"
[[ "$(bar_values noBackground)" == '[true,true]' ]] || die "JSON booleans must stay booleans: $(bar_values noBackground)"
log "ok: values are JSON, not strings"

two_bars
jq '.barConfigs[1].spacing = 8 | .barConfigs[0].spacing = 4' "$dms_settings" > "$scratch/mixed" && mv "$scratch/mixed" "$dms_settings"
run ensure_dms_bar_setting_enforced spacing 8 || die "mixed enforce failed"
grep -q "enforcing DMS bar setting" "$scratch/out" || die "one bar already matching must not skip the other"
[[ "$(bar_values spacing)" == '[8,8]' ]] || die "mixed bars not unified: $(bar_values spacing)"
log "ok: one matching bar does not count as enforced"

for broken in '{"keep":1}' '{"barConfigs":[]}'; do
  echo "$broken" > "$dms_settings"
  if run ensure_dms_bar_setting_enforced spacing 8; then die "must die without bars: $broken"; fi
  grep -q "no barConfigs" "$scratch/out" || die "missing bars not explained: $(cat "$scratch/out")"
  [[ "$(cat "$dms_settings")" == "$broken" ]] || die "settings modified despite failure"
done
log "ok: missing or empty barConfigs dies and leaves the file alone"
