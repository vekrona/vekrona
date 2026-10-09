#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/display-scale.sh"

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
# Wayland session: `nvidia-settings -l` loads X11 settings and fails at every login when no NVIDIA driver is loaded.
ensure_symlink "$VEKRONA_ROOT/config/autostart/nvidia-settings-user.desktop" "$HOME/.config/autostart/nvidia-settings-user.desktop"

ensure_symlink "$VEKRONA_ROOT/config/systemd-user/xremap.service" "$HOME/.config/systemd/user/xremap.service"
ensure_symlink "$VEKRONA_ROOT/config/vekrona-app-switch" "$HOME/.config/quickshell/vekrona-app-switch"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-app-switch.service" "$HOME/.config/systemd/user/vekrona-app-switch.service"
ensure_symlink "$VEKRONA_ROOT/config/vekrona-shell" "$HOME/.config/quickshell/vekrona-shell"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-shell.service" "$HOME/.config/systemd/user/vekrona-shell.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-cliphist.service" "$HOME/.config/systemd/user/vekrona-cliphist.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-idle.service" "$HOME/.config/systemd/user/vekrona-idle.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-night.service" "$HOME/.config/systemd/user/vekrona-night.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-weather.service" "$HOME/.config/systemd/user/vekrona-weather.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-weather.timer" "$HOME/.config/systemd/user/vekrona-weather.timer"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-calendar.service" "$HOME/.config/systemd/user/vekrona-calendar.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-calendar.timer" "$HOME/.config/systemd/user/vekrona-calendar.timer"
ensure_symlink "$VEKRONA_ROOT/config/khal/config" "$HOME/.config/khal/config"
ensure_symlink "$VEKRONA_ROOT/config/vdirsyncer/config.example" "$HOME/.config/vdirsyncer/config.example"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/tailscale-systray.service" "$HOME/.config/systemd/user/tailscale-systray.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors.service" "$HOME/.config/systemd/user/vekrona-errors.service"
ensure_symlink "$VEKRONA_ROOT/config/systemd-user/vekrona-errors-failed.service" "$HOME/.config/systemd/user/vekrona-errors-failed.service"

# The theme mode and the rendered theme come before any unit restart: the app switcher and the shell read active-theme.json on start.
theme_state_dir="$(vekrona_state_dir)"
theme_state_file="$(vekrona_active_theme_file)"
theme_name_file="$(vekrona_theme_name_file)"
ensure_dir "$theme_state_dir"
if [[ ! -f "$theme_name_file" ]]; then
  log "seeding theme mode: $theme_name_file = dark"
  printf 'dark\n' > "$theme_name_file"
elif [[ "$(cat "$theme_name_file")" != dark && "$(cat "$theme_name_file")" != light ]]; then
  log "migrating legacy theme '$(cat "$theme_name_file")' to dark: $theme_name_file"
  printf 'dark\n' > "$theme_name_file"
else
  log "theme mode already present: $theme_name_file"
fi
"$VEKRONA_ROOT/bin/vekrona-render-theme"

ensure_user_unit_stopped dms.service
systemctl --user daemon-reload
ensure_user_unit_enabled xremap.service vekrona-app-switch.service vekrona-shell.service tailscale-systray.service vekrona-errors.service vekrona-cliphist.service vekrona-idle.service vekrona-weather.timer vekrona-calendar.timer
# Enabling only wires the unit into the next login; a live session needs the overlay now.
if [[ -n "$(sway_socket)" ]]; then
  log "restarting vekrona-app-switch.service for the running sway session"
  systemctl --user restart vekrona-app-switch.service || die "vekrona-app-switch.service failed to start"
  log "restarting vekrona-idle.service for the running sway session"
  systemctl --user restart vekrona-idle.service || die "vekrona-idle.service failed to start"
  log "restarting vekrona-cliphist.service for the running sway session"
  systemctl --user restart vekrona-cliphist.service || die "vekrona-cliphist.service failed to start"
  log "starting the weather and calendar timers for the running sway session"
  systemctl --user start vekrona-weather.timer vekrona-calendar.timer || die "the weather and calendar timers failed to start"
  log "restarting vekrona-shell.service for the running sway session"
  systemctl --user restart vekrona-shell.service || die "vekrona-shell.service failed to start"
fi

for skills_dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
  ensure_symlink "$VEKRONA_ROOT/config/agents/skills/vekrona-diagnose" "$skills_dir/vekrona-diagnose"
done

for retired in "$HOME/.config/systemd/user/sway-session.target.wants/dms.service" \
  "$HOME/.config/systemd/user/graphical-session.target.wants/dms.service" \
  "$HOME/.config/systemd/user/dms.service.d" \
  "$HOME/.config/DankMaterialShell" "$HOME/.local/state/DankMaterialShell" "$HOME/.cache/DankMaterialShell" \
  "$HOME/.config/gtk-3.0/dank-colors.css" "$HOME/.config/gtk-4.0/dank-colors.css"; do
  if [[ -e "$retired" || -L "$retired" ]]; then
    log "removing: $retired (left by DankMaterialShell, which vekrona-shell replaced)"
    rm -rf "$retired"
    [[ ! -e "$retired" && ! -L "$retired" ]] || die "failed to remove $retired"
  else
    log "absent: $retired"
  fi
done

ensure_symlink "$VEKRONA_ROOT/config/fontconfig/conf.d/50-vekrona-fonts.conf" "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
fc-cache -f >/dev/null

if [[ -d "$VEKRONA_ROOT/fonts" ]] && find "$VEKRONA_ROOT/fonts" -type f -print -quit | grep -q .; then
  ensure_symlink_tree "$VEKRONA_ROOT/fonts" "$HOME/.local/share/fonts/vekrona"
  fc-cache -f >/dev/null
  for family in "AtkynsonMono Nerd Font" "Atkinson Hyperlegible Mono" "JetBrainsMono Nerd Font" "Material Symbols Rounded"; do
    assert "$family registered" bash -c 'fc-list : family | tr , "\n" | grep -qxF "$1"' _ "$family"
  done
  assert "Atkinson Hyperlegible Mono covers the backtick (U+0060)" bash -c "fc-list ':charset=60' family | grep -qF 'Atkinson Hyperlegible Mono'"
else
  warn "fonts/ missing or empty, skipping font install"
fi

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
  ensure_symlink "$appdir/app.desktop" "$HOME/.local/share/applications/$profile.desktop"
  ensure_symlink "$appdir/icon.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/$profile.svg"
done
shopt -u nullglob
# Old installs linked chrome/userChrome.css into the checkout (possibly a legacy root); the renderer writes a real file there.
while IFS= read -r profiledir; do
  userchrome="$profiledir/chrome/userChrome.css"
  [[ -L "$userchrome" ]] || continue
  log "removing legacy userChrome.css link: $userchrome -> $(readlink "$userchrome")"
  rm -f "$userchrome"
  [[ ! -L "$userchrome" ]] || die "failed to remove $userchrome"
done < <(vekrona_webapp_profile_dirs)
# The renderer themes the default profile and every vekrona-* profile, so the new ones get their userChrome.css now.
"$VEKRONA_ROOT/bin/vekrona-render-theme" firefox

ensure_symlink_tree "$VEKRONA_ROOT/bin" "$HOME/.local/bin"

# bin/vekrona-lock starts it as `qs -c vekrona-lock`, which looks under ~/.config/quickshell.
ensure_symlink "$VEKRONA_ROOT/config/vekrona-lock" "$HOME/.config/quickshell/vekrona-lock"

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
