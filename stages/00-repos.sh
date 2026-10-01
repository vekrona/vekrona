#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm dnf5 curl

download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT

ensure_rpmfusion_release() {
  local section="$1" pkg="rpmfusion-$1-release" key_repo url rpm_file
  key_repo="$(rpmfusion_key_repo "$section")"
  url="$(rpmfusion_release_url "$section")"
  rpm_file="$download_dir/$pkg.rpm"
  ensure_pkg gnupg2
  import_pinned_repo_key "$key_repo" "$VEKRONA_ROOT/etc/pki/rpm-gpg/$(repo_key_name "$key_repo")"
  if pkg_installed "$pkg"; then
    log "package present: $pkg"
  else
    log "downloading: $url"
    curl --fail --silent --show-error --location --output "$rpm_file" "$url" || die "download failed: $url"
    assert_rpm_signed_by_pinned_key "$key_repo" "$rpm_file"
    log "installing: $pkg (signature verified against pinned key $key_repo)"
    root dnf install -y "$rpm_file"
    pkg_installed "$pkg" || die "package did not install: $pkg"
  fi
  assert_repo_key_trusted "$key_repo"
  rpmfusion_repo_file_uses_pinned_key "$section" \
    || die "/etc/yum.repos.d/rpmfusion-$section.repo does not take its key only from $VEKRONA_REPO_KEY_DIR/RPM-GPG-KEY-rpmfusion-$section-fedora-\$releasever"
}

ensure_rpmfusion_release free
ensure_rpmfusion_release nonfree

ensure_repo_enabled rpmfusion-free rpmfusion-nonfree rpmfusion-free-updates rpmfusion-nonfree-updates
ensure_repo_enabled fedora-cisco-openh264

ensure_copr "${VEKRONA_COPRS[@]}"

ensure_repo_key 1password
ensure_1password_repo_file
ensure_repo_enabled 1password
