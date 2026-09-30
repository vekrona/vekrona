#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

DANKLINUX_REPO="copr:copr.fedorainfracloud.org:avengemedia:danklinux"
ensure_pkg_from_repo "$DANKLINUX_REPO" quickshell

quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell)"
[[ "$quickshell_vendor" != *agaspar* ]] || die "quickshell still built by agaspar/omedora: $quickshell_vendor"
log "ok: quickshell vendor is $quickshell_vendor"

desktop_pkgs_except_quickshell=()
for pkg in "${VEKRONA_DESKTOP_PKGS[@]}"; do
  [[ "$pkg" == quickshell ]] || desktop_pkgs_except_quickshell+=("$pkg")
done
ensure_pkg "${desktop_pkgs_except_quickshell[@]}"

declare -a desktop_pkgs
read_pkg_list desktop_pkgs vekrona_desktop_pkgs
mark_user_installed "${desktop_pkgs[@]}"

ensure_system_unit enabled tuned tuned-ppd

ensure_flatpak_remote_system flathub https://dl.flathub.org/repo/flathub.flatpakrepo

declare -a versionlock_pkgs
read_pkg_list versionlock_pkgs vekrona_versionlock_pkgs
log "versionlock packages: ${versionlock_pkgs[*]}"

versionlock_installed "${versionlock_pkgs[@]}"
