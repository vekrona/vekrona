#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

is_enabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == enabled ]]; }

session_is_sway || die "current session is not Sway (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}); start a Sway session first (log in through the greeter, or run start-sway from a text console), then rerun 90a-switch-dm"

declare -a desktop_pkgs
read_pkg_list desktop_pkgs vekrona_desktop_pkgs
mark_user_installed "${desktop_pkgs[@]}"

if is_enabled gdm; then
  root systemctl disable gdm
else
  log "gdm already disabled"
fi

enable_greetd_login_manager

warn "reboot now; then run 90b-remove from the greetd-started Sway session"
