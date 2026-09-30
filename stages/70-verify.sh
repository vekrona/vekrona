#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

[[ "${1:-}" == "--all" ]] && VEKRONA_VERIFY_ALL=1
VEKRONA_VERIFY_ALL="${VEKRONA_VERIFY_ALL:-0}"
VEKRONA_STAGES="${VEKRONA_STAGES:-}"

ran() {
  [[ "$VEKRONA_VERIFY_ALL" == "1" ]] && return 0
  [[ " $VEKRONA_STAGES " == *" $1 "* ]]
}

ok_count=0
warn_count=0

check() { "$@"; ok_count=$((ok_count + 1)); }

warn_check() {
  local msg="$1"; shift
  if "$@"; then
    log "ok: $msg"
    ok_count=$((ok_count + 1))
  else
    warn "$msg"
    warn_count=$((warn_count + 1))
  fi
}

eq() { [[ "$1" == "$2" ]]; }
ge() { [[ "$1" -ge "$2" ]]; }
contains() { [[ "$2" == *"$1"* ]]; }
not_contains() { [[ "$2" != *"$1"* ]]; }
file_exists() { [[ -e "$1" ]]; }
file_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
file_lacks_qsg_backend() { ! grep -q '^QSG_RHI_BACKEND=' "$1" 2>/dev/null; }
dir_exists() { [[ -d "$1" ]]; }
group_member() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
gsettings_eq() { [[ "$(user_gsettings get "$1" "$2")" == "'$3'" ]]; }
not_repo_enabled() { ! repo_enabled "$1"; }
copr_id() { echo "copr:copr.fedorainfracloud.org:${1/\//:}"; }
copr_enabled() { repo_enabled "$(copr_id "$1")"; }
unit_enabled() { eq "$(systemctl is-enabled "$1" 2>/dev/null || true)" enabled; }
user_unit_enabled() { eq "$(systemctl --user is-enabled "$1" 2>/dev/null || true)" enabled; }
pkg_absent() { ! pkg_installed "$1"; }
gdm_absent_or_disabled() { ! pkg_installed gdm || ! unit_enabled gdm; }
nvidia_module_present_for() { modinfo -k "$1" nvidia >/dev/null 2>&1; }

verify_greetd_active() {
  check assert "greetd enabled" greetd_enabled
  check assert "display-manager.service points to greetd" dm_is_greetd
  check assert "default target is graphical.target" default_target_is_graphical
}

if ran 00-repos; then
  check assert "repo enabled: rpmfusion-nonfree" repo_enabled rpmfusion-nonfree
  for c in blakegardner/xremap scottames/ghostty avengemedia/dms avengemedia/danklinux; do
    check assert "copr enabled: $c" copr_enabled "$c"
  done
fi

