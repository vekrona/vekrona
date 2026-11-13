#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/display-scale.sh
source "$ROOT/lib/display-scale.sh"
# shellcheck source=../lib/tor.sh
source "$ROOT/lib/tor.sh"

# Stage 30 installs the programs that the tools linked below run, so a missing one stops the stage before it changes anything.
require_desktop_pkgs

# First: a user unit linked below runs its ~/.local/bin tool as soon as any daemon-reload (an RPM scriptlet, say) sees it.
ensure_symlink_tree "$VEKRONA_ROOT/bin" "$HOME/.local/bin"
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
# Wayland session: `nvidia-settings -l` loads X11 settings and fails at every login when no NVIDIA driver is loaded.
ensure_symlink "$VEKRONA_ROOT/config/autostart/nvidia-settings-user.desktop" "$HOME/.config/autostart/nvidia-settings-user.desktop"
ensure_symlink "$VEKRONA_ROOT/config/autostart/sealertauto.desktop" "$HOME/.config/autostart/sealertauto.desktop"

ensure_symlink_tree "$VEKRONA_ROOT/config/systemd-user" "$HOME/.config/systemd/user"
ensure_symlink "$VEKRONA_ROOT/config/vekrona-shell" "$HOME/.config/quickshell/vekrona-shell"
ensure_symlink "$VEKRONA_ROOT/config/khal/config" "$HOME/.config/khal/config"
ensure_symlink "$VEKRONA_ROOT/config/vdirsyncer/config.example" "$HOME/.config/vdirsyncer/config.example"

# The theme mode and the rendered theme come before any unit restart: the app switcher and the shell read active-theme.json on start.
theme_state_dir="$(vekrona_state_dir)"
theme_name_file="$(vekrona_theme_name_file)"
ensure_dir "$theme_state_dir"
if [[ ! -f "$theme_name_file" ]]; then
  log "seeding theme mode: $theme_name_file = dark"
  write_file_atomic "$theme_name_file" $'dark\n'
elif [[ "$(cat "$theme_name_file")" != dark && "$(cat "$theme_name_file")" != light ]]; then
  log "migrating legacy theme '$(cat "$theme_name_file")' to dark: $theme_name_file"
  write_file_atomic "$theme_name_file" $'dark\n'
else
  log "theme mode already present: $theme_name_file"
fi
"$VEKRONA_ROOT/bin/vekrona-render-theme" all

# User units an earlier vekrona installed and the checkout no longer ships: stopped, disabled, and their unit files and *.wants links removed.
for retired_unit in "${VEKRONA_RETIRED_USER_UNITS[@]}"; do retire_user_unit "$retired_unit"; done

for skills_dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
  ensure_symlink "$VEKRONA_ROOT/config/agents/skills/vekrona-diagnose" "$skills_dir/vekrona-diagnose"
done

remove_retired "left by DankMaterialShell, which vekrona-shell replaced" \
  "$HOME/.config/systemd/user/dms.service.d" \
  "$HOME/.config/DankMaterialShell" "$HOME/.local/state/DankMaterialShell" "$HOME/.cache/DankMaterialShell" \
  "$HOME/.config/gtk-3.0/dank-colors.css" "$HOME/.config/gtk-4.0/dank-colors.css" \
  "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/danklinux-shell"
# The timers ran from timers.target, so under linger they polled while nobody was logged in; they now belong to the session.
remove_retired "the weather and calendar timers now start with the sway session" \
  "$HOME/.config/systemd/user/timers.target.wants/vekrona-weather.timer" \
  "$HOME/.config/systemd/user/timers.target.wants/vekrona-calendar.timer"
remove_retired "the app switcher is part of vekrona-shell now" "$HOME/.config/quickshell/vekrona-app-switch"
# A live link into the checkout, so prune_vekrona_links (stale links only) would keep it, and its directory is no longer scanned.
remove_retired "xremap runs root's copy in /etc/xremap and vekrona-keybindings reads the checkout" \
  "$HOME/.config/xremap/config.yml"
remove_retired_dir_if_empty "it held only the retired config.yml link" "$HOME/.config/xremap"

