#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/authselect-vekrona.sh"
source "$ROOT/lib/luks-fido2.sh"
source "$ROOT/lib/pam-u2f.sh"

PROFILE_NAME=vekrona
PROFILE_ID="custom/$PROFILE_NAME"
PROFILE_DIR="/etc/authselect/custom/$PROFILE_NAME"
PROFILE_FEATURES=(with-silent-lastlog with-fingerprint with-mdns4 with-pam-u2f)

ensure_pkg pam-u2f yubikey-manager pamu2fcfg fido2-tools libfido2 fprintd fprintd-pam cryptsetup
require_cmd authselect cryptsetup dracut lsinitrd jq findfs

render_profile() {
  render_authselect_profile "$(authselect_base_dir)" "$1"
}

install_profile() {
  local rendered="$1" f
  root rm -rf "$PROFILE_DIR"
  root install -d -m 0755 "$PROFILE_DIR"
  for f in "$rendered"/*; do
    root install -m 0644 "$f" "$PROFILE_DIR/$(basename "$f")"
  done
  root diff -r "$rendered" "$PROFILE_DIR" >/dev/null || die "profile content mismatch after install: $PROFILE_DIR"
}

profile_matches_rendered() {
  render_profile "$1"
  [[ -d "$PROFILE_DIR" ]] && root diff -r "$1" "$PROFILE_DIR" >/dev/null
}

render_and_install_profile() {
  render_profile "$1"
  install_profile "$1"
}

ensure_profile_files() {
  if with_scratch_dir profile_matches_rendered; then
    log "authselect profile up to date: $PROFILE_ID"
    profile_files_changed=0
  else
    log "writing authselect profile: $PROFILE_ID"
    with_scratch_dir render_and_install_profile
    profile_files_changed=1
  fi
}

current_authselect_selection() {
  local raw
  raw="$(authselect current --raw 2>/dev/null || true)"
  tr ' ' '\n' <<<"$raw" | sed '/^$/d' | sort | paste -sd' '
}

wanted_authselect_selection() {
  printf '%s\n' "$PROFILE_ID" "${PROFILE_FEATURES[@]}" | sort | paste -sd' '
}

previous_profile_id() {
  local raw
  raw="$(authselect current --raw 2>/dev/null || true)"
  printf '%s' "${raw%% *}"
}

ensure_authselect_selection() {
  local previous
  previous="$(previous_profile_id)"
  ensure_profile_files
  if [[ "$(current_authselect_selection)" == "$(wanted_authselect_selection)" ]]; then
    if [[ "$profile_files_changed" -eq 1 ]]; then
      log "reapplying authselect profile after content change"
      root authselect apply-changes
    else
      log "authselect already selects $PROFILE_ID with: ${PROFILE_FEATURES[*]}"
    fi
  else
    log "selecting $PROFILE_ID with: ${PROFILE_FEATURES[*]}"
    root authselect select "$PROFILE_ID" "${PROFILE_FEATURES[@]}"
    if [[ "$previous" == custom/yubikey ]]; then
      warn "pam_u2f origin changed from the hostname to pam://vekrona: re-register your key once with:"
      warn "  pamu2fcfg -o pam://vekrona -i pam://vekrona | sudo tee $U2F_MAPPINGS"
    fi
  fi
  [[ "$(current_authselect_selection)" == "$(wanted_authselect_selection)" ]] || die "authselect selection not applied: $PROFILE_ID"
  root authselect check || die "authselect check failed"
}

# Images with a .bak next to them: the rollback if a rebuild fails; removed once every image is verified.
initramfs_backups=()

# Under the kernel lock, so akmods' own pass over the image does not run at the same time. A .bak left by an earlier,
# failed run is the good image and stays as it is.
rebuild_initramfs() { with_kernel_lock rebuild_initramfs_locked "$1"; }

rebuild_initramfs_locked() {
  local kver="$1" img
  img="$(initramfs_path "$kver")"
  root test -e "$img.bak" || root cp -p "$img" "$img.bak"
  initramfs_backups+=("$img.bak")
  log "rebuilding initramfs for $kver (rollback: sudo cp -p $img.bak $img)"
  dracut_locked -f "$img" "$kver" || die "dracut failed for $kver; the previous image is $img.bak"
}

install_crypttab_from() {
  local content="$1" scratch="$2"
  printf '%s\n' "$content" >"$scratch/crypttab"
  root install -m 0644 "$scratch/crypttab" "$CRYPTTAB"
}

install_crypttab() {
  with_scratch_dir install_crypttab_from "$1"
}

ensure_luks_fido2_unlock() {
  local entries name dev state kver kvers crypttab_changed=0 current wanted
  local -a token_names=()
  current="$(read_crypttab)"
  entries="$(crypttab_fido2_tokens "$current")"
  while IFS=$'\t' read -r name dev state; do
    if [[ -z "$name" ]]; then
      continue
    fi
    if [[ "$state" == yes ]]; then
      log "FIDO2 token present on $dev ($name)"
      token_names+=("$name")
    else
      log "no FIDO2 token on $dev ($name)"
    fi
  done <<<"$entries"

  if [[ ${#token_names[@]} -eq 0 ]]; then
    log "no LUKS2 device with a systemd-fido2 token, crypttab and initramfs left alone"
    return 0
  fi

  wanted="$(crypttab_with_fido2 "$current" "${token_names[@]}")"
  if [[ "$wanted" != "$current" ]]; then
    log "adding fido2-device to crypttab for: ${token_names[*]}"
    install_crypttab "$wanted"
    crypttab_changed=1
  else
    log "crypttab already carries fido2-device for: ${token_names[*]}"
  fi

  kvers="$(kvers_with_initramfs)"
  [[ -n "$kvers" ]] || die "no installed kernel has an initramfs"
  while IFS= read -r kver; do
    if [[ "$crypttab_changed" -eq 1 ]] || ! initramfs_carries_fido2 "$kver"; then
      rebuild_initramfs "$kver"
    else
      log "initramfs for $kver already carries FIDO2 unlock"
    fi
  done <<<"$kvers"

  current="$(read_crypttab)"
  for name in "${token_names[@]}"; do
    assert "crypttab entry $name has fido2-device" crypttab_line_has_fido2 "$current" "$name"
  done
  while IFS= read -r kver; do
    assert "initramfs for $kver carries FIDO2 unlock" initramfs_carries_fido2 "$kver"
  done <<<"$kvers"
  if [[ ${#initramfs_backups[@]} -gt 0 ]]; then
    log "removing the initramfs backups: ${initramfs_backups[*]}"
    root rm -f "${initramfs_backups[@]}"
  fi
}

ensure_authselect_selection
ensure_u2f_mappings
ensure_luks_fido2_unlock
for pam in vekrona-lock-password vekrona-lock-u2f vekrona-lock-fprint; do
  ensure_root_file "$ROOT/etc/pam.d/$pam" "/etc/pam.d/$pam"
done
ensure_root_file_absent /etc/pam.d/dankshell-u2f # the lock screen was DMS's before vekrona-lock
