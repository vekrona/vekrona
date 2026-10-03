# DMS settings.json helpers that need no stage state beyond two globals:
#   dms_settings      path of settings.json
#   dms_settings_dir  its directory (temp files are created here so mv is atomic)
# Requires log and die from lib/common.sh.

# Set a key on every entry of .barConfigs (a bar is one entry; DMS may have several).
ensure_dms_bar_setting_enforced() {
  local key="$1" json_value="$2"
  jq -e '(.barConfigs // []) | length > 0' "$dms_settings" >/dev/null 2>&1 || die "DMS settings have no barConfigs, cannot enforce bar setting: $key"
  jq -e --arg k "$key" --argjson v "$json_value" '.barConfigs | all(.[$k] == $v)' "$dms_settings" >/dev/null 2>&1 && {
    log "DMS bar setting already enforced: $key = $json_value"
    return 0
  }
  log "enforcing DMS bar setting: $key = $json_value"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! jq --arg k "$key" --argjson v "$json_value" '.barConfigs = (.barConfigs | map(.[$k] = $v))' "$dms_settings" > "$tmp"; then
    rm -f "$tmp"
    die "jq failed to enforce DMS bar setting: $key"
  fi
  mv "$tmp" "$dms_settings"
  jq -e --arg k "$key" --argjson v "$json_value" '.barConfigs | all(.[$k] == $v)' "$dms_settings" >/dev/null || die "DMS bar setting not enforced: $key"
}
