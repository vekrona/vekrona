#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

DANKLINUX_REPO="copr:copr.fedorainfracloud.org:avengemedia:danklinux"
ensure_pkg_from_repo "$DANKLINUX_REPO" quickshell

quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell)"
[[ "$quickshell_vendor" != *agaspar* ]] || die "quickshell still built by agaspar/omedora: $quickshell_vendor"
log "ok: quickshell vendor is $quickshell_vendor"

ensure_pkg \
  sway sway-config-fedora sway-systemd \
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
  greetd tuigreet \
  ghostty \
  xremap-wlroots \
  dms dgop matugen danksearch \
  grim slurp swappy wf-recorder wl-clipboard \
  kanshi wlr-randr brightnessctl playerctl \
  firefox \
  gnome-keyring gnome-keyring-pam \
  gamescope mangohud gamemode steam \
  jetbrains-mono-fonts rsms-inter-fonts \
  accountsservice

root dnf mark user \
  NetworkManager polkit wireplumber pipewire xdg-desktop-portal-gtk \
  gnome-keyring gnome-keyring-pam

wlroots_pkg="$(rpm -q --whatprovides 'libwlroots-0.19.so()(64bit)' --qf '%{NAME}\n' 2>/dev/null | sort -u | head -n1)"
[[ -n "$wlroots_pkg" ]] || die "no installed package provides libwlroots-0.19.so"
log "wlroots package for versionlock: $wlroots_pkg"

versionlock_installed sway "$wlroots_pkg" dms quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland xremap-wlroots
