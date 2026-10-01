#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

VEKRONA_RESET_DMS_SETTINGS="${VEKRONA_RESET_DMS_SETTINGS:-0}"

ensure_symlink_tree "$VEKRONA_ROOT/config/sway" "$HOME/.config/sway"
ensure_symlink "$VEKRONA_ROOT/config/environment.d/vekrona.conf" "$HOME/.config/environment.d/vekrona.conf"

gpu_env_file="$HOME/.config/environment.d/vekrona-gpu.conf"
if [[ -e /dev/dri/vekrona-dgpu ]]; then
  gpu_env_content=$'WLR_DRM_DEVICES=/dev/dri/vekrona-dgpu\nQSG_RHI_BACKEND=vulkan'
  if [[ -f "$gpu_env_file" && "$(cat "$gpu_env_file")" == "$gpu_env_content" ]]; then
    log "up to date: $gpu_env_file"
  else
    log "writing: $gpu_env_file"
    ensure_dir "$(dirname "$gpu_env_file")"
    printf '%s\n' "$gpu_env_content" > "$gpu_env_file"
    [[ "$(cat "$gpu_env_file")" == "$gpu_env_content" ]] || die "failed to write $gpu_env_file"
  fi
elif [[ -e "$gpu_env_file" ]]; then
  log "removing: $gpu_env_file (/dev/dri/vekrona-dgpu absent)"
  rm -f "$gpu_env_file"
  [[ -e "$gpu_env_file" ]] && die "failed to remove $gpu_env_file"
else
  log "no /dev/dri/vekrona-dgpu, $gpu_env_file absent (ok)"
fi
ensure_symlink "$VEKRONA_ROOT/config/xremap/config.yml" "$HOME/.config/xremap/config.yml"
ensure_symlink "$VEKRONA_ROOT/config/ghostty/config" "$HOME/.config/ghostty/config"

ensure_symlink "$VEKRONA_ROOT/config/systemd-user/xremap.service" "$HOME/.config/systemd/user/xremap.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/dms.service.d/vekrona.conf" "$HOME/.config/systemd/user/dms.service.d/vekrona.conf"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors.service" "$HOME/.config/systemd/user/vekrona-errors.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors-failed.service" "$HOME/.config/systemd/user/vekrona-errors-failed.service"

systemctl --user daemon-reload
ensure_user_unit_enabled xremap.service
ensure_user_unit_enabled vekrona-errors.service

for skills_dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
  ensure_symlink "$VEKRONA_ROOT/config/agents/skills/vekrona-diagnose" "$skills_dir/vekrona-diagnose"
done

systemctl --user add-wants sway-session.target dms.service
assert "dms.service wanted by sway-session.target" test -e "$HOME/.config/systemd/user/sway-session.target.wants/dms.service"

dms_graphical_want="$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
[[ -e "$dms_graphical_want" || -L "$dms_graphical_want" ]] && rm -f "$dms_graphical_want"
assert "dms.service not wanted by graphical-session.target" bash -c "[[ ! -e '$dms_graphical_want' && ! -L '$dms_graphical_want' ]]"

