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

if repo_enabled 1password; then
  log "repo enabled: 1password"
else
  ensure_root_file "$ROOT/etc/yum.repos.d/1password.repo" /etc/yum.repos.d/1password.repo
  ensure_gpg_key_imported "$ONEPASSWORD_GPG_URL" "$ONEPASSWORD_GPG_FINGERPRINT"
  root dnf makecache --repo=1password
  repo_enabled 1password || die "repo not enabled: 1password"
fi
