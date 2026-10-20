#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cuda-repo.sh"

session_is_sway || die "current session is not Sway (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})"
session_started_by_gdm && die "gdm is still active; reboot into the greetd-started Sway session first"
[[ "$(systemctl is-enabled greetd 2>/dev/null || true)" == enabled ]] || die "greetd is not enabled; run 90a-switch-dm and reboot first"

BASE_PROTECTED="dnf5,sudo,systemd,systemd-udev,shim-x64,grub2-efi-x64,setup,selinux-policy-targeted"

declare -a desktop_pkgs
read_pkg_list desktop_pkgs vekrona_desktop_pkgs
PROTECTED="$BASE_PROTECTED,$(IFS=,; echo "${desktop_pkgs[*]}")"

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
  polkit-kde
  gnome-shell
  gdm
  'gnome-session*'
  gnome-control-center
  dunst # vekrona-shell owns org.freedesktop.Notifications; dunst's D-Bus activation file competes with it
)

expand_installed() {
  local pat
  for pat in "$@"; do
    rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null
  done | sort -u
}

STORE_ROOT="$(root mktemp -d)"
trap 'root rm -rf "$STORE_ROOT"' EXIT

FEDORA_PROTECTED_CONF=/etc/dnf/protected.d/fedora-workstation.conf

if pkg_installed fedora-release-identity-workstation; then
  log "reviewing identity swap: fedora-release-identity-workstation -> fedora-release-identity-basic"
  run_reviewed "$STORE_ROOT" "$PROTECTED" "the identity swap" "do" --action=remove fedora-release-identity-workstation --action=install fedora-release-identity-basic \
    || die "dnf has nothing to do for the identity swap"
  pkg_installed fedora-release-identity-workstation && die "fedora-release-identity-workstation still installed after swap"
  pkg_installed fedora-release-identity-basic || die "fedora-release-identity-basic not installed after swap"
else
  log "fedora-release-identity-workstation not installed, skipping identity swap"
fi

[[ -f "$FEDORA_PROTECTED_CONF" ]] && die "$FEDORA_PROTECTED_CONF still present, gnome-shell removal would be blocked"
log "ok: $FEDORA_PROTECTED_CONF absent"

mark_user_installed "${desktop_pkgs[@]}"

mapfile -t to_remove < <(expand_installed "${REMOVE_GLOBS[@]}")

if [[ ${#to_remove[@]} -gt 0 ]]; then
  log "reviewing removal of: ${to_remove[*]}"
  if run_reviewed "$STORE_ROOT" "$PROTECTED" "the removal" remove "${to_remove[@]}"; then
    for p in "${to_remove[@]}"; do
      pkg_installed "$p" && die "package still installed after removal: $p"
    done
  fi
else
  log "nothing from the explicit removal list is installed"
fi

ensure_copr_absent agaspar/omedora-4 alternateved/keyd wezfurlong/wezterm-nightly phracek/PyCharm

ensure_stale_cuda_repo_absent

log "reviewing autoremove"
run_reviewed "$STORE_ROOT" "$PROTECTED" "the autoremove" autoremove || log "nothing to autoremove"

for p in "${desktop_pkgs[@]}"; do
  assert "package present: $p" pkg_installed "$p"
done

if busctl --user status org.freedesktop.secrets >/dev/null 2>&1; then
  log "ok: secrets service reachable"
else
  warn "secrets service not reachable (not in a graphical session, or not yet started)"
fi

assert "AtkynsonMono Nerd Font installed" bash -c "fc-list | grep -q 'AtkynsonMono Nerd'"

for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/logind.conf.d/vekrona-idle.conf /etc/systemd/sleep.conf.d/vekrona.conf /etc/systemd/oomd.conf.d/vekrona.conf /etc/systemd/coredump.conf.d/50-vekrona.conf /etc/sudoers.d/50-vekrona-sudo-pam-service; do
  assert "override still present: $f" test -f "$f"
done

assert "greetd user exists" bash -c "getent passwd greetd >/dev/null"

log "90b-remove complete"
