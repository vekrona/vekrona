#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

is_enabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == enabled ]]; }
dm_is_greetd() { [[ "$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")" == greetd.service ]]; }

session_is_sway || die "current session is not Sway (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}); log into the GDM-started Sway session first, then rerun 90a-switch-dm"

root dnf mark user NetworkManager polkit wireplumber pipewire xdg-desktop-portal-gtk gnome-keyring gnome-keyring-pam

if is_enabled gdm; then
  root systemctl disable gdm
else
  log "gdm already disabled"
fi

if is_enabled greetd; then
  log "greetd already enabled"
else
  root systemctl enable --force greetd
fi

assert "greetd enabled" is_enabled greetd
assert "display-manager.service points to greetd" dm_is_greetd

warn "reboot now; then run 90b-remove from the greetd-started Sway session"