ensure_symlink "$VEKRONA_ROOT/config/fontconfig/conf.d/50-vekrona-fonts.conf" "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
fc-cache -f >/dev/null

font_sample=""
if [[ -d "$VEKRONA_ROOT/fonts" ]]; then font_sample="$(find "$VEKRONA_ROOT/fonts" -type f -print -quit)"; fi
if [[ -n "$font_sample" ]]; then
  ensure_symlink_tree "$VEKRONA_ROOT/fonts" "$HOME/.local/share/fonts/vekrona"
  fc-cache -f >/dev/null
  for family in "AtkynsonMono Nerd Font" "Atkinson Hyperlegible Mono" "JetBrainsMono Nerd Font" "Material Symbols Rounded"; do
    assert "$family registered" bash -c 'fc-list : family | tr , "\n" | grep -qxF "$1"' _ "$family"
  done
  assert "Atkinson Hyperlegible Mono covers the backtick (U+0060)" bash -c "fc-list ':charset=60' family | grep -qF 'Atkinson Hyperlegible Mono'"
else
  warn "fonts/ missing or empty, skipping font install"
fi

# Whether the KEY= line of `flatpak override --user --show` output ($3) lists ITEM ($2) among its ;-separated entries.
override_list_has() {
  local key="$1" item="$2" shown="$3" line
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] || continue
    if [[ ";${line#"$key="}" == *";$item;"* ]]; then return 0; fi
  done <<<"$shown"
  return 1
}

# Whether `flatpak override --user --show` output ($2) reflects the override flag $1.
flatpak_override_has() {
  local flag="$1" shown="$2" name
  case "$flag" in
    --unshare=*) override_list_has shared "!${flag#--unshare=}" "$shown" ;;
    --filesystem=*) override_list_has filesystems "${flag#--filesystem=}" "$shown" ;;
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
  flatpak_system_installed "$app_id" || { log "flatpak not installed, skipping override: $app_id"; return 0; }
  shown="$(flatpak override --user --show "$app_id")" || die "cannot read the flatpak override of $app_id"
  for flag in "$@"; do
    flatpak_override_has "$flag" "$shown" || missing+=("$flag")
  done
  if ((${#missing[@]} == 0)); then
    log "flatpak override already set: $app_id"
    return 0
  fi
  log "setting flatpak override: $app_id ${missing[*]}"
  flatpak override --user "${missing[@]}" "$app_id"
  shown="$(flatpak override --user --show "$app_id")" || die "cannot read the flatpak override of $app_id"
  for flag in "${missing[@]}"; do
    flatpak_override_has "$flag" "$shown" || die "flatpak override not applied: $app_id $flag"
  done
}

# Resets the app's user override when it holds nothing but the given socket flags (set by an earlier vekrona); dies rather than clobber overrides the user added.
ensure_flatpak_override_dropped() {
  local app_id="$1" flag shown stale=0 entry alt owned_re
  local entries=()
  shift
  flatpak_system_installed "$app_id" || { log "flatpak not installed, skipping override cleanup: $app_id"; return 0; }
  shown="$(flatpak override --user --show "$app_id")" || die "cannot read the flatpak override of $app_id"
  for flag in "$@"; do
    case "$flag" in
      --socket=*) entry="${flag#--socket=}" ;;
      --nosocket=*) entry="!${flag#--nosocket=}" ;;
      *) die "ensure_flatpak_override_dropped: unsupported override flag: $flag" ;;
    esac
    entries+=("$entry")
    if flatpak_override_has "$flag" "$shown"; then stale=1; fi
  done
  if ((stale == 0)); then
    log "flatpak override already clean: $app_id"
    return 0
  fi
  alt="$(IFS='|'; echo "${entries[*]}")"
  owned_re="^\[Context\]"$'\n'"sockets=(($alt);)+$"
  [[ "$(awk NF <<<"$shown")" =~ $owned_re ]] \
    || die "$app_id has stale vekrona socket overrides ($*) next to overrides of your own; remove those socket entries from ~/.local/share/flatpak/overrides/$app_id yourself"
  log "resetting stale flatpak override: $app_id"
  flatpak override --user --reset "$app_id"
  [[ -z "$(flatpak override --user --show "$app_id")" ]] || die "flatpak override not reset: $app_id"
}

