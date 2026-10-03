#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/display-scale.sh"
source "$ROOT/lib/dms-settings.sh"

VEKRONA_RESET_DMS_SETTINGS="${VEKRONA_RESET_DMS_SETTINGS:-0}"

ensure_symlink_tree "$VEKRONA_ROOT/config/sway" "$HOME/.config/sway"
mkdir -p "$HOME/.config/sway/config.d" # where personal settings (monitor outputs) go; config/sway/config includes it last
ensure_internal_panel_scale
ensure_symlink "$VEKRONA_ROOT/config/environment.d/vekrona.conf" "$HOME/.config/environment.d/vekrona.conf"

stale_gpu_env_file="$HOME/.config/environment.d/vekrona-gpu.conf"
if [[ -e "$stale_gpu_env_file" || -L "$stale_gpu_env_file" ]]; then
  log "removing: $stale_gpu_env_file (left by an earlier install; config/sway/environment now picks the GPU at login)"
  rm -f "$stale_gpu_env_file"
  [[ ! -e "$stale_gpu_env_file" ]] || die "failed to remove $stale_gpu_env_file"
  # The running user manager still holds what that file set; a session started before the upgrade would keep it.
  manager_env="$(systemctl --user show-environment)" || die "cannot read the systemd user manager environment"
  for stale_gpu_var in QSG_RHI_BACKEND WLR_DRM_DEVICES; do
    if grep -q "^$stale_gpu_var=" <<<"$manager_env"; then
      log "unsetting $stale_gpu_var in the systemd user manager"
      systemctl --user unset-environment "$stale_gpu_var" || die "failed to unset $stale_gpu_var in the systemd user manager"
    fi
  done
else
  log "absent: $stale_gpu_env_file"
fi
ensure_symlink "$VEKRONA_ROOT/config/xremap/config.yml" "$HOME/.config/xremap/config.yml"

ensure_symlink "$VEKRONA_ROOT/config/systemd-user/xremap.service" "$HOME/.config/systemd/user/xremap.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/dms.service.d/vekrona.conf" "$HOME/.config/systemd/user/dms.service.d/vekrona.conf"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/tailscale-systray.service" "$HOME/.config/systemd/user/tailscale-systray.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors.service" "$HOME/.config/systemd/user/vekrona-errors.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors-failed.service" "$HOME/.config/systemd/user/vekrona-errors-failed.service"

systemctl --user daemon-reload
ensure_user_unit_enabled xremap.service tailscale-systray.service vekrona-errors.service

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
  dms_restart_needed=1
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
"$VEKRONA_ROOT/bin/vekrona-render-theme"

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
ensure_dms_setting_enforced cornerRadius "$(vekrona_design_get radius)"
ensure_dms_setting_enforced trayIconSpacing "$(vekrona_design_get gap)"
ensure_dms_bar_setting_enforced noBackground true
ensure_dms_bar_setting_enforced widgetPadding "$(vekrona_design_get padding)"
ensure_dms_bar_setting_enforced innerPadding "$(vekrona_design_get gap)"
ensure_dms_bar_setting_enforced spacing "$(vekrona_design_get gap)"

# Assert <plugin_id> sits in a bar widget list and, if <stock_id> is given, no bar still lists that stock widget.
assert_dms_bar_plugin_placed() {
  local plugin_id="$1" stock_id="${2:-}"
  assert "DMS bar has the $plugin_id plugin placed in a widget list${stock_id:+ and no stock $stock_id}" python3 -c "
import json
import sys
plugin_id, stock_id = sys.argv[1], sys.argv[2]
d = json.load(open('$dms_settings'))
names = [w.get('id') if isinstance(w, dict) else w
         for bar in d.get('barConfigs', []) for k in ('leftWidgets', 'centerWidgets', 'rightWidgets') for w in (bar.get(k) or [])]
assert plugin_id in names, plugin_id
assert not stock_id or stock_id not in names, stock_id
" "$plugin_id" "$stock_id"
}

ensure_symlink_tree "$VEKRONA_ROOT/config/DankMaterialShell/plugins" "$HOME/.config/DankMaterialShell/plugins"
dms_restart_needed=0
ensure_dms_plugin_enabled vekronaSwayWorkspaces
ensure_dms_bar_widget_plugin workspaceSwitcher vekronaSwayWorkspaces
ensure_dms_bar_separator_after vekronaSwayWorkspaces
ensure_dms_bar_control_center_split
assert_dms_bar_plugin_placed vekronaSwayWorkspaces workspaceSwitcher

ensure_dms_plugin_enabled vekronaAgent
ensure_dms_bar_widget_inserted_before vekronaAgent notificationButton
assert_dms_bar_plugin_placed vekronaAgent

