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

# Run the python program on stdin as `python3 -c program settings.json args...`; it prints the new
# settings JSON. Replaces settings.json and logs only when the parsed JSON differs (DMS writes no
# trailing newline, so a byte comparison would see a change after every DMS restart).
dms_rewrite_settings() {
  local what="$1"; shift
  local program tmp
  program="$(cat)"
  jq -e '(.barConfigs // []) | length > 0' "$dms_settings" >/dev/null 2>&1 || die "DMS settings have no barConfigs, cannot change: $what"
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! python3 -c "$program" "$dms_settings" "$@" > "$tmp"; then
    rm -f "$tmp"
    die "python3 failed to change DMS settings: $what"
  fi
  if jq -n -e --slurpfile a "$tmp" --slurpfile b "$dms_settings" '$a == $b' >/dev/null; then
    rm -f "$tmp"
    log "DMS settings already as wanted: $what"
  else
    mv "$tmp" "$dms_settings"
    log "changed DMS settings: $what"
  fi
}

# Put a thin separator right after <widget> in every bar, unless one is already there.
ensure_dms_bar_separator_after() {
  local widget_id="$1"
  dms_rewrite_settings "separator after $widget_id" "$widget_id" <<'PYEOF'
import json
import sys

path, widget_id = sys.argv[1], sys.argv[2]

def widget_name(entry):
    return entry.get("id") if isinstance(entry, dict) else entry

with open(path) as f:
    data = json.load(f)

for bar in data["barConfigs"]:
    for key in ("leftWidgets", "centerWidgets", "rightWidgets"):
        widgets = bar.get(key)
        if not isinstance(widgets, list):
            continue
        names = [widget_name(w) for w in widgets]
        if widget_id not in names:
            continue
        at = names.index(widget_id) + 1
        if names[at:at + 1] != ["separator"]:
            widgets.insert(at, "separator")

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}

# controlCenterButton flags that choose which icons the button shows (ControlCenterButton.qml).
dms_control_center_flags="showNetworkIcon showBluetoothIcon showAudioIcon showAudioPercent showVpnIcon showBrightnessIcon showBrightnessPercent showMicIcon showMicPercent showBatteryIcon showPrinterIcon showScreenSharingIcon showIdleInhibitorIcon showDoNotDisturbIcon"

# Split the single controlCenterButton of each bar in two, so network/bluetooth/... and the audio
# icon sit in separate widgets and get the normal inter-widget gap between them.
ensure_dms_bar_control_center_split() {
  dms_rewrite_settings "controlCenterButton split" "$dms_control_center_flags" <<'PYEOF'
import json
import sys

path, flags = sys.argv[1], sys.argv[2].split()

def widget_name(entry):
    return entry.get("id") if isinstance(entry, dict) else entry

audio_only = {flag: flag == "showAudioIcon" for flag in flags}

def is_audio_only(entry):
    return isinstance(entry, dict) and all(entry.get(flag) is want for flag, want in audio_only.items())

with open(path) as f:
    data = json.load(f)

for bar in data["barConfigs"]:
    for key in ("leftWidgets", "centerWidgets", "rightWidgets"):
        widgets = bar.get(key)
        if not isinstance(widgets, list):
            continue
        indexes = [i for i, w in enumerate(widgets) if widget_name(w) == "controlCenterButton"]
        if len(indexes) != 1 or is_audio_only(widgets[indexes[0]]):
            continue
        rest = dict(widgets[indexes[0]]) if isinstance(widgets[indexes[0]], dict) else {}
        rest["id"] = "controlCenterButton"
        rest["showAudioIcon"] = False
        widgets[indexes[0]:indexes[0] + 1] = [rest, {"id": "controlCenterButton", **audio_only}]

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}

# Replace <stock_id> by <plugin_id> in every bar widget list, unless the plugin is already there.
ensure_dms_bar_widget_plugin() {
  local stock_id="$1" plugin_id="$2"
  dms_rewrite_settings "$stock_id -> $plugin_id" "$stock_id" "$plugin_id" <<'PYEOF'
import json
import sys

path, stock_id, plugin_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

for bar in data["barConfigs"]:
    for key in ("leftWidgets", "centerWidgets", "rightWidgets"):
        widgets = bar.get(key)
        if not isinstance(widgets, list) or plugin_id in widgets:
            continue
        if stock_id in widgets:
            widgets[widgets.index(stock_id)] = plugin_id

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}

# Insert <widget_id> before <before_id> in the first list that has it, unless the widget is already in a bar.
ensure_dms_bar_widget_inserted_before() {
  local widget_id="$1" before_id="$2"
  dms_rewrite_settings "$widget_id before $before_id" "$widget_id" "$before_id" <<'PYEOF'
import json
import sys

path, widget_id, before_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

keys = ("leftWidgets", "centerWidgets", "rightWidgets")
for bar in data["barConfigs"]:
    already_placed = any(widget_id in (bar.get(k) or []) for k in keys)
    if already_placed:
        continue
    for key in keys:
        widgets = bar.get(key)
        if not isinstance(widgets, list):
            continue
        if before_id in widgets:
            widgets.insert(widgets.index(before_id), widget_id)
            break

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
}