# Removes the --filesystem=PATH grant from the app's user override by editing the keyfile that `flatpak override --user --show` reads.
# `--nofilesystem` would keep a !PATH negation in the keyfile instead, and a reset would drop the other entries of the override, which
# the helper above refuses to do (the tor override holds vekrona's own entries next to the stale grant).
ensure_flatpak_filesystem_dropped() {
  local app_id="$1" path="$2" shown kept file
  flatpak_system_installed "$app_id" || { log "flatpak not installed, skipping override cleanup: $app_id"; return 0; }
  shown="$(flatpak override --user --show "$app_id")" || die "cannot read the flatpak override of $app_id"
  if ! flatpak_override_has "--filesystem=$path" "$shown"; then log "flatpak override already clean: $app_id"; return 0; fi
  file="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides/$app_id"
  kept="$(awk -v item="$path" '
    /^filesystems=/ {
      sub(/^filesystems=/, "")
      count = split($0, entries, ";")
      line = ""
      for (i = 1; i <= count; i++) if (entries[i] != "" && entries[i] != item) line = line entries[i] ";"
      if (line != "") print "filesystems=" line
      next
    }
    { print }
  ' "$file")" || die "cannot read $file"
  log "removing the flatpak filesystem override $path: $app_id"
  write_file_atomic "$file" "$kept"$'\n'
  shown="$(flatpak override --user --show "$app_id")" || die "cannot read the flatpak override of $app_id"
  ! flatpak_override_has "--filesystem=$path" "$shown" || die "flatpak override still grants $path: $app_id"
}

for app_id in "${VEKRONA_X11_FLATPAKS[@]}"; do
  ensure_flatpak_override "$app_id" --nosocket=wayland --socket=x11
done

# Obsidian runs native Wayland (XWayland windows blur at fractional output scale); earlier installs forced it onto X11.
ensure_flatpak_override_dropped md.obsidian.Obsidian --nosocket=wayland --socket=x11

# Electron on Sway does not recognise XDG_CURRENT_DESKTOP and falls back to a plaintext key store; greetd's PAM unlocks gnome-keyring at login.
# Electron also picks its Wayland backend from XDG_SESSION_TYPE=wayland and exits when the sandbox has no Wayland socket, so name X11.
ensure_flatpak_override org.signal.Signal --env=SIGNAL_PASSWORD_STORE=gnome-libsecret --env=XDG_SESSION_TYPE=x11

# Earlier installs granted Tor Browser the socket directory /run/tor-tb, which moved to /run/vekrona-tor; the grant is dropped before the
# tor override below adds the new one.
ensure_flatpak_filesystem_dropped org.torproject.torbrowser-launcher /run/tor-tb

# Tor Browser has no network: its Flatpak reaches the system tor through the socket in /run/vekrona-tor (stage 40), which
# vekrona-tor-browser starts tor for. No control port is passed (TOR_PROVIDER=none): the browser only proxies. `run`'s launch program
# relays the launcher's own download through the socket, from the loopback of this sandbox. No PulseAudio socket: pipewire-pulse (a process of the user, with the network)
# lets any client of its socket `load-module module-tunnel-sink server=tcp:IP`, and its module loading has no per-client switch
# (pulse.allow-module-loading is server-wide, and vekrona's tests load modules), so the socket would be a way around tor.
ensure_flatpak_override org.torproject.torbrowser-launcher --unshare=network --nosocket=pulseaudio --filesystem="$VEKRONA_TOR_SOCKET_DIR" \
  --env=TOR_PROVIDER=none --env=TOR_SKIP_LAUNCH=1 --env=TOR_SOCKS_IPC_PATH="$VEKRONA_TOR_SOCKET"

