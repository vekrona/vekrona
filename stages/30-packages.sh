#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/proton.sh
source "$ROOT/lib/proton.sh"

# An update (the 09:00 check, the midnight run) must not change the Proton repo or run dnf while this stage does; the lock
# is held until the stage ends.
update_lock

# Installs the RPM from a root-owned copy whose sha256 is checked here: the RPM is unsigned, so the pin is the only trust anchor,
# and root installs exactly the bytes checked, which a process of the user could not swap in the download directory.
install_pinned_rune_rpm() {
  local sum="$1" rpm_file="$2" root_dir="$3" copy
  copy="$(root_owned_copy "$rpm_file" "$root_dir")"
  assert_checksum sha256 "$sum" "$copy"
  log "installing: ${copy##*/} (sha256 verified against the pin)"
  root dnf install -y "$copy"
}

download_and_install_pinned_rune() {
  local sum="$1" url="$2" download_dir="$3"
  log "downloading: $url"
  download_file "$url" "$download_dir/rune.rpm"
  with_root_scratch_dir install_pinned_rune_rpm "$sum" "$download_dir/rune.rpm"
}

ensure_rune() {
  local arch sum url pinned
  arch="$(uname -m)"
  sum="$(rune_rpm_sha256 "$arch")"
  url="$(rune_rpm_url "$arch")"
  pinned="$(rune_pinned_nvr)"
  if [[ "$(rune_installed_nvr)" == "$pinned" ]]; then
    log "package present: rune-$pinned"
    return 0
  fi
  with_scratch_dir download_and_install_pinned_rune "$sum" "$url"
  [[ "$(rune_installed_nvr)" == "$pinned" ]] || die "rune-$pinned did not install (rune is $(rune_installed_nvr))"
}

for pkg in "${!VEKRONA_PINNED_PKGS[@]}"; do
  ensure_pkg_from_repo "${VEKRONA_PINNED_PKGS[$pkg]}" "$pkg"
done

quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell)"
[[ "$quickshell_vendor" != *agaspar* ]] || die "quickshell still built by agaspar/omedora: $quickshell_vendor"
log "ok: quickshell vendor is $quickshell_vendor"

# The running shell goes before its package does; stage 50 retires the unit's links (VEKRONA_RETIRED_USER_UNITS).
ensure_user_unit_stopped dms.service
ensure_pkg_absent "${VEKRONA_RETIRED_PKGS[@]}"
versionlock_absent "${VEKRONA_RETIRED_PKGS[@]}"

# Leftovers of the retired mise/agent install. The claude-code RPM and repo and nodejs24-npm are left alone: they are user-owned now.
# A link goes only when it still points into mise's tree; anything else is the user's own binary.
for link in "${VEKRONA_RETIRED_AGENT_LINKS[@]}"; do
  if path_absent "$link"; then
    log "absent: $link"
  elif links_into_retired_mise_share "$link"; then
    ensure_root_file_absent "$link"
  else
    log "keeping $link: it is not a link into $VEKRONA_RETIRED_MISE_SHARE"
  fi
done
for file in "${VEKRONA_RETIRED_AGENT_FILES[@]}"; do ensure_root_file_absent "$file"; done
for tree in "${VEKRONA_RETIRED_AGENT_TREES[@]}"; do ensure_root_tree_absent "$tree"; done
ensure_rpm_key_absent "$VEKRONA_RETIRED_MISE_KEY_FPR"

ensure_pkg_swapped ffmpeg-free ffmpeg

desktop_pkgs_except_pinned=()
for pkg in "${VEKRONA_DESKTOP_PKGS[@]}"; do
  [[ -n "${VEKRONA_PINNED_PKGS[$pkg]+x}" ]] || desktop_pkgs_except_pinned+=("$pkg")
done
ensure_pkg "${desktop_pkgs_except_pinned[@]}"
# After sway is installed: ensure_pkg_absent finds the protected wlroots package through it.
ensure_unwanted_pkgs_absent
# Removing a package does not stop what sway's XDG autostart already started from it (nm-applet, blueman-applet).
stop_orphaned_autostart_units
ensure_1password_repo_file

# The repo directory and its metadata must exist before dnf reads the repo file, or every dnf run fails on it.
ensure_pkg createrepo_c jq
root "$ROOT/bin/vekrona-proton" stage
ensure_root_file "$ROOT/etc/yum.repos.d/vekrona-proton.repo" /etc/yum.repos.d/vekrona-proton.repo
mapfile -t proton_pkgs < <(proton_package_names)
ensure_pkg "${proton_pkgs[@]}"

ensure_rune

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
