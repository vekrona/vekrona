#!/usr/bin/env bash
# NVIDIA's CUDA repo, shared by stage 10-nvidia (installs it), 70-verify (checks it) and 90b-remove (drops the stale one).
# vekrona stays on a Fedora release NVIDIA already publishes (CLAUDE.md, "Upgrading Fedora to a new major release"): moving
# on means changing CUDA_FEDORA_RELEASE, renaming etc/yum.repos.d/cuda-fedora<N>.repo and its [section] to the new
# release, and replacing etc/pki/rpm-gpg/RPM-GPG-KEY-cuda-fedora-<N> together with its fingerprint in
# VEKRONA_REPO_KEY_FINGERPRINTS (lib/common.sh).

CUDA_FEDORA_RELEASE=44
CUDA_REPO_ID="cuda-fedora$CUDA_FEDORA_RELEASE-x86_64"
CUDA_REPO_FILE_NAME="cuda-fedora$CUDA_FEDORA_RELEASE.repo"
CUDA_KEY_REPO="cuda-fedora-$CUDA_FEDORA_RELEASE"
CUDA_STALE_REPO_FILE="/etc/yum.repos.d/cuda-fedora$((CUDA_FEDORA_RELEASE - 1)).repo"

REPO_OVERRIDE_FILE=/etc/dnf/repos.override.d/99-config_manager.repo

# True when the dnf override file sets OPTION for REPO (what `dnf config-manager setopt REPO.OPTION=...` writes).
repo_override_has() {
  local repo="$1" option="$2" status=0
  [[ -e "$REPO_OVERRIDE_FILE" ]] || return 1
  awk -v section="[$repo]" -v key="$option=" '
    $0 == section { inside = 1; next }
    /^\[/ { inside = 0 }
    inside && index($0, key) == 1 { found = 1 }
    END { exit !found }' "$REPO_OVERRIDE_FILE" || status=$?
  [[ $status -le 1 ]] || die "awk failed with exit status $status on $REPO_OVERRIDE_FILE"
  return "$status"
}

ensure_repo_override_absent() {
  local repo="$1" option="$2"
  if ! repo_override_has "$repo" "$option"; then log "no $option override for repo $repo"; return 0; fi
  log "removing the $option override of repo $repo"
  root dnf5 config-manager unsetopt "$repo.$option"
  ! repo_override_has "$repo" "$option" || die "the $option override of repo $repo is still in $REPO_OVERRIDE_FILE"
}

ensure_stale_cuda_repo_absent() { ensure_root_file_absent "$CUDA_STALE_REPO_FILE"; }

# The repo file is vekrona's own: the key comes from the pinned vendored file, and includepkgs admits only the toolkit.
ensure_cuda_repo() {
  ensure_repo_key "$CUDA_KEY_REPO"
  ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/$CUDA_REPO_FILE_NAME" "/etc/yum.repos.d/$CUDA_REPO_FILE_NAME"
  # Earlier installs let `dnf config-manager addrepo` fetch NVIDIA's own repo file and kept the driver out with a denylist.
  ensure_repo_override_absent "$CUDA_REPO_ID" excludepkgs
  ensure_repo_enabled "$CUDA_REPO_ID"
  ensure_stale_cuda_repo_absent
}