shopt -s nullglob
firefox_root="$(firefox_profile_root)" || die "cannot resolve the Firefox profile root"
for appdir in "$VEKRONA_ROOT"/config/firefox/webapps/*/; do
  app="$(basename "$appdir")"
  profile="vekrona-$app"
  profiledir="$firefox_root/$profile"
  if grep -q "Name=$profile$" "$firefox_root/profiles.ini" 2>/dev/null; then
    log "firefox profile exists: $profile"
  else
    log "creating firefox profile: $profile"
    firefox --headless -CreateProfile "$profile $profiledir"
    grep -q "Name=$profile$" "$firefox_root/profiles.ini" || die "firefox profile not created: $profile"
  fi
  ensure_webapp_user_js "$appdir" "$profiledir/user.js"
  ensure_symlink "$appdir/app.desktop" "$HOME/.local/share/applications/$profile.desktop"
  ensure_symlink "$appdir/icon.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/$profile.svg"
done
shopt -u nullglob
for retired_webapp in "${VEKRONA_RETIRED_WEBAPPS[@]}"; do retire_webapp_profile "$retired_webapp"; done
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

# vekrona-lock.service starts it as `qs -c vekrona-lock`, which looks under ~/.config/quickshell.
ensure_symlink "$VEKRONA_ROOT/config/vekrona-lock" "$HOME/.config/quickshell/vekrona-lock"

ensure_symlink "$VEKRONA_ROOT/config/applications/vekrona-rune.desktop" "$HOME/.local/share/applications/vekrona-rune.desktop"
# Same file id as the Flatpak's entry, so that this one replaces it in every launcher: it starts tor first.
ensure_symlink "$VEKRONA_ROOT/config/applications/org.torproject.torbrowser-launcher.desktop" "$HOME/.local/share/applications/org.torproject.torbrowser-launcher.desktop"
ensure_default_app "$VEKRONA_BROWSER_DESKTOP" "${VEKRONA_BROWSER_MIMES[@]}"
ensure_default_app "$VEKRONA_EDITOR_DESKTOP" "${VEKRONA_EDITOR_MIMES[@]}"

ensure_symlink "$VEKRONA_ROOT/config/scopebuddy/scb.conf" "$HOME/.config/scopebuddy/scb.conf"
ensure_symlink "$VEKRONA_ROOT/config/mangohud/MangoHud.conf" "$HOME/.config/MangoHud/MangoHud.conf"
ensure_symlink_tree "$VEKRONA_ROOT/config/wireplumber" "$HOME/.config/wireplumber"

mapfile -t link_dirs < <(vekrona_link_dirs)
prune_vekrona_links "${link_dirs[@]}"

# Everything these units read when they start is linked or generated above this line; add new files before it.
prune_dead_quickshell_instances "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/quickshell"
systemctl --user daemon-reload
# The units the sway session runs, in restart order, and the timers and watcher that trigger the others.
session_services=(vekrona-lid vekrona-idle vekrona-lock-listen vekrona-session-teardown vekrona-cliphist vekrona-shell vekrona-errors vekrona-audio-watchdog)
session_triggers=(vekrona-weather.timer vekrona-calendar.timer vekrona-update-notify.path)
ensure_user_unit_enabled "${session_services[@]/%/.service}" "${session_triggers[@]}" vekrona-update-notify.service syncthing.service
# The daemon must not wait for the next login. Its GUI moves to a socket while it is stopped, and a restart (not a start) makes a
# daemon that kept running read the drop-ins linked and the config written above.
ensure_syncthing_gui_socket
systemctl --user restart syncthing.service || die "syncthing.service failed to start"
# Enabling only wires a unit into the next login; a live session needs it running now, on the files linked above.
if [[ -n "$(sway_socket)" ]]; then
  for unit in pipewire wireplumber "${session_services[@]}"; do
    log "restarting $unit.service for the running sway session"
    systemctl --user restart "$unit.service" || die "$unit.service failed to start"
  done
  log "starting the triggers (${session_triggers[*]}) for the running sway session"
  systemctl --user start "${session_triggers[@]}" || die "the triggers (${session_triggers[*]}) failed to start"
fi
# The Sync watcher follows syncthing.service (PartOf, WantedBy), which is running by now; enabling alone would leave it down until
# Syncthing next starts. A restart, not a start: a watcher that kept running would go on with the code it started with, while the
# shell reads the checkout's QML at once (and shows "out of date" for the watcher's sync.json).
ensure_user_unit_enabled vekrona-sync.service
systemctl --user restart vekrona-sync.service || die "vekrona-sync.service failed to start"
