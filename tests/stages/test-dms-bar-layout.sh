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

run() { ( "$@" ) >"$scratch/out" 2>&1; }
write_bar() { jq -n --argjson left "$1" --argjson right "$2" '{keep:1,barConfigs:[{id:"a",leftWidgets:$left,rightWidgets:$right},{id:"b",leftWidgets:$left,rightWidgets:$right}]}' > "$dms_settings"; }
sections() { jq -c '[.barConfigs[0] | .leftWidgets, .rightWidgets]' "$dms_settings"; }
expect_sections() { [[ "$(sections)" == "$1" ]] || die "$2: $(sections)"; }

# --- separator ---------------------------------------------------------------

write_bar '["launcher","workspaces","title"]' '["clock"]'
run ensure_dms_bar_separator_after workspaces || die "separator failed: $(cat "$scratch/out")"
expect_sections '[["launcher","workspaces","separator","title"],["clock"]]' "separator not inserted right after the widget"
[[ "$(jq -c '[.barConfigs[].leftWidgets]|unique|length' "$dms_settings")" == 1 ]] || die "not every bar got the separator"
[[ "$(jq .keep "$dms_settings")" == 1 ]] || die "other keys clobbered"
grep -q "changed DMS settings" "$scratch/out" || die "change not logged: $(cat "$scratch/out")"
log "ok: separator inserted right after the widget in every bar"

run ensure_dms_bar_separator_after workspaces || die "second separator run failed"
expect_sections '[["launcher","workspaces","separator","title"],["clock"]]' "second run duplicated the separator"
grep -q "already as wanted" "$scratch/out" || die "second run did not log a no-op: $(cat "$scratch/out")"
log "ok: separator second run is a no-op"

write_bar '["launcher","title"]' '["clock"]'
run ensure_dms_bar_separator_after workspaces || die "absent-widget run failed"
expect_sections '[["launcher","title"],["clock"]]' "absent widget changed the bar"
log "ok: absent widget leaves bars unchanged"

write_bar '["workspaces",{"id":"separator"},"title"]' '["clock"]'
run ensure_dms_bar_separator_after workspaces || die "object-separator run failed"
expect_sections '[["workspaces",{"id":"separator"},"title"],["clock"]]' "object-form separator not recognized"
log "ok: an existing object-form separator counts"

write_bar '[{"id":"workspaces","x":1}]' '["clock"]'
run ensure_dms_bar_separator_after workspaces || die "object-widget run failed"
expect_sections '[[{"id":"workspaces","x":1},"separator"],["clock"]]' "object-form widget not found at the section end"
log "ok: object-form widget at the end of a section is found"

# --- control center split ----------------------------------------------------

audio_only() { jq -c '[.rightWidgets[] | select(type=="object" and .showAudioIcon==true)] | length' <<<"$1"; }

write_bar '[]' '["battery","controlCenterButton","clock"]'
run ensure_dms_bar_control_center_split || die "split failed: $(cat "$scratch/out")"
bar="$(jq -c '.barConfigs[0]' "$dms_settings")"
[[ "$(jq -c '[.rightWidgets[] | if type=="object" then .id else . end]' <<<"$bar")" == '["battery","controlCenterButton","controlCenterButton","clock"]' ]] || die "not split in place: $bar"
[[ "$(jq -c '.rightWidgets[1]' <<<"$bar")" == '{"id":"controlCenterButton","showAudioIcon":false}' ]] || die "first half must only hide audio: $bar"
[[ "$(jq -c '.rightWidgets[2] | del(.id) | [to_entries[] | select(.value)] | map(.key)' <<<"$bar")" == '["showAudioIcon"]' ]] || die "second half must show only audio: $bar"
[[ "$(jq -c '.rightWidgets[2] | del(.id) | keys | length' <<<"$bar")" == 14 ]] || die "second half must set all 14 flags explicitly: $bar"
[[ "$(jq -c '.barConfigs[1].rightWidgets == .barConfigs[0].rightWidgets' "$dms_settings")" == true ]] || die "second bar not split alike"
log "ok: controlCenterButton split in two, audio icon alone in the second"

