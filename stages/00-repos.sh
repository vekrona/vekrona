#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm dnf5

fedora_version="$(rpm -E %fedora)"

ensure_rpmfusion_release() {
  local pkg="$1" section="$2"
  pkg_installed "$pkg" && { log "package present: $pkg"; return 0; }
  log "installing: $pkg"
  root dnf install -y "https://mirrors.rpmfusion.org/$section/fedora/$pkg-$fedora_version.noarch.rpm"
  pkg_installed "$pkg" || die "package did not install: $pkg"
}

ensure_rpmfusion_release rpmfusion-free-release free
ensure_rpmfusion_release rpmfusion-nonfree-release nonfree

ensure_repo_enabled rpmfusion-free rpmfusion-nonfree rpmfusion-free-updates rpmfusion-nonfree-updates
ensure_repo_enabled fedora-cisco-openh264

ensure_copr "${VEKRONA_COPRS[@]}"

ensure_1password_gpg_key() {
  local fingerprint="3fef9748469adbe15da7ca80ac2d62742012ea22"
  rpm -q "gpg-pubkey-$fingerprint" >/dev/null 2>&1 && { log "1Password GPG key imported"; return 0; }
  log "importing 1Password GPG key"
  root rpm --import https://downloads.1password.com/linux/keys/1password.asc
  rpm -q "gpg-pubkey-$fingerprint" >/dev/null 2>&1 || die "1Password GPG key not imported"
}

if repo_enabled 1password; then
  log "repo enabled: 1password"
else
  ensure_root_file "$ROOT/etc/yum.repos.d/1password.repo" /etc/yum.repos.d/1password.repo
  ensure_1password_gpg_key
  root dnf makecache --repo=1password
  repo_enabled 1password || die "repo not enabled: 1password"
fi
