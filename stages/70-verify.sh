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
dir_exists() { [[ -d "$1" ]]; }
owned_by() { [[ "$(stat -c '%U' "$1" 2>/dev/null)" == "$2" ]]; }
group_member() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
not_repo_enabled() { ! repo_enabled "$1"; }
copr_id() { echo "copr:copr.fedorainfracloud.org:${1/\//:}"; }
copr_enabled() { repo_enabled "$(copr_id "$1")"; }
unit_enabled() { eq "$(systemctl is-enabled "$1" 2>/dev/null || true)" enabled; }
user_unit_enabled() { eq "$(systemctl --user is-enabled "$1" 2>/dev/null || true)" enabled; }
pkg_absent() { ! pkg_installed "$1"; }
gdm_absent_or_disabled() { ! pkg_installed gdm || ! unit_enabled gdm; }
nvidia_module_present_for() { compgen -G "$1/extra/nvidia*" >/dev/null || compgen -G "$1/weak-updates/nvidia*" >/dev/null; }

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
    warn_check "nvidia module present for kernel $kver" nvidia_module_present_for "${d%/}"
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

  snapper_csv() { root snapper --csvout list --no-headers --columns number,type,cleanup; }
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
  wlroots_pkg="$(wlroots_package_name)"
  for p in sway "$wlroots_pkg" dms quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland xremap-wlroots ghostty greetd tuigreet; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell 2>/dev/null || true)"
  check assert "quickshell vendor is not agaspar" not_contains agaspar "$quickshell_vendor"
  for p in sway "$wlroots_pkg" dms quickshell qt6-qtbase xremap-wlroots; do
    check assert "versionlock: $p" versionlock_has "$p"
  done
  os_version_id="$(source /etc/os-release && echo "$VERSION_ID")"
  while IFS= read -r entry; do
    [[ "$entry" =~ \.fc([0-9]+) ]] || continue
    fcver="${BASH_REMATCH[1]}"
    warn_check "versionlock entry matches fc$os_version_id: $entry" eq "$fcver" "$os_version_id"
  done < <(versionlock_evrs)
  check assert "greetd user exists" bash -c "getent passwd greetd >/dev/null"
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
  check assert "sway config validates" sway --unsupported-gpu --validate -c "$HOME/.config/sway/config"
  check assert "xremap config validates" xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml"
  dms_env="$(systemctl --user show dms -p Environment 2>/dev/null || true)"
  check assert "dms.service has QSG_RHI_BACKEND=vulkan" contains 'QSG_RHI_BACKEND=vulkan' "$dms_env"
  check assert "dms.service wanted by sway-session.target" file_exists "$HOME/.config/systemd/user/sway-session.target.wants/dms.service"
  check assert "dms.service not wanted by graphical-session.target" file_absent "$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
  check assert "xremap.service enabled" user_unit_enabled xremap
  check assert "JetBrainsMono Nerd Font installed" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"
  check assert "DankMaterialShell settings.json present" file_exists "$HOME/.config/DankMaterialShell/settings.json"
  check assert "DMS settings: lockBeforeSuspend=true, acLockTimeout=300" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('lockBeforeSuspend') is True, d.get('lockBeforeSuspend')
assert d.get('acLockTimeout') == 300, d.get('acLockTimeout')
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

  if [[ -e /dev/dri/vekrona-dgpu ]]; then
    check assert "vekrona-gpu.conf present (dGPU device exists)" file_exists "$HOME/.config/environment.d/vekrona-gpu.conf"
  else
    check assert "vekrona-gpu.conf absent (no dGPU device)" file_absent "$HOME/.config/environment.d/vekrona-gpu.conf"
  fi

  user_path="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"
  warn_check "$HOME/.local/bin in systemd user PATH" contains "$HOME/.local/bin" "$user_path"
fi

if ran 60-gaming; then
  check assert "scb is executable" bash -c "[[ -x /usr/local/bin/scb ]]"
  for p in gamescope mangohud gamemode steam; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "scopebuddy config present" file_exists "$HOME/.config/scopebuddy/scb.conf"
fi

if ran 90a-switch-dm || ran 90b-remove; then
  check assert "greetd enabled" unit_enabled greetd
  warn_check "gdm not present or disabled" gdm_absent_or_disabled
  warn_check "secrets service reachable" busctl --user status org.freedesktop.secrets
  for p in omedora hyprland keyd; do
    check assert "package absent: $p" pkg_absent "$p"
  done
  for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/oomd.conf.d/vekrona.conf /etc/modprobe.d/vekrona-usb-autosuspend.conf; do
    check assert "override still present: $f" file_exists "$f"
  done
fi

log "verify summary: ok=$ok_count warn=$warn_count"