before="$(cat "$dms_settings")"
run ensure_dms_bar_control_center_split || die "second split run failed"
[[ "$(cat "$dms_settings")" == "$before" ]] || die "second split run changed the file"
grep -q "already as wanted" "$scratch/out" || die "second split run did not log a no-op"
log "ok: split second run is a no-op"

write_bar '[]' '[{"id":"controlCenterButton","showVpnIcon":true},"clock"]'
run ensure_dms_bar_control_center_split || die "object split failed"
[[ "$(jq -c '.barConfigs[0].rightWidgets[0]' "$dms_settings")" == '{"id":"controlCenterButton","showVpnIcon":true,"showAudioIcon":false}' ]] || die "object-form first half lost its own keys: $(sections)"
[[ "$(audio_only "$(jq -c '.barConfigs[0]' "$dms_settings")")" == 1 ]] || die "object form not split: $(sections)"
log "ok: object-form controlCenterButton is split and keeps its keys"

write_bar '[]' '["battery","controlCenterButton","clock"]'
run ensure_dms_bar_control_center_split || die "split before newline-less rewrite failed"
printf '%s' "$(cat "$dms_settings")" > "$dms_settings"
touch -d '2001-01-01' "$dms_settings"
before="$(stat -c '%Y %i' "$dms_settings")"
run ensure_dms_bar_control_center_split || die "run on newline-less settings failed"
grep -q "already as wanted" "$scratch/out" || die "newline-less identical settings counted as changed: $(cat "$scratch/out")"
[[ "$(stat -c '%Y %i' "$dms_settings")" == "$before" ]] || die "newline-less identical settings were rewritten"
log "ok: settings equal in content but lacking the trailing newline are not rewritten"

write_bar '[]' '["clock"]'
run ensure_dms_bar_control_center_split || die "no-button run failed"
expect_sections '[[],["clock"]]' "bar without controlCenterButton changed"
log "ok: bar without controlCenterButton unchanged"

# --- plugin placement --------------------------------------------------------

write_bar '[]' '["battery","clock"]'
run ensure_dms_bar_widget_plugin clock vekronaClock || die "plugin swap failed: $(cat "$scratch/out")"
expect_sections '[[],["battery","vekronaClock"]]' "stock widget not replaced in place by the plugin"
run ensure_dms_bar_widget_plugin clock vekronaClock || die "second plugin swap failed"
expect_sections '[[],["battery","vekronaClock"]]' "second plugin swap changed the bar"
log "ok: a stock widget is replaced in place by its plugin, once"

write_bar '[]' '["battery","clock"]'
run ensure_dms_bar_widget_inserted_before vekronaAgent clock || die "insert failed: $(cat "$scratch/out")"
expect_sections '[[],["battery","vekronaAgent","clock"]]' "widget not inserted before its anchor"
run ensure_dms_bar_widget_inserted_before vekronaAgent clock || die "second insert failed"
expect_sections '[[],["battery","vekronaAgent","clock"]]' "second insert duplicated the widget"
log "ok: a widget is inserted before its anchor, once"

# --- missing bars ------------------------------------------------------------

for helper in "ensure_dms_bar_separator_after workspaces" "ensure_dms_bar_control_center_split" "ensure_dms_bar_widget_plugin clock vekronaClock" "ensure_dms_bar_widget_inserted_before vekronaAgent clock"; do
  for broken in '{"keep":1}' '{"barConfigs":[]}'; do
    echo "$broken" > "$dms_settings"
    if run $helper; then die "$helper must die without bars: $broken"; fi
    grep -q "no barConfigs" "$scratch/out" || die "missing bars not explained: $(cat "$scratch/out")"
    [[ "$(cat "$dms_settings")" == "$broken" ]] || die "settings modified despite failure"
  done
done
log "ok: missing or empty barConfigs dies and leaves the file alone"
