#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

PROTECTED="dnf5,sudo,systemd,systemd-udev,NetworkManager,shim-x64,grub2-efi-x64,setup,selinux-policy-targeted"

REMOVE_GLOBS=(
  omedora
  omedora-settings
  omedora-nerd-fonts
  'hyprland*'
  uwsm
  xdg-desktop-portal-hyprland
  keyd
  hyprsunset
  'plasma-*'
  'kf6-*'
  polkit-kde
  gnome-shell
  gdm
  'gnome-session*'
  gnome-control-center
)

expand_installed() {
  local pat
  for pat in "$@"; do
    rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null
  done | sort -u
}

env_is_installed() { dnf environment list --installed 2>/dev/null | grep -qE "^${1}[[:space:]]"; }

review_assumeno() {
  local out rc=0
  out="$(root dnf "$@" --assumeno --setopt=protected_packages="$PROTECTED" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [[ $rc -eq 0 ]] && return 0
  [[ $rc -eq 1 && "$out" == *"Operation aborted"* ]] && return 0
  die "dnf $* --assumeno failed unexpectedly (exit $rc)"
}

MARK_USER_PKGS=(
  NetworkManager NetworkManager-wifi polkit wireplumber pipewire pipewire-pulseaudio bluez
  xdg-desktop-portal-gtk xdg-desktop-portal-wlr gnome-keyring gnome-keyring-pam
  firefox flatpak sway sway-config-fedora sway-systemd greetd tuigreet ghostty dms
  quickshell xremap-wlroots steam gamescope mangohud gamemode libnotify
  grim slurp swappy wf-recorder wl-clipboard
)

session_is_sway || die "current session is not Sway (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})"
session_started_by_gdm && die "gdm is still active; reboot into the greetd-started Sway session first"
[[ "$(systemctl is-enabled greetd 2>/dev/null || true)" == enabled ]] || die "greetd is not enabled; run 90a-switch-dm and reboot first"

mark_user_installed "${MARK_USER_PKGS[@]}"

mapfile -t to_remove < <(expand_installed "${REMOVE_GLOBS[@]}")

envs_to_remove=()
for e in workstation-product-environment kde-desktop-environment; do
  env_is_installed "$e" && envs_to_remove+=("$e")
done

if [[ ${#to_remove[@]} -gt 0 ]]; then
  log "reviewing removal of: ${to_remove[*]}"
  review_assumeno remove "${to_remove[@]}"
else
  log "nothing from the explicit removal list is installed"
fi

if [[ ${#envs_to_remove[@]} -gt 0 ]]; then
  log "reviewing removal of environment groups: ${envs_to_remove[*]}"
  review_assumeno environment remove "${envs_to_remove[@]}"
else
  log "no target environment groups installed"
fi

log "reviewing autoremove"
review_assumeno autoremove

if [[ "${VEKRONA_YES:-0}" != "1" ]]; then
  read -r -p "vekrona: proceed with the removal reviewed above? [type yes] " reply < /dev/tty
  [[ "$reply" == "yes" ]] || die "removal not confirmed"
fi

if [[ ${#to_remove[@]} -gt 0 ]]; then
  root dnf remove -y --setopt=protected_packages="$PROTECTED" "${to_remove[@]}"
  for p in "${to_remove[@]}"; do
    pkg_installed "$p" && die "package still installed after removal: $p"
  done
fi

if [[ ${#envs_to_remove[@]} -gt 0 ]]; then
  log "removing environment groups: ${envs_to_remove[*]}"
  root dnf environment remove -y --setopt=protected_packages="$PROTECTED" "${envs_to_remove[@]}"
  for e in "${envs_to_remove[@]}"; do
    env_is_installed "$e" && die "environment still installed after removal: $e"
  done
fi

ensure_copr_absent agaspar/omedora-4 alternateved/keyd wezfurlong/wezterm-nightly phracek/PyCharm

if [[ -f /etc/yum.repos.d/cuda-fedora43.repo ]]; then
  log "removing stale repo file: /etc/yum.repos.d/cuda-fedora43.repo"
  root rm -f /etc/yum.repos.d/cuda-fedora43.repo
  [[ -f /etc/yum.repos.d/cuda-fedora43.repo ]] && die "cuda-fedora43.repo still present after removal"
fi

root dnf autoremove -y --setopt=protected_packages="$PROTECTED"

for p in NetworkManager polkit wireplumber pipewire gnome-keyring firefox flatpak; do
  assert "package present: $p" pkg_installed "$p"
done

if busctl --user status org.freedesktop.secrets >/dev/null 2>&1; then
  log "ok: secrets service reachable"
else
  warn "secrets service not reachable (not in a graphical session, or not yet started)"
fi

assert "JetBrainsMono Nerd Font installed" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"

for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/oomd.conf.d/vekrona.conf /etc/modprobe.d/vekrona-usb-autosuspend.conf; do
  assert "override still present: $f" test -f "$f"
done

assert "greetd user exists" bash -c "getent passwd greetd >/dev/null"

log "90b-remove complete"
