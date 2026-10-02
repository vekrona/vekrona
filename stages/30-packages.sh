#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

for pkg in "${!VEKRONA_PINNED_PKGS[@]}"; do
  ensure_pkg_from_repo "${VEKRONA_PINNED_PKGS[$pkg]}" "$pkg"
done

quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell)"
[[ "$quickshell_vendor" != *agaspar* ]] || die "quickshell still built by agaspar/omedora: $quickshell_vendor"
log "ok: quickshell vendor is $quickshell_vendor"

ensure_pkg_swapped ffmpeg-free ffmpeg

desktop_pkgs_except_pinned=()
for pkg in "${VEKRONA_DESKTOP_PKGS[@]}"; do
  [[ -n "${VEKRONA_PINNED_PKGS[$pkg]+x}" ]] || desktop_pkgs_except_pinned+=("$pkg")
done
ensure_pkg "${desktop_pkgs_except_pinned[@]}"
ensure_1password_repo_file

declare -a desktop_pkgs
read_pkg_list desktop_pkgs vekrona_desktop_pkgs
mark_user_installed "${desktop_pkgs[@]}"

ensure_system_unit enabled tuned tuned-ppd

ensure_flatpak_remote_system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
for app_id in "${VEKRONA_FLATPAKS[@]}"; do
  ensure_flatpak_app_system flathub "$app_id"
done

declare -a versionlock_pkgs
read_pkg_list versionlock_pkgs vekrona_versionlock_pkgs
log "versionlock packages: ${versionlock_pkgs[*]}"

versionlock_installed "${versionlock_pkgs[@]}"
