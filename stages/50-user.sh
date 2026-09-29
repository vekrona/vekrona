#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

ensure_symlink_tree "$VEKRONA_ROOT/config/sway" "$HOME/.config/sway"
ensure_symlink "$VEKRONA_ROOT/config/environment.d/vekrona.conf" "$HOME/.config/environment.d/vekrona.conf"
ensure_symlink "$VEKRONA_ROOT/config/xremap/config.yml" "$HOME/.config/xremap/config.yml"
ensure_symlink "$VEKRONA_ROOT/config/ghostty/config" "$HOME/.config/ghostty/config"

ensure_symlink "$VEKRONA_ROOT/config/systemd-user/xremap.service" "$HOME/.config/systemd/user/xremap.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/dms.service.d/vekrona.conf" "$HOME/.config/systemd/user/dms.service.d/vekrona.conf"

systemctl --user daemon-reload
ensure_user_unit_enabled xremap.service

systemctl --user add-wants sway-session.target dms.service
assert "dms.service wanted by sway-session.target" test -e "$HOME/.config/systemd/user/sway-session.target.wants/dms.service"

dms_graphical_want="$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
[[ -e "$dms_graphical_want" || -L "$dms_graphical_want" ]] && rm -f "$dms_graphical_want"
assert "dms.service not wanted by graphical-session.target" bash -c "[[ ! -e '$dms_graphical_want' && ! -L '$dms_graphical_want' ]]"

dms_settings_dir="$HOME/.config/DankMaterialShell"
dms_settings="$dms_settings_dir/settings.json"
dms_seed="$VEKRONA_ROOT/config/DankMaterialShell/settings.seed.json"
[[ -f "$dms_seed" ]] || die "DMS settings seed missing: $dms_seed"
if [[ ! -f "$dms_settings" || "$VEKRONA_RESET_DMS_SETTINGS" == "1" ]]; then
  log "seeding DMS settings: $dms_settings"
  ensure_dir "$dms_settings_dir"
  sed "s|__HOME__|$HOME|g" "$dms_seed" > "$dms_settings"
  python3 -m json.tool "$dms_settings" >/dev/null || die "seeded DMS settings are not valid JSON: $dms_settings"
else
  log "DMS settings already present: $dms_settings"
fi

ensure_symlink_tree "$VEKRONA_ROOT/config/dms-themes" "$HOME/.config/DankMaterialShell/vekrona-themes"

if [[ -d "$VEKRONA_ROOT/fonts" ]] && find "$VEKRONA_ROOT/fonts" -type f -print -quit | grep -q .; then
  ensure_symlink_tree "$VEKRONA_ROOT/fonts" "$HOME/.local/share/fonts/vekrona"
  fc-cache -f >/dev/null
  assert "JetBrainsMono Nerd Font registered" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"
else
  warn "fonts/ missing or empty, skipping font install"
fi

flatpak_installed() {
  flatpak list --app --columns=application 2>/dev/null | grep -qx "$1"
}

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
  profiledir="$HOME/.mozilla/firefox/$profile"
  if grep -q "Name=$profile$" "$HOME/.mozilla/firefox/profiles.ini" 2>/dev/null; then
    log "firefox profile exists: $profile"
  else
    log "creating firefox profile: $profile"
    firefox --headless -CreateProfile "$profile $profiledir"
    grep -q "Name=$profile$" "$HOME/.mozilla/firefox/profiles.ini" || die "firefox profile not created: $profile"
  fi
  ensure_symlink "$appdir/user.js" "$profiledir/user.js"
  ensure_symlink "$appdir/userChrome.css" "$profiledir/chrome/userChrome.css"
  ensure_symlink "$appdir/app.desktop" "$HOME/.local/share/applications/$profile.desktop"
done
shopt -u nullglob

ensure_symlink_tree "$VEKRONA_ROOT/bin" "$HOME/.local/bin"

ensure_symlink "$VEKRONA_ROOT/config/scopebuddy/scb.conf" "$HOME/.config/scopebuddy/scb.conf"
ensure_symlink "$VEKRONA_ROOT/config/mangohud/MangoHud.conf" "$HOME/.config/MangoHud/MangoHud.conf"