if ran 10-nvidia; then
  check assert "akmod-nvidia installed" pkg_installed akmod-nvidia

  nvidia_disk_version="$(modinfo -F version nvidia 2>/dev/null || true)"
  nvidia_loaded_version="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
  if [[ -n "$nvidia_loaded_version" && "$nvidia_disk_version" == "$nvidia_loaded_version" ]]; then
    modeset="$(root cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo '?')"
    check assert "nvidia_drm modeset=Y" eq "$modeset" Y
    gsp="$(nvidia-smi -q 2>/dev/null | grep 'GSP Firmware' || true)"
    check assert "GSP firmware disabled (N/A)" contains 'N/A' "$gsp"
    check assert "nvidia module is proprietary, not Open" not_contains 'Open' "$(cat /proc/driver/nvidia/version 2>/dev/null || true)"
  else
    warn_check "nvidia_drm modeset=Y (reboot pending: disk=$nvidia_disk_version loaded=$nvidia_loaded_version)" false
    warn_check "GSP firmware disabled (N/A) (reboot pending)" false
    warn_check "nvidia module is proprietary, not Open (reboot pending)" false
  fi

  for arg in nvidia.NVreg_EnableGpuFirmware=0 rd.driver.blacklist=nouveau; do
    if kernel_cmdline_has "$arg"; then
      log "ok: kernel arg active: $arg"
      ok_count=$((ok_count + 1))
    elif grubby_has_arg "$arg"; then
      warn "kernel arg configured but not active yet, reboot required: $arg"
      warn_count=$((warn_count + 1))
    else
      die "kernel arg not configured: $arg"
    fi
  done

  for u in nvidia-suspend nvidia-resume nvidia-hibernate; do
    check assert "$u enabled" unit_enabled "$u"
  done

  check assert "versionlock: akmod-nvidia" versionlock_has akmod-nvidia

  for d in /lib/modules/*/; do
    kver="$(basename "$d")"
    [[ -e "/boot/vmlinuz-$kver" ]] || continue
    warn_check "nvidia module present for kernel $kver" nvidia_module_present_for "$kver"
  done

  check assert "cuda-fedora44-x86_64 enabled" repo_enabled cuda-fedora44-x86_64
  check assert "cuda-fedora43-x86_64 absent" not_repo_enabled cuda-fedora43-x86_64
fi

if ran 20-snapper; then
  check assert "snapper config: NUMBER_LIMIT=10" root grep -qE '^NUMBER_LIMIT="10"$' /etc/snapper/configs/root
  check assert "snapper config: TIMELINE_CREATE=no" root grep -qE '^TIMELINE_CREATE="no"$' /etc/snapper/configs/root
  check assert "snapper actions file present" file_exists /etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions
  check assert "libdnf5-plugin-actions installed" pkg_installed libdnf5-plugin-actions
  check assert "snapper-cleanup.timer enabled" unit_enabled snapper-cleanup.timer

  snapper_csv() { root snapper --csvout --no-headers list --columns number,type,cleanup; }
  csv_row_matches() { grep -qE -- "$1" <<<"$snapshots_csv"; }

  n0="$(snapper_csv | tail -1 | cut -d, -f1)"
  root dnf install -y hello
  root dnf remove -y hello
  snapshots_csv="$(snapper_csv)"
  n1="$(tail -1 <<<"$snapshots_csv" | cut -d, -f1)"
  check assert "at least 2 new snapshots from install/remove round-trip" ge "$((n1 - n0))" 2
  check assert "pre snapshot has cleanup=number" csv_row_matches '^[0-9]+,pre,number$'
  check assert "post snapshot has cleanup=number" csv_row_matches '^[0-9]+,post,number$'
fi

if ran 30-packages; then
  declare -a versionlock_pkgs
  read_pkg_list versionlock_pkgs vekrona_versionlock_pkgs
  for p in "${versionlock_pkgs[@]}" ghostty greetd tuigreet; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell 2>/dev/null || true)"
  check assert "quickshell vendor is not agaspar" not_contains agaspar "$quickshell_vendor"
  for p in "${versionlock_pkgs[@]}"; do
    check assert "versionlock: $p" versionlock_has "$p"
  done
  os_version_id="$(source /etc/os-release && echo "$VERSION_ID")"
  while IFS= read -r entry; do
    [[ "$entry" =~ \.fc([0-9]+) ]] || continue
    fcver="${BASH_REMATCH[1]}"
    warn_check "versionlock entry matches fc$os_version_id: $entry" eq "$fcver" "$os_version_id"
  done < <(versionlock_evrs)
  check assert "greetd user exists" bash -c "getent passwd greetd >/dev/null"

  check assert "package installed: tuned-ppd" pkg_installed tuned-ppd
  check assert "tuned.service enabled" unit_enabled tuned
  check assert "tuned-ppd.service enabled" unit_enabled tuned-ppd
  warn_check "power profiles D-Bus name answers: net.hadess.PowerProfiles" \
    busctl introspect net.hadess.PowerProfiles /net/hadess/PowerProfiles

  check assert "flathub flatpak remote present and enabled system-wide" flatpak_remote_system_enabled flathub
fi

if ran 40-system; then
  check assert_file_contains /etc/greetd/config.toml 'user = "greetd"'
  check assert "/var/cache/tuigreet exists" dir_exists /var/cache/tuigreet
  check assert "/var/cache/tuigreet owned by greetd" owned_by /var/cache/tuigreet greetd
  check assert "logind inhibit-delay drop-in present" file_exists /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf
  check assert "oomd drop-in present" file_exists /etc/systemd/oomd.conf.d/vekrona.conf
  check assert "usb autosuspend drop-in present" file_exists /etc/modprobe.d/vekrona-usb-autosuspend.conf
  check assert "$VEKRONA_USER in input group" group_member "$VEKRONA_USER" input
  check assert "/dev/uinput exists" file_exists /dev/uinput
fi

if ran 50-user; then
  check assert "sway config validates" env WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway --unsupported-gpu --validate -c "$HOME/.config/sway/config"
  check assert "xremap config validates" xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml"
  check assert "sway keybindings all described" vekrona-keybindings --check
  check assert "vekrona-keybindings --list has workspace 10 bindings" bash -c "vekrona-keybindings --list | grep -qF 'workspace 1…10'"
  check assert "vekrona-keybindings --list has the help binding" bash -c "vekrona-keybindings --list | grep -qF 'Show keybindings help'"
  check assert "dms.service wanted by sway-session.target" file_exists "$HOME/.config/systemd/user/sway-session.target.wants/dms.service"
  check assert "dms.service not wanted by graphical-session.target" file_absent "$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
  check assert "xremap.service enabled" user_unit_enabled xremap
  check assert "JetBrainsMono Nerd Font installed" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"
  check assert "vekrona fontconfig linked" file_exists "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
  check assert "fc-match sans-serif -> Atkinson Hyperlegible Next" bash -c "fc-match sans-serif | grep -q 'Atkinson Hyperlegible Next'"
  check assert "fc-match sans-serif (Ukrainian i, U+0456) -> Inter" bash -c "fc-match 'sans-serif:charset=0456' | grep -q Inter"
  check assert "fc-match monospace -> JetBrainsMono Nerd Font" bash -c "fc-match monospace | grep -q 'JetBrainsMono Nerd Font'"
  check assert "gsettings font-name: Atkinson Hyperlegible Next 11" gsettings_eq org.gnome.desktop.interface font-name "Atkinson Hyperlegible Next 11"
  check assert "gsettings document-font-name: Atkinson Hyperlegible Next 11" gsettings_eq org.gnome.desktop.interface document-font-name "Atkinson Hyperlegible Next 11"
  check assert "gsettings monospace-font-name: JetBrainsMono Nerd Font 11" gsettings_eq org.gnome.desktop.interface monospace-font-name "JetBrainsMono Nerd Font 11"
  check assert "DankMaterialShell settings.json present" file_exists "$HOME/.config/DankMaterialShell/settings.json"
  check assert "DMS changelog for the installed version marked seen" file_exists "$HOME/.config/DankMaterialShell/.changelog-$(dms_changelog_version)"
  check assert "DMS settings: lockBeforeSuspend=true, acLockTimeout=300" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('lockBeforeSuspend') is True, d.get('lockBeforeSuspend')
assert d.get('acLockTimeout') == 300, d.get('acLockTimeout')
"
  check assert "DMS settings: fontFamily=Atkinson Hyperlegible Next" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('fontFamily') == 'Atkinson Hyperlegible Next', d.get('fontFamily')
"

  check assert "vekronaSwayWorkspaces plugin linked" file_exists "$HOME/.config/DankMaterialShell/plugins/vekronaSwayWorkspaces/plugin.json"
  check assert "vekronaSwayWorkspaces plugin enabled" bash -c "jq -e '.vekronaSwayWorkspaces.enabled == true' '$HOME/.config/DankMaterialShell/plugin_settings.json' >/dev/null"
  check assert "vekronaSwayWorkspaces plugin placed in a DankBar widget list" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
bars = d.get('barConfigs', [])
assert any('vekronaSwayWorkspaces' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
"

  declare -A electron_apps=(
    [com.discordapp.Discord]=1
    [com.spotify.Client]=1
    [md.obsidian.Obsidian]=1
    [org.signal.Signal]=1
  )
  for app_id in "${!electron_apps[@]}"; do
    flatpak_installed "$app_id" || continue
    override="$(flatpak override --user --show "$app_id" 2>/dev/null || true)"
    check assert "flatpak x11 override set: $app_id" contains x11 "$override"
  done

  firefox_profiles_ini="$(firefox_profile_root)/profiles.ini"
  check assert "youtube webapp profile registered" grep -q 'vekrona-youtube' "$firefox_profiles_ini"
  check assert "whatsapp webapp profile registered" grep -q 'vekrona-whatsapp' "$firefox_profiles_ini"
  check assert "vekrona-theme installed" file_exists "$HOME/.local/bin/vekrona-theme"

  ghostty_theme_dir="/usr/share/ghostty/themes"
  for theme_json in "$VEKRONA_ROOT"/config/dms-themes/*.json; do
    theme_name="$(basename "$theme_json" .json)"
    ghostty_theme_name="$(ghostty_theme_for "$theme_name")"
    check assert "ghostty built-in theme exists: $theme_name -> $ghostty_theme_name" \
      file_exists "$ghostty_theme_dir/$ghostty_theme_name"
  done

  recorded_theme_name="$(cat "$(vekrona_theme_name_file)" 2>/dev/null || true)"
  nonempty() { [[ -n "$1" ]]; }
  check assert "recorded theme name present" nonempty "$recorded_theme_name"
  recorded_ghostty_theme="$(ghostty_theme_for "$recorded_theme_name")"
  check assert "ghostty theme include present" file_exists "$GHOSTTY_THEME_INCLUDE"
  check assert_file_contains "$GHOSTTY_THEME_INCLUDE" "^theme = $recorded_ghostty_theme\$"

  check assert_file_contains "$HOME/.config/ghostty/config" '^config-file = vekrona-theme$'
  check assert "ghostty config validates" ghostty +validate-config

  check assert "DMS matugen Ghostty template enabled" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('runDmsMatugenTemplates', True) is True
assert d.get('matugenTemplateGhostty', True) is True
"

  gpu_env_file="$HOME/.config/environment.d/vekrona-gpu.conf"
  dms_main_pid="$(systemctl --user show dms -p MainPID --value 2>/dev/null || true)"
  qsg_declared_env="$(systemctl --user show dms -p Environment 2>/dev/null || true)"
  qsg_manager_env="$(systemctl --user show-environment 2>/dev/null || true)"
  dms_process_env=""
  if [[ -n "$dms_main_pid" && "$dms_main_pid" != "0" ]]; then
    dms_process_env="$(tr '\0' '\n' < "/proc/$dms_main_pid/environ" 2>/dev/null || true)"
  fi

  if [[ -e /dev/dri/vekrona-dgpu ]]; then
    check assert "vekrona-gpu.conf present (dGPU device exists)" file_exists "$gpu_env_file"
    check assert_file_contains "$gpu_env_file" '^QSG_RHI_BACKEND=vulkan$'
    if [[ -n "$dms_main_pid" && "$dms_main_pid" != "0" ]]; then
      warn_check "dms.service process has QSG_RHI_BACKEND=vulkan (warn, not fail: environment.d only takes effect for a new login; a process already running from before this stage ran can lag until reboot or re-login)" \
        contains 'QSG_RHI_BACKEND=vulkan' "$dms_process_env"
    else
      log "dms.service not running, skipping its process environment check"
    fi
  else
    check assert "vekrona-gpu.conf absent (no dGPU device)" file_absent "$gpu_env_file"
    for f in "$HOME/.config/environment.d/vekrona.conf" "$HOME/.config/systemd/user/dms.service.d/vekrona.conf"; do
      check assert "$f has no QSG_RHI_BACKEND" file_lacks_qsg_backend "$f"
    done
    check assert "dms.service declared Environment has no QSG_RHI_BACKEND" not_contains 'QSG_RHI_BACKEND' "$qsg_declared_env"
    check assert "systemd --user manager environment has no QSG_RHI_BACKEND" not_contains 'QSG_RHI_BACKEND' "$qsg_manager_env"
    if [[ -n "$dms_main_pid" && "$dms_main_pid" != "0" ]]; then
      warn_check "dms.service process has no QSG_RHI_BACKEND (warn, not fail: environment.d only takes effect for a new login; a process already running from before this stage ran can lag until reboot or re-login)" \
        not_contains 'QSG_RHI_BACKEND' "$dms_process_env"
    else
      log "dms.service not running, skipping its process environment check"
    fi
  fi

  user_path="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"
  warn_check "$HOME/.local/bin in systemd user PATH" contains "$HOME/.local/bin" "$user_path"
fi

if ran 55-agents; then
  check assert "repo enabled: $CLAUDE_CODE_REPO_ID" repo_enabled "$CLAUDE_CODE_REPO_ID"
  check assert "repo enabled: $MISE_REPO_ID" repo_enabled "$MISE_REPO_ID"
  check assert "gpg key imported: claude-code" gpg_pubkey_installed "$(tr '[:upper:]' '[:lower:]' <<<"${CLAUDE_CODE_GPG_FINGERPRINT: -8}")"
  check assert "gpg key imported: mise" gpg_pubkey_installed "$(tr '[:upper:]' '[:lower:]' <<<"${MISE_GPG_FINGERPRINT: -8}")"
  for p in "${VEKRONA_AGENT_PKGS[@]}"; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "/etc/mise/config.toml matches repo" cmp -s "$VEKRONA_ROOT/etc/mise/config.toml" /etc/mise/config.toml
  check assert "/etc/profile.d/vekrona-mise.sh matches repo" cmp -s "$VEKRONA_ROOT/etc/profile.d/vekrona-mise.sh" /etc/profile.d/vekrona-mise.sh
  check assert "claude resolves" bash -c "command -v claude >/dev/null"
  for t in "${VEKRONA_AGENT_TOOLS[@]}"; do
    check assert "$t shim present" bash -c "[[ -x '$MISE_SYSTEM_DATA_DIR/shims/$t' ]]"
  done
  check assert "$MISE_SYSTEM_DATA_DIR owned by root" owned_by "$MISE_SYSTEM_DATA_DIR" root
  check assert "$MISE_SYSTEM_CONFIG_DIR owned by root" owned_by "$MISE_SYSTEM_CONFIG_DIR" root
  for name in claude "${VEKRONA_AGENT_TOOLS[@]}"; do
    warn_check "no user-local copy shadows $name on PATH" bash -c "[[ ! -e '$HOME/.local/bin/$name' ]]"
  done
fi

if ran 60-gaming; then
  check assert "scb is executable" bash -c "[[ -x /usr/local/bin/scb ]]"
  for p in gamescope mangohud gamemode steam; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "scopebuddy config present" file_exists "$HOME/.config/scopebuddy/scb.conf"
fi

if ran 65-login-manager; then
  dm_target="$(dm_unit_target 2>/dev/null || true)"
  if dm_is_greetd; then
    verify_greetd_active
  elif [[ -n "$dm_target" ]]; then
    log "another display manager enabled ($dm_target); skipping greetd checks, 90a-switch-dm is the migration path"
  else
    die "no display manager enabled"
  fi
fi

if ran 90a-switch-dm || ran 90b-remove; then
  verify_greetd_active
  warn_check "gdm not present or disabled" gdm_absent_or_disabled
  warn_check "secrets service reachable" busctl --user status org.freedesktop.secrets
  for p in omedora hyprland keyd; do
    check assert "package absent: $p" pkg_absent "$p"
  done
  declare -a desktop_pkgs
  read_pkg_list desktop_pkgs vekrona_desktop_pkgs
  for p in "${desktop_pkgs[@]}"; do
    check assert "protected desktop package present: $p" pkg_installed "$p"
  done
  for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/oomd.conf.d/vekrona.conf /etc/modprobe.d/vekrona-usb-autosuspend.conf; do
    check assert "override still present: $f" file_exists "$f"
  done
fi

log "verify summary: ok=$ok_count warn=$warn_count"