ensure_dms_plugin_enabled vekronaClock
ensure_dms_bar_widget_plugin clock vekronaClock
assert_dms_bar_plugin_placed vekronaClock clock
ensure_dms_plugin_enabled vekronaWeather
ensure_dms_bar_widget_plugin weather vekronaWeather
assert_dms_bar_plugin_placed vekronaWeather weather

# A running DMS does not pick up a plugin enabled after it started, so its bar widget stays blank.
if [[ "$dms_restart_needed" == 1 ]] && systemctl --user is-active --quiet dms.service; then
  log "restarting dms.service to load newly enabled plugins"
  dms restart >/dev/null || warn "dms restart failed, log out and back in to load the new DMS plugins"
fi

dms_changelog_seen="$(dirname "$dms_settings")/.changelog-$(dms_changelog_version)"
if [[ -e "$dms_changelog_seen" ]]; then
  log "already present: $dms_changelog_seen"
else
  log "marking DMS changelog as seen: $dms_changelog_seen"
  touch "$dms_changelog_seen"
fi

ensure_dms_setting_enforced matugenTemplateGhostty false
assert "DMS matugen templates: GTK on, Ghostty off" python3 -c "
import json
d = json.load(open('$dms_settings'))
assert d.get('runDmsMatugenTemplates', True) is True
assert d.get('matugenTemplateGtk', True) is True
assert d.get('matugenTemplateGhostty', True) is False
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

# Whether `flatpak override --user --show` output ($2) reflects the override flag $1.
flatpak_override_has() {
  local flag="$1" shown="$2" name
  case "$flag" in
    --socket=*) grep -Eq "^sockets=(.*;)?${flag#--socket=};" <<<"$shown" ;;
    --nosocket=*) grep -Eq "^sockets=(.*;)?!${flag#--nosocket=};" <<<"$shown" ;;
    --env=*) grep -qxF "${flag#--env=}" <<<"$shown" ;;
    --talk-name=*) name="${flag#--talk-name=}"; grep -qxF "$name=talk" <<<"$shown" ;;
    *) die "flatpak_override_has: unsupported override flag: $flag" ;;
  esac
}

ensure_flatpak_override() {
  local app_id="$1" flag shown missing=()
  shift
  flatpak_installed "$app_id" || { log "flatpak not installed, skipping override: $app_id"; return 0; }
  shown="$(flatpak override --user --show "$app_id" 2>/dev/null || true)"
  for flag in "$@"; do
    flatpak_override_has "$flag" "$shown" || missing+=("$flag")
  done
  if ((${#missing[@]} == 0)); then
    log "flatpak override already set: $app_id"
    return 0
  fi
  log "setting flatpak override: $app_id ${missing[*]}"
  flatpak override --user "${missing[@]}" "$app_id"
  shown="$(flatpak override --user --show "$app_id")"
  for flag in "${missing[@]}"; do
    flatpak_override_has "$flag" "$shown" || die "flatpak override not applied: $app_id $flag"
  done
}

for app_id in "${VEKRONA_X11_FLATPAKS[@]}"; do
  ensure_flatpak_override "$app_id" --nosocket=wayland --socket=x11
done

# Electron on Sway does not recognise XDG_CURRENT_DESKTOP and falls back to a plaintext key store; greetd's PAM unlocks gnome-keyring at login.
# Electron also picks its Wayland backend from XDG_SESSION_TYPE=wayland and exits when the sandbox has no Wayland socket, so name X11.
ensure_flatpak_override org.signal.Signal --env=SIGNAL_PASSWORD_STORE=gnome-libsecret --env=XDG_SESSION_TYPE=x11

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
  ensure_symlink "$appdir/icon.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/$profile.svg"
done
shopt -u nullglob

ensure_symlink_tree "$VEKRONA_ROOT/bin" "$HOME/.local/bin"

ensure_symlink "$VEKRONA_ROOT/config/scopebuddy/scb.conf" "$HOME/.config/scopebuddy/scb.conf"
ensure_symlink "$VEKRONA_ROOT/config/mangohud/MangoHud.conf" "$HOME/.config/MangoHud/MangoHud.conf"

mapfile -t link_dirs < <(vekrona_link_dirs)
prune_vekrona_links "${link_dirs[@]}"

require_cmd nix
if nix profile list --json | jq -e '.elements | has("devbox")' >/dev/null; then
  log "devbox already installed via nix profile"
else
  log "installing devbox via nix profile"
  nix profile install nixpkgs#devbox
fi
assert "devbox runs" "$HOME/.nix-profile/bin/devbox" version