seed_dms_json() {
  local seed="$1" dest="$2" respect_reset="${3:-1}" dest_dir
  dest_dir="$(dirname "$dest")"
  [[ -f "$seed" ]] || die "seed missing: $seed"
  if [[ -f "$dest" ]] && { [[ "$respect_reset" == "0" ]] || [[ "$VEKRONA_RESET_DMS_SETTINGS" != "1" ]]; }; then
    log "already present: $dest"
    return 0
  fi
  log "seeding: $dest"
  ensure_dir "$dest_dir"
  local tmp
  tmp="$(mktemp "$dest_dir/.$(basename "$dest").XXXXXX")"
  python3 - "$seed" "$HOME" > "$tmp" <<'PYEOF'
import json
import sys

seed_path, home = sys.argv[1], sys.argv[2]

def substitute(value):
    if isinstance(value, str):
        return value.replace("__HOME__", home)
    if isinstance(value, dict):
        return {k: substitute(v) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute(v) for v in value]
    return value

with open(seed_path) as f:
    data = json.load(f)

json.dump(substitute(data), sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
  mv "$tmp" "$dest"
}

ensure_dms_setting_default() {
  local key="$1" value="$2"
  jq -e --arg k "$key" 'has($k)' "$dms_settings" >/dev/null && { log "DMS setting already set: $key"; return 0; }
  log "setting DMS default: $key = $value"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$dms_settings" > "$tmp"; then
    rm -f "$tmp"
    die "jq failed to set DMS default: $key"
  fi
  mv "$tmp" "$dms_settings"
  [[ "$(jq -r --arg k "$key" '.[$k]' "$dms_settings")" == "$value" ]] || die "DMS default not applied: $key"
}

ensure_dms_setting_enforced() {
  local key="$1" json_value="$2"
  jq -e --arg k "$key" --argjson v "$json_value" '.[$k] == $v' "$dms_settings" >/dev/null 2>&1 && {
    log "DMS setting already enforced: $key = $json_value"
    return 0
  }
  log "enforcing DMS setting: $key = $json_value"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! jq --arg k "$key" --argjson v "$json_value" '.[$k] = $v' "$dms_settings" > "$tmp"; then
    rm -f "$tmp"
    die "jq failed to enforce DMS setting: $key"
  fi
  mv "$tmp" "$dms_settings"
  jq -e --arg k "$key" --argjson v "$json_value" '.[$k] == $v' "$dms_settings" >/dev/null || die "DMS setting not enforced: $key"
}

ensure_dms_bar_widget_plugin() {
  local stock_id="$1" plugin_id="$2"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! python3 - "$dms_settings" "$stock_id" "$plugin_id" > "$tmp" <<'PYEOF'
import json
import sys

path, stock_id, plugin_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

for bar in data.get("barConfigs", []):
    for key in ("leftWidgets", "centerWidgets", "rightWidgets"):
        widgets = bar.get(key)
        if not isinstance(widgets, list) or plugin_id in widgets:
            continue
        if stock_id in widgets:
            widgets[widgets.index(stock_id)] = plugin_id

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
  then
    rm -f "$tmp"
    die "python3 failed to migrate DMS bar widget: $stock_id -> $plugin_id"
  fi
  if cmp -s "$tmp" "$dms_settings"; then
    rm -f "$tmp"
    log "DMS bar widget already migrated or $stock_id not present: $dms_settings"
  else
    mv "$tmp" "$dms_settings"
    log "migrated DMS bar widget: $stock_id -> $plugin_id"
  fi
}

ensure_dms_bar_widget_inserted_before() {
  local widget_id="$1" before_id="$2"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
  if ! python3 - "$dms_settings" "$widget_id" "$before_id" > "$tmp" <<'PYEOF'
import json
import sys

path, widget_id, before_id = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    data = json.load(f)

keys = ("leftWidgets", "centerWidgets", "rightWidgets")
for bar in data.get("barConfigs", []):
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
  then
    rm -f "$tmp"
    die "python3 failed to insert DMS bar widget: $widget_id"
  fi
  if cmp -s "$tmp" "$dms_settings"; then
    rm -f "$tmp"
    log "DMS bar widget already present or insertion point missing: $widget_id"
  else
    mv "$tmp" "$dms_settings"
    log "inserted DMS bar widget: $widget_id before $before_id"
  fi
}

ensure_dms_plugin_enabled() {
  local plugin_id="$1"
  local plugin_settings="$dms_settings_dir/plugin_settings.json"
  if [[ -f "$plugin_settings" ]] && jq -e --arg id "$plugin_id" '.[$id].enabled == true' "$plugin_settings" >/dev/null 2>&1; then
    log "DMS plugin already enabled: $plugin_id"
    return 0
  fi
  log "enabling DMS plugin: $plugin_id"
  local tmp
  tmp="$(mktemp "$dms_settings_dir/.plugin_settings.json.XXXXXX")"
  if [[ -f "$plugin_settings" ]]; then
    jq --arg id "$plugin_id" '.[$id].enabled = true' "$plugin_settings" > "$tmp" || { rm -f "$tmp"; die "jq failed to enable DMS plugin: $plugin_id"; }
  else
    jq -n --arg id "$plugin_id" '{($id): {enabled: true}}' > "$tmp" || { rm -f "$tmp"; die "jq failed to create plugin_settings.json: $plugin_id"; }
  fi
  mv "$tmp" "$plugin_settings"
  jq -e --arg id "$plugin_id" '.[$id].enabled == true' "$plugin_settings" >/dev/null || die "DMS plugin not enabled: $plugin_id"
}

theme_state_dir="$(vekrona_state_dir)"
theme_state_file="$(vekrona_active_theme_file)"
theme_name_file="$(vekrona_theme_name_file)"
default_theme_name="tokyo-night"
default_theme_json="$VEKRONA_ROOT/config/dms-themes/$default_theme_name.json"
ensure_dir "$theme_state_dir"
if [[ -f "$theme_state_file" ]]; then
  log "active theme file already present: $theme_state_file"
else
  log "seeding active theme file: $theme_state_file"
  cp "$default_theme_json" "$theme_state_file"
fi
if [[ -f "$theme_name_file" ]]; then
  log "active theme name already present: $theme_name_file"
else
  log "seeding active theme name: $theme_name_file"
  printf '%s\n' "$default_theme_name" > "$theme_name_file"
fi

active_theme_name="$(cat "$theme_name_file")"
active_ghostty_theme="$(ghostty_theme_for "$active_theme_name")"
log "writing ghostty theme include: $active_theme_name -> $active_ghostty_theme"
write_ghostty_theme_include "$active_theme_name"
assert "ghostty theme include: theme = $active_ghostty_theme" grep -qxF "theme = $active_ghostty_theme" "$GHOSTTY_THEME_INCLUDE"

dms_settings_dir="$HOME/.config/DankMaterialShell"
dms_settings="$dms_settings_dir/settings.json"
dms_session_dir="$HOME/.local/state/DankMaterialShell"
dms_session="$dms_session_dir/session.json"

if [[ -f "$dms_settings" && "$VEKRONA_RESET_DMS_SETTINGS" != "1" ]]; then
  current_custom_theme_file="$(jq -r '.customThemeFile // empty' "$dms_settings")"
  current_theme_name="$(jq -r '.currentThemeName // empty' "$dms_settings")"
  if [[ "$current_theme_name" == "custom" && -n "$current_custom_theme_file" && "$current_custom_theme_file" != "$theme_state_file" ]]; then
    if [[ -f "$current_custom_theme_file" ]]; then
      log "migrating customThemeFile: $current_custom_theme_file -> $theme_state_file"
      cp "$current_custom_theme_file" "$theme_state_file"
      dms_settings_tmp="$(mktemp "$dms_settings_dir/.settings.json.XXXXXX")"
      if ! jq --arg f "$theme_state_file" '.customThemeFile = $f | .currentThemeName = "custom"' "$dms_settings" > "$dms_settings_tmp"; then
        rm -f "$dms_settings_tmp"
        die "jq failed to migrate customThemeFile: $dms_settings"
      fi
      mv "$dms_settings_tmp" "$dms_settings"
      [[ "$(jq -r .customThemeFile "$dms_settings")" == "$theme_state_file" ]] || die "customThemeFile migration failed: $dms_settings"
      if systemctl --user is-active --quiet dms.service; then
        log "restarting dms.service to pick up the migrated theme file"
        dms restart >/dev/null || warn "dms restart failed, log out and back in to pick up the migrated theme"
      fi
    else
      warn "customThemeFile referenced but missing, not migrating: $current_custom_theme_file"
    fi
  fi
fi

seed_dms_json "$VEKRONA_ROOT/config/DankMaterialShell/settings.seed.json" "$dms_settings"
seed_dms_json "$VEKRONA_ROOT/config/DankMaterialShell/session.seed.json" "$dms_session" 0

ensure_dms_setting_default fontFamily "Atkinson Hyperlegible Next"
ensure_dms_setting_default monoFontFamily "JetBrainsMono Nerd Font"
ensure_dms_setting_enforced notificationPopupBodyInvokesAction true

ensure_symlink_tree "$VEKRONA_ROOT/config/DankMaterialShell/plugins" "$HOME/.config/DankMaterialShell/plugins"
ensure_dms_plugin_enabled vekronaSwayWorkspaces
ensure_dms_bar_widget_plugin workspaceSwitcher vekronaSwayWorkspaces
assert "DMS bar has the vekrona workspace plugin or no stock workspaceSwitcher remains" python3 -c "
import json
d = json.load(open('$dms_settings'))
bars = d.get('barConfigs', [])
has_plugin = any('vekronaSwayWorkspaces' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
has_stock = any('workspaceSwitcher' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
assert has_plugin or not has_stock, (has_plugin, has_stock)
"

ensure_dms_plugin_enabled vekronaAgent
ensure_dms_bar_widget_inserted_before vekronaAgent notificationButton
assert "DMS bar has the vekrona agent plugin placed in a widget list" python3 -c "
import json
d = json.load(open('$dms_settings'))
bars = d.get('barConfigs', [])
assert any('vekronaAgent' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
"

dms_changelog_seen="$(dirname "$dms_settings")/.changelog-$(dms_changelog_version)"
if [[ -e "$dms_changelog_seen" ]]; then
  log "already present: $dms_changelog_seen"
else
  log "marking DMS changelog as seen: $dms_changelog_seen"
  touch "$dms_changelog_seen"
fi

assert "DMS matugen Ghostty template enabled" python3 -c "
import json
d = json.load(open('$dms_settings'))
assert d.get('runDmsMatugenTemplates', True) is True
assert d.get('matugenTemplateGhostty', True) is True
"

ensure_symlink_tree "$VEKRONA_ROOT/config/dms-themes" "$HOME/.config/DankMaterialShell/vekrona-themes"

ensure_symlink "$VEKRONA_ROOT/config/fontconfig/conf.d/50-vekrona-fonts.conf" "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
fc-cache -f >/dev/null

if [[ -d "$VEKRONA_ROOT/fonts" ]] && find "$VEKRONA_ROOT/fonts" -type f -print -quit | grep -q .; then
  ensure_symlink_tree "$VEKRONA_ROOT/fonts" "$HOME/.local/share/fonts/vekrona"
  fc-cache -f >/dev/null
  assert "JetBrainsMono Nerd Font registered" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"
else
  warn "fonts/ missing or empty, skipping font install"
fi

ensure_gsettings org.gnome.desktop.interface font-name "Atkinson Hyperlegible Next 11"
ensure_gsettings org.gnome.desktop.interface document-font-name "Atkinson Hyperlegible Next 11"
ensure_gsettings org.gnome.desktop.interface monospace-font-name "JetBrainsMono Nerd Font 11"

ensure_flatpak_override() {
  local app_id="$1" current
  flatpak_installed "$app_id" || { log "flatpak not installed, skipping override: $app_id"; return 0; }
  current="$(flatpak override --user --show "$app_id" 2>/dev/null || true)"
  if grep -q 'x11' <<<"$current" && grep -q '!wayland' <<<"$current"; then
    log "flatpak override already set: $app_id"
    return 0
  fi
  log "setting flatpak override: $app_id"
  flatpak override --user --nosocket=wayland --socket=x11 "$app_id"
  current="$(flatpak override --user --show "$app_id")"
  { grep -q 'x11' <<<"$current" && grep -q '!wayland' <<<"$current"; } || die "flatpak override not applied: $app_id"
}

for app_id in com.discordapp.Discord com.spotify.Client md.obsidian.Obsidian org.signal.Signal; do
  ensure_flatpak_override "$app_id"
done

shopt -s nullglob
for appdir in "$VEKRONA_ROOT"/config/firefox/webapps/*/; do
  app="$(basename "$appdir")"
  profile="vekrona-$app"
  profiledir="$(firefox_profile_root)/$profile"
  if grep -q "Name=$profile$" "$(firefox_profile_root)/profiles.ini" 2>/dev/null; then
    log "firefox profile exists: $profile"
  else
    log "creating firefox profile: $profile"
    firefox --headless -CreateProfile "$profile $profiledir"
    grep -q "Name=$profile$" "$(firefox_profile_root)/profiles.ini" || die "firefox profile not created: $profile"
  fi
  ensure_symlink "$appdir/user.js" "$profiledir/user.js"
  ensure_symlink "$appdir/userChrome.css" "$profiledir/chrome/userChrome.css"
  ensure_symlink "$appdir/app.desktop" "$HOME/.local/share/applications/$profile.desktop"
done
shopt -u nullglob

ensure_symlink_tree "$VEKRONA_ROOT/bin" "$HOME/.local/bin"

ensure_symlink "$VEKRONA_ROOT/config/scopebuddy/scb.conf" "$HOME/.config/scopebuddy/scb.conf"
ensure_symlink "$VEKRONA_ROOT/config/mangohud/MangoHud.conf" "$HOME/.config/MangoHud/MangoHud.conf"
