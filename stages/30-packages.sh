#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/proton.sh"

# An update (the 09:00 check, the midnight run) must not change the Proton repo or run dnf while this stage does; the lock
# is held until the stage ends.
update_lock

# rpm records a gpg-pubkey's full lowercase fingerprint as %{VERSION}, so its NVR is looked up by that.
ensure_rpm_key_absent() {
  local fingerprint_lower nvr
  fingerprint_lower="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  gpg_pubkey_installed "$fingerprint_lower" || return 0
  nvr="$(rpm -q gpg-pubkey --qf '%{VERSION} %{NAME}-%{VERSION}-%{RELEASE}\n' | awk -v v="$fingerprint_lower" 'tolower($1) == v { print $2 }')"
  [[ -n "$nvr" ]] || die "gpg-pubkey with fingerprint $fingerprint_lower is installed but rpm lists no NVR for it"
  log "removing the retired rpm signing key $nvr"
  root rpm -e "$nvr"
  ! gpg_pubkey_installed "$fingerprint_lower" || die "rpm signing key $fingerprint_lower is still installed after rpm -e $nvr"
}

for pkg in "${!VEKRONA_PINNED_PKGS[@]}"; do
  ensure_pkg_from_repo "${VEKRONA_PINNED_PKGS[$pkg]}" "$pkg"
done

quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell)"
[[ "$quickshell_vendor" != *agaspar* ]] || die "quickshell still built by agaspar/omedora: $quickshell_vendor"
log "ok: quickshell vendor is $quickshell_vendor"

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
ensure_pkg_absent "${VEKRONA_UNWANTED_PKGS[@]}"

ensure_pkg_swapped ffmpeg-free ffmpeg

# proton-vpn-daemon's %posttrans starts a service that loads libclang-cpp through python3-bcc.
# ldconfig refreshes ld.so.cache only after %posttrans, so python3-bcc goes into an earlier transaction.
ensure_pkg python3-bcc

desktop_pkgs_except_pinned=()
for pkg in "${VEKRONA_DESKTOP_PKGS[@]}"; do
  [[ -n "${VEKRONA_PINNED_PKGS[$pkg]+x}" ]] || desktop_pkgs_except_pinned+=("$pkg")
done
ensure_pkg "${desktop_pkgs_except_pinned[@]}"
ensure_1password_repo_file

# The repo directory and its metadata must exist before dnf reads the repo file, or every dnf run fails on it.
ensure_pkg createrepo_c jq
root "$ROOT/bin/vekrona-proton" stage
ensure_root_file "$ROOT/etc/yum.repos.d/vekrona-proton.repo" /etc/yum.repos.d/vekrona-proton.repo
mapfile -t proton_pkgs < <(proton_package_names)
ensure_pkg "${proton_pkgs[@]}"

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
