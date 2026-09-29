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

ensure_copr blakegardner/xremap scottames/ghostty avengemedia/dms avengemedia/danklinux
